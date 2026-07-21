#ifndef FOOTGUARD_BLE_H
#define FOOTGUARD_BLE_H

#include <stddef.h>

#include "esp_err.h"

esp_err_t footguard_ble_start(void);

int footguard_ble_notify_ack_event(const char *json, size_t json_size);

#endif