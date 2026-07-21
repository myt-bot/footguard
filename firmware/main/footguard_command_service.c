#include "footguard_command_service.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>

#include "esp_log.h"

#include "footguard_ble.h"
#include "footguard_command_executor.h"
#include "footguard_config.h"
#include "footguard_time.h"

enum {
    ACK_EVENT_MAX_SIZE = 244
};

static const char *TAG = "footguard_command";

static bool target_matches_device(footguard_command_target_t target)
{
    if (target == FOOTGUARD_COMMAND_TARGET_BOTH) {
        return true;
    }

#if FOOTGUARD_DEVICE_VARIANT == FOOTGUARD_VARIANT_LEFT
    return target == FOOTGUARD_COMMAND_TARGET_LEFT;
#else
    return target == FOOTGUARD_COMMAND_TARGET_RIGHT;
#endif
}

static void command_completed(const footguard_command_t *command,
                              esp_err_t execution_result)
{
    footguard_time_snapshot_t time_snapshot;
    char json[ACK_EVENT_MAX_SIZE + 1U];
    int length;
    int notify_result;

    footguard_time_get_snapshot(&time_snapshot);

    if (execution_result == ESP_OK) {
        length = snprintf(
            json,
            sizeof(json),
            "{\"protocol_version\":1,\"command_id\":\"%s\","
            "\"device_id\":\"%s\",\"status\":\"executed\","
            "\"ack_at_ms\":%" PRIu64 ",\"executed_at_ms\":%" PRIu64 ","
            "\"error_code\":\"none\"}",
            command->command_id,
            FOOTGUARD_DEVICE_ID,
            time_snapshot.timestamp_ms,
            time_snapshot.timestamp_ms);
    } else {
        length = snprintf(
            json,
            sizeof(json),
            "{\"protocol_version\":1,\"command_id\":\"%s\","
            "\"device_id\":\"%s\",\"status\":\"failed\","
            "\"ack_at_ms\":%" PRIu64 ",\"error_code\":\"motor_fault\"}",
            command->command_id,
            FOOTGUARD_DEVICE_ID,
            time_snapshot.timestamp_ms);
    }

    if (length < 0 || (size_t)length >= sizeof(json) ||
        length > ACK_EVENT_MAX_SIZE) {
        ESP_LOGE(TAG, "AckEvent JSON encoding failed: id=%s",
                 command->command_id);
        return;
    }

    notify_result = footguard_ble_notify_ack_event(json, (size_t)length);
    if (notify_result != 0) {
        ESP_LOGW(TAG, "AckEvent notify failed: id=%s rc=%d",
                 command->command_id,
                 notify_result);
        return;
    }

    ESP_LOGI(TAG, "AckEvent notified: id=%s status=%s",
             command->command_id,
             execution_result == ESP_OK ? "executed" : "failed");
}

esp_err_t footguard_command_service_init(void)
{
    return footguard_command_executor_init(command_completed);
}

footguard_command_submit_result_t footguard_command_service_submit(
    const footguard_command_t *command)
{
    footguard_time_snapshot_t time_snapshot;
    esp_err_t error;

    if (command == NULL) {
        return FOOTGUARD_COMMAND_SUBMIT_INTERNAL_ERROR;
    }
    if (!target_matches_device(command->target)) {
        return FOOTGUARD_COMMAND_SUBMIT_TARGET_MISMATCH;
    }

    footguard_time_get_snapshot(&time_snapshot);
    if (!time_snapshot.time_synced) {
        return FOOTGUARD_COMMAND_SUBMIT_TIME_UNSYNCED;
    }
    if (time_snapshot.timestamp_ms >= command->expire_at_ms) {
        return FOOTGUARD_COMMAND_SUBMIT_EXPIRED;
    }

    error = footguard_command_executor_submit(command);
    if (error == ESP_OK) {
        return FOOTGUARD_COMMAND_SUBMIT_ACCEPTED;
    }
    if (error == ESP_ERR_TIMEOUT) {
        return FOOTGUARD_COMMAND_SUBMIT_QUEUE_FULL;
    }
    return FOOTGUARD_COMMAND_SUBMIT_INTERNAL_ERROR;
}

const char *footguard_command_submit_result_name(
    footguard_command_submit_result_t result)
{
    static const char *const names[] = {
        "accepted",
        "target_mismatch",
        "time_unsynced",
        "expired",
        "queue_full",
        "internal_error"
    };

    if ((unsigned int)result >= sizeof(names) / sizeof(names[0])) {
        return "unknown";
    }
    return names[result];
}