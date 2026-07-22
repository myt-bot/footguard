#include "footguard_fsr.h"

#include <stdbool.h>

#include "driver/gpio.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"

#include "footguard_adc.h"

enum {
    FOOTGUARD_FSR_GPIO = GPIO_NUM_1,
    FOOTGUARD_FSR_SAMPLE_COUNT = 32
};

static const char *TAG = "footguard_fsr";
static adc_oneshot_unit_handle_t s_adc_handle;
static adc_channel_t s_adc_channel;
static bool s_initialized;

esp_err_t footguard_fsr_init(void)
{
    adc_unit_t mapped_unit;
    adc_channel_t mapped_channel;
    adc_oneshot_chan_cfg_t channel_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT
    };
    esp_err_t error;

    if (s_initialized) {
        return ESP_OK;
    }

    error = adc_oneshot_io_to_channel(FOOTGUARD_FSR_GPIO,
                                       &mapped_unit,
                                       &mapped_channel);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "GPIO1 ADC mapping failed: %s",
                 esp_err_to_name(error));
        return error;
    }
    if (mapped_unit != ADC_UNIT_1 || mapped_channel != ADC_CHANNEL_0) {
        ESP_LOGE(TAG,
                 "GPIO1 mapped to unexpected ADC unit/channel: unit=%d channel=%d",
                 mapped_unit,
                 mapped_channel);
        return ESP_ERR_INVALID_STATE;
    }

    error = footguard_adc1_get_handle(&s_adc_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Shared ADC1 acquisition failed: %s",
                 esp_err_to_name(error));
        s_adc_handle = NULL;
        return error;
    }

    error = adc_oneshot_config_channel(s_adc_handle,
                                       mapped_channel,
                                       &channel_config);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "ADC1 channel configuration failed: %s",
                 esp_err_to_name(error));
        s_adc_handle = NULL;
        return error;
    }

    s_adc_channel = mapped_channel;
    s_initialized = true;
    ESP_LOGI(TAG,
             "FSR402B ADC ready: GPIO1 -> ADC1_CH0, attenuation=12dB, samples=%d",
             FOOTGUARD_FSR_SAMPLE_COUNT);
    return ESP_OK;
}

esp_err_t footguard_fsr_read_raw(int *raw_average)
{
    int64_t raw_sum = 0;

    if (raw_average == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized || s_adc_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    for (int sample = 0; sample < FOOTGUARD_FSR_SAMPLE_COUNT; ++sample) {
        int raw_value;
        esp_err_t error = adc_oneshot_read(s_adc_handle,
                                           s_adc_channel,
                                           &raw_value);
        if (error != ESP_OK) {
            return error;
        }
        raw_sum += raw_value;
    }

    *raw_average = (int)(raw_sum / FOOTGUARD_FSR_SAMPLE_COUNT);
    return ESP_OK;
}
