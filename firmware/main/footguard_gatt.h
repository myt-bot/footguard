#ifndef FOOTGUARD_GATT_H
#define FOOTGUARD_GATT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "host/ble_uuid.h"

typedef bool (*footguard_gatt_streaming_callback_t)(void);
typedef void (*footguard_gatt_status_changed_callback_t)(void);

int footguard_gatt_register(
    footguard_gatt_streaming_callback_t streaming_callback,
    footguard_gatt_status_changed_callback_t status_changed_callback);

const ble_uuid128_t *footguard_gatt_service_uuid(void);
uint16_t footguard_gatt_sensor_data_handle(void);
uint16_t footguard_gatt_device_status_handle(void);
uint16_t footguard_gatt_ack_event_handle(void);

void footguard_gatt_notify_device_status(uint16_t conn_handle, uint16_t mtu);

int footguard_gatt_notify_sensor_data(uint16_t conn_handle,
                                      const uint8_t *frame,
                                      size_t frame_size);

#endif
