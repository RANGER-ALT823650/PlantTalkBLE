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
