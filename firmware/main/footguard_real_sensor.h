#ifndef FOOTGUARD_REAL_SENSOR_H
#define FOOTGUARD_REAL_SENSOR_H

#include <stdint.h>

#include "esp_err.h"
#include "footguard_protocol.h"
#include "footguard_time.h"

esp_err_t footguard_real_sensor_init(void);

esp_err_t footguard_real_sensor_make_data(
    uint32_t packet_seq,
    const footguard_time_snapshot_t *time_snapshot,
    footguard_sensor_data_t *sensor_data);

#endif
