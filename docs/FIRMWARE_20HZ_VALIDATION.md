# FootGuard 20 Hz 固件烧录与验证

## 固件边界

- 固件版本：`0.2.0`
- SensorData 通知：20 Hz，目标间隔 50 ms
- 压力与 MPU6050：每帧采集
- 温度：每 4 帧刷新一次，其余帧携带最近采样
- BLE 布局：`layout_6p4t_v1`，固定 60 字节，`protocol_version=1`

温度首次采样完成或当前刷新失败时，对应质量位保持无效。客户端必须忽略无效通道，不能将数值零解释成真实温度。连续帧温度相同是5 Hz缓存行为，不代表传感器卡死。

## 构建

在 ESP-IDF 5.5.4 PowerShell 中执行：

```powershell
Set-Location D:\Projects\footguard\firmware
idf.py -B build-left -D FOOTGUARD_DEVICE_VARIANT=0 build
idf.py -B build-right -D FOOTGUARD_DEVICE_VARIANT=1 build
```

构建后应分别确认二进制身份：

```text
build-left  -> FootGuard-L / foot_left_001
build-right -> FootGuard-R / foot_right_001
```

## 原生 USB 烧录

烧录前退出 App BLE 连接，并避免电池升压模块与电脑 USB 同时给开发板供电。

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
idf.py -B build-left -p COM左 flash monitor
idf.py -B build-right -p COM右 flash monitor
```

如果原生 USB 无法连接，按住 BOOT、短按 RESET、松开 BOOT，再查询一次 COM 号。只有 USB Serial/JTAG 仍无法枚举时才改用 UART。

## 单板验收

先验证一块板，再烧另一块：

1. 启动日志显示 `0.2.0`、正确侧别和协议自检全部通过。
2. App 完成 MTU、TimeSync 和 SensorData 订阅。
3. 连续采集2分钟，中位帧间隔接近50 ms，丢帧率低于2%。
4. 六路压力、四路温度和 MPU 均能产生有效数据。
5. 日志没有连续的 `Sensor acquisition exceeded 40 ms`。
6. `short`、`double`、`long`、`off` 均返回正确 ACK。

如果连续采集耗时超过40 ms，不直接修改协议。先记录日志；确认是ADC采样预算不足后，再将FSR每通道平均数从32降到16，并重新对比静止噪声和受力范围。

## 最小步态采集

两块板验收通过后只做低冲击采集：静止20秒、自然行走30秒、静止20秒、慢走30秒、静止20秒、转身后自然行走30秒。记录每段手机时间，不跑、不跳、不跺脚。

本轮数据只用于活动状态、左右交替承重、单步候选和步态节律的工程验证，不输出医学步态诊断。

2026-08-15 首轮结果与限制见 [GAIT_CAPTURE_2026-08-15.md](GAIT_CAPTURE_2026-08-15.md)。当前序号缺失约 27%，可用于基础算法开发，但尚未通过本文件要求的最终 20 Hz 验收。
