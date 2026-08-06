# PlantDisplayC3

ESP32-C3 + 128x64 SH1106 OLED 的独立 BLE 显示端。显示器一通电就广播专用的
`Plant Display` 服务；主 ESP32 持续扫描该服务，发现后立即主动连接并推送温度、
空气湿度、光照和土壤 ADC 原始值。

## 连接规则

显示器具有最高连接优先级。主 ESP32 发现通电的显示器后会停止面向 iOS/Web 的
广播；如果 App 或浏览器已经连接，主 ESP32 会先强制断开它，再连接显示器。显示器
断电后，主 ESP32 才恢复面向 iOS/Web 的广播。因此任意时刻仍然只有一个独立端。

## OLED

实物照片确认当前 1.3 英寸 `DST-013 / H13` 模块需要 SH1106 显存布局；若按
SSD1306 驱动，会出现文字放大、错位和类似“横条数字跳秒”的画面。固件现在使用
U8g2 的 SH1106 128x64 驱动，并扫描 `0x3C` / `0x3D`。

- SDA 8
- SCL 9

界面不会再显示每秒递增的数据包年龄；四项数值只在收到新的采样时更新。

## 编译与上传

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc firmware/PlantDisplayC3
arduino-cli upload -p /dev/cu.usbmodem101 --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc firmware/PlantDisplayC3
```
