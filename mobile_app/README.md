# FootGuard Flutter App

## 运行

1. 在仓库根目录启动 FastAPI：`python -m uvicorn backend.app.main:app --host 0.0.0.0 --port 8000`。
2. Android 模拟器使用默认地址 `http://10.0.2.2:8000`。
3. 在本目录执行 `flutter pub get`、`flutter run -d emulator-5554`。

## 页面

- 首页：项目能力与监测入口；
- 实时：左右脚 6 区压力热图、4 点温度、风险、同步质量和马达命令；
- 历史：FastAPI 风险事件；
- 设备：左右设备、电量、协议和数据源；
- 设置：Mock/CSV/API/BLE 数据源、场景、回放速度和后端地址。

## 马达提醒演示

在设置中选择 `Mock 实时生成` 和 `left_load_bias` 或 `right_load_bias`，保持 FastAPI 运行。持续偏载达到后端警告窗口后，实时页显示 `double · 800 ms` 命令；点击“模拟执行”会向 `/api/v1/ack` 回传执行成功。

压力显示依据足内载荷占比、左右镜像同区差异和个人动态基线，不直接使用与体重相关的原始压力固定阈值。温度显示同时给出 T1～T4 的实际位置和左右同区温差。

当前规则仅用于竞赛原型，不是医疗标准。真实 BLE 扫描、60 字节解析和命令写入将在固件联调阶段接入 `BleFootDataSource`。
