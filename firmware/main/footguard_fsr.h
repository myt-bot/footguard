#ifndef FOOTGUARD_FSR_H
#define FOOTGUARD_FSR_H

#include <stddef.h>

#include "esp_err.h"

enum {
    FOOTGUARD_FSR_CHANNEL_COUNT = 6
};

esp_err_t footguard_fsr_init(void);

esp_err_t footguard_fsr_read_raw_channel(
    size_t channel_index,
    int *raw_average);

esp_err_t footguard_fsr_read_raw(int *raw_average);

#endif
