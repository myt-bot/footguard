#ifndef FOOTGUARD_MOCK_SENSOR_H
#define FOOTGUARD_MOCK_SENSOR_H

#include <stdint.h>

#include "footguard_protocol.h"
#include "footguard_time.h"

uint8_t footguard_mock_sensor_battery_percent(void);

void footguard_mock_sensor_make_data(
    uint32_t packet_seq,
    const footguard_time_snapshot_t *time_snapshot,
    footguard_sensor_data_t *sensor_data);

#endif
