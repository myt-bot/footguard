#ifndef FOOTGUARD_CRC16_H
#define FOOTGUARD_CRC16_H

#include <stddef.h>
#include <stdint.h>

#define FOOTGUARD_CRC16_CCITT_FALSE_POLYNOMIAL 0x1021U
#define FOOTGUARD_CRC16_CCITT_FALSE_INITIAL 0xFFFFU

uint16_t footguard_crc16_ccitt_false(const uint8_t *data, size_t length);

#endif
