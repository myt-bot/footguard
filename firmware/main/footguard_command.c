#include "footguard_command.h"

#include <stdbool.h>
#include <string.h>

#include "cJSON.h"

enum {
    FIELD_PROTOCOL_VERSION = 1U << 0,
    FIELD_COMMAND_ID = 1U << 1,
    FIELD_TARGET = 1U << 2,
    FIELD_PATTERN = 1U << 3,
    FIELD_DURATION_MS = 1U << 4,
    FIELD_EXPIRE_AT_MS = 1U << 5,
    FIELD_REASON_CODE = 1U << 6,
    ALL_FIELDS = (1U << 7) - 1U
};

static uint32_t field_flag(const char *name)
{
    if (strcmp(name, "protocol_version") == 0) {
        return FIELD_PROTOCOL_VERSION;
    }
    if (strcmp(name, "command_id") == 0) {
        return FIELD_COMMAND_ID;
    }
    if (strcmp(name, "target") == 0) {
        return FIELD_TARGET;
    }
    if (strcmp(name, "pattern") == 0) {
        return FIELD_PATTERN;
    }
    if (strcmp(name, "duration_ms") == 0) {
        return FIELD_DURATION_MS;
    }
    if (strcmp(name, "expire_at_ms") == 0) {
        return FIELD_EXPIRE_AT_MS;
    }
    if (strcmp(name, "reason_code") == 0) {
        return FIELD_REASON_CODE;
    }
    return 0U;
}

static bool has_exact_fields(const cJSON *root)
{
    const cJSON *item;
    uint32_t fields = 0U;

    cJSON_ArrayForEach(item, root) {
        uint32_t flag;

        if (item->string == NULL) {
            return false;
        }
        flag = field_flag(item->string);
        if (flag == 0U || (fields & flag) != 0U) {
            return false;
        }
        fields |= flag;
    }

    return fields == ALL_FIELDS;
}

static bool read_uint64(const cJSON *item, uint64_t *value)
{
    const double maximum_exact_integer = 9007199254740991.0;
    uint64_t integer;

    if (!cJSON_IsNumber(item) || item->valuedouble < 0.0 ||
        item->valuedouble > maximum_exact_integer) {
        return false;
    }
    integer = (uint64_t)item->valuedouble;
    if ((double)integer != item->valuedouble) {
        return false;
    }
    *value = integer;
    return true;
}

static bool read_string(const cJSON *item, char *output, size_t output_size)
{
    size_t length;

    if (!cJSON_IsString(item) || item->valuestring == NULL) {
        return false;
    }
    length = strlen(item->valuestring);
    if (length >= output_size) {
        return false;
    }
    memcpy(output, item->valuestring, length + 1U);
    return true;
}

static bool valid_command_id(const char *command_id)
{
    size_t length = strlen(command_id);

    if (length < 5U || length > 52U ||
        strncmp(command_id, "cmd_", 4U) != 0) {
        return false;
    }
    for (size_t index = 4U; index < length; ++index) {
        char value = command_id[index];
        bool valid = (value >= 'A' && value <= 'Z') ||
                     (value >= 'a' && value <= 'z') ||
                     (value >= '0' && value <= '9') ||
                     value == '_' || value == '-';
        if (!valid) {
            return false;
        }
    }
    return true;
}

static bool parse_target(const char *value, footguard_command_target_t *target)
{
    if (strcmp(value, "left") == 0) {
        *target = FOOTGUARD_COMMAND_TARGET_LEFT;
        return true;
    }
    if (strcmp(value, "right") == 0) {
        *target = FOOTGUARD_COMMAND_TARGET_RIGHT;
        return true;
    }
    if (strcmp(value, "both") == 0) {
        *target = FOOTGUARD_COMMAND_TARGET_BOTH;
        return true;
    }
    return false;
}

static bool parse_pattern(const char *value,
                          footguard_command_pattern_t *pattern)
{
    if (strcmp(value, "off") == 0) {
        *pattern = FOOTGUARD_COMMAND_PATTERN_OFF;
        return true;
    }
    if (strcmp(value, "short") == 0) {
        *pattern = FOOTGUARD_COMMAND_PATTERN_SHORT;
        return true;
    }
    if (strcmp(value, "double") == 0) {
        *pattern = FOOTGUARD_COMMAND_PATTERN_DOUBLE;
        return true;
    }
    if (strcmp(value, "long") == 0) {
        *pattern = FOOTGUARD_COMMAND_PATTERN_LONG;
        return true;
    }
    return false;
}

