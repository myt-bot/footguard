# FootGuard protocol v1.3 修订说明

## 修订范围

- 文档修订号升级为 1.3。
- protocol_version 仍为 1。
- sensor_layout_version 仍为 `layout_6p4t_v1`。
- BLE layout_id 仍为 2。
- SensorData 仍为 60 字节。
- 本次没有改变字段、数组长度、帧偏移、BLE UUID 或 CRC，现有 CRC 标准向量保持不变。
- 本次冻结 P1～P6、T1～T4 的物理位置语义。左右脚按解剖方向镜像，同一通道代表同一解剖区域。
- 本次修复后端 quality_flags 校验：PACKET_GAP bit15 为合法位，bit16～31 仍为保留位；任一温度通道无效时阻断双足风险配对。

## 冻结的通道语义

- P1 拇趾区；P2 前掌外侧；P3 前掌中央；P4 前掌内侧；P5 中足中央；P6 足跟中央。
- T1 前掌外侧；T2 拇趾/第一跖骨头邻近的前掌内侧；T3 足跟中央；T4 中足中央。

以上定义用于竞赛原型的数据采集、显示和工程风险辅助监测，不构成医学诊断标准。

后续如果修改传感器数量、帧长度、字段类型或枚举语义，必须升级 protocol_version。
