#ifndef FOOTGUARD_COMMAND_SERVICE_H
#define FOOTGUARD_COMMAND_SERVICE_H

#include "esp_err.h"

#include "footguard_command.h"

typedef enum {
    FOOTGUARD_COMMAND_SUBMIT_ACCEPTED = 0,
    FOOTGUARD_COMMAND_SUBMIT_TARGET_MISMATCH,
    FOOTGUARD_COMMAND_SUBMIT_TIME_UNSYNCED,
    FOOTGUARD_COMMAND_SUBMIT_EXPIRED,
    FOOTGUARD_COMMAND_SUBMIT_QUEUE_FULL,
    FOOTGUARD_COMMAND_SUBMIT_INTERNAL_ERROR
} footguard_command_submit_result_t;

esp_err_t footguard_command_service_init(void);

footguard_command_submit_result_t footguard_command_service_submit(
    const footguard_command_t *command);

const char *footguard_command_submit_result_name(
    footguard_command_submit_result_t result);

#endif