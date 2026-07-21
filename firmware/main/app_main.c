#include "esp_log.h"

#include "footguard_ble.h"
#include "footguard_config.h"
#include "footguard_mpu6050.h"
#include "footguard_motor.h"
#include "footguard_ntc.h"
#include "footguard_protocol_selftest.h"
#include "footguard_command.h"
#include "footguard_command_executor.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "footguard";

static bool device_command_parser_selftest(void)
{
    static const char valid_command[] =
        "{\"protocol_version\":1,\"command_id\":\"cmd_selftest\","
        "\"target\":\"left\",\"pattern\":\"double\",\"duration_ms\":800,"
        "\"expire_at_ms\":1784609999999,\"reason_code\":\"manual_test\"}";
    static const char bad_protocol[] =
        "{\"protocol_version\":2,\"command_id\":\"cmd_selftest\","
        "\"target\":\"left\",\"pattern\":\"double\",\"duration_ms\":800,"
        "\"expire_at_ms\":1784609999999,\"reason_code\":\"manual_test\"}";
    static const char bad_duration[] =
        "{\"protocol_version\":1,\"command_id\":\"cmd_selftest\","
        "\"target\":\"left\",\"pattern\":\"short\",\"duration_ms\":99,"
        "\"expire_at_ms\":1784609999999,\"reason_code\":\"manual_test\"}";
    footguard_command_t command;

    return footguard_command_parse(
               (const uint8_t *)valid_command,
               sizeof(valid_command) - 1U,
               &command) == FOOTGUARD_COMMAND_PARSE_OK &&
           footguard_command_parse(
               (const uint8_t *)bad_protocol,
               sizeof(bad_protocol) - 1U,
               &command) == FOOTGUARD_COMMAND_PARSE_UNSUPPORTED_PROTOCOL &&
           footguard_command_parse(
               (const uint8_t *)bad_duration,
               sizeof(bad_duration) - 1U,
               &command) == FOOTGUARD_COMMAND_PARSE_INVALID_DURATION;
}

static void ntc_validation_task(void *arg)
{
    esp_err_t error;

    (void)arg;

    error = footguard_ntc_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "NTC validation initialization failed: %s",
                 esp_err_to_name(error));
        vTaskDelete(NULL);
        return;
    }

    for (;;) {
        footguard_ntc_reading_t reading;

        error = footguard_ntc_read(&reading);
        if (error == ESP_OK) {
            ESP_LOGI(TAG, "NTC_T1 raw=%04d voltage=%dmV temp=%.2fC",
                     reading.raw_average,
                     reading.voltage_mv,
                     (double)reading.temperature_c);
        } else {
            ESP_LOGE(TAG, "NTC_T1 read failed: %s",
                     esp_err_to_name(error));
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void start_ntc_validation_task(void)
{
    if (xTaskCreate(ntc_validation_task,
                    "footguard_ntc",
                    3072,
                    NULL,
                    tskIDLE_PRIORITY + 1,
                    NULL) != pdPASS) {
        ESP_LOGE(TAG, "NTC validation task creation failed");
    }
}

static void mpu6050_validation_task(void *arg)
{
    esp_err_t error;

    (void)arg;

    error = footguard_mpu6050_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "MPU6050 validation initialization failed: %s",
                 esp_err_to_name(error));
        vTaskDelete(NULL);
        return;
    }

    for (;;) {
        footguard_mpu6050_reading_t reading;

        error = footguard_mpu6050_read(&reading);
        if (error == ESP_OK) {
            ESP_LOGI(TAG,
                     "MPU6050 accel_g=(%.3f,%.3f,%.3f) gyro_dps=(%.2f,%.2f,%.2f) temp=%.2fC",
                     (double)reading.accel_g[0],
                     (double)reading.accel_g[1],
                     (double)reading.accel_g[2],
                     (double)reading.gyro_dps[0],
                     (double)reading.gyro_dps[1],
                     (double)reading.gyro_dps[2],
                     (double)reading.temperature_c);
        } else {
            ESP_LOGE(TAG, "MPU6050 read failed: %s",
                     esp_err_to_name(error));
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void start_mpu6050_validation_task(void)
{
    if (xTaskCreate(mpu6050_validation_task,
                    "footguard_mpu6050",
                    4096,
                    NULL,
                    tskIDLE_PRIORITY + 1,
                    NULL) != pdPASS) {
        ESP_LOGE(TAG, "MPU6050 validation task creation failed");
    }
}





static const char *selftest_status(bool passed)
{
    return passed ? "PASS" : "FAIL";
}

void app_main(void)
{
    footguard_protocol_selftest_results_t results;
    esp_err_t error;
    bool command_parser_passed;

    footguard_protocol_run_selftests(&results);
    command_parser_passed = device_command_parser_selftest();

    ESP_LOGI(TAG, "Firmware name: %s", FOOTGUARD_FIRMWARE_NAME);
    ESP_LOGI(TAG, "Firmware version: %s", FOOTGUARD_FIRMWARE_VERSION);
    ESP_LOGI(TAG, "Device side: %s", FOOTGUARD_DEVICE_SIDE_NAME);
    ESP_LOGI(TAG, "Device ID: %s", FOOTGUARD_DEVICE_ID);
    ESP_LOGI(TAG, "CRC self-test: %s", selftest_status(results.crc_passed));
    ESP_LOGI(TAG, "Left standard frame self-test: %s",
             selftest_status(results.left_frame_passed));
    ESP_LOGI(TAG, "Right standard frame self-test: %s",
             selftest_status(results.right_frame_passed));
    ESP_LOGI(TAG, "DeviceCommand parser self-test: %s",
             selftest_status(command_parser_passed));

    if (!results.crc_passed || !results.left_frame_passed ||
        !results.right_frame_passed || !command_parser_passed) {
        ESP_LOGE(TAG, "Protocol self-test failed; BLE will not start");
        return;
    }
    error = footguard_motor_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Motor initialization failed: %s",
                 esp_err_to_name(error));
        return;
    }

    error = footguard_command_executor_init(NULL);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Command executor initialization failed: %s",
                 esp_err_to_name(error));
        return;
    }

    error = footguard_ble_start();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "BLE startup failed: %s", esp_err_to_name(error));
    }

    start_ntc_validation_task();
    start_mpu6050_validation_task();
}