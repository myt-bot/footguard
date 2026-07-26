# FootGuard 足安智垫

面向糖尿病足日常管理场景的双足多源风险辅助监测原型。系统以两块 ESP32-S3 采集双足压力、温度和 IMU 数据，经 Flutter App 完成双路 BLE 同步与移动网关，再由 FastAPI 规则引擎识别持续风险、调用云端大模型生成通俗解释，并向风险侧下发震动提醒。提醒后继续采集，记录干预前后指标与恢复效果。

> 本项目是物联网竞赛工程原型，不是医疗器械，不能用于诊断或替代医生意见。当前阈值是可复核的工程参数，不是临床标准。

## 已实现的闭环

`双足感知 → BLE 同步 → 个人基线 → 持续风险识别 → DeepSeek/模板解释 → 目标侧震动 → 设备 ACK → 恢复评价 → 历史记录`

- 每只脚 6 路 FSR 相对压力、4 路 NTC 温度、1 个 MPU6050 和 1 个震动马达。
- 左右固件独立构建，广播为 `FootGuard-L` / `FootGuard-R`，真实数据以 5 Hz 通知。
- App 同时连接两只脚，执行 TimeSync、帧配对、质量屏蔽、热力图和温差展示。
- FastAPI 接收双足批量数据，使用相对分布、左右差异、持续时间和个人基线进行判定。
- 个人基线显示学习进度，可在设置页主动重新校准；重置后不会删除历史事件。
- 风险等级 2 使用双短震，等级 3 使用长震；风险识别和马达决策不由大模型控制。
- DeepSeek 负责非诊断性风险解释，失败时自动退回本地模板。
- 历史页展示风险、目标侧、震动执行状态、干预前后载荷差、恢复时间和效果结论。

## 当前布局

协议布局固定为 `layout_6p4t_v1`，左右脚按解剖区域镜像：

| 通道 | 区域 |
|---|---|
| P1 | 拇趾/最前端 |
| P2 | 前掌外侧 |
| P3 | 前掌中央 |
| P4 | 前掌内侧 |
| P5 | 中足中央 |
| P6 | 足跟中央 |
| T1 | 前掌外侧 |
| T2 | 拇趾/第一跖骨头邻近 |
| T3 | 足跟中央 |
| T4 | 中足中央 |

压力为 0～1 相对量，不是医疗级绝对压力；温度由 10K B3950 NTC 分压换算。风险分析以个人和左右相对变化为主。

## 项目结构

- `firmware/`：ESP32-S3 固件、传感器驱动、BLE、马达执行与 ACK。
- `mobile_app/`：Flutter Android App、双足连接、实时页、历史页、设置与基线管理。
- `backend/`：FastAPI、SQLite、风险规则、DeepSeek 解释、命令和恢复评价。
- `protocol/`：BLE 与 HTTP 协议、Schema、示例和修订说明。
- `sample_data/`：模拟联调场景，不作为真实算法准确率证据。
- `docs/`：竞赛实现方案和现场演示口径。
- `test_reports/`：环境与实机验证记录。

## 快速运行

### 1. 后端

```powershell
cd D:\Projects\footguard
.\backend\.venv\Scripts\python.exe -m uvicorn backend.app.main:app `
    --host 0.0.0.0 `
    --port 8000
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health | ConvertTo-Json
```

如需 DeepSeek，在启动后端的同一个终端中先设置：

```powershell
$env:FOOTGUARD_AI_BASE_URL = "https://api.deepseek.com"
$env:FOOTGUARD_AI_MODEL = "deepseek-v4-flash"
$env:FOOTGUARD_AI_API_KEY = "你的 API Key"
```

不要把密钥提交到 Git。

### 2. App

```powershell
cd D:\Projects\footguard\mobile_app
flutter pub get
flutter run -d <手机设备ID>
```

设置页把 FastAPI 地址设为电脑在手机同一局域网中的地址，例如 `http://192.168.43.15:8000`，数据源选择“BLE 真机实时数据”。

### 3. 左右脚固件

```powershell
cd D:\Projects\footguard\firmware

idf.py -B build-left -D FOOTGUARD_DEVICE_VARIANT=0 build
idf.py -B build-right -D FOOTGUARD_DEVICE_VARIANT=1 build

idf.py -B build-left -p COM左 flash monitor
idf.py -B build-right -p COM右 flash monitor
```

## 校准与风险提醒

新体验者或传感器重新固定后，应在设置页选择“重新校准个人基线”，双脚自然站立、平行且与肩同宽，保持稳定直至达到所需样本数。校准前热力图风险分数保持中性，马达不会提醒。

当前分级提醒：

| 风险等级 | 含义 | 马达 |
|---|---|---|
| 0 | 正常 | 不震动 |
| 1 | 关注（约持续 3 秒） | 不震动 |
| 2 | 警告（约持续 6 秒） | 风险侧双短震，800 ms |
| 3 | 持续异常（约持续 10 秒） | 风险侧长震，1500 ms |

详细规则见 [backend/RISK_RULES.md](backend/RISK_RULES.md)。现场操作见 [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md)。

## 阶段性实测与明天复测

今天已经记录的数据不是无效数据：它能证明各通道有响应、主要风险方向可识别，左右偏载和前掌高载等闭环能够工作。但当时鞋垫尚未完全固定，传感器位置可能轻微移动，接线偶有不稳定，左右手工结构也并非严格对称，因此只作为阶段性工程证据，不直接锁定最终个体基线、点位权重或阈值。

胶完全固化后，以下内容以同一站姿、同一穿戴方式的短复测为准：

1. P1～P6、T1～T4 的实物点位映射和左右镜像关系。
2. 空载零点、抖动、通道灵敏度和是否存在接触不良。
3. 自然站立基线的重复性，以及不同体验者重新校准后的适应性。
4. 压力增量、偏载和温差阈值是否误报或漏报。

无需因复测数据变化重写 BLE、历史、基线入口、DeepSeek、ACK 或分级震动结构；只在证据支持时调整映射、基线和集中配置的工程参数。

## 已知边界

- 当前电量字段为原型状态值，未接入真实电量计时不能宣称为真实剩余电量。
- MPU 数据链路已接入，但完整步态分类与足跟冲击融合仍需可靠行走数据验证。
- 尚无糖尿病患者临床数据，现阶段只做健康志愿者安全场景下的工程验证。
- 电脑当前运行后端和云端调用，可不出现在演示镜头中；核心 App、BLE 和震动链路在手机与设备端展示。

## 验证

```powershell
cd D:\Projects\footguard
.\backend\.venv\Scripts\python.exe -m pytest backend\tests -q

cd mobile_app
flutter analyze --no-pub
flutter test --no-pub
```

## 开发约定

- `main` 始终保持可运行，新功能在独立分支开发并通过 PR 合并。
- 接口字段修改需同步 `protocol/` 与测试。
- 禁止上传 API Key、虚拟环境、构建产物和个人隐私数据。
