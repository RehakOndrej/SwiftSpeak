#ifndef TS_MODPOW_H
#define TS_MODPOW_H
#include <stdint.h>

/// out = x ^ (2 ^ squarings) mod n, all 64-byte big-endian numbers.
/// Returns 1 on success, 0 when n is even or below 3 (not handled here).
int ts_square_repeatedly_mod(const uint8_t x[64], const uint8_t n[64], uint32_t squarings, uint8_t out[64]);

#endif