static bool valid_duration(footguard_command_pattern_t pattern,
                           uint32_t duration_ms)
{
    switch (pattern) {
    case FOOTGUARD_COMMAND_PATTERN_OFF:
        return duration_ms == 0U;
    case FOOTGUARD_COMMAND_PATTERN_SHORT:
        return duration_ms >= 100U && duration_ms <= 1000U;
    case FOOTGUARD_COMMAND_PATTERN_DOUBLE:
        return duration_ms >= 200U && duration_ms <= 2000U;
    case FOOTGUARD_COMMAND_PATTERN_LONG:
        return duration_ms >= 1000U && duration_ms <= 5000U;
    default:
        return false;
    }
}

static bool valid_reason(const char *reason)
{
    static const char *const reasons[] = {
        "manual_test",
        "left_load_bias",
        "right_load_bias",
        "forefoot_high",
        "temperature_asymmetry",
        "risk_persisted",
        "cancel"
    };

    for (size_t index = 0; index < sizeof(reasons) / sizeof(reasons[0]);
         ++index) {
        if (strcmp(reason, reasons[index]) == 0) {
            return true;
        }
    }
    return false;
}

footguard_command_parse_result_t footguard_command_parse(
    const uint8_t *payload,
    size_t payload_size,
    footguard_command_t *command)
{
    char json[FOOTGUARD_DEVICE_COMMAND_MAX_SIZE + 1U];
    char target[6];
    char pattern[7];
    uint64_t protocol_version;
    uint64_t duration_ms;
    cJSON *root;
    footguard_command_parse_result_t result = FOOTGUARD_COMMAND_PARSE_OK;

    if (payload == NULL || command == NULL || payload_size == 0U ||
        payload_size > FOOTGUARD_DEVICE_COMMAND_MAX_SIZE) {
        return FOOTGUARD_COMMAND_PARSE_INVALID_JSON;
    }
    memcpy(json, payload, payload_size);
    json[payload_size] = '\0';
    memset(command, 0, sizeof(*command));

    root = cJSON_Parse(json);
    if (!cJSON_IsObject(root) || !has_exact_fields(root)) {
        cJSON_Delete(root);
        return FOOTGUARD_COMMAND_PARSE_INVALID_JSON;
    }

    if (!read_uint64(cJSON_GetObjectItemCaseSensitive(root,
                                                      "protocol_version"),
                     &protocol_version) ||
        protocol_version != 1U) {
        result = FOOTGUARD_COMMAND_PARSE_UNSUPPORTED_PROTOCOL;
    } else if (!read_string(cJSON_GetObjectItemCaseSensitive(root,
                                                              "command_id"),
                            command->command_id,
                            sizeof(command->command_id)) ||
               !valid_command_id(command->command_id)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_COMMAND_ID;
    } else if (!read_string(cJSON_GetObjectItemCaseSensitive(root, "target"),
                            target, sizeof(target)) ||
               !parse_target(target, &command->target)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_TARGET;
    } else if (!read_string(cJSON_GetObjectItemCaseSensitive(root, "pattern"),
                            pattern, sizeof(pattern)) ||
               !parse_pattern(pattern, &command->pattern)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_PATTERN;
    } else if (!read_uint64(cJSON_GetObjectItemCaseSensitive(root,
                                                              "duration_ms"),
                            &duration_ms) ||
               duration_ms > UINT32_MAX ||
               !valid_duration(command->pattern, (uint32_t)duration_ms)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_DURATION;
    } else if (!read_uint64(cJSON_GetObjectItemCaseSensitive(root,
                                                              "expire_at_ms"),
                            &command->expire_at_ms)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_EXPIRY;
    } else if (!read_string(cJSON_GetObjectItemCaseSensitive(root,
                                                              "reason_code"),
                            command->reason_code,
                            sizeof(command->reason_code)) ||
               !valid_reason(command->reason_code)) {
        result = FOOTGUARD_COMMAND_PARSE_INVALID_REASON;
    } else {
        command->duration_ms = (uint32_t)duration_ms;
            }

    cJSON_Delete(root);
    return result;
}

const char *footguard_command_parse_result_name(
    footguard_command_parse_result_t result)
{
    static const char *const names[] = {
        "ok",
        "invalid_json",
        "unsupported_protocol",
        "invalid_command_id",
        "invalid_target",
        "invalid_pattern",
        "invalid_duration",
        "invalid_expiry",
        "invalid_reason"
    };

    if ((unsigned int)result >= sizeof(names) / sizeof(names[0])) {
        return "unknown";
    }
    return names[result];
}
