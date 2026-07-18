# FootGuard BLE 协议 v1

## 1. 设备身份

| 项目 | 左脚 | 右脚 |
|---|---|---|
| 广播名称 | FootGuard-L | FootGuard-R |
| device_id | foot_left_001 | foot_right_001 |
| side | left | right |

1. App 必须同时校验服务 UUID、DeviceStatus.side 和 SensorData.side，不能只依据广播名称连接。
2. 广播名称、DeviceStatus.side 和 SensorData.side 不一致时，App 必须断开并报告 SIDE_MISMATCH。
3. side 由固件编译配置或受控 NVS 配置确定，不允许普通运行流程动态修改。
4. device_id 为 1～16 个 ASCII 字符，在同一套双足设备中必须唯一。
5. App 同时发现多个相同 side 的设备时不得自动猜测，应让用户选择或使用已绑定的 device_id。

## 2. GATT UUID 与操作语义

服务 UUID：

~~~text
7d2f0000-5a6b-4c7d-8e9f-102030405060
~~~

| 特征值 | UUID | 属性 | 方向 | v1 语义 |
|---|---|---|---|---|
| SensorData | 7d2f0001-5a6b-4c7d-8e9f-102030405060 | Notify | ESP32 → App | 每次 Notify 恰好一条 58 字节帧 |
| DeviceStatus | 7d2f0002-5a6b-4c7d-8e9f-102030405060 | Read/Notify | ESP32 → App | 连接后读取；状态变化时 Notify |
| DeviceCommand | 7d2f0003-5a6b-4c7d-8e9f-102030405060 | Write With Response | App → ESP32 | 低频紧凑 JSON 指令 |
| TimeSync | 7d2f0004-5a6b-4c7d-8e9f-102030405060 | Write With Response | App → ESP32 | 12 字节时间同步数据 |
| AckEvent | 7d2f0005-5a6b-4c7d-8e9f-102030405060 | Notify | ESP32 → App | 指令最终结果紧凑 JSON |

GATT Write Response 只表示设备收到了写入，不表示指令已经执行。DeviceCommand 的最终结果必须以 AckEvent 为准。

## 3. MTU、单包与频率

1. App 连接后请求 MTU 247。
2. SensorData 需要协商 MTU 至少为 61；否则不得开始流式传输。
3. DeviceStatus、DeviceCommand 和 AckEvent 使用无缩进、无多余空格的紧凑 UTF-8 JSON。
4. 单条 BLE JSON 的 UTF-8 编码长度不得超过 244 字节。
5. 发送 JSON 前必须确认 `json_utf8_length <= negotiated_mtu - 3`。
6. MTU 或长度不足时不得静默截断，应报告 MTU_INSUFFICIENT 并停止对应操作。
7. v1 不支持 SensorData 或 JSON 分包，也不允许在一次 Notify 中拼接多条消息。
8. 第一版 SensorData 采样和通知频率从 5 Hz 开始。
9. DeviceStatus 仅在连接后读取或状态变化时通知；AckEvent 仅在命令产生最终结果时通知。

## 4. SensorData 固定帧

- 总长度：58 字节。
- 字节序：所有多字节整数均为 little-endian。
- 每次 SensorData Notify 必须且只能发送一条完整的 58 字节帧。
- CRC：CRC-16/CCITT-FALSE，对偏移 0～55 计算，CRC 字段本身不参与计算。
- device_id 由连接上下文和 DeviceStatus 提供，不在每一帧重复发送。

