# FootGuard 协议目录

> 状态：BASELINE  
> 逻辑协议版本：1  
> 传感器布局版本：layout_6p3t_v1

本目录是 ESP32 固件、Flutter App 和 FastAPI 后端共同遵守的协议基线。未经确认，不得在任意一端自行增加、删除或更名字段。

## 文件说明

- field_dictionary.md：统一数据字段、类型、单位、数组长度及缺失处理。
- enums_v1.md：枚举值与质量标志。
- ble_protocol_v1.md：设备身份、GATT 服务、二进制数据帧、时间同步、指令与 ACK。
- api_contract_v1.md：App 与 FastAPI 之间的 HTTP 接口。
- command_schema_v1.json：设备指令 JSON Schema。
- examples：左右脚帧、指令与 ACK 标准样例。

## 版本规则

1. protocol_version=1 表示当前逻辑协议版本。
2. 传感器位置调整但字段、数量和数据类型不变时，只更新 sensor_layout_version 和通道映射。
3. 增删字段、改变类型、改变数组长度或改变 BLE 帧长度时，必须升级 protocol_version。
4. 修改协议时必须同步修改标准样例和自动测试。
5. 发现协议问题时，通过 GitHub Issue 或 Pull Request 提出，不得只在一端静默兼容。

## 当前数据流

1. ESP32 按 BLE 二进制帧发送数据。
2. App 解析 BLE 帧，补充 device_id 和 source，转换成统一 JSON 模型。
3. App 将统一 JSON 上传给 FastAPI。
4. FastAPI 不直接解析 BLE 字节。

