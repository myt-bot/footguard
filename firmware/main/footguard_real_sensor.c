#include "footguard_real_sensor.h"

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "esp_log.h"

#include "footguard_config.h"
#include "footguard_fsr.h"
#include "footguard_mock_sensor.h"
#include "footguard_mpu6050.h"
#include "footguard_ntc.h"

#define FOOTGUARD_STANDARD_GRAVITY_M_S2 9.80665f
#define FOOTGUARD_FSR_ADC_FULL_SCALE 4095.0

/*
 * Engineering plausibility window for detecting an open, floating, or
 * otherwise invalid NTC channel. This is not a clinical alarm threshold.
 */
#define FOOTGUARD_NTC_PLAUSIBLE_MIN_C 10.0f
#define FOOTGUARD_NTC_PLAUSIBLE_MAX_C 60.0f

static const char *TAG = "footguard_sensor";
static bool s_fsr_ready;
static bool s_ntc_ready;
static bool s_mpu6050_ready;
static bool s_initialized;
static double s_temperature_cache[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT];
static bool s_temperature_has_sample[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT];
static bool s_temperature_valid[FOOTGUARD_TEMPERATURE_CHANNEL_COUNT];
static uint32_t s_temperature_frames_until_refresh;

static void refresh_temperature_cache(void)
{
    for (size_t channel = 0;
         channel < FOOTGUARD_TEMPERATURE_CHANNEL_COUNT;
         ++channel) {
        footguard_ntc_reading_t ntc;

        s_temperature_valid[channel] = false;
        if (footguard_ntc_read_channel(channel, &ntc) == ESP_OK &&
            ntc.temperature_c >= FOOTGUARD_NTC_PLAUSIBLE_MIN_C &&
            ntc.temperature_c <= FOOTGUARD_NTC_PLAUSIBLE_MAX_C) {
            s_temperature_cache[channel] = ntc.temperature_c;
            s_temperature_has_sample[channel] = true;
            s_temperature_valid[channel] = true;
        }
    }
}

esp_err_t footguard_real_sensor_init(void)
{
    esp_err_t error;

    if (s_initialized) {
        return ESP_OK;
    }

    error = footguard_fsr_init();
    s_fsr_ready = error == ESP_OK;
    if (!s_fsr_ready) {
        ESP_LOGW(TAG, "FSR unavailable; pressure will remain invalid: %s",
                 esp_err_to_name(error));
    }

    error = footguard_ntc_init();
    s_ntc_ready = error == ESP_OK;
    if (!s_ntc_ready) {
        ESP_LOGW(TAG, "NTC unavailable; T1 will be marked invalid: %s",
                 esp_err_to_name(error));
    }

    error = footguard_mpu6050_init();
    s_mpu6050_ready = error == ESP_OK;
    if (!s_mpu6050_ready) {
        ESP_LOGW(TAG, "MPU6050 unavailable; IMU will be marked invalid: %s",
                 esp_err_to_name(error));
    }

    s_initialized = true;
    ESP_LOGI(TAG, "Real sensor source ready: FSR=%s NTC_T1=%s MPU6050=%s",
             s_fsr_ready ? "ready" : "invalid",
             s_ntc_ready ? "ready" : "invalid",
             s_mpu6050_ready ? "ready" : "invalid");
    return ESP_OK;
}

esp_err_t footguard_real_sensor_make_data(
    uint32_t packet_seq,
    const footguard_time_snapshot_t *time_snapshot,
    footguard_sensor_data_t *sensor_data)
{
    footguard_mpu6050_reading_t mpu;

    if (!s_initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    if (time_snapshot == NULL || sensor_data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(sensor_data, 0, sizeof(*sensor_data));
    sensor_data->side = FOOTGUARD_DEVICE_SIDE;
    sensor_data->quality_flags =
        FOOTGUARD_QUALITY_PRESSURE_INVALID_MASK |
        FOOTGUARD_QUALITY_TEMPERATURE_INVALID_MASK |
        FOOTGUARD_QUALITY_IMU_INVALID;
    sensor_data->sync_id = time_snapshot->time_synced
                               ? time_snapshot->sync_id
                               : 0U;
    sensor_data->packet_seq = packet_seq;
    sensor_data->timestamp_ms = time_snapshot->time_synced
                                    ? time_snapshot->timestamp_ms
                                    : 0U;
    sensor_data->battery = footguard_mock_sensor_battery_percent();
    if (!time_snapshot->time_synced) {
        sensor_data->quality_flags |= FOOTGUARD_QUALITY_TIME_UNSYNCED;
    }

    if (s_fsr_ready) {
        for (size_t channel = 0;
             channel < FOOTGUARD_FSR_CHANNEL_COUNT;
             ++channel) {
            int raw_average;

            if (footguard_fsr_read_raw_channel(channel, &raw_average) == ESP_OK &&
                raw_average >= 0 && raw_average <= 4095) {
                sensor_data->pressure[channel] =
                    (double)raw_average / FOOTGUARD_FSR_ADC_FULL_SCALE;
                sensor_data->quality_flags &= ~(1U << channel);
            }
        }
    }

    if (s_ntc_ready) {
        if (s_temperature_frames_until_refresh == 0U) {
            refresh_temperature_cache();
            s_temperature_frames_until_refresh =
                FOOTGUARD_TEMPERATURE_FRAME_DIVISOR - 1U;
        } else {
            --s_temperature_frames_until_refresh;
        }

        for (size_t channel = 0;
             channel < FOOTGUARD_TEMPERATURE_CHANNEL_COUNT;
             ++channel) {
            if (s_temperature_has_sample[channel]) {
                sensor_data->temperature_c[channel] =
                    s_temperature_cache[channel];
            }
            if (s_temperature_valid[channel]) {
                sensor_data->quality_flags &=
                    ~(FOOTGUARD_QUALITY_TEMPERATURE_T1_INVALID << channel);
            }
        }
    }

    if (s_mpu6050_ready && footguard_mpu6050_read(&mpu) == ESP_OK) {
        for (size_t axis = 0; axis < FOOTGUARD_IMU_AXIS_COUNT; ++axis) {
            sensor_data->acceleration_m_s2[axis] =
                (double)(mpu.accel_g[axis] *
                         FOOTGUARD_STANDARD_GRAVITY_M_S2);
            sensor_data->gyroscope_deg_s[axis] =
                (double)mpu.gyro_dps[axis];
        }
        sensor_data->quality_flags &= ~FOOTGUARD_QUALITY_IMU_INVALID;
    }

    return ESP_OK;
}
