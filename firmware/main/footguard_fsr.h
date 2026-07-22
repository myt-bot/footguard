#ifndef FOOTGUARD_FSR_H
#define FOOTGUARD_FSR_H

#include "esp_err.h"

esp_err_t footguard_fsr_init(void);

esp_err_t footguard_fsr_read_raw(int *raw_average);

#endif
