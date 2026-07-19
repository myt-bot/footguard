# FootGuard 协议目录

> 状态：BASELINE（真实 BLE 联调修订版）  
> 逻辑协议版本：1  
> 文档修订号：1.3<br>
> 传感器布局版本：layout_6p4t_v1

本目录是 ESP32 固件、Flutter App 和 FastAPI 后端共同遵守的协议基线。未经确认，不得在任意一端自行增加、删除、更名或静默兼容字段。

本次 1.3 文档修订冻结 `layout_6p4t_v1` 的 P1～P6、T1～T4 物理位置语义，并修复后端 quality_flags 校验。protocol_version=1、layout_id=2、60 字节 SensorData、字段、数组长度、帧偏移、BLE UUID 和 CRC 均保持不变。此前的 `layout_6p3t_v1` 不再兼容。

## 文件说明

- field_dictionary.md：统一数据字段、类型、单位、数组长度、有效范围及缺失处理。
- enums_v1.md：枚举值、设备状态、ACK 状态、错误码与质量标志。
- ble_protocol_v1.md：设备身份、GATT 服务、二进制帧、MTU、时间同步、指令与 ACK。
- api_contract_v1.md：App 与 FastAPI 之间的 HTTP 接口。
- command_schema_v1.json：设备指令 JSON Schema。
- ack_schema_v1.json：设备 ACK JSON Schema。
- device_status_schema_v1.json：设备状态 JSON Schema。
- REVISION_NOTES_v1_1.md：上一版 6压3温 BLE 修订历史记录。
- REVISION_NOTES_v1_2.md：6压4温布局、帧长度及相对风险算法修订说明。
- REVISION_NOTES_v1_3.md：6压4温物理位置语义冻结及后端 quality_flags 校验修订说明。
- examples：左右脚帧、设备状态、指令、ACK、TimeSync 和 BLE 十六进制标准样例。

## 版本规则

1. protocol_version=1 表示当前逻辑协议版本；layout_id=2 对应唯一支持的 `layout_6p4t_v1`。
2. 仅修正或澄清文字、实际硬件位置未改变时，可保持 sensor_layout_version；如果传感器实际物理位置改变，即使字段数量和类型不变，也必须更新 sensor_layout_version 和通道映射。
3. 本修订版投入实现后，增删字段、改变类型、改变数组长度、改变枚举语义或改变 BLE 帧长度时，必须升级 protocol_version。
4. 修改协议时必须同步修改 Schema、标准样例、CRC 测试向量和自动测试。
5. 发现协议问题时，通过标题含 `[protocol]` 的 GitHub Issue 或 Pull Request 提出，不得只在一端静默兼容。
6. 固件、App 和后端应记录实际支持的 protocol_version；遇到不支持的版本必须明确拒绝。

## 当前数据流

1. ESP32 按 BLE 60 字节二进制帧发送 SensorData。
2. App 解析 BLE 帧，补充 device_id 和 source，转换成统一 JSON 模型。
3. App 将统一 JSON 上传给 FastAPI。
4. FastAPI 不直接解析 BLE 字节。
5. App 通过 DeviceCommand 写入低频指令，通过 AckEvent 获取设备最终执行结果。

## v1 单包约束

1. App 请求 MTU 247。
2. SensorData 每次 Notify 恰好发送一条 60 字节帧。
3. DeviceStatus、DeviceCommand 和 AckEvent 使用无缩进、无多余空格的紧凑 UTF-8 JSON。
4. 单条 BLE JSON 的 UTF-8 编码长度不得超过 244 字节。
5. v1 不支持 JSON 分包；MTU 或消息长度不满足时必须报告错误，不能截断。
