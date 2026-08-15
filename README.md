# FootGuard 足安智垫

面向糖尿病足日常管理场景的双足多源风险辅助监测原型。系统以两块 ESP32-S3 采集双足压力、温度和 IMU 数据，经 Flutter App 完成双路 BLE 同步与移动网关，再由 FastAPI 规则引擎识别持续风险、调用云端大模型生成通俗解释，并向风险侧下发震动提醒。提醒后继续采集，记录干预前后指标与恢复效果。

> 本项目是物联网竞赛工程原型，不是医疗器械，不能用于诊断或替代医生意见。当前阈值是可复核的工程参数，不是临床标准。

## 已实现的闭环

`双足感知 → BLE 同步 → 个人基线 → 持续风险识别 → DeepSeek/模板解释 → 目标侧震动 → 设备 ACK → 15 秒恢复评价 → 历史记录/CSV`

- 每只脚 6 路 FSR 相对压力、4 路 NTC 温度、1 个 MPU6050 和 1 个震动马达。
- 左右固件独立构建，广播为 `FootGuard-L` / `FootGuard-R`；压力与 MPU 以 20 Hz 通知，温度以 5 Hz 刷新并缓存到帧中。
- App 同时连接两只脚，执行 TimeSync、帧配对和质量屏蔽；正常站立时压力热力图也持续显示真实相对受力。
- 后端结合本次站立基线、左右交替承重和 MPU 运动状态生成完整行走段；单段只作观察，只有连续 3 段均出现同向单侧偏载或前掌反复受压时才形成正式工程趋势。
- FastAPI 使用平滑后的对数载荷比、区域占比相对变化、MAD 噪声尺度、双阈值和持续时间进行判定。
- 温度与压力独立降级：温度点缺失不会清空压力图、阻断压力风险、压力马达或恢复评价。
- 实时页和设置页均可开始“新体验者 / 重新穿戴”标定；计算后的基线持久化，重启后不会因历史帧窗口滑动而丢失。
- 风险等级 2 播报准确风险名称，等级 3 才向风险侧发送一次长震；风险识别和马达决策不由大模型控制。
- DeepSeek 支持正常、风险、温度不可用、连接异常和基线学习中的预设问答与自由提问，失败时自动退回状态化本地模板。
- 历史页提供“风险事件”和“步态记录”两个视图，展示四类压力异常相对个人基线的干预前后值、改善或加重比例、数据充分性、三段行走趋势和会话 AI 预设追问。
- 后端断开时，App 使用同版本轻量本地规则继续风险判定、BLE 马达和离线缓存；恢复后按设备序号幂等补传并重建历史。
- 风险干预后 App 与 Web 同时显示 15 秒观察倒计时，前台弹窗、后台 Android 通知均按事件去重。
- `http://电脑地址:8000/dashboard/` 提供双脚热力图、组合风险、AI 会话建议、趋势图、历史与 CSV 导出；内置 CSV 回放始终标注为演示数据。

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

Web 控制台：

```text
http://127.0.0.1:8000/dashboard/
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

新体验者、重新穿鞋或传感器重新固定后，应在实时页选择“新体验者 / 重新穿戴”。双脚自然平行站立，至少采集 40 对完整稳定压力帧，通常约 8～12 秒。温度或 MPU 缺失不阻止压力标定；压力通道不完整、未承重或移动会显示具体原因。标定前热力图仍显示当前压力，但压力风险与压力马达不会启用。

当前分级提醒：

| 风险等级 | 含义 | 马达 |
|---|---|---|
| 0 | 正常 | 不震动 |
| 1 | 关注（约持续 3 秒） | 不震动 |
| 2 | 需要减负（压力约持续 10 秒） | 准确风险名称播报，不震动 |
| 3 | 持续未改善（压力约持续 20 秒） | 风险侧单次长震，1500 ms |

详细规则见 [backend/RISK_RULES.md](backend/RISK_RULES.md)。现场操作见 [docs/DEMO_GUIDE.md](docs/DEMO_GUIDE.md)。

## 阶段性实测与明天复测

今天已经记录的数据不是无效数据：它能证明各通道有响应、主要风险方向可识别，左右偏载和前掌高载等闭环能够工作。但当时鞋垫尚未完全固定，传感器位置可能轻微移动，接线偶有不稳定，左右手工结构也并非严格对称，因此只作为阶段性工程证据，不直接锁定最终个体基线、点位权重或阈值。

胶完全固化后，以下内容以同一站姿、同一穿戴方式的短复测为准：

1. P1～P6、T1～T4 的实物点位映射和左右镜像关系。
2. 空载零点、抖动、通道灵敏度和是否存在接触不良。
3. 自然站立基线的重复性，以及不同体验者重新校准后的适应性。
4. 压力相对变化、偏载和温差阈值是否误报或漏报。

无需因复测数据变化重写 BLE、历史、基线入口、DeepSeek、ACK 或分级震动结构；只在证据支持时调整映射、基线和集中配置的工程参数。

## 已知边界

- 当前使用充电宝供电，协议暂保留电量字段，但 App 隐藏所有电量百分比；接入真实锂电池电量计后再恢复电量 UI 和告警。
- 当前仅完成单人重复穿戴的自动化与工程方案，不能宣称已验证多人准确率；新体验者必须现场快速标定。
- 已有有效行走分段、落脚/步频、左右压力时间积分、反复区域负荷与步时稳定性评估；拖步识别、足跟冲击、完整病理步态分型和临床阈值仍需更多低丢帧标注数据验证。
- 尚无糖尿病患者临床数据，现阶段只做健康志愿者安全场景下的工程验证。
- 无外网时 FastAPI、SQLite、Web 与本地 AI 模板仍可用；云端 DeepSeek 会自动降级。
- 无局域网或电脑熄屏导致后端不可达时，App 本地规则、BLE 马达与缓存继续运行；Web 无法接收手机新数据，可用明确标注的 CSV 回放兜底。

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
