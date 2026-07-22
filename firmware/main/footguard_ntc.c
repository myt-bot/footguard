#include "footguard_ntc.h"

#include <math.h>
#include <stdbool.h>
#include <stddef.h>

#include "driver/gpio.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"

#include "footguard_adc.h"

enum {
    FOOTGUARD_NTC_SAMPLE_COUNT = 32,
    FOOTGUARD_NTC_FIXED_RESISTOR_OHM = 10000,
    FOOTGUARD_NTC_NOMINAL_RESISTOR_OHM = 10000,
    FOOTGUARD_NTC_BETA = 3950,
    FOOTGUARD_NTC_SUPPLY_MV = 3300
};

static const gpio_num_t s_ntc_gpios[FOOTGUARD_NTC_CHANNEL_COUNT] = {
    GPIO_NUM_7,
    GPIO_NUM_8,
    GPIO_NUM_9,
    GPIO_NUM_10
};
static const adc_channel_t
    s_expected_adc_channels[FOOTGUARD_NTC_CHANNEL_COUNT] = {
        ADC_CHANNEL_6,
        ADC_CHANNEL_7,
        ADC_CHANNEL_8,
        ADC_CHANNEL_9
    };

static const char *TAG = "footguard_ntc";
static adc_oneshot_unit_handle_t s_adc_handle;
static adc_cali_handle_t s_cali_handles[FOOTGUARD_NTC_CHANNEL_COUNT];
static adc_channel_t s_adc_channels[FOOTGUARD_NTC_CHANNEL_COUNT];
static bool s_initialized;

static void release_resources(void)
{
    for (size_t channel = 0;
         channel < FOOTGUARD_NTC_CHANNEL_COUNT;
         ++channel) {
        if (s_cali_handles[channel] != NULL) {
            (void)adc_cali_delete_scheme_curve_fitting(
                s_cali_handles[channel]);
            s_cali_handles[channel] = NULL;
        }
    }
    s_adc_handle = NULL;
}
esp_err_t footguard_ntc_init(void)
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
         channel < FOOTGUARD_NTC_CHANNEL_COUNT;
         ++channel) {
        adc_cali_curve_fitting_config_t cali_config;
        adc_unit_t mapped_unit;
        adc_channel_t mapped_channel;

        error = adc_oneshot_io_to_channel(s_ntc_gpios[channel],
                                          &mapped_unit,
                                          &mapped_channel);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "NTC T%u GPIO%d ADC mapping failed: %s",
                     (unsigned int)(channel + 1U),
                     s_ntc_gpios[channel],
                     esp_err_to_name(error));
            release_resources();
            return error;
        }
        if (mapped_unit != ADC_UNIT_1 ||
            mapped_channel != s_expected_adc_channels[channel]) {
            ESP_LOGE(TAG,
                     "NTC T%u GPIO%d mapped unexpectedly: unit=%d channel=%d",
                     (unsigned int)(channel + 1U),
                     s_ntc_gpios[channel],
                     mapped_unit,
                     mapped_channel);
            release_resources();
            return ESP_ERR_INVALID_STATE;
        }

        error = adc_oneshot_config_channel(s_adc_handle,
                                           mapped_channel,
                                           &channel_config);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "NTC T%u ADC channel configuration failed: %s",
                     (unsigned int)(channel + 1U),
                     esp_err_to_name(error));
            release_resources();
            return error;
        }

        cali_config = (adc_cali_curve_fitting_config_t) {
            .unit_id = ADC_UNIT_1,
            .chan = mapped_channel,
            .atten = ADC_ATTEN_DB_12,
            .bitwidth = ADC_BITWIDTH_DEFAULT
        };
        error = adc_cali_create_scheme_curve_fitting(
            &cali_config,
            &s_cali_handles[channel]);
        if (error != ESP_OK) {
            ESP_LOGE(TAG, "NTC T%u ADC calibration failed: %s",
                     (unsigned int)(channel + 1U),
                     esp_err_to_name(error));
            release_resources();
            return error;
        }
        s_adc_channels[channel] = mapped_channel;
    }

    s_initialized = true;
    ESP_LOGI(TAG,
             "NTC ADC ready: T1-T4 GPIO7-GPIO10 -> ADC1_CH6-ADC1_CH9, "
             "10K B3950, samples=%d",
             FOOTGUARD_NTC_SAMPLE_COUNT);
    return ESP_OK;
}

esp_err_t footguard_ntc_read_channel(
    size_t channel_index,
    footguard_ntc_reading_t *reading)
{
    int64_t raw_sum = 0;
    int voltage_mv;
    float resistance_ohm;
    float temperature_kelvin;
    esp_err_t error;

    if (reading == NULL || channel_index >= FOOTGUARD_NTC_CHANNEL_COUNT) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized || s_adc_handle == NULL ||
        s_cali_handles[channel_index] == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    for (int sample = 0; sample < FOOTGUARD_NTC_SAMPLE_COUNT; ++sample) {
        int raw_value;

        error = adc_oneshot_read(s_adc_handle,
                                 s_adc_channels[channel_index],
                                 &raw_value);
        if (error != ESP_OK) {
            return error;
        }
        raw_sum += raw_value;
    }

    reading->raw_average = (int)(raw_sum / FOOTGUARD_NTC_SAMPLE_COUNT);
    error = adc_cali_raw_to_voltage(s_cali_handles[channel_index],
                                    reading->raw_average,
                                    &voltage_mv);
    if (error != ESP_OK) {
        return error;
    }
    if (voltage_mv <= 0 || voltage_mv >= FOOTGUARD_NTC_SUPPLY_MV) {
        return ESP_ERR_INVALID_RESPONSE;
    }

    resistance_ohm =
        (float)FOOTGUARD_NTC_FIXED_RESISTOR_OHM * (float)voltage_mv /
        (float)(FOOTGUARD_NTC_SUPPLY_MV - voltage_mv);
    temperature_kelvin =
        1.0f /
        ((1.0f / 298.15f) +
         (logf(resistance_ohm /
               (float)FOOTGUARD_NTC_NOMINAL_RESISTOR_OHM) /
          (float)FOOTGUARD_NTC_BETA));

    reading->voltage_mv = voltage_mv;
    reading->temperature_c = temperature_kelvin - 273.15f;
    return ESP_OK;
}

esp_err_t footguard_ntc_read(footguard_ntc_reading_t *reading)
{
    return footguard_ntc_read_channel(0U, reading);
}
