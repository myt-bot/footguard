#include "footguard_mpu6050.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

enum {
    FOOTGUARD_MPU6050_SDA_GPIO = GPIO_NUM_11,
    FOOTGUARD_MPU6050_SCL_GPIO = GPIO_NUM_12,
    FOOTGUARD_MPU6050_ADDRESS = 0x68,
    FOOTGUARD_MPU6050_I2C_HZ = 100000,
    FOOTGUARD_MPU6050_TIMEOUT_MS = 100,
    MPU6050_REG_SMPLRT_DIV = 0x19,
    MPU6050_REG_CONFIG = 0x1A,
    MPU6050_REG_GYRO_CONFIG = 0x1B,
    MPU6050_REG_ACCEL_CONFIG = 0x1C,
    MPU6050_REG_ACCEL_XOUT_H = 0x3B,
    MPU6050_REG_PWR_MGMT_1 = 0x6B,
    MPU6050_REG_WHO_AM_I = 0x75,
    MPU6050_WHO_AM_I_VALUE = 0x68
};

static const char *TAG = "footguard_mpu6050";
static i2c_master_bus_handle_t s_bus_handle;
static i2c_master_dev_handle_t s_device_handle;
static bool s_initialized;

static esp_err_t mpu6050_write_register(uint8_t reg, uint8_t value)
{
    const uint8_t data[2] = {reg, value};

    return i2c_master_transmit(s_device_handle,
                               data,
                               sizeof(data),
                               FOOTGUARD_MPU6050_TIMEOUT_MS);
}

static esp_err_t mpu6050_read_registers(uint8_t start_reg,
                                        uint8_t *data,
                                        size_t data_size)
{
    return i2c_master_transmit_receive(s_device_handle,
                                       &start_reg,
                                       sizeof(start_reg),
                                       data,
                                       data_size,
                                       FOOTGUARD_MPU6050_TIMEOUT_MS);
}

static int16_t read_be_i16(const uint8_t *data)
{
    return (int16_t)(((uint16_t)data[0] << 8U) | (uint16_t)data[1]);
}

esp_err_t footguard_mpu6050_init(void)
{
    i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = FOOTGUARD_MPU6050_SDA_GPIO,
        .scl_io_num = FOOTGUARD_MPU6050_SCL_GPIO,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true
    };
    i2c_device_config_t device_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = FOOTGUARD_MPU6050_ADDRESS,
        .scl_speed_hz = FOOTGUARD_MPU6050_I2C_HZ
    };
    uint8_t who_am_i = 0;
    esp_err_t error;

    if (s_initialized) {
        return ESP_OK;
    }

    error = i2c_new_master_bus(&bus_config, &s_bus_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus initialization failed: %s",
                 esp_err_to_name(error));
        return error;
    }

    error = i2c_master_probe(s_bus_handle,
                             FOOTGUARD_MPU6050_ADDRESS,
                             FOOTGUARD_MPU6050_TIMEOUT_MS);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "MPU6050 not found at I2C address 0x68: %s",
                 esp_err_to_name(error));
        (void)i2c_del_master_bus(s_bus_handle);
        s_bus_handle = NULL;
        return error;
    }

    error = i2c_master_bus_add_device(s_bus_handle,
                                      &device_config,
                                      &s_device_handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "MPU6050 device registration failed: %s",
                 esp_err_to_name(error));
        (void)i2c_del_master_bus(s_bus_handle);
        s_bus_handle = NULL;
        return error;
    }

    error = mpu6050_read_registers(MPU6050_REG_WHO_AM_I,
                                   &who_am_i,
                                   sizeof(who_am_i));
    if (error != ESP_OK || who_am_i != MPU6050_WHO_AM_I_VALUE) {
        ESP_LOGE(TAG, "Unexpected WHO_AM_I: read_error=%s value=0x%02X",
                 esp_err_to_name(error),
                 who_am_i);
        (void)i2c_master_bus_rm_device(s_device_handle);
        (void)i2c_del_master_bus(s_bus_handle);
        s_device_handle = NULL;
        s_bus_handle = NULL;
        return error == ESP_OK ? ESP_ERR_INVALID_RESPONSE : error;
    }

    error = mpu6050_write_register(MPU6050_REG_PWR_MGMT_1, 0x00);
    if (error == ESP_OK) {
        vTaskDelay(pdMS_TO_TICKS(100));
        error = mpu6050_write_register(MPU6050_REG_SMPLRT_DIV, 0x09);
    }
    if (error == ESP_OK) {
        error = mpu6050_write_register(MPU6050_REG_CONFIG, 0x03);
    }
    if (error == ESP_OK) {
        error = mpu6050_write_register(MPU6050_REG_GYRO_CONFIG, 0x00);
    }
    if (error == ESP_OK) {
        error = mpu6050_write_register(MPU6050_REG_ACCEL_CONFIG, 0x00);
    }
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "MPU6050 configuration failed: %s",
                 esp_err_to_name(error));
        (void)i2c_master_bus_rm_device(s_device_handle);
        (void)i2c_del_master_bus(s_bus_handle);
        s_device_handle = NULL;
        s_bus_handle = NULL;
        return error;
    }

    s_initialized = true;
    ESP_LOGI(TAG,
             "MPU6050 ready: address=0x68 SDA=GPIO11 SCL=GPIO12 WHO_AM_I=0x%02X",
             who_am_i);
    return ESP_OK;
}

esp_err_t footguard_mpu6050_read(footguard_mpu6050_reading_t *reading)
{
    uint8_t data[14];
    int16_t accel_raw[3];
    int16_t temperature_raw;
    int16_t gyro_raw[3];
    esp_err_t error;

    if (reading == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_initialized || s_device_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    error = mpu6050_read_registers(MPU6050_REG_ACCEL_XOUT_H,
                                   data,
                                   sizeof(data));
    if (error != ESP_OK) {
        return error;
    }

    accel_raw[0] = read_be_i16(&data[0]);
    accel_raw[1] = read_be_i16(&data[2]);
    accel_raw[2] = read_be_i16(&data[4]);
    temperature_raw = read_be_i16(&data[6]);
    gyro_raw[0] = read_be_i16(&data[8]);
    gyro_raw[1] = read_be_i16(&data[10]);
    gyro_raw[2] = read_be_i16(&data[12]);

    for (int axis = 0; axis < 3; ++axis) {
        reading->accel_g[axis] = (float)accel_raw[axis] / 16384.0f;
        reading->gyro_dps[axis] = (float)gyro_raw[axis] / 131.0f;
    }
    reading->temperature_c =
        ((float)temperature_raw / 340.0f) + 36.53f;
    return ESP_OK;
}
