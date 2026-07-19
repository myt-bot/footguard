idf_component_register(
    SRCS
        "app_main.c"
        "footguard_crc16.c"
        "footguard_protocol.c"
        "footguard_protocol_selftest.c"
    INCLUDE_DIRS "."
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
