#include "footguard_ble.h"

#include <inttypes.h>
#include <stdbool.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "footguard_config.h"
#include "footguard_fsr.h"
#include "footguard_gatt.h"
#include "footguard_protocol.h"
#include "footguard_real_sensor.h"
#include "footguard_time.h"

enum {
    SENSOR_DATA_REQUIRED_MTU = FOOTGUARD_SENSOR_FRAME_SIZE + 3,
    SENSOR_PERIOD_MS = 200,
    SENSOR_LOG_INTERVAL = 25,
    DEFAULT_ATT_MTU = 23
};

typedef struct {
    bool connected;
    uint16_t conn_handle;
    uint16_t mtu;
    bool sensor_subscribed;
    bool status_subscribed;
    bool ack_subscribed;
    bool streaming;
    bool mtu_warning_logged;
} footguard_ble_state_t;

static const char *TAG = "footguard_ble";
static portMUX_TYPE s_state_lock = portMUX_INITIALIZER_UNLOCKED;
static footguard_ble_state_t s_state = {
    .conn_handle = BLE_HS_CONN_HANDLE_NONE,
    .mtu = DEFAULT_ATT_MTU
};
static uint8_t s_own_addr_type;

static int gap_event_handler(struct ble_gap_event *event, void *arg);
static void notify_device_status(void);

static footguard_ble_state_t get_state(void)
{
    footguard_ble_state_t state;

    portENTER_CRITICAL(&s_state_lock);
    state = s_state;
    portEXIT_CRITICAL(&s_state_lock);

    return state;
}

static bool is_streaming(void)
{
    return get_state().streaming;
}

static void notify_device_status(void)
{
    footguard_ble_state_t state = get_state();

    if (!state.connected || !state.status_subscribed) {
        return;
    }
    footguard_gatt_notify_device_status(state.conn_handle, state.mtu);
}

int footguard_ble_notify_ack_event(const char *json, size_t json_size)
{
    footguard_ble_state_t state = get_state();

    if (json == NULL || json_size == 0U) {
        return BLE_HS_EINVAL;
    }
    if (!state.connected) {
        return BLE_HS_ENOTCONN;
    }
    if (!state.ack_subscribed || json_size + 3U > state.mtu) {
        return BLE_HS_EINVAL;
    }

    return footguard_gatt_notify_ack_event(state.conn_handle,
                                           json,
                                           json_size);
}

static bool refresh_streaming_state(void)
{
    bool previous_streaming;
    bool streaming;
    bool log_mtu_warning = false;
    uint16_t mtu;

    portENTER_CRITICAL(&s_state_lock);
    previous_streaming = s_state.streaming;
    streaming = s_state.connected && s_state.sensor_subscribed &&
                s_state.mtu >= SENSOR_DATA_REQUIRED_MTU;
    s_state.streaming = streaming;
    mtu = s_state.mtu;

    if (s_state.connected && s_state.sensor_subscribed &&
        s_state.mtu < SENSOR_DATA_REQUIRED_MTU) {
        if (!s_state.mtu_warning_logged) {
            s_state.mtu_warning_logged = true;
            log_mtu_warning = true;
        }
    } else {
        s_state.mtu_warning_logged = false;
    }
    portEXIT_CRITICAL(&s_state_lock);

    if (log_mtu_warning) {
        ESP_LOGW(TAG,
                 "SensorData notify blocked: MTU %u is below required %u",
                 mtu,
                 SENSOR_DATA_REQUIRED_MTU);
    }
    if (streaming != previous_streaming) {
        ESP_LOGI(TAG, "SensorData notifications %s",
                 streaming ? "started" : "stopped");
    }

    return streaming != previous_streaming;
}

static void clear_connection_state(void)
{
    bool was_streaming;

    portENTER_CRITICAL(&s_state_lock);
    was_streaming = s_state.streaming;
    s_state.connected = false;
    s_state.conn_handle = BLE_HS_CONN_HANDLE_NONE;
    s_state.mtu = DEFAULT_ATT_MTU;
    s_state.sensor_subscribed = false;
    s_state.status_subscribed = false;
    s_state.ack_subscribed = false;
    s_state.streaming = false;
    s_state.mtu_warning_logged = false;
    portEXIT_CRITICAL(&s_state_lock);

    footguard_time_reset();
    if (was_streaming) {
        ESP_LOGI(TAG, "SensorData notifications stopped");
    }
}

