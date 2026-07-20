#ifndef FOOTGUARD_PROTOCOL_H
#define FOOTGUARD_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    FOOTGUARD_PROTOCOL_VERSION = 1,
    FOOTGUARD_LAYOUT_ID_6P4T_V1 = 2,
    FOOTGUARD_SENSOR_FRAME_SIZE = 60,
    FOOTGUARD_SENSOR_FRAME_CRC_OFFSET = 58,
    FOOTGUARD_SENSOR_FRAME_CRC_INPUT_SIZE = 58,
    FOOTGUARD_PRESSURE_CHANNEL_COUNT = 6,
    FOOTGUARD_TEMPERATURE_CHANNEL_COUNT = 4,
    FOOTGUARD_IMU_AXIS_COUNT = 3
};

#define FOOTGUARD_SENSOR_LAYOUT_VERSION "layout_6p4t_v1"
#define FOOTGUARD_QUALITY_TIME_UNSYNCED UINT32_C(0x00000800)

typedef enum {
    FOOTGUARD_SIDE_LEFT = 0,
    FOOTGUARD_SIDE_RIGHT = 1
} footguard_side_t;

#define FOOTGUARD_QUALITY_FLAGS_V1_MASK UINT32_C(0x0000FFFF)

typedef struct {
    footguard_side_t side;
    uint32_t quality_flags;
    uint32_t sync_id;
    uint32_t packet_seq;
    uint64_t timestamp_ms;
    double pressure[FOOTGUARD_PRESSURE_CHANNEL_COUNT];
    double temperature_c[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT];
    double acceleration_m_s2[FOOTGUARD_IMU_AXIS_COUNT];
    double gyroscope_deg_s[FOOTGUARD_IMU_AXIS_COUNT];
    uint8_t battery;
} footguard_sensor_data_t;

bool footguard_protocol_encode_sensor_data(
    const footguard_sensor_data_t *sensor_data,
    uint8_t *output,
    size_t output_size);

bool footguard_protocol_sensor_frame_crc_is_valid(
    const uint8_t *frame,
    size_t frame_size);

#endif
