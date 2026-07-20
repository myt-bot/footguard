#ifndef FOOTGUARD_TIME_H
#define FOOTGUARD_TIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    FOOTGUARD_TIME_SYNC_PAYLOAD_SIZE = 12
};

typedef enum {
    FOOTGUARD_TIME_SYNC_OK = 0,
    FOOTGUARD_TIME_SYNC_INVALID_LENGTH,
    FOOTGUARD_TIME_SYNC_INVALID_SYNC_ID
} footguard_time_sync_result_t;

typedef struct {
    bool time_synced;
    uint32_t sync_id;
    uint64_t timestamp_ms;
} footguard_time_snapshot_t;

void footguard_time_reset(void);

footguard_time_sync_result_t footguard_time_apply_sync_payload(
    const uint8_t *payload,
    size_t payload_size);

void footguard_time_get_snapshot(footguard_time_snapshot_t *snapshot);

#endif
