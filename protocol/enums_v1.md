# FootGuard 枚举与质量标志 v1

## side

- left
- right

BLE 编码：0 表示 left，1 表示 right。

## source

- mock
- csv_replay
- ble

## BLE command target

- left
- right
- both

`none` 不是可下发到设备的目标，只能用于 risk_side 等内部无目标状态。App 不得向 DeviceCommand 写入 `target=none`。

## command pattern

- off
- short
- double
- long

内部编码建议：0=off，1=short，2=double，3=long。

## 后端命令状态

- pending
- sent
- executed
- rejected
- expired
- failed

## 设备 ACK status

- executed
- rejected
- expired
- failed

ESP32 不得在 AckEvent 中返回 pending 或 sent。

## ACK error_code

- none
- invalid_json
- unsupported_protocol
- target_mismatch
- invalid_pattern
- invalid_duration
- command_expired
- time_unsynced
- motor_fault
- command_conflict
- internal_error

`executed` 必须配合 `error_code=none`。其他状态使用最具体的错误码。

## DeviceStatus state

- booting
- idle
- streaming
- error

## DeviceStatus error_code

- none
- sensor_error
- calibration_error
- imu_error
- motor_error
- low_battery
- internal_error

## risk_type

- normal
- left_load_bias
- right_load_bias
- forefoot_high
- temperature_asymmetry
- data_incomplete

## risk_side

- left
- right
- both
- none

## risk_level

- 0：normal
- 1：attention
- 2：warning
- 3：persistent

## effect_label

- effective
- partial
- ineffective
- unknown

## quality_flags

某一位为 1 表示对应异常成立。

| 位 | 掩码 | 名称 | 含义 |
|---:|---:|---|---|
| 0 | 0x00000001 | PRESSURE_P1_INVALID | P1 无效 |
| 1 | 0x00000002 | PRESSURE_P2_INVALID | P2 无效 |
| 2 | 0x00000004 | PRESSURE_P3_INVALID | P3 无效 |
| 3 | 0x00000008 | PRESSURE_P4_INVALID | P4 无效 |
| 4 | 0x00000010 | PRESSURE_P5_INVALID | P5 无效 |
| 5 | 0x00000020 | PRESSURE_P6_INVALID | P6 无效 |
| 6 | 0x00000040 | TEMPERATURE_T1_INVALID | T1 无效 |
| 7 | 0x00000080 | TEMPERATURE_T2_INVALID | T2 无效 |
| 8 | 0x00000100 | TEMPERATURE_T3_INVALID | T3 无效 |
| 9 | 0x00000200 | TEMPERATURE_T4_INVALID | T4 无效 |
| 10 | 0x00000400 | IMU_INVALID | IMU 无效 |
| 11 | 0x00000800 | TIME_UNSYNCED | 时间未同步 |
| 12 | 0x00001000 | LOW_BATTERY | 低电量 |
| 13 | 0x00002000 | CALIBRATION_INVALID | 标定无效 |
| 14 | 0x00004000 | SENSOR_STUCK | 传感器疑似卡死 |
| 15 | 0x00008000 | PACKET_GAP | 数据包序号跳变 |
| 16～31 | - | RESERVED | 保留，发送端必须置 0 |

quality_flags=0 表示当前帧未发现质量异常。接收端发现保留位非 0 时应记录协议告警；v1 不把未知保留位解释为已知状态。
