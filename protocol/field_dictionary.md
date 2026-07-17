# FootGuard 字段字典 v1

## 1. 单脚传感器帧

| 字段 | 类型 | 必填 | 单位或范围 | 说明 |
|---|---|---:|---|---|
| protocol_version | integer | 是 | 固定为 1 | 逻辑协议版本 |
| sensor_layout_version | string | 是 | layout_6p3t_v1 | 传感器布局版本 |
| device_id | string | 是 | 非空 | 左脚示例 foot_left_001 |
| side | string | 是 | left 或 right | 设备侧别 |
| sync_id | integer | 是 | 0～4294967295 | 时间同步编号 |
| packet_seq | integer | 是 | 0～4294967295 | 单设备递增序号 |
| timestamp_ms | integer | 是 | Unix 毫秒 | 同步后的采样时间 |
| pressure | number 数组 | 是 | 长度 6，建议 0.0～1.0 | 六个压力通道的归一化相对值 |
| temperature | number 数组 | 是 | 长度 3，℃ | 三个温度通道 |
| imu.ax/ay/az | number | 是 | m/s² | 三轴加速度 |
| imu.gx/gy/gz | number | 是 | °/s | 三轴角速度 |
| battery | integer | 是 | 0～100 | 电量百分比 |
| quality_flags | integer | 是 | 32 位无符号位标志 | 数据质量状态 |
| source | string | App和后端必填 | mock、csv_replay、ble | 数据来源，不进入 BLE SensorData 固定帧 |

## 2. 压力通道

| 数组索引 | 通道 | 当前暂定区域 |
|---:|---|---|
| 0 | P1 | 前掌内侧 |
| 1 | P2 | 前掌中部 |
| 2 | P3 | 前掌外侧 |
| 3 | P4 | 足弓或中足外侧 |
| 4 | P5 | 足跟内侧 |
| 5 | P6 | 足跟外侧 |

以上物理位置是暂定映射。代码使用数组索引和 sensor_layout_version，不得在业务逻辑中到处写死物理位置。

## 3. 温度通道

| 数组索引 | 通道 | 当前暂定区域 |
|---:|---|---|
| 0 | T1 | 前掌 |
| 1 | T2 | 中足 |
| 2 | T3 | 足跟 |

## 4. 缺失数据

1. 缺失通道不能解释为正常的 0 值。
2. BLE 固定帧中无效通道可以填 0，但必须设置对应 quality_flags。
3. App 解析后应把无效通道标记为无效，不参与相关规则。
4. 一侧断连时另一侧仍可显示，但不得输出可信的双足偏载结论。
5. 时间未同步时可显示数据，但不得进行高精度双足配对。

## 5. 时间与序号

1. App 向 ESP32 下发 sync_id 和 unix_time_ms。
2. ESP32 保存手机时间与本地单调时钟的偏移。
3. timestamp_ms 表示估算的 Unix 毫秒时间。
4. packet_seq 在每台设备上独立递增，溢出后从 0 开始。
5. 接收端发现序号跳变时记录丢包并设置 PACKET_GAP。

## 6. 数值说明

1. 压力是相对归一化值，不宣传为医疗级绝对压力。
2. 温度传输精度为 0.01℃，页面可按 0.1℃显示。
3. 风险阈值存入配置文件，不散落在页面和接口代码中。

