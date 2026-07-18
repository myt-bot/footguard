# FootGuard App 与 FastAPI 接口 v1

## 通用规则

- 开发环境基地址：http://127.0.0.1:8000
- Android 模拟器访问电脑：http://10.0.2.2:8000
- 真机访问电脑：使用电脑局域网 IP
- Content-Type：application/json
- 时间：Unix 毫秒
- 接口前缀：/api/v1
- 错误响应包含 detail 和可选 error_code
- JSON 模型拒绝未知字段
- App 从 BLE 接收的数据补充 device_id、sensor_layout_version 和 source=ble 后再上传

## GET /health

响应：

~~~json
{"status":"ok","version":"0.1.0","protocol_version":1}
~~~

## POST /api/v1/sensor/batch

请求：

~~~json
{
  "protocol_version": 1,
  "app_received_at_ms": 1760000000500,
  "frames": []
}
~~~

frames 中每一项符合 field_dictionary.md，允许左右帧交错。

校验规则：

1. 外层 protocol_version 必须为 1。
2. 每个 frame.protocol_version 必须与外层一致。
3. 单帧字段错误只拒绝该帧并计入 rejected；请求体结构错误则整批返回 422。
4. 后端不得把缺失通道或质量异常通道自动改写成正常 0 值。

成功响应：

~~~json
{
  "accepted": 20,
  "rejected": 0,
  "latest_risk": "normal"
}
~~~

## GET /api/v1/realtime

响应至少包含：

~~~json
{
  "left": null,
  "right": null,
  "paired_timestamp_ms": null,
  "sync_error_ms": null,
  "load_bias": null,
  "load_diff": null,
  "risk": {
    "risk_type": "data_incomplete",
    "risk_side": "none",
    "risk_level": 0,
    "duration_ms": 0
  }
}
~~~

## GET /api/v1/events

查询参数 limit 默认 50，最大 200，返回风险事件数组。

## GET /api/v1/command/pending

可选查询参数 target=left、right 或 both。`none` 不是可下发命令目标。

无待执行指令：

~~~json
{"command":null}
~~~

有待执行指令：

~~~json
{"command":{"protocol_version":1,"command_id":"cmd_000001","target":"left","pattern":"double","duration_ms":800,"expire_at_ms":1760000005000,"reason_code":"left_load_bias"}}
~~~

返回的 command 必须通过 command_schema_v1.json 校验。

## POST /api/v1/ack

请求体必须通过 ack_schema_v1.json 校验。示例：

~~~json
{
  "protocol_version": 1,
  "command_id": "cmd_000001",
  "device_id": "foot_left_001",
  "status": "executed",
  "ack_at_ms": 1760000000100,
  "executed_at_ms": 1760000000100,
  "error_code": "none"
}
~~~

后端按 `(command_id, device_id)` 幂等记录。重复提交相同 ACK 返回 recorded=true，但不得重复产生副作用；同一键内容冲突返回 409。

响应：

~~~json
{"recorded":true}
~~~

## POST /api/v1/intervention/feedback

请求：

~~~json
{
  "event_id": "evt_000001",
  "user_action": "shift_weight",
  "effect_label": "effective",
  "before_load_diff": 0.25,
  "after_load_diff": 0.08,
  "recovery_time_ms": 8500
}
~~~

响应：

~~~json
{"recorded":true}
~~~

## HTTP 状态码

| 状态码 | 用途 |
|---:|---|
| 200 | 查询或幂等处理成功 |
| 201 | 记录创建成功 |
| 400 | 业务字段不合法 |
| 404 | 资源不存在 |
| 409 | 重复序号、命令内容冲突或状态冲突 |
| 422 | Schema、模型或协议版本校验失败 |
| 500 | 未处理的服务端错误 |
