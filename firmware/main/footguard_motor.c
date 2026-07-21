#include "footguard_motor.h"

#include "driver/gpio.h"
#include "esp_log.h"

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