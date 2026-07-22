#include "footguard_motor.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define FOOTGUARD_MOTOR_GPIO GPIO_NUM_13

static const char *TAG = "footguard_motor";
static bool s_initialized;

esp_err_t footguard_motor_init(void)
{
    const gpio_config_t config = {
        .pin_bit_mask = 1ULL << FOOTGUARD_MOTOR_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };

    esp_err_t error = gpio_config(&config);
    if (error != ESP_OK) {
        return error;
    }

    error = gpio_set_level(FOOTGUARD_MOTOR_GPIO, 0);
    if (error != ESP_OK) {
        return error;
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Motor ready: GPIO13, active-high, initial=OFF");
    return ESP_OK;
}

esp_err_t footguard_motor_set(bool enabled)
{
    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    return gpio_set_level(FOOTGUARD_MOTOR_GPIO, enabled ? 1 : 0);
}

static esp_err_t motor_pulse(uint32_t duration_ms)
{
    esp_err_t error = footguard_motor_set(true);

    if (error != ESP_OK) {
        return error;
    }

    vTaskDelay(pdMS_TO_TICKS(duration_ms));

    error = footguard_motor_set(false);
    if (error != ESP_OK) {
        (void)footguard_motor_set(false);
    }
    return error;
}

esp_err_t footguard_motor_execute_pattern(
    footguard_command_pattern_t pattern,
    uint32_t duration_ms)
{
    esp_err_t error;

    switch (pattern) {
    case FOOTGUARD_COMMAND_PATTERN_OFF:
        if (duration_ms != 0U) {
            return ESP_ERR_INVALID_ARG;
        }
        return footguard_motor_set(false);

    case FOOTGUARD_COMMAND_PATTERN_SHORT:
        if (duration_ms < 100U || duration_ms > 1000U) {
            return ESP_ERR_INVALID_ARG;
        }
        return motor_pulse(duration_ms);

    case FOOTGUARD_COMMAND_PATTERN_DOUBLE: {
        uint32_t first_pulse;
        uint32_t second_pulse;

        if (duration_ms < 200U || duration_ms > 2000U) {
            return ESP_ERR_INVALID_ARG;
        }

        first_pulse = duration_ms / 2U;
        second_pulse = duration_ms - first_pulse;

        error = motor_pulse(first_pulse);
        if (error != ESP_OK) {
            (void)footguard_motor_set(false);
            return error;
        }

        vTaskDelay(pdMS_TO_TICKS(200));

        error = motor_pulse(second_pulse);
        if (error != ESP_OK) {
            (void)footguard_motor_set(false);
        }
        return error;
    }

    case FOOTGUARD_COMMAND_PATTERN_LONG:
        if (duration_ms < 1000U || duration_ms > 5000U) {
            return ESP_ERR_INVALID_ARG;
        }
        return motor_pulse(duration_ms);

    default:
        return ESP_ERR_INVALID_ARG;
    }
}