static void start_advertising(void)
{
    struct ble_hs_adv_fields fields;
    struct ble_hs_adv_fields response_fields;
    struct ble_gap_adv_params parameters;
    footguard_ble_state_t state = get_state();
    int rc;

    if (state.connected) {
        return;
    }

    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)footguard_gatt_service_uuid();
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Advertising data setup failed: rc=%d", rc);
        return;
    }

    memset(&response_fields, 0, sizeof(response_fields));
    response_fields.name = (const uint8_t *)FOOTGUARD_BLE_DEVICE_NAME;
    response_fields.name_len = sizeof(FOOTGUARD_BLE_DEVICE_NAME) - 1U;
    response_fields.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Scan response setup failed: rc=%d", rc);
        return;
    }

    memset(&parameters, 0, sizeof(parameters));
    parameters.conn_mode = BLE_GAP_CONN_MODE_UND;
    parameters.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_own_addr_type,
                           NULL,
                           BLE_HS_FOREVER,
                           &parameters,
                           gap_event_handler,
                           NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "Advertising start failed: rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "Advertising started: name=%s side=%s",
             FOOTGUARD_BLE_DEVICE_NAME,
             FOOTGUARD_DEVICE_SIDE_NAME);
}

static void update_subscription(uint16_t conn_handle,
                                uint16_t attr_handle,
                                bool subscribed)
{
    const char *name = NULL;
    bool notify_status = false;
    bool streaming_changed;
    bool is_current_connection;

    portENTER_CRITICAL(&s_state_lock);
    is_current_connection = s_state.connected &&
                            s_state.conn_handle == conn_handle;
    if (!is_current_connection) {
        portEXIT_CRITICAL(&s_state_lock);
        return;
    }

    if (attr_handle == footguard_gatt_sensor_data_handle()) {
        s_state.sensor_subscribed = subscribed;
        name = "SensorData";
    } else if (attr_handle == footguard_gatt_device_status_handle()) {
        s_state.status_subscribed = subscribed;
        name = "DeviceStatus";
        notify_status = subscribed;
    } else if (attr_handle == footguard_gatt_ack_event_handle()) {
        s_state.ack_subscribed = subscribed;
        name = "AckEvent";
    }
    portEXIT_CRITICAL(&s_state_lock);

    if (name != NULL) {
        ESP_LOGI(TAG, "%s subscription %s", name,
                 subscribed ? "enabled" : "disabled");
    }
    streaming_changed = refresh_streaming_state();
    if (notify_status || streaming_changed) {
        notify_device_status();
    }
}

static int gap_event_handler(struct ble_gap_event *event, void *arg)
{
    (void)arg;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            ESP_LOGW(TAG, "Connection failed: status=%d",
                     event->connect.status);
            start_advertising();
            return 0;
        }

        footguard_time_reset();
        portENTER_CRITICAL(&s_state_lock);
        s_state.connected = true;
        s_state.conn_handle = event->connect.conn_handle;
        s_state.mtu = ble_att_mtu(event->connect.conn_handle);
        s_state.sensor_subscribed = false;
        s_state.status_subscribed = false;
        s_state.ack_subscribed = false;
        s_state.streaming = false;
        s_state.mtu_warning_logged = false;
        portEXIT_CRITICAL(&s_state_lock);
        ESP_LOGI(TAG, "Connection established: handle=%u MTU=%u",
                 event->connect.conn_handle,
                 ble_att_mtu(event->connect.conn_handle));
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Disconnected: reason=%d; restarting advertising",
                 event->disconnect.reason);
        clear_connection_state();
        start_advertising();
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "Advertising completed: reason=%d; restarting",
                 event->adv_complete.reason);
        start_advertising();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        update_subscription(event->subscribe.conn_handle,
                            event->subscribe.attr_handle,
                            event->subscribe.cur_notify != 0);
        return 0;

    case BLE_GAP_EVENT_MTU: {
        bool is_current_connection;

        portENTER_CRITICAL(&s_state_lock);
        is_current_connection = s_state.connected &&
                                s_state.conn_handle == event->mtu.conn_handle;
        if (is_current_connection) {
            s_state.mtu = event->mtu.value;
        }
        portEXIT_CRITICAL(&s_state_lock);
        if (!is_current_connection) {
            return 0;
        }

        ESP_LOGI(TAG, "MTU updated: handle=%u MTU=%u",
                 event->mtu.conn_handle,
                 event->mtu.value);
        refresh_streaming_state();
        notify_device_status();
        return 0;
    }

    default:
        return 0;
    }
}

