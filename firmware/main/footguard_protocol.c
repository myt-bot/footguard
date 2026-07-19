#include "footguard_protocol.h"

#include <limits.h>
#include <math.h>

#include "footguard_crc16.h"

#define FOOTGUARD_STANDARD_GRAVITY_M_S2 9.80665

enum {
    MAGIC_OFFSET = 0,
    PROTOCOL_VERSION_OFFSET = 2,
    LAYOUT_ID_OFFSET = 3,
    SIDE_OFFSET = 4,
    QUALITY_FLAGS_OFFSET = 5,
    SYNC_ID_OFFSET = 9,
    PACKET_SEQ_OFFSET = 13,
    TIMESTAMP_MS_OFFSET = 17,
    PRESSURE_OFFSET = 25,
    TEMPERATURE_OFFSET = 37,
    ACCELERATION_OFFSET = 45,
    GYROSCOPE_OFFSET = 51,
    BATTERY_OFFSET = 57
};

_Static_assert(FOOTGUARD_PROTOCOL_VERSION == 1,
               "Unexpected protocol version");
_Static_assert(FOOTGUARD_LAYOUT_ID_6P4T_V1 == 2,
               "Unexpected sensor layout ID");
_Static_assert(MAGIC_OFFSET + 2 == PROTOCOL_VERSION_OFFSET,
               "magic field layout mismatch");
_Static_assert(PROTOCOL_VERSION_OFFSET + 1 == LAYOUT_ID_OFFSET,
               "protocol version field layout mismatch");
_Static_assert(LAYOUT_ID_OFFSET + 1 == SIDE_OFFSET,
               "layout ID field layout mismatch");
_Static_assert(SIDE_OFFSET + 1 == QUALITY_FLAGS_OFFSET,
               "side field layout mismatch");
_Static_assert(QUALITY_FLAGS_OFFSET + sizeof(uint32_t) == SYNC_ID_OFFSET,
               "quality flags field layout mismatch");
_Static_assert(SYNC_ID_OFFSET + sizeof(uint32_t) == PACKET_SEQ_OFFSET,
               "sync ID field layout mismatch");
_Static_assert(PACKET_SEQ_OFFSET + sizeof(uint32_t) == TIMESTAMP_MS_OFFSET,
               "packet sequence field layout mismatch");
_Static_assert(TIMESTAMP_MS_OFFSET + sizeof(uint64_t) == PRESSURE_OFFSET,
               "timestamp field layout mismatch");
_Static_assert(PRESSURE_OFFSET +
                       FOOTGUARD_PRESSURE_CHANNEL_COUNT * sizeof(uint16_t) ==
                   TEMPERATURE_OFFSET,
               "pressure field layout mismatch");
_Static_assert(TEMPERATURE_OFFSET +
                       FOOTGUARD_TEMPERATURE_CHANNEL_COUNT * sizeof(int16_t) ==
                   ACCELERATION_OFFSET,
               "temperature field layout mismatch");
_Static_assert(ACCELERATION_OFFSET +
                       FOOTGUARD_IMU_AXIS_COUNT * sizeof(int16_t) ==
                   GYROSCOPE_OFFSET,
               "acceleration field layout mismatch");
_Static_assert(GYROSCOPE_OFFSET +
                       FOOTGUARD_IMU_AXIS_COUNT * sizeof(int16_t) ==
                   BATTERY_OFFSET,
               "gyroscope field layout mismatch");
_Static_assert(BATTERY_OFFSET + sizeof(uint8_t) ==
                   FOOTGUARD_SENSOR_FRAME_CRC_OFFSET,
               "battery field layout mismatch");
_Static_assert(FOOTGUARD_SENSOR_FRAME_CRC_INPUT_SIZE ==
                   FOOTGUARD_SENSOR_FRAME_CRC_OFFSET,
               "CRC input length mismatch");
_Static_assert(FOOTGUARD_SENSOR_FRAME_CRC_OFFSET + sizeof(uint16_t) ==
                   FOOTGUARD_SENSOR_FRAME_SIZE,
               "SensorData frame size mismatch");

static void write_u16_le(uint8_t *output, size_t offset, uint16_t value)
{
    output[offset] = (uint8_t)(value & 0xFFU);
    output[offset + 1U] = (uint8_t)(value >> 8U);
}

static void write_i16_le(uint8_t *output, size_t offset, int16_t value)
{
    write_u16_le(output, offset, (uint16_t)value);
}

static void write_u32_le(uint8_t *output, size_t offset, uint32_t value)
{
    for (size_t byte = 0; byte < sizeof(value); ++byte) {
        output[offset + byte] = (uint8_t)(value >> (byte * 8U));
    }
}

static void write_u64_le(uint8_t *output, size_t offset, uint64_t value)
{
    for (size_t byte = 0; byte < sizeof(value); ++byte) {
        output[offset + byte] = (uint8_t)(value >> (byte * 8U));
    }
}

static bool quantize(double scaled_value,
                     int32_t minimum,
                     int32_t maximum,
                     int32_t *quantized)
{
    double rounded;

    if (!isfinite(scaled_value)) {
        return false;
    }

    rounded = scaled_value >= 0.0
                  ? floor(scaled_value + 0.5)
                  : ceil(scaled_value - 0.5);
    if (rounded < (double)minimum || rounded > (double)maximum) {
        return false;
    }

    *quantized = (int32_t)rounded;
    return true;
}

