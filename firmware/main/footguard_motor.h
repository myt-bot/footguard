#pragma once

#include <stdbool.h>

#include "esp_err.h"
#include "footguard_command.h"

esp_err_t footguard_motor_init(void);
esp_err_t footguard_motor_set(bool enabled);
esp_err_t footguard_motor_execute_pattern(
    footguard_command_pattern_t pattern,
    uint32_t duration_ms);