| 偏移 | 长度 | 类型 | 字段 | 编码 |
|---:|---:|---|---|---|
| 0 | 2 | bytes | magic | 固定 0x46 0x47，即 ASCII FG |
| 2 | 1 | uint8 | protocol_version | 固定 1 |
| 3 | 1 | uint8 | layout_id | 1=layout_6p3t_v1 |
| 4 | 1 | uint8 | side | 0=left，1=right |
| 5 | 4 | uint32 | quality_flags | 见 enums_v1.md |
| 9 | 4 | uint32 | sync_id | 时间同步编号；0 表示未同步 |
| 13 | 4 | uint32 | packet_seq | 单设备递增序号 |
| 17 | 8 | uint64 | timestamp_ms | Unix 毫秒；未同步时为 0 |
| 25 | 12 | 6×uint16 | pressure | round_half_away_from_zero(value×10000) |
| 37 | 6 | 3×int16 | temperature | round_half_away_from_zero(℃×100) |
| 43 | 6 | 3×int16 | acceleration | round_half_away_from_zero(m/s²÷9.80665×1000)，单位 mg |
| 49 | 6 | 3×int16 | gyroscope | round_half_away_from_zero(°/s×10) |
| 55 | 1 | uint8 | battery | 0～100 |
| 56 | 2 | uint16 | crc16 | CRC 值按小端序写入，低字节在前 |

解码公式：

~~~text
pressure_value = encoded / 10000.0
temperature_c = encoded / 100.0
acceleration_m_s2 = encoded_mg * 9.80665 / 1000.0
gyroscope_deg_s = encoded / 10.0
~~~

编码取整统一采用“最近整数，中点远离 0”。压力值超出 0～1、温度超出 -40～125℃或 IMU 超出所配置量程时，固件按 field_dictionary.md 限幅或填 0，并设置相应 quality_flags。

## 5. CRC-16/CCITT-FALSE

完整参数：

~~~text
width   = 16
poly    = 0x1021
init    = 0xFFFF
refin   = false
refout  = false
xorout  = 0x0000
check("123456789") = 0x29B1
~~~

CRC 对 SensorData 偏移 0～55 的 56 个字节按顺序计算。计算结果作为 uint16 小端序写入偏移 56～57，即先写低字节，再写高字节。

固件和 App 必须分别使用以下标准向量进行独立测试：

- examples/sensor_frame_left_v1.hex
- examples/sensor_frame_right_v1.hex
- examples/ble_test_vectors_v1.md

## 6. DeviceStatus

DeviceStatus 使用紧凑 UTF-8 JSON，并通过 device_status_schema_v1.json 校验。标准结构：

~~~json
{
  "protocol_version": 1,
  "firmware_version": "0.1.0",
  "device_id": "foot_left_001",
  "side": "left",
  "sensor_layout_version": "layout_6p3t_v1",
  "battery": 95,
  "state": "streaming",
  "error_code": "none",
  "time_synced": true,
  "sync_id": 1
}
~~~

1. firmware_version 长度为 1～12 个 ASCII 字符。
2. device_id 长度为 1～16 个 ASCII 字符。
3. state 和 error_code 使用 enums_v1.md 中的 DeviceStatus 枚举。
4. time_synced=false 时 sync_id 必须为 0；time_synced=true 时 sync_id 必须大于 0。
5. App 连接后先读取 DeviceStatus，校验版本、布局和侧别，再订阅 SensorData。
6. 电量、状态、错误、同步状态发生变化时，ESP32 应发送新的 DeviceStatus Notify。

## 7. TimeSync

TimeSync 使用 Write With Response，固定 12 字节，小端序：

| 偏移 | 长度 | 类型 | 字段 |
|---:|---:|---|---|
| 0 | 4 | uint32 | sync_id |
| 4 | 8 | uint64 | unix_time_ms |

处理规则：

1. App 每次新连接后生成非 0 sync_id，并写入当前 Unix 毫秒时间。
2. ESP32 在收到写入时记录 unix_time_ms 与本地单调时钟基准，后续由二者计算 timestamp_ms。
3. 写入成功后 ESP32 设置 time_synced=true、保存 sync_id、清除 TIME_UNSYNCED，并更新 DeviceStatus。
4. App 必须重新读取或等待 DeviceStatus Notify，确认 time_synced=true 且 sync_id 与本次写入一致。
5. ESP32 重启后 time_synced=false、sync_id=0、timestamp_ms=0，并在 SensorData 中设置 TIME_UNSYNCED，直到再次同步。
6. 未完成时间同步时，ESP32 必须拒绝依赖 expire_at_ms 的 DeviceCommand，并返回 rejected/time_unsynced。
7. App 在重新连接后必须重新同步；长时间连接可按配置周期重新同步，第一版建议每 10 分钟一次。

