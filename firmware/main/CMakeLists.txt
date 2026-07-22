idf_component_register(
    SRCS
        "app_main.c"
        "footguard_ble.c"
        "footguard_command.c"
        "footguard_command_executor.c"
        "footguard_command_service.c"
        "footguard_crc16.c"
        "footguard_fsr.c"
        "footguard_gatt.c"
        "footguard_mock_sensor.c"
        "footguard_motor.c"
        "footguard_mpu6050.c"
        "footguard_ntc.c"
        "footguard_protocol.c"
        "footguard_real_sensor.c"
        "footguard_protocol_selftest.c"
        "footguard_time.c"
    INCLUDE_DIRS "."
    REQUIRES bt esp_adc esp_driver_gpio esp_driver_i2c esp_timer json nvs_flash
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)