#include "footguard_ntc.h"

#include <math.h>
#include <stdbool.h>

#include "driver/gpio.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"

enum {
    FOOTGUARD_NTC_GPIO = GPIO_NUM_7,
    FOOTGUARD_NTC_SAMPLE_COUNT = 32,
    FOOTGUARD_NTC_FIXED_RESISTOR_OHM = 10000,
    FOOTGUARD_NTC_NOMINAL_RESISTOR_OHM = 10000,
    FOOTGUARD_NTC_BETA = 3950,
    FOOTGUARD_NTC_SUPPLY_MV = 3300
};

static const char *TAG = "footguard_ntc";
static adc_oneshot_unit_handle_t s_adc_handle;
static adc_cali_handle_t s_cali_handle;
static adc_channel_t s_adc_channel;
static bool s_initialized;

esp_err_t footguard_ntc_init(void)
{
    adc_unit_t mapped_unit;
    adc_channel_t mapped_channel;
    adc_oneshot_unit_init_cfg_t unit_config = {
        .unit_id = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE
    };
    adc_oneshot_chan_cfg_t channel_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT
    };
    adc_cali_curve_fitting_config_t cali_config;
    esp_err_t error;

    if (s_initialized) {
        return ESP_OK;
    }

    error = adc_oneshot_io_to_channel(FOOTGUARD_NTC_GPIO,
                                      &mapped_unit,
                                      &mapped_channel);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "GPIO7 ADC mapping failed: %s",
                 esp_err_to_name(error));
        return error;
    }
    if (mapped_unit != ADC_UNIT_1 || mapped_channel != ADC_CHANNEL_6) {
        ESP_LOGE(TAG,
                 "GPIO7 mapped to unexpected ADC unit/channel: unit=%d channel=%d",
                 mapped_unit,
                 mapped_channel);
        return ESP_ERR_INVALID_STATE;
    }

    error = adc_oneshot_new_unit(&unit_config, &s_adc_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "ADC1 oneshot initialization failed: %s",
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
        (void)adc_oneshot_del_unit(s_adc_handle);
        s_adc_handle = NULL;
        return error;
    }

    cali_config = (adc_cali_curve_fitting_config_t) {
        .unit_id = ADC_UNIT_1,
        .chan = mapped_channel,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT
    };
    error = adc_cali_create_scheme_curve_fitting(&cali_config,
                                                  &s_cali_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "ADC calibration initialization failed: %s",
                 esp_err_to_name(error));
        (void)adc_oneshot_del_unit(s_adc_handle);
        s_adc_handle = NULL;
        return error;
    }

    s_adc_channel = mapped_channel;
    s_initialized = true;
    ESP_LOGI(TAG,
             "NTC ADC ready: GPIO7 -> ADC1_CH6, 10K B3950, samples=%d",
             FOOTGUARD_NTC_SAMPLE_COUNT);
    return ESP_OK;
}

esp_err_t footguard_ntc_read(footguard_ntc_reading_t *reading)
{
    int64_t raw_sum = 0;
    int voltage_mv;
    float resistance_ohm;
    float temperature_kelvin;
    esp_err_t error;

    if (reading == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized || s_adc_handle == NULL || s_cali_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    for (int sample = 0; sample < FOOTGUARD_NTC_SAMPLE_COUNT; ++sample) {
        int raw_value;

        error = adc_oneshot_read(s_adc_handle,
                                 s_adc_channel,
                                 &raw_value);
        if (error != ESP_OK) {
            return error;
        }
        raw_sum += raw_value;
    }

    reading->raw_average = (int)(raw_sum / FOOTGUARD_NTC_SAMPLE_COUNT);
    error = adc_cali_raw_to_voltage(s_cali_handle,
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
