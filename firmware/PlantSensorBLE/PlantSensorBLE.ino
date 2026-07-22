#include <Wire.h>
#include <Adafruit_SHT31.h>
#include <BH1750.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <FS.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <sys/time.h>
#include <time.h>

// ---------- Hardware ----------
constexpr uint8_t I2C_SDA_PIN = 21;
constexpr uint8_t I2C_SCL_PIN = 22;
constexpr uint8_t SOIL_ADC_PIN = 34;
constexpr uint8_t SHT31_ADDRESS = 0x44;
constexpr uint8_t BH1750_ADDRESS = 0x23;

// BH1750 已焊接并接入共享 I2C 总线。
constexpr bool ENABLE_BH1750 = true;
constexpr unsigned long SAMPLE_INTERVAL_MS = 5UL * 60UL * 1000UL;
constexpr unsigned long BOOT_TIME_SYNC_GRACE_MS = 15UL * 1000UL;

// ---------- BLE protocol ----------
constexpr uint8_t PROTOCOL_VERSION = 1;
constexpr size_t LIVE_PACKET_SIZE = 16;
constexpr size_t HISTORY_PACKET_SIZE = 20;
constexpr uint16_t MAX_HISTORY_BATCH_SIZE = 64;
constexpr unsigned long HISTORY_NOTIFY_INTERVAL_MS = 20;
// Restart advertising only after the BLE stack has finished tearing down the
// previous GATT link. Starting it directly inside onDisconnect can race the
// controller cleanup and leave both iOS and Web unable to discover the device.
constexpr unsigned long ADVERTISING_RESTART_DELAY_MS = 250;

constexpr uint8_t HISTORY_TYPE_RECORD = 0x01;
constexpr uint8_t HISTORY_TYPE_BATCH_END = 0x02;
constexpr uint8_t HISTORY_TYPE_FAILURE = 0x03;
constexpr uint8_t COMMAND_REQUEST_AFTER_SEQUENCE = 0x10;
constexpr uint8_t COMMAND_ACKNOWLEDGE_SEQUENCE = 0x11;
constexpr uint8_t COMMAND_SET_UNIX_TIME = 0x12;
// Takes one extra sample immediately. It intentionally does not reset the
// five-minute scheduler's lastSampleTime.
constexpr uint8_t COMMAND_REQUEST_IMMEDIATE_SAMPLE = 0x13;

constexpr uint8_t FLAG_SHT31_VALID = 0x01;
constexpr uint8_t FLAG_BH1750_VALID = 0x02;
constexpr uint8_t FLAG_TIME_ESTIMATED = 0x04;

constexpr char DEVICE_NAME[] = "Plant Sensor";
constexpr char SERVICE_UUID[] = "7A1E0001-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr char DATA_CHARACTERISTIC_UUID[] = "7A1E0002-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr char CONTROL_CHARACTERISTIC_UUID[] = "7A1E0003-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr char HISTORY_CHARACTERISTIC_UUID[] = "7A1E0004-7C6D-4A8B-9E1F-2D3C4B5A6000";

// ---------- LittleFS ring storage ----------
constexpr char HISTORY_FILE_PATH[] = "/history.bin";
constexpr size_t HISTORY_FS_RESERVE_BYTES = 64UL * 1024UL;
constexpr uint32_t SEQUENCE_RESERVATION_SIZE = 1024;
constexpr uint32_t MIN_REASONABLE_UNIX_TIME = 1704067200UL;  // 2024-01-01 UTC

Adafruit_SHT31 sht31;
BH1750 lightMeter;
BLECharacteristic *dataCharacteristic = nullptr;
BLECharacteristic *historyCharacteristic = nullptr;
QueueHandle_t controlCommandQueue = nullptr;
Preferences sequencePreferences;

