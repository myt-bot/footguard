#ifndef FOOTGUARD_MPU6050_H
#define FOOTGUARD_MPU6050_H

#include "esp_err.h"

typedef struct {
    float accel_g[3];
    float gyro_dps[3];
    float temperature_c;
} footguard_mpu6050_reading_t;

esp_err_t footguard_mpu6050_init(void);

esp_err_t footguard_mpu6050_read(footguard_mpu6050_reading_t *reading);

#endif