static void sensor_task(void *arg)
{
    TickType_t last_wake_time = xTaskGetTickCount();
    uint32_t packet_seq = 0;
    uint32_t notified_count = 0;
    int last_notify_error = 0;

    (void)arg;

    for (;;) {
        uint8_t frame[FOOTGUARD_SENSOR_FRAME_SIZE];
        footguard_ble_state_t state;
        footguard_time_snapshot_t time_snapshot;
        footguard_sensor_data_t sensor_data;
        int rc;

        vTaskDelayUntil(&last_wake_time, pdMS_TO_TICKS(SENSOR_PERIOD_MS));
        state = get_state();
        if (!state.streaming) {
            last_notify_error = 0;
            continue;
        }

        footguard_time_get_snapshot(&time_snapshot);
        if (footguard_real_sensor_make_data(packet_seq,
                                            &time_snapshot,
                                            &sensor_data) != ESP_OK) {
            ESP_LOGE(TAG, "Real SensorData acquisition failed");
            continue;
        }
        if (!footguard_protocol_encode_sensor_data(&sensor_data,
                                                   frame,
                                                   sizeof(frame))) {
            ESP_LOGE(TAG, "Real SensorData encoding failed");
            continue;
        }
        ++packet_seq;

        rc = footguard_gatt_notify_sensor_data(state.conn_handle,
                                               frame,
                                               sizeof(frame));
        if (rc != 0) {
            if (rc != last_notify_error) {
                ESP_LOGW(TAG, "SensorData notify failed: rc=%d", rc);
            }
            last_notify_error = rc;
            continue;
        }

        last_notify_error = 0;
        ++notified_count;
        if (notified_count % SENSOR_LOG_INTERVAL == 0U) {
            int fsr_raw[FOOTGUARD_FSR_CHANNEL_COUNT];

            for (size_t channel = 0;
                 channel < FOOTGUARD_FSR_CHANNEL_COUNT;
                 ++channel) {
                if (footguard_fsr_read_raw_channel(channel,
                                                   &fsr_raw[channel]) != ESP_OK) {
                    fsr_raw[channel] = -1;
                }
            }

            ESP_LOGI(TAG,
                     "Real SensorData: count=%" PRIu32
                     " seq=%" PRIu32
                     " flags=0x%08" PRIX32
                     " fsr_raw=(%d,%d,%d,%d,%d,%d)"
                     " temp=(%.2f,%.2f,%.2f,%.2f)C"
                     " accel=(%.2f,%.2f,%.2f)m/s2"
                     " gyro=(%.2f,%.2f,%.2f)dps",
                     notified_count,
                     packet_seq - 1U,
                     sensor_data.quality_flags,
                     fsr_raw[0],
                     fsr_raw[1],
                     fsr_raw[2],
                     fsr_raw[3],
                     fsr_raw[4],
                     fsr_raw[5],
                     sensor_data.temperature_c[0],
                     sensor_data.temperature_c[1],
                     sensor_data.temperature_c[2],
                     sensor_data.temperature_c[3],
                     sensor_data.acceleration_m_s2[0],
                     sensor_data.acceleration_m_s2[1],
                     sensor_data.acceleration_m_s2[2],
                     sensor_data.gyroscope_deg_s[0],
                     sensor_data.gyroscope_deg_s[1],
                     sensor_data.gyroscope_deg_s[2]);
        }
    }
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static void host_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE host reset: reason=%d", reason);
    clear_connection_state();
}

static void host_synced(void)
{
    int rc;

    rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "BLE address setup failed: rc=%d", rc);
        return;
    }
    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "BLE address type inference failed: rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "NimBLE host synchronized");
    start_advertising();
}

esp_err_t footguard_ble_start(void)
{
    esp_err_t error;
    int rc;

    error = nvs_flash_init();
    if (error == ESP_ERR_NVS_NO_FREE_PAGES ||
        error == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        error = nvs_flash_init();
    }
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "NVS initialization failed: %s",
                 esp_err_to_name(error));
        return error;
    }

    footguard_time_reset();
    error = nimble_port_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE initialization failed: %s",
                 esp_err_to_name(error));
        return error;
    }

    ble_hs_cfg.reset_cb = host_reset;
    ble_hs_cfg.sync_cb = host_synced;
    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = footguard_gatt_register(is_streaming, notify_device_status);
    if (rc != 0) {
        ESP_LOGE(TAG, "GATT service registration failed: rc=%d", rc);
        return ESP_FAIL;
    }

    rc = ble_svc_gap_device_name_set(FOOTGUARD_BLE_DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "BLE device name setup failed: rc=%d", rc);
        return ESP_FAIL;
    }

    error = footguard_real_sensor_init();
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Real sensor source initialization failed: %s",
                 esp_err_to_name(error));
        return error;
    }

    if (xTaskCreate(sensor_task,
                    "footguard_sensor",
                    4096,
                    NULL,
                    5,
                    NULL) != pdPASS) {
        ESP_LOGE(TAG, "Sensor task creation failed");
        return ESP_ERR_NO_MEM;
    }

    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "NimBLE initialized with 5 Hz real SensorData");
    return ESP_OK;
}
