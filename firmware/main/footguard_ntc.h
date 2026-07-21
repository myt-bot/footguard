#ifndef FOOTGUARD_NTC_H
#define FOOTGUARD_NTC_H

#include "esp_err.h"

typedef struct {
    int raw_average;
    int voltage_mv;
    float temperature_c;
} footguard_ntc_reading_t;

esp_err_t footguard_ntc_init(void);

esp_err_t footguard_ntc_read(footguard_ntc_reading_t *reading);

#endif
