# FootGuard Flutter App

## 运行

1. 在仓库根目录启动 FastAPI：`python -m uvicorn backend.app.main:app --host 0.0.0.0 --port 8000`。
2. Android 模拟器使用默认地址 `http://10.0.2.2:8000`。
3. 在本目录执行 `flutter pub get`、`flutter run -d emulator-5554`。

真机正式构建可在编译时指定默认后端地址：

```powershell
flutter build apk --release `
  --dart-define=FOOTGUARD_BACKEND_URL=http://192.168.1.6:8000
```

正式版设置页始终允许修改和检测后端地址，但不显示模拟数据源或 CSV 回放。只有显式增加 `--dart-define=FOOTGUARD_DIAGNOSTIC_REPLAY=true` 时才显示诊断回放入口。

## 页面

- 首页：项目能力与监测入口；
- 实时：左右脚 6 区压力热图、4 点温度、独立站立风险、最近行走评估、同步质量和马达命令；
- 历史：风险事件和步态记录双视图；
- 设备：左右设备、电量、协议和数据源；
- 设置：Mock/CSV/API/BLE 数据源、场景、回放速度和后端地址。

## 马达提醒演示

诊断模式可选择 `Mock 实时生成` 和 `left_load_bias` 或 `right_load_bias`。持续偏载达到等级 2 时只播报准确风险名称；达到等级 3 后，实时页显示风险侧 `long · 1500 ms` 单次命令，点击“模拟执行”会向 `/api/v1/ack` 回传执行成功。

压力显示依据足内载荷占比、左右镜像同区差异和个人动态基线，不直接使用与体重相关的原始压力固定阈值。温度显示同时给出 T1～T4 的实际位置和左右同区温差。

当前规则仅用于竞赛原型，不是医疗标准。真实 BLE 扫描、60 字节解析和命令写入将在固件联调阶段接入 `BleFootDataSource`。
