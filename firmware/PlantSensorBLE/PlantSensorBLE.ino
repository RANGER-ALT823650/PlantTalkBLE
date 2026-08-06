#include <Wire.h>
#include <Adafruit_SHT31.h>
#include <BH1750.h>
#include <NimBLEDevice.h>
#include <FS.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <sys/time.h>
#include <time.h>

// The no-cloud branch is intentionally BLE-only even if a developer has an
// ignored CloudConfig.h beside the sketch. This keeps the main ESP32 local.
// The OLED display has hard connection priority over iOS and Web: when its
// advertisement appears, this board disconnects the current app/browser and
// connects to the display itself.
#define PLANT_CLOUD_ENABLED 0
#if PLANT_CLOUD_ENABLED
#include "CloudConfig.h"
#include <esp_sntp.h>
#include <HTTPClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <freertos/task.h>
#endif

// ---------- Hardware ----------
constexpr uint8_t STATUS_LED_PIN = 2;
// This board's blue status LED is driven high. Keep the polarity in one place
// so a future board revision with an active-low LED only needs these two values
// changed.
constexpr uint8_t STATUS_LED_ON_LEVEL = HIGH;
constexpr uint8_t STATUS_LED_OFF_LEVEL = LOW;
constexpr unsigned long WIFI_SEARCH_LED_TOGGLE_MS = 500;
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

// The ESP32-C3 display is deliberately a different GATT service from the
// phone/browser service above. It advertises this service continuously; the
// main ESP32 scans for it and becomes the BLE central for that link.
constexpr char DISPLAY_NAME[] = "Plant Display";
constexpr char DISPLAY_SERVICE_UUID[] = "7A1E1001-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr char DISPLAY_DATA_CHARACTERISTIC_UUID[] = "7A1E1002-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr unsigned long DISPLAY_RETRY_DELAY_MS = 250;

#if PLANT_CLOUD_ENABLED
// ---------- Cloud command mailbox ----------
// Poll cadence. The cloud expires an unclaimed command after 60 s, so this must
// stay well below that or a request can expire before the device ever sees it.
constexpr unsigned long CLOUD_POLL_INTERVAL_MS = 3000;
// Backoff applied after a failed poll, so a flaky link or a cold cloud function
// does not turn into a tight request loop.
constexpr unsigned long CLOUD_POLL_BACKOFF_MS = 15000;
constexpr unsigned long CLOUD_WIFI_RETRY_MS = 30000;
constexpr unsigned long CLOUD_HTTP_TIMEOUT_MS = 20000;
constexpr unsigned long CLOUD_TLS_HANDSHAKE_TIMEOUT_SECONDS = 20;
// How long the Wi-Fi task waits for the main loop to take the sample it asked
// for. Sampling itself is fast; the budget covers a loop busy shipping a
// history batch over BLE.
constexpr unsigned long CLOUD_SAMPLE_WAIT_MS = 6000;
// Keep more than five hours of five-minute readings in RAM while Wi-Fi or the
// cloud is temporarily unavailable. LittleFS remains the durable source of
// truth; this queue is the live Wi-Fi delivery path and retries its oldest item
// before accepting that it has reached the cloud.
constexpr UBaseType_t CLOUD_HISTORY_UPLOAD_QUEUE_DEPTH = 64;
constexpr uint32_t CLOUD_TASK_STACK_BYTES = 12288;
// The ESP32 Bluetooth/Wi-Fi controller work is concentrated on core 0. Keep our
// TLS/JSON application work on the Arduino core, and suspend it entirely while
// a BLE client owns the device.
constexpr BaseType_t CLOUD_TASK_CORE = 1;
constexpr UBaseType_t CLOUD_TASK_PRIORITY = 1;
#endif

// ---------- LittleFS ring storage ----------
constexpr char HISTORY_FILE_PATH[] = "/history.bin";
constexpr char HISTORY_REBASE_FILE_PATH[] = "/history.rebase";
constexpr char HISTORY_BACKUP_FILE_PATH[] = "/history.backup";
constexpr size_t HISTORY_FS_RESERVE_BYTES = 64UL * 1024UL;
constexpr uint32_t SEQUENCE_RESERVATION_SIZE = 1024;
constexpr uint32_t MIN_REASONABLE_UNIX_TIME = 1704067200UL;  // 2024-01-01 UTC
// Arduino's __DATE__/__TIME__ values use the build machine's wall clock. This
// project is built in China, so convert that UTC+8 wall time to Unix UTC before
// it is used as the offline clock fallback. Phone/NTP time remains UTC already.
constexpr uint32_t BUILD_TIME_UTC_OFFSET_SECONDS = 8UL * 60UL * 60UL;
constexpr uint32_t MAX_BUILD_CLOCK_FUTURE_SKEW_SECONDS = 5UL * 60UL;
// Version 2 moves the sequence space into the Unix-time range. Sequence 1 was
// previously reused after both LittleFS and NVS were reset, while iOS correctly
// retained a much higher durable cursor. The reused records then became
// permanently invisible to every already-synced client.
constexpr uint8_t SEQUENCE_SCHEMA_VERSION = 2;

Adafruit_SHT31 sht31;
BH1750 lightMeter;
NimBLECharacteristic *dataCharacteristic = nullptr;
NimBLECharacteristic *historyCharacteristic = nullptr;
NimBLEServer *sensorServer = nullptr;
NimBLEClient *displayClient = nullptr;
NimBLERemoteCharacteristic *displayDataCharacteristic = nullptr;
QueueHandle_t controlCommandQueue = nullptr;
Preferences sequencePreferences;

bool sht31Ready = false;
bool bh1750Ready = false;
const char *i2cPinTestResult = "not run";
uint8_t lastI2CAddressFound = 0;
volatile bool clientConnected = false;
volatile uint16_t clientConnectionHandle = BLE_HS_CONN_HANDLE_NONE;
volatile bool advertisingRestartPending = false;
volatile unsigned long advertisingRestartRequestedAt = 0;
volatile bool displayCandidateFound = false;
volatile bool displayConnecting = false;
volatile bool displayConnected = false;
volatile bool displayImmediateSamplePending = false;
NimBLEAddress displayCandidateAddress;
unsigned long displayScanRetryAt = 0;
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

#if PLANT_CLOUD_ENABLED
// The reading the main loop most recently committed to history. The Wi-Fi task
// reads it to build its upload body.
//
// Sampling is NOT done on the Wi-Fi task: sampleStoreAndPublish() touches
// LittleFS, the I2C bus and the BLE characteristics, none of which are
// thread-safe. The task instead enqueues RequestImmediateSample on the existing
// control queue and waits for the main loop to run it — the same path the BLE
// 0x13 command already uses.
struct CloudSampleResult {
  uint32_t token;       // matches the request token, so a stale sample is not reused
  uint32_t sequence;
  uint32_t recordedAt;
  uint16_t soilRaw;
  float temperature;
  float humidity;
  float lightLux;
  uint8_t flags;
  bool stored;
};

