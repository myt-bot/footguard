# FootGuard 基础风险与马达提醒规则

这些参数仅用于物联网竞赛原型验证，不是医疗诊断或治疗标准。

## 输入有效性

- 左右有效帧必须具有相同 `sync_id`、相同 `packet_seq`，时间差不超过 50 ms。
- 关键压力无效、时间未同步、标定无效、传感器卡死或单侧缺失时输出 `data_incomplete`，不产生马达命令。
- 当前布局固定为每脚 `pressure[6] + temperature[4]`，布局标识为 `layout_6p4t_v1`。

## 与体重无关的压力判定

系统不使用“某压力原始值大于固定值”直接报警。

1. 双足偏载使用 `load_bias = (left_total - right_total) / (left_total + right_total)`；分母含双足总载荷，因此用户整体体重或传感器总量程变化会被约去。
2. 区域载荷使用 `p_i / single_foot_total`，比较该区域占单脚总载荷的比例，而不是比较原始压力。
3. 从双足平衡、温差稳定的有效帧中学习个人基线；至少 10 对有效帧后使用个人中位数基线。基线不足时使用布局默认分布，并在接口中标记 `baseline_source=layout_default`。
4. 前掌风险比较 P1～P4 当前占比相对于个人前掌基线的增量；增量达到 0.12 才进入候选窗口。
5. 左右同区域采用 `(left_i-right_i)/(left_i+right_i)` 比较，并扣除个人正常不对称基线，用于热区严重度计算。

## 温度判定

- T1 前掌外侧、T2 前掌内侧、T3 足跟中央、T4 中足内侧。
- 比较左右脚镜像同区域温差，并扣除个人正常温差基线。
- 校正后的同区温差绝对值达到 2.0℃时进入 `temperature_asymmetry` 候选窗口；风险侧为温度更高的一侧。

## 持续时间与马达

- 校正后的 `abs(load_bias) >= 0.25` 进入偏载候选窗口。
- 连续 3 秒为 attention，6 秒为 warning，10 秒为 persistent。
- 风险达到 warning 时，每个连续风险事件只生成一次马达提醒命令：目标为风险侧，模式 `double`，时长 800 ms，命令有效期 30 秒。
- 设备重连或新的 `sync_id` 连续窗口开始后，即使风险类型相同，也会关闭旧事件并为新一轮监测重新生成马达命令。
- ESP32 执行马达振动后通过 ACK 报告 `executed/rejected/expired/failed`；相同设备的相同 ACK 幂等保存。
- 执行振动后风险恢复时，按载荷差改善比例生成 `effective/partial/ineffective` 恢复评价。

所有可调参数集中在 `backend/app/config.py`。
