# ESP32 硬件信息 (PlantSensorBLE)

本文档记录当前连接并用于开发 **PlantSensorBLE** 的 ESP32 硬件参数。

## 1. 核心硬件规格

| 参数项 | 检测参数 | 说明 |
| :--- | :--- | :--- |
| **芯片型号** | `ESP32-D0WD-V3` | Revision v3.1 |
| **CPU 核心** | 双核 (Dual Core) | 主频最高 240MHz |
| **Wi-Fi 支持** | **支持** | 2.4 GHz Wi-Fi (IEEE 802.11 b/g/n) |
| **蓝牙支持** | **支持** | Bluetooth v4.2 BR/EDR & BLE (低功耗蓝牙) |
| **Flash 容量** | 4 MB | 外部 SPI Flash (Manufacturer ID: 0b, Device: 4016) |
| **晶振频率** | 40 MHz | Crystal Frequency |
| **MAC 地址** | `8c:94:df:a1:c6:bc` | 硬件唯一 MAC 地址 |

## 2. 串口连接与调试参数

* **串口设备路径**: `/dev/cu.wchusbserial110` (macOS)
* **USB 转串口芯片**: CH340 / CH341
* **检测工具**: `esptool.py v4.7.0`
* **记录时间**: 2026-07-27

## 3. 功能验证

- [x] **Wi-Fi 接口**: 硬件具备完整 Wi-Fi 协议栈与 Radio 功能。
- [x] **BLE 接口**: 硬件支持 Bluetooth Low Energy 广播与连接。

## 4. 编译配置

### 分区方案（启用远程采样时必须改）

远程采样需要同时链接 BLE 与 Wi-Fi + TLS,固件体积约 1.82 MB,**默认分区的
1.25 MB APP 区装不下**(编译报 `text section exceeds available space`)。

| 模式 | 分区方案 | 固件占用 |
| :--- | :--- | :--- |
| 纯 BLE(无 `CloudConfig.h`) | 默认 `Default 4MB with spiffs` 即可 | 1.13 MB / 1.25 MB(90%) |
| BLE + 远程采样 | **`No OTA (2MB APP/2MB SPIFFS)`** | 1.78 MB / 2 MB(88%) |

Arduino IDE 里选 **工具 → Partition Scheme → No OTA (2MB APP/2MB SPIFFS)**。
命令行等价写法:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=no_ota firmware/PlantSensorBLE
```

本项目通过 USB 串口刷机,不使用 OTA,因此让出 OTA 备份区没有代价。SPIFFS 区
反而从 1.44 MB 增至 2 MB,LittleFS 历史环形缓冲的容量随之变大。

> 切换分区方案会重新划分 flash,**LittleFS 里已有的历史记录会丢失**。
> 刷机前先用 App 通过 BLE 把历史同步下来。

### 远程采样配置

复制 `CloudConfig.example.h` 为 `CloudConfig.h` 并填入 Wi-Fi 凭据、FC 地址与
`AUTH_TOKEN`。该文件已被 `.gitignore` 排除。不创建它则编译为纯 BLE 模式,行为
与加入 Wi-Fi 之前完全一致。

### Wi-Fi / BLE 射频共存

ESP32-D0WD-V3 的 Wi-Fi 与 BLE 共用同一个 2.4 GHz 射频。两者共存时 BLE 吞吐会
下降,历史同步比纯 BLE 模式慢。固件已开启 modem sleep(`WiFi.setSleep(true)`)
让共存仲裁在轮询间隙把射频交回 BLE,但下降无法完全消除。
