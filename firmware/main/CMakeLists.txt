idf_component_register(
    SRCS
        "app_main.c"
        "footguard_ble.c"
        "footguard_crc16.c"
        "footguard_gatt.c"
        "footguard_mock_sensor.c"
        "footguard_protocol.c"
        "footguard_protocol_selftest.c"
        "footguard_time.c"
    INCLUDE_DIRS "."
    REQUIRES bt esp_timer nvs_flash
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
