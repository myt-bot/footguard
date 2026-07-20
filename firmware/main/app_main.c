#include "esp_log.h"

#include "footguard_ble.h"
#include "footguard_config.h"
#include "footguard_protocol_selftest.h"

static const char *TAG = "footguard";

static const char *selftest_status(bool passed)
{
    return passed ? "PASS" : "FAIL";
}

void app_main(void)
{
    footguard_protocol_selftest_results_t results;
    esp_err_t error;

    footguard_protocol_run_selftests(&results);

    ESP_LOGI(TAG, "Firmware name: %s", FOOTGUARD_FIRMWARE_NAME);
    ESP_LOGI(TAG, "Firmware version: %s", FOOTGUARD_FIRMWARE_VERSION);
    ESP_LOGI(TAG, "Device side: %s", FOOTGUARD_DEVICE_SIDE_NAME);
    ESP_LOGI(TAG, "Device ID: %s", FOOTGUARD_DEVICE_ID);
    ESP_LOGI(TAG, "CRC self-test: %s", selftest_status(results.crc_passed));
    ESP_LOGI(TAG, "Left standard frame self-test: %s",
             selftest_status(results.left_frame_passed));
    ESP_LOGI(TAG, "Right standard frame self-test: %s",
             selftest_status(results.right_frame_passed));

    if (!results.crc_passed || !results.left_frame_passed ||
        !results.right_frame_passed) {
        ESP_LOGE(TAG, "Protocol self-test failed; BLE will not start");
        return;
    }

    error = footguard_ble_start();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "BLE startup failed: %s", esp_err_to_name(error));
    }
}
