# FootGuard 字段字典 v1

## 1. 单脚传感器帧

| 字段 | 类型 | 必填 | 单位或范围 | 说明 |
|---|---|---:|---|---|
| protocol_version | integer | 是 | 固定为 1 | 逻辑协议版本 |
| sensor_layout_version | string | 是 | layout_6p3t_v1 | 传感器布局版本 |
| device_id | string | 是 | 1～16 个 ASCII 字符 | 左脚示例 foot_left_001 |
| side | string | 是 | left 或 right | 设备侧别 |
| sync_id | integer | 是 | 0～4294967295 | 时间同步编号；0 表示尚未同步 |
| packet_seq | integer | 是 | 0～4294967295 | 单设备递增序号 |
| timestamp_ms | integer | 是 | Unix 毫秒；未同步时为 0 | 同步后的采样时间 |
| pressure | number 数组 | 是 | 长度 6，每项 0.0～1.0 | 六个压力通道的归一化相对值 |
| temperature | number 数组 | 是 | 长度 3，每项 -40.00～125.00℃ | 三个温度通道；风险阈值另行配置 |
| imu.ax/ay/az | number | 是 | m/s² | 三轴加速度 |
| imu.gx/gy/gz | number | 是 | °/s | 三轴角速度 |
| battery | integer | 是 | 0～100 | 电量百分比 |
| quality_flags | integer | 是 | 0～4294967295 | 32 位无符号位标志 |
| source | string | App和后端必填 | mock、csv_replay、ble | 数据来源，不进入 BLE SensorData 固定帧 |

JSON 模型必须拒绝未知字段。BLE 解码得到的字段由 App 补充 device_id、sensor_layout_version 和 source 后再形成统一 JSON。

## 2. 压力通道

| 数组索引 | 通道 | 当前暂定区域 |
|---:|---|---|
| 0 | P1 | 前掌内侧 |
| 1 | P2 | 前掌中部 |
| 2 | P3 | 前掌外侧 |
| 3 | P4 | 足弓或中足外侧 |
| 4 | P5 | 足跟内侧 |
| 5 | P6 | 足跟外侧 |

物理位置是 layout_6p3t_v1 的暂定映射。代码使用数组索引和 sensor_layout_version，不得在业务逻辑中到处写死物理位置。

压力 BLE 编码范围为 0～10000，对应归一化值 0.0～1.0。固件计算值超出范围时应限幅，同时设置相应压力通道无效位和 CALIBRATION_INVALID；接收端不得把被标记无效的 0 值解释为正常无压力。

## 3. 温度通道

| 数组索引 | 通道 | 当前暂定区域 |
|---:|---|---|
| 0 | T1 | 前掌 |
| 1 | T2 | 中足 |
| 2 | T3 | 足跟 |

温度传输范围为 -40.00～125.00℃，这是传输合法范围，不是人体风险阈值。读取失败或超出所用传感器量程时，固件填 0 并设置对应 TEMPERATURE_Tn_INVALID。

## 4. IMU 与数值饱和

1. 加速度以 int16 mg 传输，可表示 -32768～32767 mg。
2. 角速度以 int16、0.1°/s 传输，可表示 -3276.8～3276.7°/s。
3. 超出所配置 IMU 量程或发生读取失败时，数值应限幅或填 0，并设置 IMU_INVALID。
4. 风险算法必须忽略被 quality_flags 标记为无效的通道。

## 5. 缺失数据

1. 缺失通道不能解释为正常的 0 值。
2. BLE 固定帧中无效通道填 0，同时设置对应 quality_flags。
3. App 解析后保留数值和质量标志，但相关规则必须排除无效通道。
4. 一侧断连时另一侧仍可显示，但不得输出可信的双足偏载结论。
5. 时间未同步时可显示数据，但不得进行高精度双足配对或执行依赖绝对过期时间的指令。

## 6. 时间与序号

1. App 向 ESP32 下发 sync_id 和 unix_time_ms。
2. ESP32 保存手机时间与本地单调时钟的偏移。
3. timestamp_ms 表示估算的 Unix 毫秒时间；未同步时必须为 0，并设置 TIME_UNSYNCED。
4. packet_seq 在每台设备每次启动后从 0 开始并独立递增，溢出后从 0 开始。
5. App 在新连接或 sync_id 变化时重置期望序号；只有同一连接、同一 sync_id 内的异常跳变才记录 PACKET_GAP。
6. 重新连接后 App 必须重新执行 TimeSync。

## 7. 数值与显示说明

1. 压力是相对归一化值，不宣传为医疗级绝对压力。
2. 温度传输精度为 0.01℃，页面可按 0.1℃显示。
3. 风险阈值存入配置文件，不散落在页面和接口代码中。
4. 编码使用四舍五入到最近整数；恰好位于中点时远离 0 取整，固件和测试工具必须使用一致规则。
