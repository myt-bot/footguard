# FootGuard App 开发交接

## 范围

本轮只维护 Android App、BLE、本地离线闭环、历史记录和会话级 AI。Web 端已经完全舍弃，不修改 `backend/web`，不增加 Web 页面或 Web 图表。

App 开发分支使用 `feat/app-voice-history`。完整 SQLite 数据库不是 App 开发依赖；联调使用 `protocol/examples/app_*_fixture.json` 和 `sample_data/labeled_20260814`。

## 数据边界

ESP32 只向 App 提供：

- 60 字节 SensorData：6 路压力、4 路温度、三轴加速度、三轴角速度、时间戳、序号和质量位；
- DeviceStatus；
- 马达 AckEvent。

App 向 ESP32 提供 TimeSync 和 DeviceCommand。风险类型、历史、恢复评价和 AI 均不写入固件协议。后续固件将压力/MPU 提升到约 20 Hz，但 60 字节布局不变，App 解析器不得假设固定 200ms 间隔。

## App 任务

1. 使用 Android 本地 TTS；增加语音开关和测试按钮，中文语音不可用时保留文字提醒。
2. 校准阶段只在状态切换时播报：保持鞋垫空载、空载参考完成并穿鞋、开始自然站立基线、基线完成。
3. 压力持续 10 秒或温度持续 15 秒时，一个事件只播报一次；压力 20 秒或温度 30 秒仍未恢复时才执行一次马达。
4. 风险卡只显示一个主压力风险；其他分量显示“同时存在”。组合压力风险共用一个 15 秒观察窗口。
5. 历史页删除所有折线图、趋势图和 timeseries 请求，只保留事件、组成风险、持续时间、马达/ACK、干预前后数值和恢复结果。
6. 移除实时页的当前风险 AI 卡片。AI 主入口放在历史页，读取最近会话建议；脱鞋或断联后继续显示最近会话，并明确不是当前风险。
7. 正式设置页不显示 Web、模拟场景和电量百分比；真实 CSV 回放只保留在隐藏诊断入口。
8. 后端断开时继续使用本地 BLE、压力热力图、本地规则、语音、马达和离线缓存。

## 风险显示词

内部继续使用 0-3 级，但 App 不显示临床数字等级：

- 0：正常；
- 1：趋势观察中，不播报、不震动；
- 2：需要减负，播报一次；
- 3：持续未改善，执行一次马达，不重复播报。

计划新增的字符串风险类型为 `medial_load_concentration` 和 `lateral_load_concentration`，侧别仍为 `left`、`right` 或 `both`。Dart 模型应继续按字符串解析，未知类型使用通用“区域负荷集中”文案，避免新版后端导致 App 崩溃。

主压力风险优先级为：前掌或内外侧局部负荷集中，高于整体左右偏载。温度趋势独立显示，不进入 15 秒压力改善成功率。

## 主要 HTTP 接口

- `POST /api/v1/sensor/batch`
- `POST /api/v1/sensor/offline-sync`
- `POST /api/v1/sensor/offline-interventions`
- `GET /api/v1/realtime`
- `GET /api/v1/calibration/status`
- `POST /api/v1/calibration/reset`
- `GET /api/v1/command/pending`
- `POST /api/v1/ack`
- `GET /api/v1/events?limit=50`
- `GET /api/v1/session/latest`
- `POST /api/v1/ai/session-advice`

本轮 App 不再调用 `/api/v1/analytics/timeseries`。

## 验收

- 同一风险过程只弹窗和播报一次；
- 1 级不打扰，3 级才震动；
- 组合风险只有一个倒计时；
- 温度不计入压力干预成功；
- 历史页没有图表；
- 无实时数据时仍可查看最近会话 AI 建议；
- 后端断联时 BLE 和本地闭环继续运行；
- `flutter analyze` 和 `flutter test` 全部通过。
