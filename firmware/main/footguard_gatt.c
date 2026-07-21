#include "footguard_gatt.h"

#include <inttypes.h>
#include <stdio.h>

#include "esp_log.h"
#include "host/ble_hs.h"
#include "os/os_mbuf.h"

#include "footguard_config.h"
#include "footguard_mock_sensor.h"
#include "footguard_protocol.h"
#include "footguard_time.h"
#include "footguard_command.h"

enum {
    DEVICE_STATUS_MAX_SIZE = 244
};

static const char *TAG = "footguard_gatt";
static footguard_gatt_streaming_callback_t s_streaming_callback;
static footguard_gatt_status_changed_callback_t s_status_changed_callback;

static uint16_t s_sensor_data_handle;
static uint16_t s_device_status_handle;
static uint16_t s_device_command_handle;
static uint16_t s_time_sync_handle;
static uint16_t s_ack_event_handle;

#define FOOTGUARD_UUID128(value)                                           \
    BLE_UUID128_INIT(0x60, 0x50, 0x40, 0x30, 0x20, 0x10, 0x9f, 0x8e,      \
                     0x7d, 0x4c, 0x6b, 0x5a, (value), 0x00, 0x2f, 0x7d)

static const ble_uuid128_t s_service_uuid = FOOTGUARD_UUID128(0x00);
static const ble_uuid128_t s_sensor_data_uuid = FOOTGUARD_UUID128(0x01);
static const ble_uuid128_t s_device_status_uuid = FOOTGUARD_UUID128(0x02);
static const ble_uuid128_t s_device_command_uuid = FOOTGUARD_UUID128(0x03);
static const ble_uuid128_t s_time_sync_uuid = FOOTGUARD_UUID128(0x04);
static const ble_uuid128_t s_ack_event_uuid = FOOTGUARD_UUID128(0x05);

static int gatt_access_handler(uint16_t conn_handle,
                               uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *context,
                               void *arg);
static int notify_only_access_handler(uint16_t conn_handle,
                                      uint16_t attr_handle,
                                      struct ble_gatt_access_ctxt *context,
                                      void *arg);

static const struct ble_gatt_svc_def s_gatt_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_sensor_data_uuid.u,
                .access_cb = notify_only_access_handler,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_sensor_data_handle
            },
            {
                .uuid = &s_device_status_uuid.u,
                .access_cb = gatt_access_handler,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_device_status_handle
            },
            {
                .uuid = &s_device_command_uuid.u,
                .access_cb = gatt_access_handler,
                .flags = BLE_GATT_CHR_F_WRITE,
                .val_handle = &s_device_command_handle
            },
            {
                .uuid = &s_time_sync_uuid.u,
                .access_cb = gatt_access_handler,
                .flags = BLE_GATT_CHR_F_WRITE,
                .val_handle = &s_time_sync_handle
            },
            {
                .uuid = &s_ack_event_uuid.u,
                .access_cb = notify_only_access_handler,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_ack_event_handle
            },
            {0}
        }
    },
    {0}
};

static size_t build_device_status_json(char *output, size_t output_size)
{
    footguard_time_snapshot_t time_snapshot;
    bool streaming = s_streaming_callback != NULL && s_streaming_callback();
    int length;

    footguard_time_get_snapshot(&time_snapshot);
    length = snprintf(
        output,
        output_size,
        "{\"protocol_version\":%u,\"firmware_version\":\"%s\","
        "\"device_id\":\"%s\",\"side\":\"%s\","
        "\"sensor_layout_version\":\"%s\",\"battery\":%u,"
        "\"state\":\"%s\",\"error_code\":\"none\","
        "\"time_synced\":%s,\"sync_id\":%" PRIu32 "}",
        FOOTGUARD_PROTOCOL_VERSION,
        FOOTGUARD_FIRMWARE_VERSION,
        FOOTGUARD_DEVICE_ID,
        FOOTGUARD_DEVICE_SIDE_NAME,
        FOOTGUARD_SENSOR_LAYOUT_VERSION,
        footguard_mock_sensor_battery_percent(),
        streaming ? "streaming" : "idle",
        time_snapshot.time_synced ? "true" : "false",
        time_snapshot.sync_id);

    if (length < 0 || (size_t)length >= output_size ||
        length > DEVICE_STATUS_MAX_SIZE) {
        ESP_LOGE(TAG, "DeviceStatus JSON exceeds %d bytes",
                 DEVICE_STATUS_MAX_SIZE);
        return 0;
    }

    return (size_t)length;
}

void footguard_gatt_notify_device_status(uint16_t conn_handle, uint16_t mtu)
{
    char json[DEVICE_STATUS_MAX_SIZE + 1];
    size_t json_size = build_device_status_json(json, sizeof(json));
    struct os_mbuf *packet;
    int rc;

    if (json_size == 0U) {
        return;
    }
    if (mtu < json_size + 3U) {
        ESP_LOGW(TAG,
                 "DeviceStatus notify skipped: MTU %u is below required %u",
                 mtu,
                 (unsigned int)(json_size + 3U));
        return;
    }

    packet = ble_hs_mbuf_from_flat(json, (uint16_t)json_size);
    if (packet == NULL) {
        ESP_LOGE(TAG, "DeviceStatus notify allocation failed");
        return;
    }

    rc = ble_gatts_notify_custom(conn_handle, s_device_status_handle, packet);
    if (rc != 0) {
        ESP_LOGW(TAG, "DeviceStatus notify failed: rc=%d", rc);
    }
}

