#include "footguard_command_service.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "host/ble_hs.h"

#include "footguard_ble.h"
#include "footguard_command_executor.h"
#include "footguard_config.h"
#include "footguard_time.h"

enum {
    ACK_EVENT_MAX_SIZE = 244,
    COMMAND_CACHE_CAPACITY = 32
};

typedef enum {
    COMMAND_CACHE_EMPTY = 0,
    COMMAND_CACHE_PENDING,
    COMMAND_CACHE_COMPLETED
} command_cache_state_t;

typedef struct {
    command_cache_state_t state;
    footguard_command_t command;
    char ack_json[ACK_EVENT_MAX_SIZE + 1U];
    size_t ack_size;
} command_cache_entry_t;

typedef enum {
    CACHE_BEGIN_NEW = 0,
    CACHE_BEGIN_DUPLICATE_PENDING,
    CACHE_BEGIN_DUPLICATE_COMPLETED,
    CACHE_BEGIN_CONFLICT,
    CACHE_BEGIN_FULL
} cache_begin_result_t;

static const char *TAG = "footguard_command";
static portMUX_TYPE s_cache_lock = portMUX_INITIALIZER_UNLOCKED;
static command_cache_entry_t s_command_cache[COMMAND_CACHE_CAPACITY];
static size_t s_next_cache_index;

static bool command_content_equal(const footguard_command_t *left,
                                  const footguard_command_t *right)
{
    return left->target == right->target &&
           left->pattern == right->pattern &&
           left->duration_ms == right->duration_ms &&
           left->expire_at_ms == right->expire_at_ms &&
           strcmp(left->reason_code, right->reason_code) == 0;
}

static int find_cache_entry_locked(const char *command_id)
{
    for (size_t index = 0U; index < COMMAND_CACHE_CAPACITY; ++index) {
        if (s_command_cache[index].state != COMMAND_CACHE_EMPTY &&
            strcmp(s_command_cache[index].command.command_id,
                   command_id) == 0) {
            return (int)index;
        }
    }
    return -1;
}

static cache_begin_result_t cache_begin(const footguard_command_t *command,
                                        char *cached_ack,
                                        size_t cached_ack_capacity,
                                        size_t *cached_ack_size)
{
    cache_begin_result_t result = CACHE_BEGIN_FULL;
    int existing_index;

    *cached_ack_size = 0U;
    portENTER_CRITICAL(&s_cache_lock);
    existing_index = find_cache_entry_locked(command->command_id);
    if (existing_index >= 0) {
        command_cache_entry_t *entry = &s_command_cache[existing_index];

        if (!command_content_equal(&entry->command, command)) {
            result = CACHE_BEGIN_CONFLICT;
        } else if (entry->state == COMMAND_CACHE_PENDING) {
            result = CACHE_BEGIN_DUPLICATE_PENDING;
        } else if (entry->ack_size > 0U &&
                   entry->ack_size < cached_ack_capacity) {
            memcpy(cached_ack, entry->ack_json, entry->ack_size + 1U);
            *cached_ack_size = entry->ack_size;
            result = CACHE_BEGIN_DUPLICATE_COMPLETED;
        }
        portEXIT_CRITICAL(&s_cache_lock);
        return result;
    }

    for (size_t offset = 0U; offset < COMMAND_CACHE_CAPACITY; ++offset) {
        size_t index = (s_next_cache_index + offset) %
                       COMMAND_CACHE_CAPACITY;
        command_cache_entry_t *entry = &s_command_cache[index];

        if (entry->state == COMMAND_CACHE_PENDING) {
            continue;
        }
        memset(entry, 0, sizeof(*entry));
        entry->state = COMMAND_CACHE_PENDING;
        entry->command = *command;
        s_next_cache_index = (index + 1U) % COMMAND_CACHE_CAPACITY;
        result = CACHE_BEGIN_NEW;
        break;
    }
    portEXIT_CRITICAL(&s_cache_lock);
    return result;
}

static void cache_abort(const footguard_command_t *command)
{
    int index;

    portENTER_CRITICAL(&s_cache_lock);
    index = find_cache_entry_locked(command->command_id);
    if (index >= 0 &&
        s_command_cache[index].state == COMMAND_CACHE_PENDING &&
        command_content_equal(&s_command_cache[index].command, command)) {
        memset(&s_command_cache[index], 0, sizeof(s_command_cache[index]));
    }
    portEXIT_CRITICAL(&s_cache_lock);
}

