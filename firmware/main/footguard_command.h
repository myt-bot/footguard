#ifndef FOOTGUARD_COMMAND_H
#define FOOTGUARD_COMMAND_H

#include <stddef.h>
#include <stdint.h>

enum {
    FOOTGUARD_DEVICE_COMMAND_MAX_SIZE = 244,
    FOOTGUARD_COMMAND_ID_CAPACITY = 53,
    FOOTGUARD_REASON_CODE_CAPACITY = 32
};

typedef enum {
    FOOTGUARD_COMMAND_TARGET_LEFT = 0,
    FOOTGUARD_COMMAND_TARGET_RIGHT,
    FOOTGUARD_COMMAND_TARGET_BOTH
} footguard_command_target_t;

typedef enum {
    FOOTGUARD_COMMAND_PATTERN_OFF = 0,
    FOOTGUARD_COMMAND_PATTERN_SHORT,
    FOOTGUARD_COMMAND_PATTERN_DOUBLE,
    FOOTGUARD_COMMAND_PATTERN_LONG
} footguard_command_pattern_t;

typedef struct {
    char command_id[FOOTGUARD_COMMAND_ID_CAPACITY];
    footguard_command_target_t target;
    footguard_command_pattern_t pattern;
    uint32_t duration_ms;
    uint64_t expire_at_ms;
    char reason_code[FOOTGUARD_REASON_CODE_CAPACITY];
} footguard_command_t;

typedef enum {
    FOOTGUARD_COMMAND_PARSE_OK = 0,
    FOOTGUARD_COMMAND_PARSE_INVALID_JSON,
    FOOTGUARD_COMMAND_PARSE_UNSUPPORTED_PROTOCOL,
    FOOTGUARD_COMMAND_PARSE_INVALID_COMMAND_ID,
    FOOTGUARD_COMMAND_PARSE_INVALID_TARGET,
    FOOTGUARD_COMMAND_PARSE_INVALID_PATTERN,
    FOOTGUARD_COMMAND_PARSE_INVALID_DURATION,
    FOOTGUARD_COMMAND_PARSE_INVALID_EXPIRY,
    FOOTGUARD_COMMAND_PARSE_INVALID_REASON
} footguard_command_parse_result_t;

footguard_command_parse_result_t footguard_command_parse(
    const uint8_t *payload,
    size_t payload_size,
    footguard_command_t *command);

const char *footguard_command_parse_result_name(
    footguard_command_parse_result_t result);
    
#endif

