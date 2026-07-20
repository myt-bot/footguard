# FootGuard 左脚固件 BLE 实机验证报告

## 1. 报告信息

| 项目 | 内容 |
|---|---|
| 项目 | FootGuard 足安智垫 |
| 验证日期 | 2026-07-20 |
| 验证对象 | 左脚 ESP32-S3 固件 BLE 链路 |
| 固件分支 | `feature/firmware-ble` |
| 固件最终提交 | `ff2b4e1`（修复：完善 NimBLE 通知特征注册并匹配 8MB 闪存） |
| 合入主分支 | PR #6，合并提交 `a2fb40c` |
| ESP-IDF | v5.5.4 |
| 目标芯片 | ESP32-S3 |
| 开发板 | ESP32-S3-DevKitC-1 |
| 串口 | COM13 |
| 测试手机 | 华为 P40（Android） |
| BLE测试工具 | nRF Connect for Mobile |

## 2. 验证范围

本次验证覆盖：

- ESP-IDF 工程编译；
- 固件烧录和串口启动；
- 协议 CRC 与标准向量自测；
- BLE 广播、扫描和连接；
- GATT 服务及五个特征发现；
- MTU 协商；
- DeviceStatus 读取和通知；
- TimeSync 写入；
- 60 字节 SensorData 通知；
- 同步前后 SensorData 字段与 CRC；
- SensorData 订阅启停；
- 断线、重新广播和重新连接。

本次使用模拟传感器数据验证通信链路，尚未接入真实 FSR、NTC、MPU6050、马达和电量采集。

本次手机侧工具为 nRF Connect for Mobile，并非项目当前的 Flutter APK。因此，本报告证明固件 BLE 接口可被标准 BLE 客户端访问，不代表项目 APK 已经完成真实设备联调。

## 3. 硬件识别结果

烧录工具成功识别开发板：

```text
Chip is ESP32-S3 (QFN56) (revision v0.2)
Features: WiFi, BLE, Embedded PSRAM 8MB (AP_3v3)
Crystal is 40MHz
MAC: 58:e6:c5:74:71:70
```

BLE 控制器使用的地址：

```text
58:E6:C5:74:71:72
```

Flash 配置和启动日志确认：

```text
SPI Flash Size : 8MB
ESP-IDF        : v5.5.4
```

## 4. 编译与烧录结果

使用命令：

```powershell
cd D:\Projects\footguard\firmware
idf.py -p COM13 flash monitor
```

烧录成功，应用镜像信息：

```text
footguard_firmware.bin binary size 0x75170 bytes
Smallest app partition is 0x100000 bytes
0x8ae90 bytes (54%) free
```

烧录过程完成数据校验：

```text
Hash of data verified.
Hard resetting via RTS pin...
```

结论：**通过**。

## 5. 启动和协议自测

启动日志：

```text
Firmware name: FootGuard
Firmware version: 0.1.0
Device side: left
Device ID: foot_left_001
CRC self-test: PASS
Left standard frame self-test: PASS
Right standard frame self-test: PASS
```

验证内容：

- CRC-16/CCITT-FALSE 自测通过；
- 左脚 60 字节标准向量逐字节自测通过；
- 右脚 60 字节标准向量逐字节自测通过。

结论：**通过**。

## 6. BLE 广播与连接

开发板启动后成功广播：

```text
Advertising started: name=FootGuard-L side=left
NimBLE initialized with 5 Hz mock SensorData
```

固件广播配置明确将完整 FootGuard 128 位服务 UUID 放入主广播包：

```c
fields.uuids128 = (ble_uuid128_t *)footguard_gatt_service_uuid();
fields.num_uuids128 = 1;
fields.uuids128_is_complete = 1;
ble_gap_adv_set_fields(&fields);
```

设备名称 `FootGuard-L` 放在扫描响应中。需要注意：本次已经验证手机能够发现、连接并在连接后发现该服务，但没有单独保存原始 Advertising PDU，因此“广播包原始字节中包含服务 UUID”目前属于**代码配置确认**，不是独立的空口抓包证据。手机 App 在完成真实扫描验证前，不应只依赖服务 UUID 过滤；更稳妥的策略是先按 `FootGuard-L`/`FootGuard-R` 名称识别候选设备，连接后再严格校验服务 UUID 和五个特征 UUID。