SemaphoreHandle_t cloudSampleMutex = nullptr;
QueueHandle_t cloudHistoryUploadQueue = nullptr;
TaskHandle_t cloudTaskHandle = nullptr;
volatile uint32_t cloudSampleRequestToken = 0;
uint32_t lastUploadedSequence = 0;  // Persistent cursor for WiFi upload resumption
CloudSampleResult cloudLastSample = {};
bool cloudClockSynced = false;
bool cloudClockSyncStarted = false;
volatile uint8_t cloudLastWiFiDisconnectReason = 0;
#endif

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
  const int64_t localBuildTime =
    days * 86400 + hour * 3600 + minute * 60 + second;
  return static_cast<uint32_t>(
    max(
      localBuildTime - static_cast<int64_t>(BUILD_TIME_UTC_OFFSET_SECONDS),
      static_cast<int64_t>(MIN_REASONABLE_UNIX_TIME)
    )
  );
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

// Builds before the UTC conversion fix wrote the compiler's UTC+8 wall clock
// directly into records made before iPhone/NTP synchronization. Correct only
// estimated records that are implausibly in the future and become plausible
// after the known offset is removed. The test is deliberately idempotent, so an
// interrupted pass can safely continue on the next boot.
bool repairFutureEstimatedHistoryTimestamps() {
  if (historyCount == 0) {
    return true;
  }

  File file = LittleFS.open(HISTORY_FILE_PATH, "r+");
  if (!file) {
    Serial.println("ERROR: Could not open history for timestamp repair.");
    return false;
  }

  const uint32_t plausibleNow = currentUnixTime();
  const uint32_t latestPlausible =
    plausibleNow + MAX_BUILD_CLOCK_FUTURE_SKEW_SECONDS;
  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  uint32_t repairedCount = 0;
  uint32_t recordsVisited = 0;

  // The ring file is sparse: an epoch-sized sequence can place a few records
  // tens of thousands of physical slots into the file. Iterate the logical
  // sequence range instead of seeking through every empty slot on every boot.
  for (
    uint32_t sequence = oldestSequence;
    sequence != 0
      && sequence <= newestSequence
      && recordsVisited < historyCount;
    ++sequence
  ) {
    const uint32_t slot = (sequence - 1) % historyCapacity;
    const size_t offset = static_cast<size_t>(slot) * HISTORY_PACKET_SIZE;
    if (!file.seek(offset, SeekSet)
        || file.read(packet, sizeof(packet)) != sizeof(packet)
        || !isValidStoredRecord(packet)
        || readUInt32LE(packet + 4) != sequence) {
      continue;
    }
    ++recordsVisited;
    if ((packet[2] & FLAG_TIME_ESTIMATED) == 0) {
      continue;
    }

    const uint32_t timestamp = readUInt32LE(packet + 8);
    if (timestamp <= latestPlausible
        || timestamp <= BUILD_TIME_UTC_OFFSET_SECONDS) {
      continue;
    }
    const uint32_t corrected =
      timestamp - BUILD_TIME_UTC_OFFSET_SECONDS;
    if (corrected > latestPlausible) {
      continue;
    }

    writeUInt32LE(packet + 8, corrected);
    packet[3] = historyChecksum(packet, sizeof(packet));
    if (!file.seek(offset, SeekSet)
        || file.write(packet, sizeof(packet)) != sizeof(packet)) {
      file.close();
      Serial.println("ERROR: Could not repair estimated history timestamp.");
      return false;
    }
    ++repairedCount;
  }
  file.flush();
  file.close();

  if (repairedCount > 0) {
    Serial.printf(
      "Repaired %lu future estimated history timestamps.\n",
      static_cast<unsigned long>(repairedCount)
    );
    restoreHistoryState();
  }
  return true;
}

// Once phone or cloud time is available, it becomes a hard upper bound for
// earlier estimated records. Move the complete future-shifted run together so
// the five-minute spacing survives instead of clamping every row to one time.
bool reanchorFutureEstimatedHistoryTimestamps(uint32_t exactUnixTime) {
  if (historyCount == 0) {
    return true;
  }

  File file = LittleFS.open(HISTORY_FILE_PATH, "r+");
  if (!file) {
    Serial.println("ERROR: Could not open history for exact-time repair.");
    return false;
  }

  const uint32_t latestPlausible =
    exactUnixTime + MAX_BUILD_CLOCK_FUTURE_SKEW_SECONDS;
  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  uint32_t latestFutureTimestamp = 0;
  uint32_t recordsVisited = 0;

  for (
    uint32_t sequence = oldestSequence;
    sequence != 0
      && sequence <= newestSequence
      && recordsVisited < historyCount;
    ++sequence
  ) {
    if (!readHistoryRecord(file, sequence, packet)) {
      continue;
    }
    ++recordsVisited;
    if ((packet[2] & FLAG_TIME_ESTIMATED) == 0) {
      continue;
    }
    const uint32_t timestamp = readUInt32LE(packet + 8);
    if (timestamp > latestPlausible) {
      latestFutureTimestamp = max(latestFutureTimestamp, timestamp);
    }
  }

  if (latestFutureTimestamp == 0) {
    file.close();
    return true;
  }

  const uint32_t shift = latestFutureTimestamp - exactUnixTime;
  uint32_t repairedCount = 0;
  recordsVisited = 0;
  for (
    uint32_t sequence = oldestSequence;
    sequence != 0
      && sequence <= newestSequence
      && recordsVisited < historyCount;
    ++sequence
  ) {
    const uint32_t slot = (sequence - 1) % historyCapacity;
    const size_t offset = static_cast<size_t>(slot) * HISTORY_PACKET_SIZE;
    if (!file.seek(offset, SeekSet)
        || file.read(packet, sizeof(packet)) != sizeof(packet)
        || !isValidStoredRecord(packet)
        || readUInt32LE(packet + 4) != sequence) {
      continue;
    }
    ++recordsVisited;
    const uint32_t timestamp = readUInt32LE(packet + 8);
    if ((packet[2] & FLAG_TIME_ESTIMATED) == 0
        || timestamp <= latestPlausible) {
      continue;
    }

    writeUInt32LE(packet + 8, timestamp > shift ? timestamp - shift : exactUnixTime);
    packet[3] = historyChecksum(packet, sizeof(packet));
    if (!file.seek(offset, SeekSet)
        || file.write(packet, sizeof(packet)) != sizeof(packet)) {
      file.close();
      Serial.println("ERROR: Could not re-anchor estimated history timestamp.");
      return false;
    }
    ++repairedCount;
  }
  file.flush();
  file.close();

  if (repairedCount > 0) {
    Serial.printf(
      "Re-anchored %lu future estimated history timestamps by %lu seconds.\n",
      static_cast<unsigned long>(repairedCount),
      static_cast<unsigned long>(shift)
    );
    restoreHistoryState();
  }
  return true;
}

bool recoverInterruptedHistoryRebase() {
  if (!LittleFS.exists(HISTORY_FILE_PATH)
      && LittleFS.exists(HISTORY_BACKUP_FILE_PATH)) {
    if (!LittleFS.rename(HISTORY_BACKUP_FILE_PATH, HISTORY_FILE_PATH)) {
      Serial.println("ERROR: Could not recover history backup after interrupted rebase.");
      return false;
    }
    Serial.println("Recovered history backup after interrupted sequence rebase.");
  }
  if (LittleFS.exists(HISTORY_REBASE_FILE_PATH)) {
    LittleFS.remove(HISTORY_REBASE_FILE_PATH);
  }
  if (LittleFS.exists(HISTORY_FILE_PATH)
      && LittleFS.exists(HISTORY_BACKUP_FILE_PATH)) {
    LittleFS.remove(HISTORY_BACKUP_FILE_PATH);
  }
  return true;
}

