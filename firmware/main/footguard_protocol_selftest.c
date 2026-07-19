#include "footguard_protocol_selftest.h"

#include <stdint.h>
#include <string.h>

#include "footguard_crc16.h"
#include "footguard_protocol.h"

static const uint8_t LEFT_FRAME_V1[FOOTGUARD_SENSOR_FRAME_SIZE] = {
    0x46, 0x47, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x2C,
    0xC8, 0x99, 0x01, 0x00, 0x00, 0x08, 0x07, 0x1C, 0x0C, 0x68,
    0x10, 0x98, 0x08, 0xC4, 0x09, 0xB0, 0x04, 0x08, 0x0C, 0xF4,
    0x0B, 0xE0, 0x0B, 0x02, 0x00, 0xFD, 0xFF, 0xE5, 0x03, 0x01,
    0x00, 0x02, 0x00, 0xFF, 0xFF, 0x5F, 0xA1, 0x67
};

static const uint8_t RIGHT_FRAME_V1[FOOTGUARD_SENSOR_FRAME_SIZE] = {
    0x46, 0x47, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0xC0, 0x2C,
    0xC8, 0x99, 0x01, 0x00, 0x00, 0xA4, 0x06, 0xB8, 0x0B, 0xA0,
    0x0F, 0xD0, 0x07, 0x60, 0x09, 0x14, 0x05, 0xFE, 0x0B, 0xEA,
    0x0B, 0xD6, 0x0B, 0xFF, 0xFF, 0x02, 0x00, 0xE6, 0x03, 0xFF,
    0xFF, 0x01, 0x00, 0x00, 0x00, 0x5D, 0xBE, 0x51
};

static bool frame_selftest(const footguard_sensor_data_t *sensor_data,
                           const uint8_t *expected_frame)
{
    uint8_t encoded[FOOTGUARD_SENSOR_FRAME_SIZE];
    uint8_t corrupted[FOOTGUARD_SENSOR_FRAME_SIZE];

    if (!footguard_protocol_encode_sensor_data(sensor_data,
                                               encoded,
                                               sizeof(encoded)) ||
        memcmp(encoded, expected_frame, sizeof(encoded)) != 0 ||
        !footguard_protocol_sensor_frame_crc_is_valid(encoded,
                                                      sizeof(encoded))) {
        return false;
    }

    memcpy(corrupted, encoded, sizeof(corrupted));
    corrupted[25] ^= 0x01U;
    if (footguard_protocol_sensor_frame_crc_is_valid(corrupted,
                                                     sizeof(corrupted))) {
        return false;
    }

    memcpy(corrupted, encoded, sizeof(corrupted));
    corrupted[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET] =
        encoded[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET + 1U];
    corrupted[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET + 1U] =
        encoded[FOOTGUARD_SENSOR_FRAME_CRC_OFFSET];

    return !footguard_protocol_sensor_frame_crc_is_valid(corrupted,
                                                         sizeof(corrupted));
}

bool footguard_protocol_selftest_crc(void)
{
    static const uint8_t CHECK_INPUT[] = "123456789";

    return footguard_crc16_ccitt_false(CHECK_INPUT,
                                       sizeof(CHECK_INPUT) - 1U) == 0x29B1U;
}

bool footguard_protocol_selftest_left_frame(void)
{
    static const footguard_sensor_data_t SENSOR_DATA = {
        .side = FOOTGUARD_SIDE_LEFT,
        .quality_flags = 0,
        .sync_id = 1,
        .packet_seq = 1,
        .timestamp_ms = UINT64_C(1760000000000),
        .pressure = {0.18, 0.31, 0.42, 0.22, 0.25, 0.12},
        .temperature_c = {30.8, 30.6, 30.4},
        .acceleration_m_s2 = {0.02, -0.03, 9.78},
        .gyroscope_deg_s = {0.1, 0.2, -0.1},
        .battery = 95
    };

    return frame_selftest(&SENSOR_DATA, LEFT_FRAME_V1);
}

bool footguard_protocol_selftest_right_frame(void)
{
    static const footguard_sensor_data_t SENSOR_DATA = {
        .side = FOOTGUARD_SIDE_RIGHT,
        .quality_flags = 0,
        .sync_id = 1,
        .packet_seq = 1,
        .timestamp_ms = UINT64_C(1760000000020),
        .pressure = {0.17, 0.30, 0.40, 0.20, 0.24, 0.13},
        .temperature_c = {30.7, 30.5, 30.3},
        .acceleration_m_s2 = {-0.01, 0.02, 9.79},
        .gyroscope_deg_s = {-0.1, 0.1, 0.0},
        .battery = 93
    };

    return frame_selftest(&SENSOR_DATA, RIGHT_FRAME_V1);
}

void footguard_protocol_run_selftests(
    footguard_protocol_selftest_results_t *results)
{
    if (results == NULL) {
        return;
    }

    results->crc_passed = footguard_protocol_selftest_crc();
    results->left_frame_passed = footguard_protocol_selftest_left_frame();
    results->right_frame_passed = footguard_protocol_selftest_right_frame();
}
