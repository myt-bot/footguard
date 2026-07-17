# FootGuard BLE 协议 v1

## 1. 设备身份

| 项目 | 左脚 | 右脚 |
|---|---|---|
| 广播名称 | FootGuard-L | FootGuard-R |
| device_id | foot_left_001 | foot_right_001 |
| side | left | right |

App 必须同时校验服务 UUID 和设备侧别，不能只依据广播名称连接。

## 2. GATT UUID

服务 UUID：

~~~text
7d2f0000-5a6b-4c7d-8e9f-102030405060
~~~

| 特征值 | UUID | 属性 | 方向 |
|---|---|---|---|
| SensorData | 7d2f0001-5a6b-4c7d-8e9f-102030405060 | Notify | ESP32 → App |
| DeviceStatus | 7d2f0002-5a6b-4c7d-8e9f-102030405060 | Read/Notify | ESP32 → App |
| DeviceCommand | 7d2f0003-5a6b-4c7d-8e9f-102030405060 | Write | App → ESP32 |
| TimeSync | 7d2f0004-5a6b-4c7d-8e9f-102030405060 | Write | App → ESP32 |
| AckEvent | 7d2f0005-5a6b-4c7d-8e9f-102030405060 | Notify | ESP32 → App |

## 3. MTU 与频率

1. App 连接后请求 MTU 不小于 100，推荐 247。
2. 第一版 SensorData 采样和通知频率从 5 Hz 开始。
3. MTU 不足时不得静默截断，应报告协议错误或使用后续分包协议。

## 4. SensorData 固定帧

- 总长度：58 字节。
- 字节序：little-endian。
- CRC：CRC-16/CCITT-FALSE，多项式 0x1021，初值 0xFFFF。
- device_id 由连接上下文和 DeviceStatus 提供，不在每一帧重复发送。

| 偏移 | 长度 | 类型 | 字段 | 编码 |
|---:|---:|---|---|---|
| 0 | 2 | bytes | magic | 固定 0x46 0x47，即 ASCII FG |
| 2 | 1 | uint8 | protocol_version | 固定 1 |
| 3 | 1 | uint8 | layout_id | 1=layout_6p3t_v1 |
| 4 | 1 | uint8 | side | 0=left，1=right |
| 5 | 4 | uint32 | quality_flags | 见 enums_v1.md |
| 9 | 4 | uint32 | sync_id | 时间同步编号 |
| 13 | 4 | uint32 | packet_seq | 单设备递增序号 |
| 17 | 8 | uint64 | timestamp_ms | Unix 毫秒时间 |
| 25 | 12 | 6×uint16 | pressure | round(value×10000) |
| 37 | 6 | 3×int16 | temperature | round(℃×100) |
| 43 | 6 | 3×int16 | acceleration | 单位 mg |
| 49 | 6 | 3×int16 | gyroscope | round(°/s×10) |
| 55 | 1 | uint8 | battery | 0～100 |
| 56 | 2 | uint16 | crc16 | 对偏移 0～55 计算 |

解码公式：

~~~text
pressure_value = encoded / 10000.0
temperature_c = encoded / 100.0
acceleration_m_s2 = encoded_mg * 9.80665 / 1000.0
gyroscope_deg_s = encoded / 10.0
~~~

## 5. DeviceStatus

DeviceStatus 使用 UTF-8 JSON：

~~~json
{
  "protocol_version": 1,
  "firmware_version": "0.1.0",
  "device_id": "foot_left_001",
  "side": "left",
  "sensor_layout_version": "layout_6p3t_v1",
  "battery": 95,
  "state": "streaming",
  "error_code": "none"
}
~~~

## 6. TimeSync

固定 12 字节，小端序：

| 偏移 | 长度 | 类型 | 字段 |
|---:|---:|---|---|
| 0 | 4 | uint32 | sync_id |
| 4 | 8 | uint64 | unix_time_ms |

## 7. DeviceCommand

低频指令使用紧凑 UTF-8 JSON，并通过 command_schema_v1.json 校验。

执行前检查：

1. target 与设备 side 匹配，或 target 为 both。
2. pattern 位于白名单。
3. command_id 未执行过。
4. expire_at_ms 未过期。
5. 不符合条件时返回 rejected 或 expired ACK，不得执行。

## 8. AckEvent

ACK 使用 UTF-8 JSON，字段见 examples/ack_executed.json。

## 9. 解析失败

以下情况丢弃当前帧并记录日志：

- 长度不是 58；
- magic 错误；
- protocol_version 不支持；
- side 与连接设备不一致；
- CRC 失败；
- 解码后数值明显越界。

序号跳变时可保留后续合法帧，但应记录丢包并设置 PACKET_GAP。

