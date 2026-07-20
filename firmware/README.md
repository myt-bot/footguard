# FootGuard Firmware

ESP-IDF firmware for the FootGuard ESP32-S3 devices. The project targets
ESP-IDF v5.5.4 and uses the built-in NimBLE C stack without Arduino or external
BLE components.

## Current scope

This phase provides protocol self-tests, a single-connection BLE peripheral,
TimeSync handling, and a 5 Hz mock SensorData stream. It uses the frozen
`layout_6p4t_v1` layout:

- 6 pressure channels and 4 temperature channels per foot
- `protocol_version=1` and `layout_id=2`
- fixed 60-byte SensorData frames
- CRC-16/CCITT-FALSE over bytes 0 through 57, stored little-endian at bytes
  58 and 59
- SensorData notifications only after subscription and MTU negotiation to at
  least 63

FSR402B, NTC, ADC, MPU6050, real battery measurement, and motor GPIO/PWM are
not connected. DeviceCommand execution and executed AckEvent generation are
also not implemented. The stream and battery value are simulated; this
firmware does not collect data from real hardware.

## Mock stream timing limitations

The current 5 Hz mock stream is intended to validate BLE transport and frame
parsing. Mock tasks running on two development boards are not yet subject to
strict sampling-phase synchronization, so this phase does not guarantee that
left and right frames always have the same `packet_seq` or a timestamp
difference of at most 50 ms. A separate synchronized-sampling strategy is
required before bilateral risk pairing is enabled. Do not change the frozen
protocol or backend pairing rules to work around this current limitation.

## Device configuration

Device identity is selected only in `main/footguard_config.h`. Change
`FOOTGUARD_DEVICE_VARIANT` from `FOOTGUARD_VARIANT_LEFT` to
`FOOTGUARD_VARIANT_RIGHT` to build the right-foot firmware. Side, device ID,
advertising name, and SensorData side value are derived from that setting.

| Variant | BLE name | Device ID | Side |
| --- | --- | --- | --- |
| Left (default) | `FootGuard-L` | `foot_left_001` | `left` / 0 |
| Right | `FootGuard-R` | `foot_right_001` | `right` / 1 |

## BLE service

The advertising packet contains the FootGuard service UUID. The scan response
contains the configured BLE device name.

| Item | UUID | Properties | Direction |
| --- | --- | --- | --- |
| FootGuard service | `7d2f0000-5a6b-4c7d-8e9f-102030405060` | Primary | - |
| SensorData | `7d2f0001-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 to App |
| DeviceStatus | `7d2f0002-5a6b-4c7d-8e9f-102030405060` | Read, Notify | ESP32 to App |
| DeviceCommand | `7d2f0003-5a6b-4c7d-8e9f-102030405060` | Write With Response | App to ESP32 |
| TimeSync | `7d2f0004-5a6b-4c7d-8e9f-102030405060` | Write With Response | App to ESP32 |
| AckEvent | `7d2f0005-5a6b-4c7d-8e9f-102030405060` | Notify | ESP32 to App |

DeviceCommand writes are explicitly rejected as unsupported in this phase;
they never control a motor or generate a false executed ACK. AckEvent is
registered for notification but no executed event is generated.

The initial left-device status is the following compact 212-byte UTF-8 JSON:

```json
{"protocol_version":1,"firmware_version":"0.1.0","device_id":"foot_left_001","side":"left","sensor_layout_version":"layout_6p4t_v1","battery":95,"state":"idle","error_code":"none","time_synced":false,"sync_id":0}
```

The App should negotiate MTU 247. TimeSync is a 12-byte little-endian payload:
a 32-bit nonzero `sync_id` followed by a 64-bit Unix time in milliseconds. A
disconnect clears the time base, so every new connection must synchronize
again. DeviceStatus is notified after time or streaming state changes when its
CCCD is enabled and the negotiated MTU can carry the JSON.

## Build

Run these commands from the `firmware` directory in an ESP-IDF v5.5.4 shell:

```text
idf.py set-target esp32s3
idf.py build
```

Once hardware is available, flashing and monitoring use:

```text
idf.py -p COMx flash monitor
```

Replace `COMx` with the board's serial port. Press `Ctrl+]` to exit the serial
monitor. No flash, monitor, phone scan, or physical BLE validation is part of
this phase.

At startup, BLE starts only after the CRC and both SensorData standard-vector
self-tests pass.
