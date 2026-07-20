#include "footguard_mock_sensor.h"

#include <string.h>

#include "footguard_config.h"

enum {
    MOCK_BATTERY_PERCENT = 95
};

uint8_t footguard_mock_sensor_battery_percent(void)
{
    return MOCK_BATTERY_PERCENT;
}

void footguard_mock_sensor_make_data(
    uint32_t packet_seq,
    const footguard_time_snapshot_t *time_snapshot,
    footguard_sensor_data_t *sensor_data)
{
    static const double pressure[FOOTGUARD_PRESSURE_CHANNEL_COUNT] = {
        0.12, 0.24, 0.36, 0.48, 0.30, 0.42
    };
    static const double temperature_c[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT] = {
        31.25, 31.50, 30.80, 30.95
    };
    static const double acceleration_m_s2[FOOTGUARD_IMU_AXIS_COUNT] = {
        0.0, 0.0, 9.80665
    };
    static const double gyroscope_deg_s[FOOTGUARD_IMU_AXIS_COUNT] = {
        0.0, 0.0, 0.0
    };

    if (time_snapshot == NULL || sensor_data == NULL) {
        return;
    }

    memset(sensor_data, 0, sizeof(*sensor_data));
    sensor_data->side = FOOTGUARD_DEVICE_SIDE;
    sensor_data->quality_flags = time_snapshot->time_synced
                                     ? 0U
                                     : FOOTGUARD_QUALITY_TIME_UNSYNCED;
    sensor_data->sync_id = time_snapshot->time_synced
                               ? time_snapshot->sync_id
                               : 0U;
    sensor_data->packet_seq = packet_seq;
    sensor_data->timestamp_ms = time_snapshot->time_synced
                                    ? time_snapshot->timestamp_ms
                                    : 0U;
    memcpy(sensor_data->pressure, pressure, sizeof(pressure));
    memcpy(sensor_data->temperature_c,
           temperature_c,
           sizeof(temperature_c));
    memcpy(sensor_data->acceleration_m_s2,
           acceleration_m_s2,
           sizeof(acceleration_m_s2));
    memcpy(sensor_data->gyroscope_deg_s,
           gyroscope_deg_s,
           sizeof(gyroscope_deg_s));
    sensor_data->battery = MOCK_BATTERY_PERCENT;
}