华为 P40 能够扫描并连接设备：

```text
设备名：FootGuard-L
BLE地址：58:E6:C5:74:71:72
```

连接日志：

```text
Connection established: handle=1 MTU=23
MTU updated: handle=1 MTU=247
```

结论：**广播、连接和 MTU 247 协商均通过**。

## 7. GATT 服务与特征

手机成功发现 FootGuard 主服务：

```text
7d2f0000-5a6b-4c7d-8e9f-102030405060
```

发现的特征如下：

| 名称 | UUID | 属性 | 方向 | 结果 |
|---|---|---|---|---|
| SensorData | `7d2f0001-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 → App | 通过 |
| DeviceStatus | `7d2f0002-5a6b-4c7d-8e9f-102030405060` | Read/Notify | ESP32 → App | 通过 |
| DeviceCommand | `7d2f0003-5a6b-4c7d-8e9f-102030405060` | Write With Response | App → ESP32 | 特征发现通过，命令执行尚未实现 |
| TimeSync | `7d2f0004-5a6b-4c7d-8e9f-102030405060` | Write With Response | App → ESP32 | 通过 |
| AckEvent | `7d2f0005-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 → App | 特征发现通过，事件生成尚未实现 |

结论：**服务和五个特征均与协议文档一致**。

## 8. DeviceStatus 验证

DeviceStatus 能够通过 Read 获取紧凑 UTF-8 JSON。左脚返回内容包含：

同步前实际读取到的完整紧凑 JSON 原文：

```json
{"protocol_version":1,"firmware_version":"0.1.0","device_id":"foot_left_001","side":"left","sensor_layout_version":"layout_6p4t_v1","battery":95,"state":"idle","error_code":"none","time_synced":false,"sync_id":0}
```

为便于阅读，格式化后为：

```json
{
  "protocol_version": 1,
  "firmware_version": "0.1.0",
  "device_id": "foot_left_001",
  "side": "left",
  "sensor_layout_version": "layout_6p4t_v1",
  "battery": 95,
  "state": "idle",
  "error_code": "none",
  "time_synced": false,
  "sync_id": 0
}
```

订阅 DeviceStatus Notify 后，实际观察到状态变化：

```text
idle → streaming → idle
```

TimeSync 成功后，DeviceStatus 更新为：

```text
time_synced=true
sync_id=1
```

同步后实际读取到的完整紧凑 JSON 原文：

```json
{"protocol_version":1,"firmware_version":"0.1.0","device_id":"foot_left_001","side":"left","sensor_layout_version":"layout_6p4t_v1","battery":95,"state":"idle","error_code":"none","time_synced":true,"sync_id":1}
```

断线重连后，DeviceStatus 恢复为：

```text
time_synced=false
sync_id=0
state=idle
```

结论：**Read、Notify、状态切换及断线复位均通过**。

## 9. SensorData 通知验证

SensorData 仅在以下条件同时满足时发送：

- BLE 已连接；
- SensorData CCCD 已订阅；
- MTU ≥ 63。

手机订阅后，固件以约 5 Hz（每 200 ms 一帧）持续发送：

```text
SensorData subscription enabled
SensorData notifications started
SensorData notifications sent: count=225 latest_packet_seq=224
```

取消订阅后停止发送：

```text
SensorData subscription disabled
SensorData notifications stopped
```

结论：**通知启停和 5 Hz 连续发送通过**。

## 10. 同步前 60 字节实收帧

手机实际接收：

```text
46 47 01 02 00 00 08 00 00 00 00 00 00 D3 00 00
00 00 00 00 00 00 00 00 00 B0 04 60 09 10 0E C0
12 B8 0B 68 10 35 0C 4E 0C 08 0C 17 0C 00 00 00
00 E8 03 00 00 00 00 00 00 5F 07 5F
```

解析结果：

| 字段 | 值 |
|---|---:|
| magic | `0x4746`（字节为 `46 47`） |
| protocol_version | 1 |
| layout_id | 2 |
| side | 0（left） |
| quality_flags | `0x00000800`（TIME_UNSYNCED） |
| sync_id | 0 |
| packet_seq | 211 |
| timestamp_ms | 0 |
| 帧长度 | 60 字节 |
| CRC（小端） | `0x5F07` |

重新计算 CRC 与帧尾 CRC 一致。