bool sht31Ready = false;
bool bh1750Ready = false;
const char *i2cPinTestResult = "not run";
uint8_t lastI2CAddressFound = 0;
volatile bool clientConnected = false;
volatile bool advertisingRestartPending = false;
volatile unsigned long advertisingRestartRequestedAt = 0;
bool historyStorageReady = false;
bool clockEstimated = true;
bool initialSamplePending = true;
unsigned long lastSampleTime = 0;
unsigned long initialSampleDeadline = 0;

uint32_t historyCapacity = 0;
uint32_t historyCount = 0;
uint32_t oldestSequence = 0;
uint32_t newestSequence = 0;
uint32_t nextSequence = 1;
uint32_t newestTimestamp = 0;
uint32_t sequenceReservationEnd = 0;

enum class QueuedCommandType : uint8_t {
  RequestHistory,
  Acknowledge,
  SetUnixTime,
  RequestImmediateSample,
  SendFailure
};

struct QueuedCommand {
  QueuedCommandType type;
  uint32_t value;
  uint16_t limit;
};

struct SensorSample {
  uint8_t flags;
  uint16_t soilRaw;
  float temperature;
  float humidity;
  float lightLux;
};

// ---------- Binary helpers ----------
void writeUInt16LE(uint8_t *target, uint16_t value) {
  target[0] = value & 0xFF;
  target[1] = (value >> 8) & 0xFF;
}

void writeInt16LE(uint8_t *target, int16_t value) {
  writeUInt16LE(target, static_cast<uint16_t>(value));
}

void writeUInt32LE(uint8_t *target, uint32_t value) {
  target[0] = value & 0xFF;
  target[1] = (value >> 8) & 0xFF;
  target[2] = (value >> 16) & 0xFF;
  target[3] = (value >> 24) & 0xFF;
}

uint16_t readUInt16LE(const uint8_t *source) {
  return static_cast<uint16_t>(source[0])
    | (static_cast<uint16_t>(source[1]) << 8);
}

uint32_t readUInt32LE(const uint8_t *source) {
  return static_cast<uint32_t>(source[0])
    | (static_cast<uint32_t>(source[1]) << 8)
    | (static_cast<uint32_t>(source[2]) << 16)
    | (static_cast<uint32_t>(source[3]) << 24);
}

void writeFloatLE(uint8_t *target, float value) {
  static_assert(sizeof(float) == 4, "This packet requires 32-bit float.");
  uint32_t bits;
  memcpy(&bits, &value, sizeof(bits));
  writeUInt32LE(target, bits);
}

uint8_t historyChecksum(const uint8_t *data, size_t length) {
  uint8_t crc = 0;
  for (size_t index = 0; index < length; ++index) {
    if (index == 3) {
      continue;
    }
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x80) == 0
        ? static_cast<uint8_t>(crc << 1)
        : static_cast<uint8_t>((crc << 1) ^ 0x07);
    }
  }
  return crc;
}

bool isValidStoredRecord(const uint8_t *packet) {
  return packet[0] == PROTOCOL_VERSION
    && packet[1] == HISTORY_TYPE_RECORD
    && packet[3] == historyChecksum(packet, HISTORY_PACKET_SIZE)
    && readUInt32LE(packet + 4) > 0
    && readUInt32LE(packet + 8) > 0;
}

