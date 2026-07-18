# FootGuard protocol v1.1 修订说明

## 修订目的

本次修订用于在 ESP32 固件和 Flutter App 开始真实 BLE 联调前，消除原 v1 草案中可能导致截断、CRC 不一致、指令重复执行、时间状态不确定和 ACK 解释不一致的问题。

## 保持不变

- protocol_version 仍为 1。
- sensor_layout_version 仍为 layout_6p3t_v1。
- 每只脚保持 6 个压力通道和 3 个温度通道。
- SensorData 总长度保持 58 字节。
- GATT Service UUID 和五个 Characteristic UUID 保持不变。
- 字节序保持 little-endian。

## 主要修订

1. MTU 改为请求 247，所有 BLE JSON 限制为不超过 244 个 UTF-8 字节，v1 不支持 JSON 分包。
2. 明确一条 SensorData Notify 恰好对应一条 58 字节帧。
3. 补全 CRC-16/CCITT-FALSE 参数、CRC 小端存储规则和左右脚标准测试向量。
4. 补充加速度编码公式、统一取整方式和各传感器传输范围。
5. DeviceCommand 增加 protocol_version，移除可下发的 target=none，并明确 pattern/duration_ms 语义。
6. 增加命令幂等缓存、重复 ID 和内容冲突处理规则。
7. 新增 ack_schema_v1.json，分离后端命令状态和设备 ACK 状态。
8. DeviceStatus 增加 time_synced 和 sync_id，并新增 device_status_schema_v1.json。
9. 明确 TimeSync 确认流程、未同步行为、重连和重启行为。
10. 补充设备状态、取消指令、执行/拒绝/过期/失败 ACK 和 TimeSync 样例。

## 实现同步要求

固件、Flutter 和后端必须同时采用本修订版。此前尚未按照旧草案投入真实联调，因此本修订作为唯一支持的 protocol_version=1 基线。若已有任何一端按照旧草案实现，应先停止合并，由团队确认是同步升级到本修订还是另行建立 protocol_version=2。