int footguard_gatt_notify_sensor_data(uint16_t conn_handle,
                                      const uint8_t *frame,
                                      size_t frame_size)
{
    struct os_mbuf *packet;

    if (frame == NULL || frame_size != FOOTGUARD_SENSOR_FRAME_SIZE) {
        return BLE_HS_EINVAL;
    }

    packet = ble_hs_mbuf_from_flat(frame, (uint16_t)frame_size);
    if (packet == NULL) {
        return BLE_HS_ENOMEM;
    }

    return ble_gatts_notify_custom(conn_handle, s_sensor_data_handle, packet);
}

int footguard_gatt_notify_ack_event(uint16_t conn_handle,
                                    const char *json,
                                    size_t json_size)
{
    struct os_mbuf *packet;

    if (json == NULL || json_size == 0U ||
        json_size > DEVICE_STATUS_MAX_SIZE) {
        return BLE_HS_EINVAL;
    }

    packet = ble_hs_mbuf_from_flat(json, (uint16_t)json_size);
    if (packet == NULL) {
        return BLE_HS_ENOMEM;
    }

    return ble_gatts_notify_custom(conn_handle, s_ack_event_handle, packet);
}

static int read_device_status(struct ble_gatt_access_ctxt *context)
{
    char json[DEVICE_STATUS_MAX_SIZE + 1];
    size_t json_size = build_device_status_json(json, sizeof(json));

    if (json_size == 0U) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (os_mbuf_append(context->om, json, (uint16_t)json_size) != 0) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    return 0;
}

static int write_device_command(struct ble_gatt_access_ctxt *context)
{
    uint8_t payload[FOOTGUARD_DEVICE_COMMAND_MAX_SIZE];
    uint16_t payload_size = OS_MBUF_PKTLEN(context->om);
    footguard_command_t command;
    footguard_command_parse_result_t result;

    if (payload_size == 0U || payload_size > sizeof(payload)) {
        ESP_LOGW(TAG, "DeviceCommand rejected: invalid length %u",
                 payload_size);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(context->om,
                            payload,
                            sizeof(payload),
                            NULL) != 0) {
        ESP_LOGE(TAG, "DeviceCommand rejected: payload copy failed");
        return BLE_ATT_ERR_UNLIKELY;
    }

    result = footguard_command_parse(payload, payload_size, &command);
    if (result != FOOTGUARD_COMMAND_PARSE_OK) {
        ESP_LOGW(TAG, "DeviceCommand rejected: parse_result=%s",
                 footguard_command_parse_result_name(result));
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }

    ESP_LOGI(TAG,
             "DeviceCommand parsed: id=%s duration_ms=%" PRIu32
             " expire_at_ms=%" PRIu64,
             command.command_id,
             command.duration_ms,
             command.expire_at_ms);
    ESP_LOGW(TAG,
             "DeviceCommand rejected: execution and AckEvent not implemented");
    return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
}

static int write_time_sync(struct ble_gatt_access_ctxt *context)
{
    uint8_t payload[FOOTGUARD_TIME_SYNC_PAYLOAD_SIZE];
    uint16_t payload_size = OS_MBUF_PKTLEN(context->om);
    footguard_time_sync_result_t result;
    footguard_time_snapshot_t snapshot;

    if (payload_size != sizeof(payload)) {
        ESP_LOGW(TAG, "TimeSync rejected: invalid length %u", payload_size);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(context->om,
                            payload,
                            sizeof(payload),
                            NULL) != 0) {
        ESP_LOGE(TAG, "TimeSync rejected: payload copy failed");
        return BLE_ATT_ERR_UNLIKELY;
    }

    result = footguard_time_apply_sync_payload(payload, sizeof(payload));
    if (result == FOOTGUARD_TIME_SYNC_INVALID_SYNC_ID) {
        ESP_LOGW(TAG, "TimeSync rejected: sync_id must be nonzero");
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }
    if (result != FOOTGUARD_TIME_SYNC_OK) {
        ESP_LOGW(TAG, "TimeSync rejected: invalid payload");
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    footguard_time_get_snapshot(&snapshot);
    ESP_LOGI(TAG, "TimeSync accepted: sync_id=%" PRIu32
                  " timestamp_ms=%" PRIu64,
             snapshot.sync_id,
             snapshot.timestamp_ms);
    if (s_status_changed_callback != NULL) {
        s_status_changed_callback();
    }
    return 0;
}

static int gatt_access_handler(uint16_t conn_handle,
                               uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *context,
                               void *arg)
{
    (void)conn_handle;
    (void)arg;

    if (attr_handle == s_device_status_handle &&
        context->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return read_device_status(context);
    }
    if (attr_handle == s_device_command_handle &&
        context->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return write_device_command(context);
    }
    if (attr_handle == s_time_sync_handle &&
        context->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return write_time_sync(context);
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static int notify_only_access_handler(uint16_t conn_handle,
                                      uint16_t attr_handle,
                                      struct ble_gatt_access_ctxt *context,
                                      void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    if (context->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    if (context->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
}

int footguard_gatt_register(
    footguard_gatt_streaming_callback_t streaming_callback,
    footguard_gatt_status_changed_callback_t status_changed_callback)
{
    int rc;

    s_streaming_callback = streaming_callback;
    s_status_changed_callback = status_changed_callback;
    rc = ble_gatts_count_cfg(s_gatt_services);
    if (rc == 0) {
        rc = ble_gatts_add_svcs(s_gatt_services);
    }

    return rc;
}

const ble_uuid128_t *footguard_gatt_service_uuid(void)
{
    return &s_service_uuid;
}

uint16_t footguard_gatt_sensor_data_handle(void)
{
    return s_sensor_data_handle;
}

uint16_t footguard_gatt_device_status_handle(void)
{
    return s_device_status_handle;
}

uint16_t footguard_gatt_ack_event_handle(void)
{
    return s_ack_event_handle;
}
