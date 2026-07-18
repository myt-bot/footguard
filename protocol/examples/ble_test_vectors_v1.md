# FootGuard BLE v1 标准测试向量

所有多字节整数均为 little-endian。SensorData CRC 使用 CRC-16/CCITT-FALSE，计算偏移 0～55，CRC 值按小端序写入偏移 56～57。

## 左脚帧

对应 JSON：left_frame.json。

| 项目 | 值 |
|---|---|
| 总长度 | 58 字节 |
| side 编码 | 0 |
| sync_id | 1 |
| packet_seq | 1 |
| timestamp_ms | 1760000000000 |
| acceleration mg | [2, -3, 997] |
| CRC 数值 | 0x67A1 |
| CRC 帧内字节 | A1 67 |

完整帧见 sensor_frame_left_v1.hex。

## 右脚帧

对应 JSON：right_frame.json。

| 项目 | 值 |
|---|---|
| 总长度 | 58 字节 |
| side 编码 | 1 |
| sync_id | 1 |
| packet_seq | 1 |
| timestamp_ms | 1760000000020 |
| acceleration mg | [-1, 2, 998] |
| CRC 数值 | 0x51BE |
| CRC 帧内字节 | BE 51 |

完整帧见 sensor_frame_right_v1.hex。

## TimeSync

| 项目 | 值 |
|---|---|
| 总长度 | 12 字节 |
| sync_id | 1 |
| unix_time_ms | 1760000000000 |

完整字节见 time_sync_v1.hex。

## 自动测试要求

1. 固件编码器对同一字段输入必须生成与 `.hex` 文件完全一致的 58 字节。
2. Flutter 解析器必须把 `.hex` 文件还原为对应 JSON 中的字段；IMU 浮点值允许由量化导致的微小误差。
3. 修改任意受 CRC 保护的字节后，CRC 校验必须失败。
4. 交换 CRC 两个字节后，CRC 校验必须失败。
