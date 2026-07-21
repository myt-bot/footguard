# FootGuard 固件

FootGuard ESP32-S3 双足设备固件，基于 ESP-IDF v5.5.4 和内置 NimBLE C 协议栈开发，不使用 Arduino 或外部 BLE 组件。

## 当前状态

固件已完成以下基础能力：

- 协议 CRC 和标准 SensorData 帧自测；
- 单连接 BLE 外设；
- 左右脚设备身份配置；
- MTU 协商后的 5 Hz SensorData Notify；
- DeviceStatus Read/Notify；
- TimeSync 写入和断线后清除时间基准；
- 单路 FSR ADC 驱动验证代码；
- 单路 NTC 10K B3950 温度采集验证；
- 单个 GY-521 MPU6050 六轴数据采集验证；
- GPIO13 高电平有效的马达控制和一次性测试时序。

当前 BLE SensorData 仍使用模拟数据，尚未把真实 FSR、NTC 和 MPU6050 数据写入固定 60 字节帧。电量值也是模拟值。

DeviceCommand 仍会被拒绝，真实命令执行、重复命令去重和 AckEvent 通知尚未实现。GPIO13 马达时序已通过串口验证，但真实马达和驱动模块尚未完成接线震动测试。

## 固定协议

当前协议布局为 `layout_6p4t_v1`：

- 每足 6 路压力和 4 路温度；
- `protocol_version=1`；
- `layout_id=2`；
- SensorData 固定 60 字节；
- CRC-16/CCITT-FALSE 覆盖字节 0～57；
- CRC 以小端序存放在字节 58～59；
- SensorData 仅在客户端订阅 Notify 且协商 MTU 足以承载数据后发送。

## 当前引脚分配

| 功能 | ESP32-S3 引脚 | 当前状态 |
| --- | --- | --- |
| FSR P1 | GPIO1 / ADC1_CH0 | 单路 ADC 驱动已实现，当前启动流程未运行 FSR 任务 |
| NTC T1 | GPIO7 / ADC1_CH6 | 已完成桌面、手指加热和冷却变化验证 |
| MPU6050 SDA | GPIO11 | 已完成静止、改变姿态和快速转动验证 |
| MPU6050 SCL | GPIO12 | I2C 100 kHz，地址 0x68 |
| 马达 IO/PWM | GPIO13 | 高电平启动；软件时序已验证，真实震动待验证 |

左右脚开发板使用相同的传感器和马达引脚分配，通过 `main/footguard_config.h` 选择设备身份。

## FSR 单路驱动

`footguard_fsr.c` 当前实现 GPIO1 单路 ADC oneshot 读取：

- ADC1_CH0；
- 12 dB 衰减；
- 每次读取平均 32 个原始样本。

早期 FSR402B 已完成按压变化验证，但原传感器量程不适合最终鞋垫。最终压力传感器及 47 kΩ 分压电阻到货后，需要重新完成量程、饱和点和重复性验证。真实压力值尚未接入 BLE SensorData。

## NTC 单路验证

`footguard_ntc.c` 当前支持 GPIO7 上的一路 NTC 10K B3950：

- 10 kΩ 固定分压电阻；
- ADC1_CH6；
- 12 dB 衰减；
- ADC 曲线拟合校准；
- 每次读取平均 32 个样本；
- 输出 ADC 原始值、毫伏值和摄氏温度。

已实测桌面温度约 28℃，手指捏住后上升到约 35℃，冷却后能够正常下降。NTC 未连接时 ADC 引脚悬空，串口温度没有物理意义。

## MPU6050 单模块验证

`footguard_mpu6050.c` 当前配置：

- GY-521 MPU6050；
- I2C 地址 `0x68`；
- SDA=GPIO11，SCL=GPIO12；
- I2C 频率 100 kHz；
- 加速度计量程 ±2 g；
- 陀螺仪量程 ±250 °/s；
- 读取三轴加速度、三轴角速度和芯片温度。

已完成静止、直立和快速转动验证。快速转动时达到 ±2 g 或 ±250 °/s 属于当前量程饱和，不代表通信故障。模块未连接时启动日志会报告 `ESP_ERR_NOT_FOUND`。

## 马达 GPIO 验证

`footguard_motor.c` 使用 GPIO13 控制高电平有效的 MOSFET 马达驱动模块：

- 初始化后首先强制输出低电平；
- 启动 3 秒后输出一次 300 ms 高电平；
- 等待 1 秒；
- 输出两次各 250 ms 的高电平，中间间隔 200 ms；
- 测试结束后强制恢复低电平并删除测试任务。

该启动测试只用于硬件验证，后续实现 DeviceCommand 时应移除自动震动，改为由通过校验的命令控制，并在执行后通过 AckEvent 返回真实结果。

## BLE 服务

| 项目 | UUID | 属性 | 方向 |
| --- | --- | --- | --- |
| FootGuard Service | `7d2f0000-5a6b-4c7d-8e9f-102030405060` | Primary | - |
| SensorData | `7d2f0001-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 → App |
| DeviceStatus | `7d2f0002-5a6b-4c7d-8e9f-102030405060` | Read、Notify | ESP32 → App |
| DeviceCommand | `7d2f0003-5a6b-4c7d-8e9f-102030405060` | Write With Response | App → ESP32 |
| TimeSync | `7d2f0004-5a6b-4c7d-8e9f-102030405060` | Write With Response | App → ESP32 |
| AckEvent | `7d2f0005-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 → App |

App 应协商 MTU 247。TimeSync 为 12 字节小端载荷：4 字节非零 `sync_id`，随后是 8 字节 Unix 毫秒时间。设备断开连接后会清除时间基准，重新连接必须再次同步。

当前 DeviceCommand 不会控制马达，也不会生成虚假的 `executed` ACK。

## 设备配置

在 `main/footguard_config.h` 中修改 `FOOTGUARD_DEVICE_VARIANT`：

| Variant | BLE 名称 | Device ID | Side |
| --- | --- | --- | --- |
| Left（默认） | `FootGuard-L` | `foot_left_001` | `left` / 0 |
| Right | `FootGuard-R` | `foot_right_001` | `right` / 1 |

## 构建、烧录和监视

在 ESP-IDF v5.5.4 终端中进入 `firmware` 目录：

```text
idf.py set-target esp32s3
idf.py build
```

左脚板：

```text
idf.py -p COM13 flash monitor
```

右脚板：

```text
idf.py -p COM14 flash monitor
```

按 `Ctrl+]` 退出串口监视器。

固件只有在 CRC 和左右标准 SensorData 帧自测全部通过后才会启动 BLE。

## 后续工作

1. 完成真实马达和驱动模块接线验证；
2. 实现 DeviceCommand 校验、马达执行、命令去重和 AckEvent；
3. 将 6 路压力、4 路温度和 MPU6050 真实数据接入 SensorData；
4. 完成左右脚固件烧录和 App 双足联调；
5. 完成电池电量采集及最终鞋垫装配验证。