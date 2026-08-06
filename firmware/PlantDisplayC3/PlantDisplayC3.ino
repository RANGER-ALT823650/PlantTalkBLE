#include <Wire.h>
#include <U8g2lib.h>
#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// Plant Talk's no-cloud display endpoint. The ESP32-C3 is a BLE peripheral:
// it advertises as soon as it has power. The main ESP32 continuously scans for
// this dedicated service, disconnects iOS/Web if necessary, and connects here.

constexpr uint8_t PROTOCOL_VERSION = 1;
constexpr size_t LIVE_PACKET_SIZE = 16;
constexpr uint8_t FLAG_SHT31_VALID = 0x01;
constexpr uint8_t FLAG_BH1750_VALID = 0x02;

constexpr char DISPLAY_NAME[] = "Plant Display";
constexpr char DISPLAY_SERVICE_UUID[] = "7A1E1001-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr char DISPLAY_DATA_CHARACTERISTIC_UUID[] = "7A1E1002-7C6D-4A8B-9E1F-2D3C4B5A6000";
constexpr unsigned long ADVERTISING_RESTART_DELAY_MS = 100;

constexpr int OLED_SDA_PIN = 8;
constexpr int OLED_SCL_PIN = 9;
constexpr uint8_t OLED_ADDRESSES[] = {0x3C, 0x3D};

// The photographed 1.3-inch DST-013/H13 module uses the SH1106 memory layout.
// Driving it as SSD1306 enlarges and displaces the framebuffer, which made the
// packet-age digits look like a jumping counter bar.
U8G2_SH1106_128X64_NONAME_F_HW_I2C display(
  U8G2_R0,
  U8X8_PIN_NONE,
  OLED_SCL_PIN,
  OLED_SDA_PIN
);

struct PendingLivePacket {
  uint8_t bytes[LIVE_PACKET_SIZE];
};

bool oledReady = false;
uint8_t oledAddress = 0;
int oledSDA = -1;
int oledSCL = -1;
volatile bool mainConnected = false;
volatile bool advertisingRestartPending = false;
volatile unsigned long advertisingRestartRequestedAt = 0;
volatile bool displayRefreshPending = true;
QueueHandle_t livePacketQueue = nullptr;
bool hasReading = false;
bool sensorValuesValid = false;
bool lightValueValid = false;
float temperature = NAN;
float humidity = NAN;
float lightLux = NAN;
uint16_t soilRaw = 0;
unsigned long lastReadingAt = 0;

float readFloatLE(const uint8_t *source) {
  uint32_t bits = static_cast<uint32_t>(source[0])
    | (static_cast<uint32_t>(source[1]) << 8)
    | (static_cast<uint32_t>(source[2]) << 16)
    | (static_cast<uint32_t>(source[3]) << 24);
  float value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

uint16_t readUInt16LE(const uint8_t *source) {
  return static_cast<uint16_t>(source[0])
    | (static_cast<uint16_t>(source[1]) << 8);
}

void drawTextValue(const char *label, const char *value, int16_t y) {
  display.setCursor(0, y);
  display.print(label);
  // "Humidity" is 48 pixels wide in the built-in 6-pixel font. Leave a
  // visible gap so its value never overwrites the label.
  display.setCursor(56, y);
  display.print(value);
}

void renderDisplay() {
  if (!oledReady) {
    return;
  }

  display.clearBuffer();
  display.setDrawColor(1);
  display.setFont(u8g2_font_6x10_tf);
  display.drawStr(0, 8, "Plant Monitor");
  display.drawStr(98, 8, mainConnected ? "BLE" : "WAIT");
  display.drawHLine(0, 10, 128);

  if (!hasReading) {
    display.setCursor(0, 23);
    display.print(mainConnected ? "Main ESP32 connected" : "Waiting for main ESP32");
    display.setCursor(0, 38);
    display.print("Waiting for live data");
    display.setCursor(0, 53);
    display.print("Display has priority");
    display.sendBuffer();
    return;
  }

  char value[22] = {};
  if (sensorValuesValid) {
    snprintf(value, sizeof(value), "%.1f C", temperature);
  } else {
    snprintf(value, sizeof(value), "-- C");
  }
  drawTextValue("Temp", value, 22);

  if (sensorValuesValid) {
    snprintf(value, sizeof(value), "%.1f %%", humidity);
  } else {
    snprintf(value, sizeof(value), "-- %%");
  }
  drawTextValue("Humidity", value, 34);

  if (lightValueValid) {
    snprintf(value, sizeof(value), "%.0f lx", lightLux);
  } else {
    snprintf(value, sizeof(value), "-- lx");
  }
  drawTextValue("Light", value, 46);

  snprintf(value, sizeof(value), "%u raw", soilRaw);
  drawTextValue("Soil", value, 58);

  // Keep the screen stable between real sensor samples. The old per-second
  // packet-age counter was not useful on this dedicated display.
  display.sendBuffer();
}

void acceptLivePacket(const uint8_t *data, size_t length) {
  if (data == nullptr || length != LIVE_PACKET_SIZE || data[0] != PROTOCOL_VERSION) {
    Serial.printf("Ignored invalid live packet (%u bytes).\n", static_cast<unsigned>(length));
    return;
  }

  const uint8_t flags = data[1];
  sensorValuesValid = (flags & FLAG_SHT31_VALID) != 0;
  lightValueValid = (flags & FLAG_BH1750_VALID) != 0;
  soilRaw = readUInt16LE(data + 2);
  temperature = readFloatLE(data + 4);
  humidity = readFloatLE(data + 8);
  lightLux = readFloatLE(data + 12);
  hasReading = true;
  lastReadingAt = millis();

  Serial.printf(
    "Reading: temp=%.1f C humidity=%.1f %% light=%.0f lx soil=%u flags=0x%02X\n",
    temperature,
    humidity,
    lightLux,
    soilRaw,
    flags
  );
}

class LiveDataCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(
    NimBLECharacteristic *characteristic,
    NimBLEConnInfo &connection
  ) override {
    const NimBLEAttValue value = characteristic->getValue();
    if (value.size() != LIVE_PACKET_SIZE
        || value.data() == nullptr
        || value.data()[0] != PROTOCOL_VERSION
        || livePacketQueue == nullptr) {
      Serial.printf(
        "Ignored invalid live packet in BLE callback (%u bytes).\n",
        static_cast<unsigned>(value.size())
      );
      return;
    }

    // NimBLE invokes this callback on its host task. Never touch Wire or the
    // SSD1306 here: Adafruit's display buffer/I2C writes are not thread-safe.
    // A one-slot queue keeps only the newest reading for the Arduino loop.
    PendingLivePacket packet = {};
    memcpy(packet.bytes, value.data(), LIVE_PACKET_SIZE);
    xQueueOverwrite(livePacketQueue, &packet);
  }
};

class DisplayServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(
    NimBLEServer *server,
    NimBLEConnInfo &connection
  ) override {
    mainConnected = true;
    advertisingRestartPending = false;
    displayRefreshPending = true;
    Serial.printf(
      "Main ESP32 connected from %s.\n",
      connection.getAddress().toString().c_str()
    );
  }

  void onDisconnect(
    NimBLEServer *server,
    NimBLEConnInfo &connection,
    int reason
  ) override {
    mainConnected = false;
    displayRefreshPending = true;
    advertisingRestartRequestedAt = millis();
    advertisingRestartPending = true;
    Serial.printf(
      "Main ESP32 disconnected (reason %d); advertising will resume.\n",
      reason
    );
  }
};

bool addressResponds(uint8_t address) {
  Wire.beginTransmission(address);
  return Wire.endTransmission() == 0;
}

void initializeOLED() {
  Wire.end();
  if (!Wire.begin(OLED_SDA_PIN, OLED_SCL_PIN, 100000)) {
    Serial.println("Could not initialize the OLED I2C bus.");
    return;
  }
  delay(20);
  for (uint8_t address : OLED_ADDRESSES) {
    if (!addressResponds(address)) {
      continue;
    }
    Serial.printf(
      "SH1106 OLED ACK at 0x%02X on SDA=%d SCL=%d.\n",
      address,
      OLED_SDA_PIN,
      OLED_SCL_PIN
    );
    display.setI2CAddress(static_cast<uint8_t>(address << 1));
    display.setBusClock(100000);
    display.begin();
    oledReady = true;
    oledAddress = address;
    oledSDA = OLED_SDA_PIN;
    oledSCL = OLED_SCL_PIN;
    renderDisplay();
    return;
  }
  Serial.println("SH1106 OLED not found at 0x3C/0x3D on SDA=8 SCL=9.");
}

void initializeBLE() {
  NimBLEDevice::init(DISPLAY_NAME);
  NimBLEDevice::setPower(3);

  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new DisplayServerCallbacks());
  NimBLEService *service = server->createService(DISPLAY_SERVICE_UUID);
  NimBLECharacteristic *liveData = service->createCharacteristic(
    DISPLAY_DATA_CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR,
    LIVE_PACKET_SIZE
  );
  liveData->setCallbacks(new LiveDataCallbacks());
  service->start();

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(DISPLAY_SERVICE_UUID);
  advertising->enableScanResponse(true);
  advertising->setMinInterval(0x20);
  advertising->setMaxInterval(0x30);
  NimBLEDevice::startAdvertising();

  Serial.println("Priority display BLE advertising started.");
  displayRefreshPending = true;
}

void restartAdvertisingAfterDisconnect() {
  if (!advertisingRestartPending || mainConnected) {
    return;
  }
  if (millis() - advertisingRestartRequestedAt < ADVERTISING_RESTART_DELAY_MS) {
    return;
  }

  advertisingRestartPending = false;
  NimBLEDevice::startAdvertising();
  Serial.println("Priority display BLE advertising restarted.");
}

void setup() {
  Serial.begin(115200);
  delay(700);
  Serial.println("Plant Talk ESP32-C3 priority OLED BLE display");
  initializeOLED();
  livePacketQueue = xQueueCreate(1, sizeof(PendingLivePacket));
  if (livePacketQueue == nullptr) {
    Serial.println("ERROR: Could not allocate live-packet queue.");
  }
  initializeBLE();
}

void loop() {
  restartAdvertisingAfterDisconnect();

  PendingLivePacket packet = {};
  if (livePacketQueue != nullptr
      && xQueueReceive(livePacketQueue, &packet, 0) == pdTRUE) {
    acceptLivePacket(packet.bytes, sizeof(packet.bytes));
    displayRefreshPending = true;
  }

  static unsigned long lastRefreshAt = 0;
  if (displayRefreshPending || millis() - lastRefreshAt >= 1000) {
    displayRefreshPending = false;
    lastRefreshAt = millis();
    renderDisplay();
  }
  delay(20);
}
