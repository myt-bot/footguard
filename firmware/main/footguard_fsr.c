#include "footguard_fsr.h"

#include <stdbool.h>
#include <stddef.h>

#include "driver/gpio.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"

#include "footguard_adc.h"

enum {
    FOOTGUARD_FSR_SAMPLE_COUNT = 32
};

static const gpio_num_t s_fsr_gpios[FOOTGUARD_FSR_CHANNEL_COUNT] = {
    GPIO_NUM_1,
    GPIO_NUM_2,
    GPIO_NUM_3,
    GPIO_NUM_4,
    GPIO_NUM_5,
    GPIO_NUM_6
};
static const adc_channel_t
    s_expected_adc_channels[FOOTGUARD_FSR_CHANNEL_COUNT] = {
        ADC_CHANNEL_0,
        ADC_CHANNEL_1,
        ADC_CHANNEL_2,
        ADC_CHANNEL_3,
        ADC_CHANNEL_4,
        ADC_CHANNEL_5
    };

static const char *TAG = "footguard_fsr";
static adc_oneshot_unit_handle_t s_adc_handle;
static adc_channel_t s_adc_channels[FOOTGUARD_FSR_CHANNEL_COUNT];
static bool s_initialized;

esp_err_t footguard_fsr_init(void)
{
    adc_oneshot_chan_cfg_t channel_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT
    };
    esp_err_t error;

    if (s_initialized) {
        return ESP_OK;
    }

    error = footguard_adc1_get_handle(&s_adc_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Shared ADC1 acquisition failed: %s",
                 esp_err_to_name(error));
        s_adc_handle = NULL;
        return error;
    }

    for (size_t channel = 0;
         channel < FOOTGUARD_FSR_CHANNEL_COUNT;
         ++channel) {
        adc_unit_t mapped_unit;
        adc_channel_t mapped_channel;

        error = adc_oneshot_io_to_channel(s_fsr_gpios[channel],
                                          &mapped_unit,
                                          &mapped_channel);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "FSR P%u GPIO%d ADC mapping failed: %s",
                     (unsigned int)(channel + 1U),
                     s_fsr_gpios[channel],
                     esp_err_to_name(error));
            s_adc_handle = NULL;
            return error;
        }
        if (mapped_unit != ADC_UNIT_1 ||
            mapped_channel != s_expected_adc_channels[channel]) {
            ESP_LOGE(TAG,
                     "FSR P%u GPIO%d mapped unexpectedly: unit=%d channel=%d",
                     (unsigned int)(channel + 1U),
                     s_fsr_gpios[channel],
                     mapped_unit,
                     mapped_channel);
            s_adc_handle = NULL;
            return ESP_ERR_INVALID_STATE;
        }

        error = adc_oneshot_config_channel(s_adc_handle,
                                           mapped_channel,
                                           &channel_config);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "FSR P%u ADC channel configuration failed: %s",
                     (unsigned int)(channel + 1U),
                     esp_err_to_name(error));
            s_adc_handle = NULL;
            return error;
        }
        s_adc_channels[channel] = mapped_channel;
    }

    s_initialized = true;
    ESP_LOGI(TAG,
             "FSR ADC ready: P1-P6 GPIO1-GPIO6 -> ADC1_CH0-ADC1_CH5, "
             "attenuation=12dB, samples=%d",
             FOOTGUARD_FSR_SAMPLE_COUNT);
    return ESP_OK;
}

esp_err_t footguard_fsr_read_raw_channel(
    size_t channel_index,
    int *raw_average)
{
    int64_t raw_sum = 0;

    if (raw_average == NULL ||
        channel_index >= FOOTGUARD_FSR_CHANNEL_COUNT) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized || s_adc_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    for (int sample = 0; sample < FOOTGUARD_FSR_SAMPLE_COUNT; ++sample) {
        int raw_value;
        esp_err_t error = adc_oneshot_read(s_adc_handle,
                                           s_adc_channels[channel_index],
                                           &raw_value);
        if (error != ESP_OK) {
            return error;
        }
        raw_sum += raw_value;
    }

    *raw_average = (int)(raw_sum / FOOTGUARD_FSR_SAMPLE_COUNT);
    return ESP_OK;
}

esp_err_t footguard_fsr_read_raw(int *raw_average)
{
    return footguard_fsr_read_raw_channel(0U, raw_average);
}