// ---------- Clock ----------
int monthNumber(const char *month) {
  constexpr char monthNames[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
  const char *match = strstr(monthNames, month);
  return match == nullptr ? 1 : static_cast<int>((match - monthNames) / 3) + 1;
}

// Gregorian civil date to Unix days, adapted to avoid timezone-dependent mktime().
int64_t daysFromCivil(int year, unsigned month, unsigned day) {
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yearOfEra = static_cast<unsigned>(year - era * 400);
  const unsigned dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  const unsigned dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
  return static_cast<int64_t>(era) * 146097 + static_cast<int64_t>(dayOfEra) - 719468;
}

uint32_t buildUnixTime() {
  char month[4] = {};
  int day = 1;
  int year = 2024;
  int hour = 0;
  int minute = 0;
  int second = 0;
  sscanf(__DATE__, "%3s %d %d", month, &day, &year);
  sscanf(__TIME__, "%d:%d:%d", &hour, &minute, &second);
  const int64_t days = daysFromCivil(year, monthNumber(month), day);
  return static_cast<uint32_t>(days * 86400 + hour * 3600 + minute * 60 + second);
}

void setSystemClock(uint32_t unixTime, bool estimated) {
  timeval now = {};
  now.tv_sec = unixTime;
  settimeofday(&now, nullptr);
  clockEstimated = estimated;
}

uint32_t currentUnixTime() {
  const time_t now = time(nullptr);
  return now >= MIN_REASONABLE_UNIX_TIME
    ? static_cast<uint32_t>(now)
    : buildUnixTime() + millis() / 1000;
}

// ---------- LittleFS ring storage ----------
bool readHistoryRecord(File &file, uint32_t sequence, uint8_t *packet) {
  if (sequence == 0 || historyCapacity == 0) {
    return false;
  }
  const uint32_t slot = (sequence - 1) % historyCapacity;
  const size_t offset = static_cast<size_t>(slot) * HISTORY_PACKET_SIZE;
  if (offset + HISTORY_PACKET_SIZE > file.size() || !file.seek(offset, SeekSet)) {
    return false;
  }
  if (file.read(packet, HISTORY_PACKET_SIZE) != HISTORY_PACKET_SIZE) {
    return false;
  }
  return isValidStoredRecord(packet) && readUInt32LE(packet + 4) == sequence;
}

void restoreHistoryState() {
  historyCount = 0;
  oldestSequence = 0;
  newestSequence = 0;
  newestTimestamp = 0;
  nextSequence = 1;

  File file = LittleFS.open(HISTORY_FILE_PATH, "r");
  if (!file) {
    Serial.println("History file does not exist yet.");
    return;
  }

  const uint32_t slots = min(
    historyCapacity,
    static_cast<uint32_t>(file.size() / HISTORY_PACKET_SIZE)
  );
  uint8_t packet[HISTORY_PACKET_SIZE] = {};

  for (uint32_t slot = 0; slot < slots; ++slot) {
    if (!file.seek(static_cast<size_t>(slot) * HISTORY_PACKET_SIZE, SeekSet)
        || file.read(packet, sizeof(packet)) != sizeof(packet)
        || !isValidStoredRecord(packet)) {
      continue;
    }

    const uint32_t sequence = readUInt32LE(packet + 4);
    ++historyCount;
    if (oldestSequence == 0 || sequence < oldestSequence) {
      oldestSequence = sequence;
    }
    if (sequence > newestSequence) {
      newestSequence = sequence;
      newestTimestamp = readUInt32LE(packet + 8);
    }
  }
  file.close();

  if (newestSequence > 0 && newestSequence < UINT32_MAX) {
    nextSequence = newestSequence + 1;
  }

  Serial.printf(
    "History restored: %lu records, sequence %lu...%lu, next %lu.\n",
    static_cast<unsigned long>(historyCount),
    static_cast<unsigned long>(oldestSequence),
    static_cast<unsigned long>(newestSequence),
    static_cast<unsigned long>(nextSequence)
  );
}

bool reserveSequenceRangeIfNeeded() {
  if (nextSequence < sequenceReservationEnd) {
    return true;
  }
  if (nextSequence == 0 || nextSequence > UINT32_MAX - SEQUENCE_RESERVATION_SIZE) {
    Serial.println("ERROR: History sequence space exhausted.");
    return false;
  }

  sequenceReservationEnd = nextSequence + SEQUENCE_RESERVATION_SIZE;
  if (sequencePreferences.putULong("seqEnd", sequenceReservationEnd) != sizeof(uint32_t)) {
    Serial.println("ERROR: Could not reserve history sequence range in NVS.");
    sequenceReservationEnd = 0;
    return false;
  }
  Serial.printf(
    "Reserved history sequences through %lu in NVS.\n",
    static_cast<unsigned long>(sequenceReservationEnd - 1)
  );
  return true;
}

void initializeSequenceReservation() {
  if (!sequencePreferences.begin("planttalk", false)) {
    Serial.println("ERROR: Could not open sequence NVS namespace; history disabled.");
    historyStorageReady = false;
    return;
  }

  const bool hadReservation = sequencePreferences.isKey("seqEnd");
  sequenceReservationEnd = sequencePreferences.getULong("seqEnd", 0);

  // A valid NVS reservation with an empty/reformatted LittleFS means previously
  // issued sequence numbers must not be reused. Skip to the reserved boundary.
  if (hadReservation && historyCount == 0 && sequenceReservationEnd > nextSequence) {
    nextSequence = sequenceReservationEnd;
  }
  if (!reserveSequenceRangeIfNeeded()) {
    historyStorageReady = false;
  }
}

void initializeHistoryStorage() {
  if (!LittleFS.begin(false)) {
    Serial.println("LittleFS mount failed; formatting once.");
    if (!LittleFS.begin(true)) {
      Serial.println("ERROR: LittleFS format/mount failed; history disabled.");
      return;
    }
  }

  const size_t totalBytes = LittleFS.totalBytes();
  const size_t reserveBytes = min(HISTORY_FS_RESERVE_BYTES, totalBytes / 4);
  if (totalBytes <= reserveBytes + HISTORY_PACKET_SIZE) {
    Serial.println("ERROR: LittleFS partition is too small; history disabled.");
    return;
  }

  historyCapacity = static_cast<uint32_t>(
    (totalBytes - reserveBytes) / HISTORY_PACKET_SIZE
  );
  historyStorageReady = historyCapacity > 0;
  restoreHistoryState();
  initializeSequenceReservation();

  Serial.printf(
    "LittleFS: total=%u, used=%u, history capacity=%lu records (~%lu days).\n",
    static_cast<unsigned>(totalBytes),
    static_cast<unsigned>(LittleFS.usedBytes()),
    static_cast<unsigned long>(historyCapacity),
    static_cast<unsigned long>(historyCapacity / 288)
  );
}

int16_t encodeTemperature(float value) {
  if (isnan(value)) {
    return 0;
  }
  const float scaled = roundf(value * 100.0f);
  return static_cast<int16_t>(constrain(scaled, -32768.0f, 32767.0f));
}

uint16_t encodeUnsignedHundredths(float value, float maximum) {
  if (isnan(value)) {
    return 0;
  }
  return static_cast<uint16_t>(roundf(constrain(value, 0.0f, maximum) * 100.0f));
}

bool appendHistoryRecord(const SensorSample &sample) {
  if (!historyStorageReady || !reserveSequenceRangeIfNeeded()) {
    return false;
  }

  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  packet[0] = PROTOCOL_VERSION;
  packet[1] = HISTORY_TYPE_RECORD;
  packet[2] = sample.flags | (clockEstimated ? FLAG_TIME_ESTIMATED : 0);
  writeUInt32LE(packet + 4, nextSequence);
  writeUInt32LE(packet + 8, currentUnixTime());
  writeUInt16LE(packet + 12, sample.soilRaw);
  writeInt16LE(packet + 14, encodeTemperature(sample.temperature));
  writeUInt16LE(packet + 16, encodeUnsignedHundredths(sample.humidity, 100.0f));
  const float clampedLux = isnan(sample.lightLux)
    ? 0.0f
    : constrain(sample.lightLux, 0.0f, 65535.0f);
  writeUInt16LE(packet + 18, static_cast<uint16_t>(roundf(clampedLux)));
  packet[3] = historyChecksum(packet, sizeof(packet));

  File file = LittleFS.open(HISTORY_FILE_PATH, LittleFS.exists(HISTORY_FILE_PATH) ? "r+" : "w+");
  if (!file) {
    Serial.println("ERROR: Could not open history ring file.");
    return false;
  }

  const uint32_t slot = (nextSequence - 1) % historyCapacity;
  const size_t offset = static_cast<size_t>(slot) * HISTORY_PACKET_SIZE;
  const bool stored = file.seek(offset, SeekSet)
    && file.write(packet, sizeof(packet)) == sizeof(packet);
  file.flush();
  file.close();

  if (!stored) {
    Serial.println("ERROR: Could not write history record.");
    return false;
  }

  newestSequence = nextSequence;
  newestTimestamp = readUInt32LE(packet + 8);
  if (historyCount < historyCapacity) {
    ++historyCount;
  }
  oldestSequence = newestSequence >= historyCount
    ? newestSequence - historyCount + 1
    : 1;
  ++nextSequence;

  Serial.printf(
    "History stored: sequence=%lu, slot=%lu, count=%lu.\n",
    static_cast<unsigned long>(newestSequence),
    static_cast<unsigned long>(slot),
    static_cast<unsigned long>(historyCount)
  );
  return true;
}

// ---------- Sensors ----------
uint8_t scanI2C() {
  Serial.println("Scanning I2C bus...");
  uint8_t count = 0;
  lastI2CAddressFound = 0;
  for (uint8_t address = 1; address < 127; ++address) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      Serial.printf("I2C device found at 0x%02X\n", address);
      lastI2CAddressFound = address;
      ++count;
    }
  }
  if (count == 0) {
    Serial.println("No I2C devices found. Check wiring.");
  }
  return count;
}

