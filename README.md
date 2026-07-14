# FootGuard 足安智垫

基于双足多源感知、ESP32-S3、Flutter App和云端大模型的足部风险辅助监测系统。

## 当前技术栈

- 固件：ESP-IDF v5.5.4、C/C++
- 主控：ESP32-S3
- 通信：Bluetooth Low Energy
- App：Flutter
- 后端：FastAPI、SQLite
- 电脑BLE调试：Python 3.11、Bleak

## 目录

- `firmware/`：ESP32-S3固件
- `mobile_app/`：Flutter App
- `backend/`：FastAPI后端
- `protocol/`：双方共同遵守的接口协议
- `tools/`：模拟数据和BLE调试工具
- `sample_data/`：标准测试数据
- `test_reports/`：联调和测试记录

## 开发约定

- `main`始终保持可运行。
- 新功能在独立分支开发。
- 接口字段修改必须先修改`protocol/`并经双方确认。
- 禁止上传密钥、虚拟环境、编译产物和个人隐私数据。