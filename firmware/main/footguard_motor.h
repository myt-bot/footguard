#pragma once

#include <stdbool.h>

#include "esp_err.h"

esp_err_t footguard_motor_init(void);
esp_err_t footguard_motor_set(bool enabled);