static void cache_complete(const footguard_command_t *command,
                           const char *ack_json,
                           size_t ack_size)
{
    int index;

    portENTER_CRITICAL(&s_cache_lock);
    index = find_cache_entry_locked(command->command_id);
    if (index >= 0 &&
        s_command_cache[index].state == COMMAND_CACHE_PENDING &&
        command_content_equal(&s_command_cache[index].command, command) &&
        ack_size <= ACK_EVENT_MAX_SIZE) {
        memcpy(s_command_cache[index].ack_json, ack_json, ack_size);
        s_command_cache[index].ack_json[ack_size] = '\0';
        s_command_cache[index].ack_size = ack_size;
        s_command_cache[index].state = COMMAND_CACHE_COMPLETED;
    }
    portEXIT_CRITICAL(&s_cache_lock);
}

static int notify_rejection(const footguard_command_t *command,
                            const char *error_code)
{
    footguard_time_snapshot_t time_snapshot;
    char json[ACK_EVENT_MAX_SIZE + 1U];
    int length;

    footguard_time_get_snapshot(&time_snapshot);
    length = snprintf(
        json,
        sizeof(json),
        "{\"protocol_version\":1,\"command_id\":\"%s\","
        "\"device_id\":\"%s\",\"status\":\"rejected\","
        "\"ack_at_ms\":%" PRIu64 ",\"error_code\":\"%s\"}",
        command->command_id,
        FOOTGUARD_DEVICE_ID,
        time_snapshot.timestamp_ms,
        error_code);
    if (length < 0 || (size_t)length >= sizeof(json)) {
        return BLE_HS_EINVAL;
    }
    return footguard_ble_notify_ack_event(json, (size_t)length);
}

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

    cache_complete(command, json, (size_t)length);
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
    portENTER_CRITICAL(&s_cache_lock);
    memset(s_command_cache, 0, sizeof(s_command_cache));
    s_next_cache_index = 0U;
    portEXIT_CRITICAL(&s_cache_lock);

    return footguard_command_executor_init(command_completed);
}

footguard_command_submit_result_t footguard_command_service_submit(
    const footguard_command_t *command)
{
    footguard_time_snapshot_t time_snapshot;
    char cached_ack[ACK_EVENT_MAX_SIZE + 1U];
    size_t cached_ack_size;
    cache_begin_result_t cache_result;
    esp_err_t error;

    if (command == NULL) {
        return FOOTGUARD_COMMAND_SUBMIT_INTERNAL_ERROR;
    }

    cache_result = cache_begin(command,
                               cached_ack,
                               sizeof(cached_ack),
                               &cached_ack_size);
    if (cache_result == CACHE_BEGIN_DUPLICATE_PENDING) {
        ESP_LOGI(TAG, "Duplicate command still pending: id=%s",
                 command->command_id);
        return FOOTGUARD_COMMAND_SUBMIT_DUPLICATE_PENDING;
    }
    if (cache_result == CACHE_BEGIN_DUPLICATE_COMPLETED) {
        int notify_result = footguard_ble_notify_ack_event(cached_ack,
                                                            cached_ack_size);

        if (notify_result != 0) {
            ESP_LOGW(TAG, "Cached AckEvent replay failed: id=%s rc=%d",
                     command->command_id, notify_result);
        } else {
            ESP_LOGI(TAG, "Cached AckEvent replayed: id=%s",
                     command->command_id);
        }
        return FOOTGUARD_COMMAND_SUBMIT_DUPLICATE_REPLAYED;
    }
    if (cache_result == CACHE_BEGIN_CONFLICT) {
        int notify_result = notify_rejection(command, "command_conflict");

        if (notify_result != 0) {
            ESP_LOGW(TAG, "Command conflict ACK failed: id=%s rc=%d",
                     command->command_id, notify_result);
        } else {
            ESP_LOGW(TAG, "Command conflict rejected: id=%s",
                     command->command_id);
        }
        return FOOTGUARD_COMMAND_SUBMIT_COMMAND_CONFLICT;
    }
    if (cache_result != CACHE_BEGIN_NEW) {
        return FOOTGUARD_COMMAND_SUBMIT_INTERNAL_ERROR;
    }

    if (!target_matches_device(command->target)) {
        cache_abort(command);
        return FOOTGUARD_COMMAND_SUBMIT_TARGET_MISMATCH;
    }

    footguard_time_get_snapshot(&time_snapshot);
    if (!time_snapshot.time_synced) {
        cache_abort(command);
        return FOOTGUARD_COMMAND_SUBMIT_TIME_UNSYNCED;
    }
    if (time_snapshot.timestamp_ms >= command->expire_at_ms) {
        cache_abort(command);
        return FOOTGUARD_COMMAND_SUBMIT_EXPIRED;
    }

    error = footguard_command_executor_submit(command);
    if (error == ESP_OK) {
        return FOOTGUARD_COMMAND_SUBMIT_ACCEPTED;
    }
    cache_abort(command);
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
        "duplicate_pending",
        "duplicate_replayed",
        "command_conflict",
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