void selectI2CPinOrder() {
  // Give the serial monitor time to attach after the upload-triggered reset.
  delay(3000);
  Serial.printf(
    "I2C test A: SDA=D%u, SCL=D%u\n",
    I2C_SDA_PIN,
    I2C_SCL_PIN
  );
  if (scanI2C() > 0) {
    i2cPinTestResult = "A: SDA=D21, SCL=D22";
    Serial.println("I2C test A selected.");
    return;
  }

  Wire.end();
  delay(20);
  Wire.begin(I2C_SCL_PIN, I2C_SDA_PIN);
  Wire.setClock(100000);
  Serial.printf(
    "I2C test B: SDA=D%u, SCL=D%u (swapped)\n",
    I2C_SCL_PIN,
    I2C_SDA_PIN
  );
  if (scanI2C() > 0) {
    i2cPinTestResult = "B: SDA=D22, SCL=D21";
    Serial.println("I2C test B selected.");
    return;
  }

  // Leave the bus in its documented pin order when neither test responds.
  Wire.end();
  delay(20);
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(100000);
  i2cPinTestResult = "none: A and B both found no device";
  Serial.println("Neither I2C pin order found a device; restored test A order.");
}

void initializeSensors() {
  if (!sht31Ready) {
    sht31Ready = sht31.begin(SHT31_ADDRESS);
    Serial.println(sht31Ready
      ? "SHT31 initialized."
      : "ERROR: SHT31 not found at 0x44; will retry.");
  }

  if (ENABLE_BH1750 && !bh1750Ready) {
    bh1750Ready = lightMeter.begin(
      BH1750::CONTINUOUS_HIGH_RES_MODE,
      BH1750_ADDRESS,
      &Wire
    );
    Serial.println(bh1750Ready
      ? "BH1750 initialized."
      : "ERROR: BH1750 not found at 0x23; will retry.");
  }
}