结论：**通过**。

## 11. TimeSync 验证

PowerShell 生成的 12 字节小端序载荷：

```text
01 00 00 00 E9 45 92 7D 9F 01 00 00
```

字段含义：

| 偏移 | 类型 | 值 |
|---:|---|---:|
| 0～3 | uint32 little-endian | sync_id = 1 |
| 4～11 | uint64 little-endian | unix_time_ms = 1784518165993 |

固件确认：

```text
TimeSync accepted: sync_id=1 timestamp_ms=1784518165993
```

结论：**通过**。

## 12. 同步后 60 字节实收帧

手机实际接收：

```text
46 47 01 02 00 00 00 00 00 01 00 00 00 F1 00 00
00 02 5E 94 7D 9F 01 00 00 B0 04 60 09 10 0E C0
12 B8 0B 68 10 35 0C 4E 0C 08 0C 17 0C 00 00 00
00 E8 03 00 00 00 00 00 00 5F 93 04
```

解析结果：

| 字段 | 值 |
|---|---:|
| magic | `0x4746` |
| protocol_version | 1 |
| layout_id | 2 |
| side | 0（left） |
| quality_flags | `0x00000000` |
| sync_id | 1 |
| packet_seq | 241 |
| timestamp_ms | 1784518303234 |
| 帧长度 | 60 字节 |
| CRC（小端） | `0x0493` |

验证结果：

- `TIME_UNSYNCED` 已清除；
- `sync_id` 从 0 更新为 1；
- `timestamp_ms` 变为有效 Unix 毫秒时间；
- `packet_seq` 持续递增；
- 重新计算 CRC 与帧尾 CRC 一致。

结论：**通过**。

## 13. 断线重连验证

手机断开后，固件自动重新开始广播：

```text
Disconnected: reason=531; restarting advertising
Advertising started: name=FootGuard-L side=left
```

手机能够再次连接并重新协商 MTU：

```text
Connection established: handle=1 MTU=23
MTU updated: handle=1 MTU=247
```

重连后同步状态被清除，需要 App 再次写入 TimeSync。

结论：**通过**。

## 14. 验证结论

左脚 ESP32-S3 的 BLE 基础链路已经完成实机闭环验证：

```text
ESP32-S3启动
→ BLE广播
→ Android扫描和连接
→ MTU 247
→ GATT服务发现
→ DeviceStatus读取/通知
→ TimeSync写入
→ 60字节SensorData通知
→ App侧接收
→ CRC验证
→ 断线重连
```

本次验证结果可作为手机端实现以下功能的固件依据：

- 搜索 `FootGuard-L`；
- 发现 FootGuard 服务；
- 请求较大 MTU；
- 读取和订阅 DeviceStatus；
- 写入 12 字节 TimeSync；
- 订阅并解析 60 字节 SensorData；
- 校验 magic、协议版本、布局、side、CRC、序号和时间戳；
- 断线后重新连接并重新同步时间。

## 15. 尚未验证或尚未实现

以下内容不属于本次“左脚 BLE 模拟数据链路”通过范围：

- 右脚实体 ESP32-S3 开发板；
- 手机同时连接左右两块 ESP32-S3；
- 当前 Flutter APK 在华为 P40 上扫描和连接 `FootGuard-L`；
- 当前 Flutter APK 的扫描阶段服务 UUID 过滤兼容性；
- 当前 Flutter APK 自动请求 MTU、读取/订阅 DeviceStatus、自动 TimeSync 和订阅 SensorData；
- 当前 Flutter APK 对实收 60 字节帧的解析与 CRC 回归测试；
- 双足采样相位严格同步；
- 双足帧时间差始终不超过 50 ms；
- 真实 FSR402B 压力采集；
- 真实 10K B3950 NTC 温度采集；
- MPU6050 六轴数据采集；
- 真实电池电量测量；
- DeviceCommand 指令解析和马达执行；
- AckEvent 的 `executed`、`failed`、`rejected`、`expired`；
- 长时间稳定性、丢包率、功耗和续航测试；
- 医疗准确性或医疗诊断有效性。

## 16. 当前判定

**左脚 BLE 模拟数据通信链路：通过。**

**右脚和双足联合验证：待第二块开发板到位后进行。**

**真实传感器链路：进入下一阶段开发。**
