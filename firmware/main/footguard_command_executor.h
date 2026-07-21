#ifndef FOOTGUARD_COMMAND_EXECUTOR_H
#define FOOTGUARD_COMMAND_EXECUTOR_H

#include "esp_err.h"

#include "footguard_command.h"

typedef void (*footguard_command_completed_callback_t)(
    const footguard_command_t *command,
    esp_err_t execution_result);

esp_err_t footguard_command_executor_init(
    footguard_command_completed_callback_t completed_callback);

esp_err_t footguard_command_executor_submit(
    const footguard_command_t *command);

#endif