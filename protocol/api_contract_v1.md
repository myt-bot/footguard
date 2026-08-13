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

当前唯一支持的布局是 `layout_6p4t_v1`，即每帧 `pressure[6]` 和 `temperature[4]`。

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
  "motion_state": "unavailable",
  "pressure_available": false,
  "temperature_available": false,
  "active_risks": [],
  "regional_analysis": null,
  "risk": {
    "risk_type": "data_incomplete",
    "risk_side": "none",
    "risk_level": 0,
    "duration_ms": 0
  }
}
~~~

双足配对有效时，`regional_analysis` 返回六个压力区域分数、四个温度区域分数、左右同区温差、逐通道有效位以及基线状态。温度同区任一侧无效时，相应 `temperature_delta_c` 为 `null`；不得用 0 代替。压力分数由足内占比变化和左右同区差异计算，不是原始压力固定阈值；`baseline_source=personal` 表示已获得至少 40 对合格压力帧，并已持久化本次穿戴基线。温度缺失不改变 `pressure_available`。

`active_risks` 包含当前同时成立的全部风险。兼容字段 `risk` 仍返回一个主风险，旧客户端可以继续使用；新客户端必须优先展示 `active_risks`。偏载和左右脚前掌高载独立计算，因此可以同时出现。

`regional_analysis` 还返回以下逐压力通道数组：

- `left/right_pressure_valid`：固件原始有效位；为 `false` 时按数据/硬件不可用处理并置灰。
- `left/right_pressure_baseline_trusted`：本次标定是否覆盖该点。
- `left/right_pressure_analysis_valid`：当前是否参与区域风险计算。
- `left/right_pressure_channel_status`：值为 `ok`、`uncovered_in_baseline`、`raw_invalid` 或 `residual_suspect`。后两种可信度诊断不得阻止原始有效通道继续显示实时受力颜色。

## GET /api/v1/calibration/status

响应示例：

~~~json
{
  "baseline_ready": false,
  "sample_count": 18,
  "required_samples": 40,
  "reset_at_ms": 1785000000000,
  "status_reason": "unstable"
}
~~~

`status_reason` 可为 `ready`、`waiting_for_data`、`pressure_unavailable`、`not_loaded`、`moving` 或 `unstable`。温度和 MPU 缺失不直接阻止压力基线；MPU 明确检测到移动时会暂停采样。

## POST /api/v1/calibration/reset

开始新体验者或重新穿戴标定，返回与状态接口相同的结构。该操作清除当前活动基线、终止活动风险并使待执行命令过期，但不删除历史事件。

## POST /api/v1/ai/chat

请求只包含自由问题和结构化当前状态摘要，不上传连续原始传感器帧：

~~~json
{
  "protocol_version": 1,
  "question": "温度不可用会影响压力判断吗？",
  "risk": {"risk_type":"normal","risk_side":"none","risk_level":0,"duration_ms":0},
  "active_risks": [],
  "load_diff": 0.03,
  "temperature_delta_max_c": null,
  "baseline_ready": true,
  "pressure_available": true,
  "temperature_available": false,
  "valid_temperature_pairs": 0,
  "motion_state": "stationary",
  "left_connected": true,
  "right_connected": true
}
~~~

响应：

~~~json
{
  "protocol_version": 1,
  "provider": "local-safe-fallback",
  "question": "温度不可用会影响压力判断吗？",
  "answer": "温度通道与压力显示、压力风险独立处理。"
}
~~~

云端失败时后端必须根据当前状态返回本地模板。AI 不得产生或修改风险等级、目标侧、马达模式和命令。

## GET /api/v1/events

查询参数 limit 默认 50，最大 200，返回风险事件数组。同一连续时间段内同时出现的偏载、前掌高载和温差风险合并为一条事件，`active_risks` 保存全部组件及各自侧别、等级和持续时间；旧记录缺少组合字段时按其兼容主风险生成单个组件。

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

`target=both` 的命令必须分别收到左右设备 ACK。收到第一侧 ACK 后命令仍为 `pending`，只有两个设备均返回最终 ACK 后才汇总为完成或失败。

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