SensorSample readSensors() {
  initializeSensors();
  SensorSample sample = {0, 0, NAN, NAN, NAN};

  if (sht31Ready) {
    sample.temperature = sht31.readTemperature();
    sample.humidity = sht31.readHumidity();
    if (!isnan(sample.temperature) && !isnan(sample.humidity)) {
      sample.flags |= FLAG_SHT31_VALID;
    } else {
      Serial.println("ERROR: SHT31 read failed; will reinitialize.");
      sht31Ready = false;
    }
  }

  if (ENABLE_BH1750 && bh1750Ready && lightMeter.measurementReady()) {
    sample.lightLux = lightMeter.readLightLevel();
    if (sample.lightLux >= 0) {
      sample.flags |= FLAG_BH1750_VALID;
    } else {
      sample.lightLux = NAN;
      bh1750Ready = false;
    }
  }

  sample.soilRaw = static_cast<uint16_t>(analogRead(SOIL_ADC_PIN));
  return sample;
}

void publishLiveReading(const SensorSample &sample) {
  uint8_t packet[LIVE_PACKET_SIZE] = {};
  packet[0] = PROTOCOL_VERSION;
  packet[1] = sample.flags;
  writeUInt16LE(packet + 2, sample.soilRaw);
  writeFloatLE(packet + 4, sample.temperature);
  writeFloatLE(packet + 8, sample.humidity);
  writeFloatLE(packet + 12, sample.lightLux);

  dataCharacteristic->setValue(packet, sizeof(packet));
  if (clientConnected) {
    dataCharacteristic->notify();
  }
}

