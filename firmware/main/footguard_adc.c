#include "footguard_adc.h"

#include <stdbool.h>

#include "esp_log.h"

static const char *TAG = "footguard_adc";
static adc_oneshot_unit_handle_t s_adc1_handle;
static bool s_initialized;

esp_err_t footguard_adc1_get_handle(
    adc_oneshot_unit_handle_t *handle)
{
    adc_oneshot_unit_init_cfg_t unit_config = {
        .unit_id = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE
    };
    esp_err_t error;

    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized) {
        error = adc_oneshot_new_unit(&unit_config, &s_adc1_handle);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "ADC1 oneshot initialization failed: %s",
                     esp_err_to_name(error));
            s_adc1_handle = NULL;
            return error;
        }
        s_initialized = true;
        ESP_LOGI(TAG, "Shared ADC1 oneshot unit ready");
    }
    if (s_adc1_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    *handle = s_adc1_handle;
    return ESP_OK;
}
