#include <Wire.h>
#include <Adafruit_SHT31.h>
#include <BH1750.h>

// ESP32 引脚定义
constexpr uint8_t I2C_SDA_PIN = 21;
constexpr uint8_t I2C_SCL_PIN = 22;
constexpr uint8_t SOIL_ADC_PIN = 34;

// 传感器常用 I2C 地址
constexpr uint8_t SHT31_ADDRESS = 0x44;
constexpr uint8_t BH1750_ADDRESS = 0x23;

// 采样间隔
constexpr unsigned long READ_INTERVAL_MS = 2000;

Adafruit_SHT31 sht31 = Adafruit_SHT31();
BH1750 lightMeter;

bool sht31Ready = false;
bool bh1750Ready = false;

unsigned long lastReadTime = 0;

// 扫描并打印 I2C 总线上的设备地址
void scanI2C() {
  Serial.println("Scanning I2C bus...");

  uint8_t deviceCount = 0;

  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    uint8_t error = Wire.endTransmission();

    if (error == 0) {
      Serial.printf("I2C device found at 0x%02X\n", address);
      deviceCount++;
    } else if (error == 4) {
      Serial.printf("Unknown I2C error at 0x%02X\n", address);
    }
  }

  if (deviceCount == 0) {
    Serial.println("No I2C devices found. Please check wiring.");
  } else {
    Serial.printf("I2C scan complete: %u device(s) found.\n", deviceCount);
  }

  Serial.println("----------------------");
}

// 尝试初始化尚未就绪的传感器
void initializeSensors() {
  if (!sht31Ready) {
    sht31Ready = sht31.begin(SHT31_ADDRESS);

    if (sht31Ready) {
      Serial.println("SHT31 initialized successfully.");
    } else {
      Serial.println(
        "ERROR: SHT31 initialization failed at address 0x44."
      );
    }
  }

  if (!bh1750Ready) {
    bh1750Ready = lightMeter.begin(
      BH1750::CONTINUOUS_HIGH_RES_MODE,
      BH1750_ADDRESS,
      &Wire
    );

    if (bh1750Ready) {
      Serial.println("BH1750 initialized successfully.");
    } else {
      Serial.println(
        "ERROR: BH1750 initialization failed at address 0x23."
      );
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("ESP32 Plant Sensor Demo");

  // 初始化 ESP32 I2C：SDA = GPIO21，SCL = GPIO22
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);

  // 可选：设置 I2C 时钟为标准的 100 kHz
  Wire.setClock(100000);

  // 扫描总线，正常情况下应看到 0x23 和 0x44
  scanI2C();

  // GPIO34 仅支持输入，适合读取模拟信号
  pinMode(SOIL_ADC_PIN, INPUT);

  // ESP32 Arduino ADC 默认通常为 12 位：0～4095
  analogReadResolution(12);

  initializeSensors();

  Serial.println("----------------------");
}

void loop() {
  unsigned long currentTime = millis();

  if (currentTime - lastReadTime < READ_INTERVAL_MS) {
    return;
  }

  lastReadTime = currentTime;

  // 如果初始化失败，后续每 2 秒再次尝试，程序不会卡死
  initializeSensors();

  // 读取 SHT31
  if (sht31Ready) {
    float temperature = sht31.readTemperature();
    float humidity = sht31.readHumidity();

    if (!isnan(temperature)) {
      Serial.printf("Temp: %.1f C\n", temperature);
    } else {
      Serial.println("Temp: read failed");
      sht31Ready = false;
    }

    if (!isnan(humidity)) {
      Serial.printf("Air Humidity: %.1f %%\n", humidity);
    } else {
      Serial.println("Air Humidity: read failed");
      sht31Ready = false;
    }
  } else {
    Serial.println("Temp: SHT31 unavailable");
    Serial.println("Air Humidity: SHT31 unavailable");
  }

  // 读取 BH1750
  if (bh1750Ready && lightMeter.measurementReady()) {
    float lux = lightMeter.readLightLevel();

    if (lux >= 0) {
      Serial.printf("Light: %.0f lx\n", lux);
    } else {
      Serial.println("Light: read failed");
      bh1750Ready = false;
    }
  } else if (bh1750Ready) {
    Serial.println("Light: measurement not ready");
  } else {
    Serial.println("Light: BH1750 unavailable");
  }

  // 读取 GPIO34 的 ADC 原始值，典型范围为 0～4095
  int soilAdcRaw = analogRead(SOIL_ADC_PIN);
  Serial.printf("Soil ADC Raw: %d\n", soilAdcRaw);

  Serial.println("----------------------");
}