// Rewrites every currently valid record into one fresh, contiguous sequence
// range without changing timestamps or sensor values. The original file stays
// intact until the replacement has been fully flushed, and a backup is kept
// across the final rename so a power loss can be recovered on the next boot.
bool rebaseHistorySequences(uint32_t firstSequence) {
  if (historyCount == 0) {
    oldestSequence = 0;
    newestSequence = 0;
    nextSequence = firstSequence;
    return true;
  }
  if (firstSequence == 0
      || historyCount - 1 > UINT32_MAX - firstSequence) {
    Serial.println("ERROR: Not enough sequence space to rebase history.");
    return false;
  }

  File source = LittleFS.open(HISTORY_FILE_PATH, "r");
  if (!source) {
    Serial.println("ERROR: Could not open history source for sequence rebase.");
    return false;
  }
  LittleFS.remove(HISTORY_REBASE_FILE_PATH);
  File replacement = LittleFS.open(HISTORY_REBASE_FILE_PATH, "w+");
  if (!replacement) {
    source.close();
    Serial.println("ERROR: Could not create history sequence rebase file.");
    return false;
  }

  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  uint32_t rebasedCount = 0;
  uint32_t candidate = oldestSequence;
  while (candidate <= newestSequence && rebasedCount < historyCount) {
    if (readHistoryRecord(source, candidate, packet)) {
      const uint32_t rebasedSequence = firstSequence + rebasedCount;
      writeUInt32LE(packet + 4, rebasedSequence);
      packet[3] = historyChecksum(packet, sizeof(packet));
      const uint32_t slot = (rebasedSequence - 1) % historyCapacity;
      const size_t offset = static_cast<size_t>(slot) * HISTORY_PACKET_SIZE;
      if (!replacement.seek(offset, SeekSet)
          || replacement.write(packet, sizeof(packet)) != sizeof(packet)) {
        source.close();
        replacement.close();
        LittleFS.remove(HISTORY_REBASE_FILE_PATH);
        Serial.println("ERROR: Could not write rebased history record.");
        return false;
      }
      ++rebasedCount;
    }
    if (candidate == UINT32_MAX) {
      break;
    }
    ++candidate;
  }
  replacement.flush();
  replacement.close();
  source.close();

  if (rebasedCount == 0 || rebasedCount != historyCount) {
    LittleFS.remove(HISTORY_REBASE_FILE_PATH);
    Serial.printf(
      "ERROR: History rebase found %lu of %lu records.\n",
      static_cast<unsigned long>(rebasedCount),
      static_cast<unsigned long>(historyCount)
    );
    return false;
  }

  LittleFS.remove(HISTORY_BACKUP_FILE_PATH);
  if (!LittleFS.rename(HISTORY_FILE_PATH, HISTORY_BACKUP_FILE_PATH)) {
    LittleFS.remove(HISTORY_REBASE_FILE_PATH);
    Serial.println("ERROR: Could not preserve original history before rebase.");
    return false;
  }
  if (!LittleFS.rename(HISTORY_REBASE_FILE_PATH, HISTORY_FILE_PATH)) {
    LittleFS.rename(HISTORY_BACKUP_FILE_PATH, HISTORY_FILE_PATH);
    Serial.println("ERROR: Could not activate rebased history; original restored.");
    return false;
  }
  LittleFS.remove(HISTORY_BACKUP_FILE_PATH);

  historyCount = rebasedCount;
  oldestSequence = firstSequence;
  newestSequence = firstSequence + rebasedCount - 1;
  nextSequence = newestSequence + 1;
  Serial.printf(
    "History sequence epoch migrated: %lu records now %lu...%lu.\n",
    static_cast<unsigned long>(historyCount),
    static_cast<unsigned long>(oldestSequence),
    static_cast<unsigned long>(newestSequence)
  );
  return true;
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
  const uint8_t storedSchema = sequencePreferences.getUChar("seqSchema", 0);

  // Legacy sequence values were small counters. Move any such surviving file
  // into a globally newer range before BLE or Wi-Fi can expose it. Build time is
  // available even before NTP and grows much faster than the five-minute counter,
  // so a later storage reset cannot reuse an earlier client's sequence IDs.
  if (historyCount > 0 && newestSequence < MIN_REASONABLE_UNIX_TIME) {
    const uint32_t epochStart = max(buildUnixTime(), MIN_REASONABLE_UNIX_TIME);
    if (!rebaseHistorySequences(epochStart)) {
      historyStorageReady = false;
      return;
    }
    sequenceReservationEnd = 0;
  } else if (historyCount == 0
             && sequenceReservationEnd < MIN_REASONABLE_UNIX_TIME) {
    nextSequence = max(buildUnixTime(), MIN_REASONABLE_UNIX_TIME);
    sequenceReservationEnd = 0;
  }

  if (storedSchema < SEQUENCE_SCHEMA_VERSION
      && sequencePreferences.putUChar("seqSchema", SEQUENCE_SCHEMA_VERSION)
          != sizeof(uint8_t)) {
    Serial.println("ERROR: Could not persist history sequence schema.");
    historyStorageReady = false;
    return;
  }

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
  if (!recoverInterruptedHistoryRebase()) {
    historyStorageReady = false;
    return;
  }
  restoreHistoryState();
  if (!repairFutureEstimatedHistoryTimestamps()) {
    historyStorageReady = false;
    return;
  }
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

float decodeTemperature(int16_t encoded) {
  return static_cast<float>(encoded) / 100.0f;
}

#if PLANT_CLOUD_ENABLED
void publishCloudSample(const SensorSample &sample, uint32_t sequence, uint32_t recordedAt);
#endif

uint16_t encodeUnsignedHundredths(float value, float maximum) {
  if (isnan(value)) {
    return 0;
  }
  return static_cast<uint16_t>(roundf(constrain(value, 0.0f, maximum) * 100.0f));
}

float decodeUnsignedHundredths(uint16_t encoded) {
  return static_cast<float>(encoded) / 100.0f;
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

#if PLANT_CLOUD_ENABLED
  // Hand the committed record to the Wi-Fi task. Publishing the sequence that
  // was actually written (rather than re-deriving one on the network side) keeps
  // the cloud row's primary key identical to the one BLE sync will later push,
  // so remote sampling cannot create a duplicate of the same reading.
  publishCloudSample(sample, newestSequence, newestTimestamp);
#endif

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

  if (dataCharacteristic != nullptr) {
    dataCharacteristic->setValue(packet, sizeof(packet));
  }
  if (clientConnected && dataCharacteristic != nullptr) {
    dataCharacteristic->notify();
  }

  if (displayConnected && displayDataCharacteristic != nullptr) {
    // Use a write response for the display path. This is only one 16-byte
    // packet per sample, and the acknowledgement proves the C3 accepted it
    // before the main ESP32 reports success.
    if (displayDataCharacteristic->writeValue(packet, sizeof(packet), true)) {
      Serial.println("Live reading pushed to the priority OLED display.");
    } else {
      Serial.println("ERROR: Could not push reading to OLED display; disconnecting stale link.");
      if (displayClient != nullptr) {
        displayClient->disconnect();
      }
    }
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

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(
    NimBLECharacteristic *characteristic,
    NimBLEConnInfo &connection
  ) override {
    const NimBLEAttValue value = characteristic->getValue();
    const uint8_t *data = value.data();
    const size_t length = value.size();
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

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(
    NimBLEServer *server,
    NimBLEConnInfo &connection
  ) override {
    clientConnected = true;
    clientConnectionHandle = connection.getConnHandle();
    advertisingRestartPending = false;
    Serial.println("iOS/Web BLE client connected.");
    if (displayCandidateFound || displayConnecting || displayConnected) {
      Serial.println("OLED display has priority; current iOS/Web client will be disconnected.");
    }
  }

  void onDisconnect(
    NimBLEServer *server,
    NimBLEConnInfo &connection,
    int reason
  ) override {
    clientConnected = false;
    clientConnectionHandle = BLE_HS_CONN_HANDLE_NONE;
    if (controlCommandQueue != nullptr) {
      xQueueReset(controlCommandQueue);
    }
    advertisingRestartRequestedAt = millis();
    advertisingRestartPending = true;
    Serial.println("iOS/Web BLE client disconnected; advertising restart scheduled.");
  }
};

class DisplayClientCallbacks : public NimBLEClientCallbacks {
  void onConnect(NimBLEClient *client) override {
    displayConnected = true;
    Serial.printf(
      "Priority OLED display connected at %s.\n",
      client->getPeerAddress().toString().c_str()
    );
  }

  void onDisconnect(NimBLEClient *client, int reason) override {
    displayDataCharacteristic = nullptr;
    displayConnected = false;
    displayConnecting = false;
    displayCandidateFound = false;
    displayImmediateSamplePending = false;
    displayScanRetryAt = millis() + DISPLAY_RETRY_DELAY_MS;
    advertisingRestartRequestedAt = millis();
    advertisingRestartPending = true;
    Serial.printf(
      "Priority OLED display disconnected (reason %d); iOS/Web will become available again.\n",
      reason
    );
  }
};

class DisplayScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice *advertisedDevice) override {
    if (displayCandidateFound || displayConnecting || displayConnected) {
      return;
    }

    const bool matchingName =
      advertisedDevice->haveName() && advertisedDevice->getName() == DISPLAY_NAME;
    const bool matchingService = advertisedDevice->isAdvertisingService(
      NimBLEUUID(DISPLAY_SERVICE_UUID)
    );
    if (!matchingName && !matchingService) {
      return;
    }

    displayCandidateAddress = advertisedDevice->getAddress();
    displayCandidateFound = true;
    NimBLEDevice::getScan()->stop();
    Serial.printf(
      "Priority OLED display discovered at %s; claiming the single endpoint slot.\n",
      displayCandidateAddress.toString().c_str()
    );
  }
};

bool displayOwnsEndpointSlot() {
  return displayCandidateFound || displayConnecting || displayConnected;
}

void restartAdvertisingAfterDisconnect() {
  if (!advertisingRestartPending || clientConnected || displayOwnsEndpointSlot()) {
    return;
  }

  const unsigned long requestedAt = advertisingRestartRequestedAt;
  if (millis() - requestedAt < ADVERTISING_RESTART_DELAY_MS) {
    return;
  }

  advertisingRestartPending = false;
  NimBLEDevice::startAdvertising();
  Serial.println("BLE advertising restarted; waiting for one client.");
}

void startDisplayScanIfNeeded() {
  if (displayOwnsEndpointSlot()
      || static_cast<long>(millis() - displayScanRetryAt) < 0) {
    return;
  }

  NimBLEScan *scan = NimBLEDevice::getScan();
  if (scan->isScanning()) {
    return;
  }
  scan->start(0, false, true);
  Serial.println("Scanning continuously for the priority OLED display.");
}

void releaseDisplayCandidate() {
  displayDataCharacteristic = nullptr;
  displayCandidateFound = false;
  displayConnecting = false;
  displayConnected = false;
  displayScanRetryAt = millis() + DISPLAY_RETRY_DELAY_MS;
  advertisingRestartRequestedAt = millis();
  advertisingRestartPending = true;
}

void connectPriorityDisplayIfFound() {
  if (!displayCandidateFound || displayConnecting || displayConnected) {
    return;
  }

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  if (advertising->isAdvertising()) {
    advertising->stop();
    Serial.println("Stopped iOS/Web advertising for the priority OLED display.");
  }

  // A powered display always wins. Wait for the server-side disconnect callback
  // before opening the central-side link so there is never more than one endpoint.
  if (clientConnected) {
    const uint16_t handle = clientConnectionHandle;
    if (sensorServer != nullptr && handle != BLE_HS_CONN_HANDLE_NONE) {
      Serial.println("Disconnecting iOS/Web because the OLED display is powered on.");
      sensorServer->disconnect(handle);
    }
    return;
  }

  displayConnecting = true;
  NimBLEDevice::getScan()->stop();

  if (displayClient == nullptr) {
    displayClient = NimBLEDevice::createClient();
    if (displayClient == nullptr) {
      Serial.println("ERROR: Could not allocate BLE client for OLED display.");
      releaseDisplayCandidate();
      return;
    }
    displayClient->setClientCallbacks(new DisplayClientCallbacks(), true);
    displayClient->setConnectionParams(12, 24, 0, 200);
    displayClient->setConnectTimeout(3000);
    displayClient->setConnectRetries(2);
  }

  Serial.printf(
    "Connecting to priority OLED display at %s...\n",
    displayCandidateAddress.toString().c_str()
  );
  if (!displayClient->connect(displayCandidateAddress)) {
    Serial.println("Priority OLED display connection failed; retrying immediately.");
    releaseDisplayCandidate();
    return;
  }

  NimBLERemoteService *service = displayClient->getService(DISPLAY_SERVICE_UUID);
  if (service == nullptr) {
    Serial.println("ERROR: OLED display service is missing.");
    displayClient->disconnect();
    return;
  }

  displayDataCharacteristic = service->getCharacteristic(
    DISPLAY_DATA_CHARACTERISTIC_UUID
  );
  if (displayDataCharacteristic == nullptr
      || (!displayDataCharacteristic->canWrite()
          && !displayDataCharacteristic->canWriteNoResponse())) {
    Serial.println("ERROR: OLED display data characteristic is not writable.");
    displayClient->disconnect();
    return;
  }

  displayCandidateFound = false;
  displayConnecting = false;
  displayConnected = true;
  displayImmediateSamplePending = true;
  advertisingRestartPending = false;
  Serial.println("Priority OLED display claimed; taking an immediate sensor sample.");
}

void initializeBLE() {
  controlCommandQueue = xQueueCreate(8, sizeof(QueuedCommand));
  // NimBLE preserves the GATT protocol while leaving substantially more heap
  // available for TLS than the original Bluedroid stack.
  NimBLEDevice::init(DEVICE_NAME);

  sensorServer = NimBLEDevice::createServer();
  sensorServer->setCallbacks(new ServerCallbacks());
  NimBLEService *service = sensorServer->createService(SERVICE_UUID);

  dataCharacteristic = service->createCharacteristic(
    DATA_CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  NimBLECharacteristic *controlCharacteristic = service->createCharacteristic(
    CONTROL_CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::WRITE
  );
  controlCharacteristic->setCallbacks(new ControlCallbacks());

  historyCharacteristic = service->createCharacteristic(
    HISTORY_CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::NOTIFY
  );

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->enableScanResponse(true);
  advertising->setPreferredParams(0x06, 0x12);
  NimBLEDevice::startAdvertising();

  NimBLEScan *displayScan = NimBLEDevice::getScan();
  displayScan->setScanCallbacks(new DisplayScanCallbacks(), false);
  displayScan->setActiveScan(true);
  displayScan->setInterval(45);
  displayScan->setWindow(30);
  displayScan->setMaxResults(0);
  displayScan->start(0, false, true);

  Serial.println("BLE advertising for iOS/Web and scanning for the priority OLED display.");
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
        if (!reanchorFutureEstimatedHistoryTimestamps(command.value)) {
          Serial.println("WARNING: Exact clock applied, but stored estimates could not be repaired.");
        }
        Serial.printf(
          "Clock synchronized by client or NTP: %lu.\n",
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

#if PLANT_CLOUD_ENABLED
// ---------- Cloud command mailbox (Wi-Fi side channel) ----------
//
// Everything below runs on a dedicated low-priority task and is strictly additive: it
// never touches BLE state, LittleFS or the sample scheduler directly. The only
// coupling points are the existing control queue (to ask for a sample) and
// cloudLastSample (to read the result back).

void publishCloudSample(const SensorSample &sample, uint32_t sequence, uint32_t recordedAt) {
  if (cloudSampleMutex == nullptr || cloudHistoryUploadQueue == nullptr) {
    return;
  }

  const CloudSampleResult committed = {
    cloudSampleRequestToken,
    sequence,
    recordedAt,
    sample.soilRaw,
    sample.temperature,
    sample.humidity,
    sample.lightLux,
    static_cast<uint8_t>(
      sample.flags | (clockEstimated ? FLAG_TIME_ESTIMATED : 0)
    ),
    true
  };

  // The immediate-command mailbox is best-effort here. A scheduled sample must
  // still enter the history upload queue even if command polling happens to
  // hold this mutex at the same instant.
  if (xSemaphoreTake(cloudSampleMutex, pdMS_TO_TICKS(50)) == pdTRUE) {
    cloudLastSample = committed;
    xSemaphoreGive(cloudSampleMutex);
  }

  // Queue only after LittleFS committed the record. The network task peeks and
  // removes it only after a successful /sync/push response, so a transient HTTP
  // failure does not silently lose the next five-minute reading.
  if (xQueueSend(cloudHistoryUploadQueue, &committed, 0) != pdTRUE) {
    Serial.printf(
      "CLOUD: history upload queue full; sequence %lu remains available over BLE.\n",
      static_cast<unsigned long>(sequence)
    );
  }
}

// Asks the main loop for a fresh sample and waits for it. Returns false if the
// loop did not deliver one in time, so the command stays pending in the cloud
// and the next poll can retry it.
bool requestSampleFromMainLoop(CloudSampleResult *out) {
  if (controlCommandQueue == nullptr || cloudSampleMutex == nullptr) {
    return false;
  }

  const uint32_t token = cloudSampleRequestToken + 1;
  cloudSampleRequestToken = token;

  const QueuedCommand request = {QueuedCommandType::RequestImmediateSample, 0, 0};
  if (xQueueSend(controlCommandQueue, &request, pdMS_TO_TICKS(500)) != pdTRUE) {
    Serial.println("CLOUD: control queue full; sample request dropped.");
    return false;
  }

  const unsigned long deadline = millis() + CLOUD_SAMPLE_WAIT_MS;
  while (static_cast<long>(millis() - deadline) < 0) {
    vTaskDelay(pdMS_TO_TICKS(50));
    if (xSemaphoreTake(cloudSampleMutex, pdMS_TO_TICKS(50)) != pdTRUE) {
      continue;
    }
    const bool ready = cloudLastSample.stored && cloudLastSample.token == token;
    if (ready) {
      *out = cloudLastSample;
    }
    xSemaphoreGive(cloudSampleMutex);
    if (ready) {
      return true;
    }
  }

  Serial.println("CLOUD: timed out waiting for the main loop to sample.");
  return false;
}

bool ensureWiFiConnected() {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }

  Serial.println("CLOUD: connecting to configured Wi-Fi network...");
  WiFi.mode(WIFI_STA);
  // Switching from WIFI_OFF can emit the previous intentional STA_LEAVING
  // event asynchronously. Clear it after the mode transition so the failure
  // below reports the current association attempt.
  vTaskDelay(pdMS_TO_TICKS(50));
  cloudLastWiFiDisconnectReason = 0;
  // Wi-Fi and BLE share one 2.4 GHz radio on this chip. Modem sleep lets the
  // coexistence arbiter hand the radio back to BLE between polls; without it
  // BLE history transfer slows down noticeably.
  WiFi.setSleep(true);
  WiFi.begin(PLANT_WIFI_SSID, PLANT_WIFI_PASSWORD);

  const unsigned long deadline = millis() + 15000;
  while (WiFi.status() != WL_CONNECTED && static_cast<long>(millis() - deadline) < 0) {
    vTaskDelay(pdMS_TO_TICKS(250));
  }

  if (WiFi.status() != WL_CONNECTED) {
    const uint8_t reason = cloudLastWiFiDisconnectReason;
    Serial.printf(
      "CLOUD: Wi-Fi connect failed (status %d, reason %u %s); staying in BLE-only mode this round.\n",
      static_cast<int>(WiFi.status()),
      static_cast<unsigned>(reason),
      WiFi.STA.disconnectReasonName(static_cast<wifi_err_reason_t>(reason))
    );
    // Drop the radio rather than leaving it retrying in the background, so BLE
    // gets the full airtime until the next attempt.
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    return false;
  }

  Serial.print("CLOUD: Wi-Fi connected, IP ");
  Serial.println(WiFi.localIP());
  return true;
}

bool publishExactClockToMainLoop(uint32_t unixTime, const char *source) {
  if (unixTime < MIN_REASONABLE_UNIX_TIME) {
    return false;
  }
  const QueuedCommand command = {
    QueuedCommandType::SetUnixTime,
    unixTime,
    0
  };
  if (xQueueSend(controlCommandQueue, &command, pdMS_TO_TICKS(500)) != pdTRUE) {
    Serial.printf("CLOUD: could not publish %s time to the sampling loop.\n", source);
    return false;
  }
  cloudClockSynced = true;
  Serial.printf(
    "CLOUD: clock synchronized by %s: %lu.\n",
    source,
    static_cast<unsigned long>(unixTime)
  );
  return true;
}

// Starts SNTP once and observes it without blocking cloud command polling.
// The HTTPS poll response is the primary clock source; NTP remains a fallback
// for compatible deployments that have not yet added serverTime.
void updateClockFromNTP() {
  if (cloudClockSynced
      || WiFi.status() != WL_CONNECTED
      || clientConnected) {
    return;
  }

  if (!cloudClockSyncStarted) {
    Serial.println("CLOUD: starting background NTP synchronization...");
    configTime(0, 0, "ntp.aliyun.com", "pool.ntp.org");
    cloudClockSyncStarted = true;
  }

  if (sntp_get_sync_status() != SNTP_SYNC_STATUS_COMPLETED) {
    return;
  }
  const time_t synchronized = time(nullptr);
  if (synchronized < static_cast<time_t>(MIN_REASONABLE_UNIX_TIME)) {
    return;
  }

  // SNTP has already set the system clock. Route the exact timestamp through the
  // main-loop queue as well so timestamp quality changes on the sampling thread.
  publishExactClockToMainLoop(static_cast<uint32_t>(synchronized), "NTP");
}

// Shared by all three calls. Returns the HTTP status, or a negative value on
// transport failure; the body is appended to `response`.
int cloudRequest(const char *method, const String &url, const String &body, String *response) {
  // Modem sleep is useful between polls, but on a busy BLE/Wi-Fi coexistence
  // radio it can starve the first TLS handshake long enough for HTTPClient to
  // report a connection refusal. Keep the radio awake only for the request;
  // cloudTask already suspends all HTTPS work while a BLE client is connected.
  WiFi.setSleep(false);

  WiFiClientSecure client;
  // The device has no CA bundle and no reliable wall clock before the first time
  // sync, so certificate validation cannot be performed here. The link is still
  // encrypted; the auth token is what proves the caller's identity to the cloud.
  client.setInsecure();
  client.setTimeout(CLOUD_HTTP_TIMEOUT_MS / 1000);
  client.setHandshakeTimeout(CLOUD_TLS_HANDSHAKE_TIMEOUT_SECONDS);

  HTTPClient http;
  if (!http.begin(client, url)) {
    WiFi.setSleep(true);
    return -1;
  }
  http.setTimeout(CLOUD_HTTP_TIMEOUT_MS);
  http.setConnectTimeout(CLOUD_HTTP_TIMEOUT_MS);
  http.addHeader("x-auth-token", PLANT_CLOUD_AUTH_TOKEN);

  int status = -1;
  if (strcmp(method, "POST") == 0) {
    http.addHeader("Content-Type", "application/json");
    status = http.POST(body);
  } else {
    status = http.GET();
  }

  if (status > 0 && response != nullptr) {
    *response = http.getString();
  } else if (status < 0) {
    char tlsError[160] = {};
    const int tlsErrorCode = client.lastError(tlsError, sizeof(tlsError));
    Serial.printf(
      "CLOUD: transport error %d (%s), TLS %d (%s), RSSI %d dBm, free heap %u.\n",
      status,
      HTTPClient::errorToString(status).c_str(),
      tlsErrorCode,
      tlsError,
      WiFi.RSSI(),
      ESP.getFreeHeap()
    );
  }
  http.end();
  WiFi.setSleep(true);
  return status;
}

// Minimal string extraction for the two fields the device needs. A JSON parser
// would be more robust, but pulling one in for two known keys is not worth the
// flash; the cloud responses are generated by our own function.
bool extractJSONString(const String &source, const char *key, String *value) {
  String needle = String("\"") + key + "\"";
  int keyAt = source.indexOf(needle);
  if (keyAt < 0) {
    return false;
  }
  int cursor = source.indexOf(':', keyAt + needle.length());
  if (cursor < 0) {
    return false;
  }
  ++cursor;
  while (cursor < static_cast<int>(source.length()) && isspace(source[cursor])) {
    ++cursor;
  }
  // The value must be a string starting right here. Scanning ahead for the next
  // quote would, for a null value, return some later key's string instead.
  if (cursor >= static_cast<int>(source.length()) || source[cursor] != '"') {
    return false;
  }
  int lastQuote = source.indexOf('"', cursor + 1);
  if (lastQuote < 0) {
    return false;
  }
  *value = source.substring(cursor + 1, lastQuote);
  return true;
}

bool jsonBoolIsTrue(const String &source, const char *key) {
  String needle = String("\"") + key + "\"";
  int keyAt = source.indexOf(needle);
  if (keyAt < 0) {
    return false;
  }
  int cursor = source.indexOf(':', keyAt + needle.length());
  if (cursor < 0) {
    return false;
  }
  ++cursor;
  while (cursor < static_cast<int>(source.length()) && isspace(source[cursor])) {
    ++cursor;
  }
  // Match the value position exactly. Searching for "true" anywhere after the
  // colon would find a later key's value and report this one as true.
  return source.startsWith("true", cursor);
}

bool extractJSONUnsigned64(const String &source, const char *key, uint64_t *value) {
  String needle = String("\"") + key + "\"";
  int keyAt = source.indexOf(needle);
  if (keyAt < 0) {
    return false;
  }
  int cursor = source.indexOf(':', keyAt + needle.length());
  if (cursor < 0) {
    return false;
  }
  ++cursor;
  while (cursor < static_cast<int>(source.length()) && isspace(source[cursor])) {
    ++cursor;
  }
  const int firstDigit = cursor;
  while (
    cursor < static_cast<int>(source.length())
      && source[cursor] >= '0'
      && source[cursor] <= '9'
  ) {
    ++cursor;
  }
  if (cursor == firstDigit) {
    return false;
  }

  const String number = source.substring(firstDigit, cursor);
  char *end = nullptr;
  const unsigned long long parsed = strtoull(number.c_str(), &end, 10);
  if (end == number.c_str() || *end != '\0') {
    return false;
  }
  *value = static_cast<uint64_t>(parsed);
  return true;
}

void updateClockFromCloudResponse(const String &response) {
  if (cloudClockSynced) {
    return;
  }
  uint64_t serverTimeMs = 0;
  if (!extractJSONUnsigned64(response, "serverTime", &serverTimeMs)) {
    return;
  }
  const uint64_t serverTimeSeconds = serverTimeMs / 1000ULL;
  if (serverTimeSeconds > UINT32_MAX) {
    return;
  }
  publishExactClockToMainLoop(
    static_cast<uint32_t>(serverTimeSeconds),
    "HTTPS server"
  );
}

String cloudEndpoint(const char *suffix) {
  return String(PLANT_CLOUD_BASE_URL) + suffix;
}

// Appends `name: value` to a JSON body, rendering unavailable sensors as null
// rather than 0 — the cloud omits null metrics instead of storing a fake zero.
void appendJSONFloat(String *body, const char *name, float value, bool valid) {
  *body += "\"";
  *body += name;
  *body += "\":";
  if (valid && !isnan(value)) {
    *body += String(value, 2);
  } else {
    *body += "null";
  }
}

String cloudReadingJSON(const CloudSampleResult &sample) {
  String body = "{\"deviceId\":\"";
  body += PLANT_CLOUD_DEVICE_ID;
  body += "\",\"sequence\":";
  body += String(sample.sequence);
  body += ",\"recordedAt\":";
  // The cloud stores milliseconds; the firmware clock is in seconds.
  body += String(static_cast<uint64_t>(sample.recordedAt) * 1000ULL);
  body += ",\"timestampEstimated\":";
  body += (sample.flags & FLAG_TIME_ESTIMATED) ? "true" : "false";
  body += ",\"soilRaw\":";
  body += String(sample.soilRaw);
  body += ",";
  appendJSONFloat(&body, "temperature", sample.temperature, sample.flags & FLAG_SHT31_VALID);
  body += ",";
  appendJSONFloat(&body, "humidity", sample.humidity, sample.flags & FLAG_SHT31_VALID);
  body += ",";
  appendJSONFloat(&body, "lightLux", sample.lightLux, sample.flags & FLAG_BH1750_VALID);
  body += "}";
  return body;
}

bool uploadCloudHistorySample(const CloudSampleResult &sample) {
  String body = "{\"sensorReadings\":[";
  body += cloudReadingJSON(sample);
  body += "]}";

  String response;
  const int status = cloudRequest("POST", cloudEndpoint("/sync/push"), body, &response);
  if (status != 200 || !jsonBoolIsTrue(response, "success")) {
    Serial.printf(
      "CLOUD: history sync failed for sequence %lu, HTTP %d; will retry.\n",
      static_cast<unsigned long>(sample.sequence),
      status
    );
    return false;
  }
  Serial.printf(
    "CLOUD: synced history sequence %lu.\n",
    static_cast<unsigned long>(sample.sequence)
  );
  return true;
}

void loadUploadCursor() {
  lastUploadedSequence = sequencePreferences.getULong("lastUpload", 0);
  if (lastUploadedSequence > 0) {
    Serial.printf(
      "CLOUD: resuming upload from sequence %lu.\n",
      static_cast<unsigned long>(lastUploadedSequence)
    );
  }
}

bool saveUploadCursor(uint32_t sequence) {
  if (sequencePreferences.putULong("lastUpload", sequence) != sizeof(uint32_t)) {
    Serial.printf(
      "CLOUD: WARNING: failed to persist upload cursor %lu to NVS.\n",
      static_cast<unsigned long>(sequence)
    );
    return false;
  }
  return true;
}

bool flushPendingCloudHistory() {
  if (cloudHistoryUploadQueue == nullptr) {
    return true;
  }

  // First, drain any remaining items from the legacy RAM queue (for backward compatibility
  // during the transition period, or if the cursor is somehow behind queued items).
  for (uint8_t attempt = 0; attempt < 4; ++attempt) {
    CloudSampleResult pending = {};
    if (xQueuePeek(cloudHistoryUploadQueue, &pending, 0) != pdTRUE) {
      break;  // Queue empty, proceed to LittleFS scan
    }
    if (!uploadCloudHistorySample(pending)) {
      return false;
    }
    xQueueReceive(cloudHistoryUploadQueue, &pending, 0);
    lastUploadedSequence = pending.sequence;
    saveUploadCursor(lastUploadedSequence);
  }

  // Now backfill from LittleFS: find records with sequence > lastUploadedSequence.
  // Upload a small batch per cycle to avoid starving command polling.
  if (!historyStorageReady || historyCount == 0 || newestSequence <= lastUploadedSequence) {
    return true;  // Nothing to backfill
  }

  File file = LittleFS.open(HISTORY_FILE_PATH, "r");
  if (!file) {
    Serial.println("CLOUD: cannot open history file for backfill.");
    return false;
  }

  uint8_t packet[HISTORY_PACKET_SIZE] = {};
  uint8_t uploaded = 0;
  const uint8_t maxPerCycle = 4;

  // Never scan from sequence 1 when NVS has no cursor but LittleFS contains
  // epoch-sized sequence values. The ring buffer cannot contain anything older
  // than oldestSequence, so beginning there avoids billions of empty reads.
  const uint32_t firstPendingSequence = max(
    lastUploadedSequence + 1,
    oldestSequence
  );

  // The ring buffer may have gaps or wrap-around, so try each sequence that can
  // still be represented by the retained LittleFS window.
  for (uint32_t seq = firstPendingSequence; seq <= newestSequence && uploaded < maxPerCycle; ++seq) {
    if (!readHistoryRecord(file, seq, packet)) {
      // This slot might be empty (ring buffer wrapped), or the record is invalid. Skip.
      continue;
    }

    // Reconstruct CloudSampleResult from the stored packet
    CloudSampleResult sample = {};
    sample.token = 0;  // Not used for history backfill
    sample.sequence = readUInt32LE(packet + 4);
    sample.recordedAt = readUInt32LE(packet + 8);
    sample.soilRaw = readUInt16LE(packet + 12);
    sample.temperature = decodeTemperature(static_cast<int16_t>(readUInt16LE(packet + 14)));
    sample.humidity = decodeUnsignedHundredths(readUInt16LE(packet + 16));
    sample.lightLux = static_cast<float>(readUInt16LE(packet + 18));
    sample.flags = packet[2];
    sample.stored = true;

    if (!uploadCloudHistorySample(sample)) {
      file.close();
      return false;  // Upload failed, retry next cycle
    }

    lastUploadedSequence = sample.sequence;
    saveUploadCursor(lastUploadedSequence);
    ++uploaded;
  }

  file.close();
  return true;
}

bool uploadCloudSample(const String &commandID, const CloudSampleResult &sample) {
  String body = "{\"commandId\":\"";
  body += commandID;
  body += "\",\"reading\":";
  body += cloudReadingJSON(sample);
  body += "}";

  String response;
  const int status = cloudRequest("POST", cloudEndpoint("/command/respond"), body, &response);
  if (status != 200) {
    Serial.printf("CLOUD: respond failed, HTTP %d.\n", status);
    return false;
  }
  if (!jsonBoolIsTrue(response, "success")) {
    // The cloud rejected the payload (bad reading, missing table). Log the body
    // verbatim: it carries the actionable hint.
    Serial.print("CLOUD: respond rejected: ");
    Serial.println(response);
    return false;
  }
  Serial.printf("CLOUD: uploaded sequence %lu.\n", static_cast<unsigned long>(sample.sequence));
  return true;
}

// One poll cycle. Returns false when the round failed, so the caller can back off.
bool runCloudPollCycle() {
  String response;
  String url = cloudEndpoint("/command/poll");
  url += "?deviceId=";
  url += PLANT_CLOUD_DEVICE_ID;

  const int status = cloudRequest("GET", url, String(), &response);
  if (status != 200) {
    Serial.printf("CLOUD: poll failed, HTTP %d.\n", status);
    return false;
  }
  updateClockFromCloudResponse(response);
  if (!jsonBoolIsTrue(response, "hasCommand")) {
    return true;  // idle, nothing to do
  }

  String commandID;
  if (!extractJSONString(response, "commandId", &commandID) || commandID.isEmpty()) {
    Serial.println("CLOUD: poll returned a command without an id.");
    return false;
  }

  String action;
  extractJSONString(response, "action", &action);
  if (action.length() > 0 && action != "refresh_sensor" && action != "read_sensor") {
    // Unknown actions are left pending rather than silently consumed, so a newer
    // firmware can pick them up.
    Serial.print("CLOUD: ignoring unsupported action ");
    Serial.println(action);
    return true;
  }

  Serial.print("CLOUD: remote sampling requested by command ");
  Serial.println(commandID);

  CloudSampleResult sample = {};
  if (!requestSampleFromMainLoop(&sample)) {
    return false;
  }
  return uploadCloudSample(commandID, sample);
}

void cloudTask(void *) {
  // Let BLE finish advertising and the first sample settle before bringing the
  // second radio up.
  vTaskDelay(pdMS_TO_TICKS(5000));

  // Load the upload cursor from NVS to resume from the last successful upload.
  loadUploadCursor();

  // Sync nextSequence with cloud to handle LittleFS ring buffer wrap-around.
  // If the ring buffer has overwritten newer data, LittleFS scan will report
  // an old newestSequence. Query the cloud to get the true latest sequence.
  if (ensureWiFiConnected()) {
    String url = cloudEndpoint("/sync/last_sequence");
    url += "?deviceId=";
    url += PLANT_CLOUD_DEVICE_ID;
    String response;
    if (cloudRequest("GET", url, String(), &response) == 200) {
      const int startPos = response.indexOf("\"lastSequence\":");
      if (startPos >= 0) {
        const int numStart = startPos + 15;
        const int numEnd = response.indexOf(',', numStart);
        const String seqStr = response.substring(numStart, numEnd > 0 ? numEnd : response.length());
        const uint32_t cloudLastSeq = static_cast<uint32_t>(seqStr.toInt());

        if (cloudLastSeq > lastUploadedSequence) {
          // The cloud cursor is authoritative for already accepted readings.
          // Persist it so a fresh NVS state does not resend old LittleFS data.
          lastUploadedSequence = cloudLastSeq;
          saveUploadCursor(lastUploadedSequence);
        }

        if (cloudLastSeq > 0 && cloudLastSeq >= nextSequence) {
          // Cloud has newer data. Advance only the allocation cursor; keep
          // newestSequence describing records that actually exist in LittleFS.
          nextSequence = cloudLastSeq + 1;
          Serial.printf(
            "CLOUD: adjusted nextSequence to %lu based on cloud state.\n",
            static_cast<unsigned long>(nextSequence)
          );
        }
      }
    }
  }

  for (;;) {
    // BLE is an intentionally exclusive local maintenance channel. Remote
    // commands can wait until it disconnects; continuing HTTPS/TLS work while a
    // client downloads history is what previously made notifications stall.
    if (clientConnected) {
      vTaskDelay(pdMS_TO_TICKS(250));
      continue;
    }
    if (!ensureWiFiConnected()) {
      vTaskDelay(pdMS_TO_TICKS(CLOUD_WIFI_RETRY_MS));
      continue;
    }
    // NTP is best-effort. HTTPS uses the existing estimated clock safely, so a
    // network that blocks UDP/123 must not disable remote sampling.
    updateClockFromNTP();
    if (!flushPendingCloudHistory()) {
      vTaskDelay(pdMS_TO_TICKS(CLOUD_POLL_BACKOFF_MS));
      continue;
    }
    const bool ok = runCloudPollCycle();
    vTaskDelay(pdMS_TO_TICKS(ok ? CLOUD_POLL_INTERVAL_MS : CLOUD_POLL_BACKOFF_MS));
  }
}

void initializeCloudTask() {
  if (strlen(PLANT_CLOUD_AUTH_TOKEN) == 0) {
    Serial.println("CLOUD: AUTH_TOKEN is empty; remote sampling disabled.");
    return;
  }

  cloudSampleMutex = xSemaphoreCreateMutex();
  cloudHistoryUploadQueue = xQueueCreate(
    CLOUD_HISTORY_UPLOAD_QUEUE_DEPTH,
    sizeof(CloudSampleResult)
  );
  if (cloudSampleMutex == nullptr || cloudHistoryUploadQueue == nullptr) {
    Serial.println("CLOUD: could not create sample delivery state; remote sampling disabled.");
    if (cloudSampleMutex != nullptr) {
      vSemaphoreDelete(cloudSampleMutex);
      cloudSampleMutex = nullptr;
    }
    if (cloudHistoryUploadQueue != nullptr) {
      vQueueDelete(cloudHistoryUploadQueue);
      cloudHistoryUploadQueue = nullptr;
    }
    return;
  }

  WiFi.onEvent(
    [](WiFiEvent_t, WiFiEventInfo_t info) {
      cloudLastWiFiDisconnectReason = info.wifi_sta_disconnected.reason;
    },
    WiFiEvent_t::ARDUINO_EVENT_WIFI_STA_DISCONNECTED
  );

  const BaseType_t created = xTaskCreatePinnedToCore(
    cloudTask,
    "cloudPoll",
    CLOUD_TASK_STACK_BYTES,
    nullptr,
    CLOUD_TASK_PRIORITY,
    &cloudTaskHandle,
    CLOUD_TASK_CORE
  );
  if (created != pdPASS) {
    Serial.println("CLOUD: could not start poll task; remote sampling disabled.");
    vSemaphoreDelete(cloudSampleMutex);
    cloudSampleMutex = nullptr;
    vQueueDelete(cloudHistoryUploadQueue);
    cloudHistoryUploadQueue = nullptr;
    return;
  }
  Serial.printf(
    "CLOUD: remote sampling enabled, polling every %lu ms as device %s.\n",
    CLOUD_POLL_INTERVAL_MS,
    PLANT_CLOUD_DEVICE_ID
  );
}
#endif

// Reflect physical Wi-Fi association without blocking the Arduino loop:
// searching/retrying flashes slowly, while an associated station stays lit.
// The LED intentionally follows Wi-Fi itself, not cloud HTTP success.
void updateWiFiStatusLED(unsigned long now) {
#if PLANT_CLOUD_ENABLED
  static unsigned long lastToggleAt = 0;
  static bool isOn = false;

  if (WiFi.status() == WL_CONNECTED) {
    isOn = true;
    lastToggleAt = now;
    digitalWrite(STATUS_LED_PIN, STATUS_LED_ON_LEVEL);
    return;
  }

  if (lastToggleAt == 0 || now - lastToggleAt >= WIFI_SEARCH_LED_TOGGLE_MS) {
    lastToggleAt = now;
    isOn = !isOn;
    digitalWrite(
      STATUS_LED_PIN,
      isOn ? STATUS_LED_ON_LEVEL : STATUS_LED_OFF_LEVEL
    );
  }
#else
  digitalWrite(STATUS_LED_PIN, STATUS_LED_OFF_LEVEL);
#endif
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, STATUS_LED_OFF_LEVEL);

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

#if PLANT_CLOUD_ENABLED
  initializeCloudTask();
#else
  Serial.println("Remote sampling not compiled in (no CloudConfig.h); BLE-only mode.");
#endif
}

void loop() {
  updateWiFiStatusLED(millis());
  connectPriorityDisplayIfFound();
  startDisplayScanIfNeeded();
  restartAdvertisingAfterDisconnect();
  processControlCommands();

  if (displayImmediateSamplePending
      && displayConnected
      && displayDataCharacteristic != nullptr) {
    displayImmediateSamplePending = false;
    // If this is the first endpoint after boot, use this sample as the normal
    // initial sample instead of creating a second record 15 seconds later.
    if (initialSamplePending) {
      initialSamplePending = false;
      lastSampleTime = millis();
    }
    sampleStoreAndPublish();
  }

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
