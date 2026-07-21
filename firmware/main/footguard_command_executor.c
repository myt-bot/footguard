#include "footguard_command_executor.h"

#include <inttypes.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "footguard_motor.h"

enum {
    COMMAND_QUEUE_DEPTH = 4,
    COMMAND_TASK_STACK_SIZE = 4096
};

static const char *TAG = "footguard_executor";
static QueueHandle_t s_command_queue;
static footguard_command_completed_callback_t s_completed_callback;

static void command_executor_task(void *arg)
{
    footguard_command_t command;

    (void)arg;

    for (;;) {
        esp_err_t result;

        if (xQueueReceive(s_command_queue,
                          &command,
                          portMAX_DELAY) != pdTRUE) {
            continue;
        }

        ESP_LOGI(TAG,
                 "Executing command: id=%s pattern=%d duration_ms=%" PRIu32,
                 command.command_id,
                 (int)command.pattern,
                 command.duration_ms);

        result = footguard_motor_execute_pattern(command.pattern,
                                                 command.duration_ms);

        if (result == ESP_OK) {
            ESP_LOGI(TAG, "Command execution finished: id=%s",
                     command.command_id);
        } else {
            ESP_LOGE(TAG, "Command execution failed: id=%s error=%s",
                     command.command_id,
                     esp_err_to_name(result));
            (void)footguard_motor_set(false);
        }

        if (s_completed_callback != NULL) {
            s_completed_callback(&command, result);
        }
    }
}

esp_err_t footguard_command_executor_init(
    footguard_command_completed_callback_t completed_callback)
{
    if (s_command_queue != NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    s_command_queue = xQueueCreate(COMMAND_QUEUE_DEPTH,
                                   sizeof(footguard_command_t));
    if (s_command_queue == NULL) {
        return ESP_ERR_NO_MEM;
    }

    s_completed_callback = completed_callback;

    if (xTaskCreate(command_executor_task,
                    "footguard_command",
                    COMMAND_TASK_STACK_SIZE,
                    NULL,
                    tskIDLE_PRIORITY + 2,
                    NULL) != pdPASS) {
        vQueueDelete(s_command_queue);
        s_command_queue = NULL;
        s_completed_callback = NULL;
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "Command executor ready: queue_depth=%d",
             COMMAND_QUEUE_DEPTH);
    return ESP_OK;
}

esp_err_t footguard_command_executor_submit(
    const footguard_command_t *command)
{
    if (command == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_command_queue == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xQueueSend(s_command_queue, command, 0) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    ESP_LOGI(TAG, "Command queued: id=%s", command->command_id);
    return ESP_OK;
}