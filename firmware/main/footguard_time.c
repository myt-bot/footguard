#include "footguard_time.h"

#include "esp_timer.h"
#include "freertos/FreeRTOS.h"

static portMUX_TYPE s_time_lock = portMUX_INITIALIZER_UNLOCKED;
static bool s_time_synced;
static uint32_t s_sync_id;
static uint64_t s_unix_time_ms;
static int64_t s_monotonic_time_us;

static uint32_t read_u32_le(const uint8_t *input)
{
    uint32_t value = 0;

    for (size_t byte = 0; byte < sizeof(value); ++byte) {
        value |= (uint32_t)input[byte] << (byte * 8U);
    }

    return value;
}

static uint64_t read_u64_le(const uint8_t *input)
{
    uint64_t value = 0;

    for (size_t byte = 0; byte < sizeof(value); ++byte) {
        value |= (uint64_t)input[byte] << (byte * 8U);
    }

    return value;
}

void footguard_time_reset(void)
{
    portENTER_CRITICAL(&s_time_lock);
    s_time_synced = false;
    s_sync_id = 0;
    s_unix_time_ms = 0;
    s_monotonic_time_us = 0;
    portEXIT_CRITICAL(&s_time_lock);
}

footguard_time_sync_result_t footguard_time_apply_sync_payload(
    const uint8_t *payload,
    size_t payload_size)
{
    uint32_t sync_id;
    uint64_t unix_time_ms;
    int64_t monotonic_time_us;

    if (payload == NULL || payload_size != FOOTGUARD_TIME_SYNC_PAYLOAD_SIZE) {
        return FOOTGUARD_TIME_SYNC_INVALID_LENGTH;
    }

    sync_id = read_u32_le(payload);
    if (sync_id == 0U) {
        return FOOTGUARD_TIME_SYNC_INVALID_SYNC_ID;
    }

    unix_time_ms = read_u64_le(payload + sizeof(sync_id));
    monotonic_time_us = esp_timer_get_time();

    portENTER_CRITICAL(&s_time_lock);
    s_sync_id = sync_id;
    s_unix_time_ms = unix_time_ms;
    s_monotonic_time_us = monotonic_time_us;
    s_time_synced = true;
    portEXIT_CRITICAL(&s_time_lock);

    return FOOTGUARD_TIME_SYNC_OK;
}

void footguard_time_get_snapshot(footguard_time_snapshot_t *snapshot)
{
    bool time_synced;
    uint32_t sync_id;
    uint64_t unix_time_ms;
    int64_t monotonic_time_us;
    int64_t current_time_us;
    int64_t elapsed_time_us;

    if (snapshot == NULL) {
        return;
    }

    portENTER_CRITICAL(&s_time_lock);
    time_synced = s_time_synced;
    sync_id = s_sync_id;
    unix_time_ms = s_unix_time_ms;
    monotonic_time_us = s_monotonic_time_us;
    portEXIT_CRITICAL(&s_time_lock);

    if (!time_synced) {
        snapshot->time_synced = false;
        snapshot->sync_id = 0U;
        snapshot->timestamp_ms = 0U;
        return;
    }

    current_time_us = esp_timer_get_time();
    elapsed_time_us = current_time_us >= monotonic_time_us
                          ? current_time_us - monotonic_time_us
                          : 0;

    snapshot->time_synced = time_synced;
    snapshot->sync_id = sync_id;
    snapshot->timestamp_ms = unix_time_ms +
                             (uint64_t)elapsed_time_us / 1000U;
}