static bool quantize_sensor_values(
    const footguard_sensor_data_t *sensor_data,
    uint16_t pressure[FOOTGUARD_PRESSURE_CHANNEL_COUNT],
    int16_t temperature[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT],
    int16_t acceleration[FOOTGUARD_IMU_AXIS_COUNT],
    int16_t gyroscope[FOOTGUARD_IMU_AXIS_COUNT])
{
    int32_t value;

    for (size_t channel = 0;
         channel < FOOTGUARD_PRESSURE_CHANNEL_COUNT;
         ++channel) {
        if (!quantize(sensor_data->pressure[channel] * 10000.0,
                      0,
                      10000,
                      &value)) {
            return false;
        }
        pressure[channel] = (uint16_t)value;
    }

    for (size_t channel = 0;
         channel < FOOTGUARD_TEMPERATURE_CHANNEL_COUNT;
         ++channel) {
        if (!quantize(sensor_data->temperature_c[channel] * 100.0,
                      -4000,
                      12500,
                      &value)) {
            return false;
        }
        temperature[channel] = (int16_t)value;
    }

    for (size_t axis = 0; axis < FOOTGUARD_IMU_AXIS_COUNT; ++axis) {
        if (!quantize(sensor_data->acceleration_m_s2[axis] /
                          FOOTGUARD_STANDARD_GRAVITY_M_S2 * 1000.0,
                      INT16_MIN,
                      INT16_MAX,
                      &value)) {
            return false;
        }
        acceleration[axis] = (int16_t)value;

        if (!quantize(sensor_data->gyroscope_deg_s[axis] * 10.0,
                      INT16_MIN,
                      INT16_MAX,
                      &value)) {
            return false;
        }
        gyroscope[axis] = (int16_t)value;
    }

    return true;
}

bool footguard_protocol_encode_sensor_data(
    const footguard_sensor_data_t *sensor_data,
    uint8_t *output,
    size_t output_size)
{
    uint16_t pressure[FOOTGUARD_PRESSURE_CHANNEL_COUNT];
    int16_t temperature[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT];
    int16_t acceleration[FOOTGUARD_IMU_AXIS_COUNT];
    int16_t gyroscope[FOOTGUARD_IMU_AXIS_COUNT];
    uint16_t crc;

    if (sensor_data == NULL || output == NULL ||
        output_size < FOOTGUARD_SENSOR_FRAME_SIZE ||
        (sensor_data->side != FOOTGUARD_SIDE_LEFT &&
         sensor_data->side != FOOTGUARD_SIDE_RIGHT) ||
        sensor_data->battery > 100U ||
        (sensor_data->quality_flags & ~FOOTGUARD_QUALITY_FLAGS_V1_MASK) != 0U ||
        !quantize_sensor_values(sensor_data,
                                pressure,
                                temperature,
                                acceleration,
                                gyroscope)) {
        return false;
    }

    output[MAGIC_OFFSET] = 0x46U;
    output[MAGIC_OFFSET + 1U] = 0x47U;
    output[PROTOCOL_VERSION_OFFSET] = FOOTGUARD_PROTOCOL_VERSION;
    output[LAYOUT_ID_OFFSET] = FOOTGUARD_LAYOUT_ID_6P4T_V1;
    output[SIDE_OFFSET] = (uint8_t)sensor_data->side;
    write_u32_le(output, QUALITY_FLAGS_OFFSET, sensor_data->quality_flags);
    write_u32_le(output, SYNC_ID_OFFSET, sensor_data->sync_id);
    write_u32_le(output, PACKET_SEQ_OFFSET, sensor_data->packet_seq);
    write_u64_le(output, TIMESTAMP_MS_OFFSET, sensor_data->timestamp_ms);

    for (size_t channel = 0;
         channel < FOOTGUARD_PRESSURE_CHANNEL_COUNT;
         ++channel) {
        write_u16_le(output,
                     PRESSURE_OFFSET + channel * sizeof(uint16_t),
                     pressure[channel]);
    }

    for (size_t channel = 0;
         channel < FOOTGUARD_TEMPERATURE_CHANNEL_COUNT;
         ++channel) {
        write_i16_le(output,
                     TEMPERATURE_OFFSET + channel * sizeof(int16_t),
                     temperature[channel]);
    }

    for (size_t axis = 0; axis < FOOTGUARD_IMU_AXIS_COUNT; ++axis) {
        write_i16_le(output,
                     ACCELERATION_OFFSET + axis * sizeof(int16_t),
                     acceleration[axis]);
        write_i16_le(output,
                     GYROSCOPE_OFFSET + axis * sizeof(int16_t),
                     gyroscope[axis]);
    }

    output[BATTERY_OFFSET] = sensor_data->battery;
    crc = footguard_crc16_ccitt_false(
        output,
        FOOTGUARD_SENSOR_FRAME_CRC_INPUT_SIZE);
    write_u16_le(output, FOOTGUARD_SENSOR_FRAME_CRC_OFFSET, crc);

    return true;
}

bool footguard_protocol_sensor_frame_crc_is_valid(
    const uint8_t *frame,
    size_t frame_size)
{
    uint16_t expected_crc;
    uint16_t actual_crc;

    if (frame == NULL || frame_size != FOOTGUARD_SENSOR_FRAME_SIZE) {
        return false;
    }

    expected_crc = footguard_crc16_ccitt_false(
        frame,
        FOOTGUARD_SENSOR_FRAME_CRC_INPUT_SIZE);
    actual_crc = (uint16_t)frame[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET] |
                 ((uint16_t)frame[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET + 1U]
                  << 8U);

    return actual_crc == expected_crc;
}
