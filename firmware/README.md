# FootGuard Firmware

Initial ESP-IDF firmware skeleton for the FootGuard ESP32-S3 devices. The
project targets ESP-IDF v5.5.4 and uses the native ESP-IDF C framework.

## Current scope

This version implements only SensorData protocol encoding and startup
self-tests for the frozen `layout_6p4t_v1` layout:

- 6 pressure channels and 4 temperature channels per foot
- `layout_id=2`
- fixed 60-byte SensorData frames
- CRC-16/CCITT-FALSE over the first 58 bytes, stored little-endian at bytes
  58 and 59

BLE, ADC, NTC, FSR, MPU6050, and motor support are not connected. This firmware
does not yet collect data from real hardware.

## Device configuration

Device identity is selected in `main/footguard_config.h`. Change
`FOOTGUARD_DEVICE_VARIANT` from `FOOTGUARD_VARIANT_LEFT` to
`FOOTGUARD_VARIANT_RIGHT` to build the right-foot firmware. The side value,
device ID, and reserved BLE device name are derived from that single setting.

The default configuration is:

- side: `left`
- device ID: `foot_left_001`
- reserved BLE name: `FootGuard-L`

## Build and flash

Run these commands from the `firmware` directory in an ESP-IDF v5.5.4 shell:

```text
idf.py set-target esp32s3
idf.py build
idf.py -p COMx flash monitor
```

Replace `COMx` with the board's serial port. Press `Ctrl+]` to exit the serial
monitor.

At startup, the firmware logs its identity and the results of the CRC and both
SensorData standard-vector self-tests.