标准字节样例见 examples/time_sync_v1.hex。

## 8. DeviceCommand

DeviceCommand 使用紧凑 UTF-8 JSON，通过 command_schema_v1.json 校验，并使用 Write With Response。

执行前按顺序检查：

1. JSON 可解析且 protocol_version=1。
2. target 与设备 side 匹配，或 target 为 both；target=none 不允许进入 BLE DeviceCommand。
3. pattern 和 duration_ms 满足 Schema。
4. command_id 与缓存中的已执行命令不存在冲突。
5. 设备已经完成 TimeSync，且 expire_at_ms 未过期。
6. 马达和设备状态允许执行。

pattern 语义：

| pattern | duration_ms 语义 | v1 执行方式 |
|---|---|---|
| off | 必须为 0 | 立即停止马达 |
| short | 100～1000 | 单次连续震动，通电时间为 duration_ms |
| double | 200～2000 | 总通电时间为 duration_ms；分为两次，第一次 floor(duration_ms/2)，第二次为剩余时间，中间固定间隔 200 ms |
| long | 1000～5000 | 单次连续震动，通电时间为 duration_ms |

幂等规则：

1. ESP32 在内存中至少保存最近 32 个 command_id、规范化命令内容和最终 ACK，设备重启后可清空。
2. 收到相同 command_id 且内容完全相同时，不得再次驱动马达，应重新发送第一次的最终 ACK。
3. 收到相同 command_id 但内容不同时，不得执行，返回 rejected/command_conflict。
4. target=both 时，App 向左右设备写入相同 command_id；完成状态按 `(command_id, device_id)` 区分，必须分别等待两侧 ACK。

## 9. AckEvent

AckEvent 使用紧凑 UTF-8 JSON，通过 ack_schema_v1.json 校验，并通过 Notify 发送。

1. App 必须在发送 DeviceCommand 前订阅 AckEvent。
2. ACK status 只能是 executed、rejected、expired、failed。
3. ack_at_ms 对所有 ACK 必填。
4. executed_at_ms 仅在 status=executed 时必填。
5. executed 必须配合 error_code=none。
6. rejected、expired、failed 使用 enums_v1.md 中最具体的 ACK error_code。
7. 重复 ACK 按 `(command_id, device_id)` 幂等处理，不得重复创建事件或重复计算恢复效果。

## 10. packet_seq、重启与丢包

1. packet_seq 在每台 ESP32 每次启动后从 0 开始并独立递增。
2. uint32 溢出后从 0 继续。
3. App 在建立新连接或发现 sync_id 变化时重置该设备的期望序号。
4. 只有同一连接、同一 sync_id 内的非预期跳变才记录丢包并设置本地 PACKET_GAP 状态。
5. PACKET_GAP 不要求丢弃后续合法帧。

## 11. 推荐连接与联调顺序

1. 扫描包含服务 UUID 的设备。
2. 连接单侧设备并请求 MTU 247。
3. 读取 DeviceStatus，校验 protocol_version、布局、device_id 和 side。
4. 订阅 DeviceStatus、AckEvent 和 SensorData。
5. 写入 TimeSync，并确认 DeviceStatus 中的 sync_id。
6. 开始解析 SensorData，检查长度、magic、版本、布局、side、CRC 和序号。
7. 单侧稳定后再连接另一侧，重复上述流程。
8. 双侧数据稳定后再测试 DeviceCommand 和 AckEvent。
9. 最后接入后端上传，不要同时首次调试双脚、后端和指令。

## 12. 解析失败与错误处理

以下情况丢弃当前 SensorData 帧并记录日志：

- 长度不是 58；
- magic 错误；
- protocol_version 不支持；
- layout_id 不支持；
- side 与连接设备不一致；
- CRC 失败；
- battery 大于 100；
- 解码后数值违反 field_dictionary.md 的传输范围且未设置对应质量标志。

以下情况不一定丢弃整帧，但不得用于相关风险计算：

- 通道被 quality_flags 标记无效；
- TIME_UNSYNCED；
- 序号跳变；
- 保留质量位非 0。
