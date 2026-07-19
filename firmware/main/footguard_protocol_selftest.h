#ifndef FOOTGUARD_PROTOCOL_SELFTEST_H
#define FOOTGUARD_PROTOCOL_SELFTEST_H

#include <stdbool.h>

typedef struct {
    bool crc_passed;
    bool left_frame_passed;
    bool right_frame_passed;
} footguard_protocol_selftest_results_t;

bool footguard_protocol_selftest_crc(void);
bool footguard_protocol_selftest_left_frame(void);
bool footguard_protocol_selftest_right_frame(void);

void footguard_protocol_run_selftests(
    footguard_protocol_selftest_results_t *results);

#endif