void sampleStoreAndPublish() {
  const SensorSample sample = readSensors();
  Serial.printf(
    "I2C pin test result: %s; last address: 0x%02X\n",
    i2cPinTestResult,
    lastI2CAddressFound
  );
  Serial.printf("Temp: %.1f C\n", sample.temperature);
  Serial.printf("Air Humidity: %.1f %%\n", sample.humidity);
  if (sample.flags & FLAG_BH1750_VALID) {
    Serial.printf("Light: %.0f lx\n", sample.lightLux);
  } else {
    Serial.println("Light: unavailable");
  }
  Serial.printf("Soil ADC Raw: %u\n", sample.soilRaw);

  appendHistoryRecord(sample);
  publishLiveReading(sample);
  Serial.println("----------------------");
}

// ---------- History transfer ----------
void sendHistoryFailure(uint16_t code) {
  if (!clientConnected || historyCharacteristic == nullptr) {
    return;
  }
  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  packet[0] = PROTOCOL_VERSION;
  packet[1] = HISTORY_TYPE_FAILURE;
  writeUInt16LE(packet + 4, code);
  packet[3] = historyChecksum(packet, sizeof(packet));
  historyCharacteristic->setValue(packet, sizeof(packet));
  historyCharacteristic->notify();
}

void sendBatchEnd(
  uint32_t firstSequence,
  uint32_t lastSequence,
  uint8_t recordCount,
  uint32_t remainingCount
) {
  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  packet[0] = PROTOCOL_VERSION;
  packet[1] = HISTORY_TYPE_BATCH_END;
  packet[2] = recordCount;
  writeUInt32LE(packet + 4, lastSequence);
  writeUInt32LE(packet + 8, remainingCount);
  writeUInt32LE(packet + 12, newestSequence);
  writeUInt32LE(packet + 16, firstSequence);
  packet[3] = historyChecksum(packet, sizeof(packet));
  historyCharacteristic->setValue(packet, sizeof(packet));
  historyCharacteristic->notify();
}

