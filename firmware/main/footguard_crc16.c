#include "footguard_crc16.h"

uint16_t footguard_crc16_ccitt_false(const uint8_t *data, size_t length)
{
    uint16_t crc = FOOTGUARD_CRC16_CCITT_FALSE_INITIAL;

    for (size_t index = 0; index < length; ++index) {
        crc ^= (uint16_t)data[index] << 8U;

        for (unsigned int bit = 0; bit < 8U; ++bit) {
            if ((crc & 0x8000U) != 0U) {
                crc = (uint16_t)((crc << 1U) ^
                                 FOOTGUARD_CRC16_CCITT_FALSE_POLYNOMIAL);
            } else {
                crc = (uint16_t)(crc << 1U);
            }
        }
    }

    return crc;
}
