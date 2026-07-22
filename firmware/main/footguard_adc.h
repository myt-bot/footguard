#ifndef FOOTGUARD_ADC_H
#define FOOTGUARD_ADC_H

#include "esp_adc/adc_oneshot.h"
#include "esp_err.h"

esp_err_t footguard_adc1_get_handle(
    adc_oneshot_unit_handle_t *handle);

#endif