void sendHistoryBatch(uint32_t afterSequence, uint16_t requestedLimit) {
  if (!clientConnected) {
    return;
  }
  if (!historyStorageReady) {
    sendHistoryFailure(2);
    return;
  }

  const uint16_t limit = constrain(
    requestedLimit == 0 ? MAX_HISTORY_BATCH_SIZE : requestedLimit,
    static_cast<uint16_t>(1),
    MAX_HISTORY_BATCH_SIZE
  );

  if (historyCount == 0 || afterSequence >= newestSequence) {
    sendBatchEnd(0, afterSequence, 0, 0);
    return;
  }

  File file = LittleFS.open(HISTORY_FILE_PATH, "r");
  if (!file) {
    sendHistoryFailure(3);
    return;
  }

  uint32_t candidate = afterSequence == UINT32_MAX ? UINT32_MAX : afterSequence + 1;
  if (candidate < oldestSequence) {
    candidate = oldestSequence;
  }

  uint16_t sent = 0;
  uint32_t firstSent = 0;
  uint32_t lastSent = afterSequence;
  uint8_t packet[HISTORY_PACKET_SIZE] = {};

  while (candidate <= newestSequence && sent < limit && clientConnected) {
    if (!readHistoryRecord(file, candidate, packet)) {
      if (sent > 0) {
        break;
      }
      ++candidate;
      continue;
    }

    historyCharacteristic->setValue(packet, sizeof(packet));
    historyCharacteristic->notify();
    if (sent == 0) {
      firstSent = candidate;
    }
    lastSent = candidate;
    ++sent;
    ++candidate;
    delay(HISTORY_NOTIFY_INTERVAL_MS);
  }
  file.close();

  if (!clientConnected) {
    return;
  }
  if (sent == 0 && afterSequence < newestSequence) {
    sendHistoryFailure(5);
    return;
  }
  const uint32_t remaining = lastSent < newestSequence
    ? newestSequence - lastSent
    : 0;
  // The end marker declares the exact contiguous range attempted by this
  // batch. iOS compares it with the notifications actually received before
  // committing, so a lost prefix cannot silently advance the durable cursor.
  sendBatchEnd(firstSent, lastSent, static_cast<uint8_t>(sent), remaining);

  Serial.printf(
    "History batch: after=%lu, sent=%u, last=%lu, remaining=%lu.\n",
    static_cast<unsigned long>(afterSequence),
    sent,
    static_cast<unsigned long>(lastSent),
    static_cast<unsigned long>(remaining)
  );
}

void enqueueCommand(const QueuedCommand &command) {
  if (controlCommandQueue == nullptr
      || xQueueSend(controlCommandQueue, &command, 0) != pdTRUE) {
    Serial.println("ERROR: BLE control command queue is full.");
  }
}

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const uint8_t *data = characteristic->getData();
    const size_t length = characteristic->getLength();
    if (data == nullptr || length < 2 || data[0] != PROTOCOL_VERSION) {
      enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
      return;
    }

    switch (data[1]) {
      case COMMAND_REQUEST_AFTER_SEQUENCE:
        if (length != 8) {
          enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
          return;
        }
        enqueueCommand({
          QueuedCommandType::RequestHistory,
          readUInt32LE(data + 2),
          readUInt16LE(data + 6)
        });
        break;

      case COMMAND_ACKNOWLEDGE_SEQUENCE:
        if (length != 6) {
          enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
          return;
        }
        enqueueCommand({
          QueuedCommandType::Acknowledge,
          readUInt32LE(data + 2),
          0
        });
        break;

      case COMMAND_SET_UNIX_TIME:
        if (length != 6) {
          enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
          return;
        }
        enqueueCommand({
          QueuedCommandType::SetUnixTime,
          readUInt32LE(data + 2),
          0
        });
        break;

      case COMMAND_REQUEST_IMMEDIATE_SAMPLE:
        if (length != 2) {
          enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
          return;
        }
        enqueueCommand({QueuedCommandType::RequestImmediateSample, 0, 0});
        break;

      default:
        enqueueCommand({QueuedCommandType::SendFailure, 1, 0});
        break;
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    clientConnected = true;
    advertisingRestartPending = false;
    Serial.println("BLE client connected.");
  }

  void onDisconnect(BLEServer *server) override {
    clientConnected = false;
    if (controlCommandQueue != nullptr) {
      xQueueReset(controlCommandQueue);
    }
    advertisingRestartRequestedAt = millis();
    advertisingRestartPending = true;
    Serial.println("BLE client disconnected; advertising restart scheduled.");
  }
};

