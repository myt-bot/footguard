# FootGuard 基础风险与马达提醒规则

这些参数仅用于物联网竞赛原型验证，不是医疗诊断或治疗标准。

- 左右有效帧必须具有相同 `sync_id`、相同 `packet_seq`，时间差不超过 50 ms。
- 关键压力无效、时间未同步、标定无效、传感器卡死或单侧缺失时输出 `data_incomplete`，不产生马达命令。
- `load_bias = (left_total - right_total) / (left_total + right_total)`。
- `abs(load_bias) >= 0.25` 进入偏载候选窗口。
- 连续 3 秒为 attention，6 秒为 warning，10 秒为 persistent。
- 前掌三个压力点占单脚总压力不小于 0.65 时进入 `forefoot_high` 候选窗口。
- 风险达到 warning 时，每个风险事件只生成一次马达提醒命令：目标为风险侧，模式 `double`，时长 800 ms，命令有效期 5 秒。
- ESP32 执行马达振动后通过 ACK 报告 `executed/rejected/expired/failed`；相同设备的相同 ACK 幂等保存。
- 执行振动后风险恢复时，按载荷差改善比例生成 `effective/partial/ineffective` 恢复评价。

所有可调参数集中在 `backend/app/config.py`。