void restartAdvertisingAfterDisconnect() {
  if (!advertisingRestartPending || clientConnected) {
    return;
  }

  const unsigned long requestedAt = advertisingRestartRequestedAt;
  if (millis() - requestedAt < ADVERTISING_RESTART_DELAY_MS) {
    return;
  }

  advertisingRestartPending = false;
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising restarted; waiting for one client.");
}

void initializeBLE() {
  controlCommandQueue = xQueueCreate(8, sizeof(QueuedCommand));
  BLEDevice::init(DEVICE_NAME);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(SERVICE_UUID);

  dataCharacteristic = service->createCharacteristic(
    DATA_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  dataCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *controlCharacteristic = service->createCharacteristic(
    CONTROL_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  controlCharacteristic->setCallbacks(new ControlCallbacks());

  historyCharacteristic = service->createCharacteristic(
    HISTORY_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  historyCharacteristic->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE advertising with live, control, and history characteristics.");
}

void processControlCommands() {
  if (controlCommandQueue == nullptr) {
    return;
  }
  QueuedCommand command = {};
  if (xQueueReceive(controlCommandQueue, &command, 0) != pdTRUE) {
    return;
  }

  switch (command.type) {
    case QueuedCommandType::RequestHistory:
      sendHistoryBatch(command.value, command.limit);
      break;
    case QueuedCommandType::Acknowledge:
      Serial.printf(
        "App persisted history through sequence %lu.\n",
        static_cast<unsigned long>(command.value)
      );
      break;
    case QueuedCommandType::SetUnixTime:
      if (command.value >= MIN_REASONABLE_UNIX_TIME) {
        setSystemClock(command.value, false);
        Serial.printf(
          "Clock synchronized by iPhone: %lu.\n",
          static_cast<unsigned long>(command.value)
        );
      } else {
        sendHistoryFailure(4);
      }
      break;
    case QueuedCommandType::RequestImmediateSample:
      Serial.println("Immediate sample requested by app.");
      // This creates a normal extra history record and live notification, but
      // deliberately leaves lastSampleTime untouched so the scheduled 5-minute
      // rhythm remains anchored to its original cadence.
      sampleStoreAndPublish();
      break;
    case QueuedCommandType::SendFailure:
      sendHistoryFailure(static_cast<uint16_t>(command.value));
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(100000);
  pinMode(SOIL_ADC_PIN, INPUT);
  analogReadResolution(12);
  analogSetPinAttenuation(SOIL_ADC_PIN, ADC_11db);

  Serial.println("ESP32 Plant Sensor BLE + LittleFS History");
  initializeHistoryStorage();

  // After a reboot, the last stored time is the best available approximation until
  // the iPhone sends command 0x12. Exact time across power loss requires RTC or NTP.
  const uint32_t startupTime = newestTimestamp >= MIN_REASONABLE_UNIX_TIME
    ? newestTimestamp + SAMPLE_INTERVAL_MS / 1000
    : buildUnixTime();
  setSystemClock(startupTime, true);

  selectI2CPinOrder();
  initializeSensors();
  initializeBLE();

  // Give a nearby iPhone time to connect and send command 0x12. If no phone is
  // available, the first sample still proceeds with an explicitly estimated time.
  Serial.println("Waiting up to 15 seconds for iPhone time sync before first sample.");
  lastSampleTime = millis();
  initialSampleDeadline = lastSampleTime + BOOT_TIME_SYNC_GRACE_MS;
}

void loop() {
  restartAdvertisingAfterDisconnect();
  processControlCommands();

  const unsigned long now = millis();
  if (initialSamplePending
      && (!clockEstimated
          || static_cast<long>(now - initialSampleDeadline) >= 0)) {
    initialSamplePending = false;
    lastSampleTime = now;
    sampleStoreAndPublish();
  } else if (!initialSamplePending && now - lastSampleTime >= SAMPLE_INTERVAL_MS) {
    lastSampleTime = now;
    sampleStoreAndPublish();
  }
  delay(5);
}
