#include "include/ts_modpow.h"
#include <string.h>

// 512-bit numbers as eight 64-bit limbs, least significant first. Repeated squaring uses
// Montgomery multiplication, which needs an odd modulus.
#define LIMBS 8
typedef unsigned __int128 u128;

static int at_least(const uint64_t *a, const uint64_t *b) {
    for (int i = LIMBS - 1; i >= 0; i--) {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return 1;
}

static void subtract(uint64_t *r, const uint64_t *a, const uint64_t *b) {
    uint64_t borrow = 0;
    for (int i = 0; i < LIMBS; i++) {
        u128 d = (u128)a[i] - b[i] - borrow;
        r[i] = (uint64_t)d;
        borrow = (uint64_t)(d >> 64) & 1;
    }
}

/// r = (2r + bit) mod n, for r < n.
static void double_mod(uint64_t *r, const uint64_t *n, uint64_t bit) {
    uint64_t carry = bit;
    for (int i = 0; i < LIMBS; i++) {
        uint64_t next = r[i] >> 63;
        r[i] = (r[i] << 1) | carry;
        carry = next;
    }
    if (carry || at_least(r, n)) subtract(r, r, n);
}

/// r = a * b / 2^512 mod n, for a, b < n. `n_inverse` is -1/n mod 2^64.
static void montgomery_multiply(uint64_t *r, const uint64_t *a, const uint64_t *b, const uint64_t *n, uint64_t n_inverse) {
    uint64_t t[LIMBS + 2] = {0};
    for (int i = 0; i < LIMBS; i++) {
        uint64_t carry = 0;
        for (int j = 0; j < LIMBS; j++) {
            u128 p = (u128)a[j] * b[i] + t[j] + carry;
            t[j] = (uint64_t)p;
            carry = (uint64_t)(p >> 64);
        }
        u128 p = (u128)t[LIMBS] + carry;
        t[LIMBS] = (uint64_t)p;
        t[LIMBS + 1] = (uint64_t)(p >> 64);

        uint64_t m = t[0] * n_inverse;
        p = (u128)m * n[0] + t[0];
        carry = (uint64_t)(p >> 64);
        for (int j = 1; j < LIMBS; j++) {
            p = (u128)m * n[j] + t[j] + carry;
            t[j - 1] = (uint64_t)p;
            carry = (uint64_t)(p >> 64);
        }
        p = (u128)t[LIMBS] + carry;
        t[LIMBS - 1] = (uint64_t)p;
        t[LIMBS] = t[LIMBS + 1] + (uint64_t)(p >> 64);
    }
    if (t[LIMBS] || at_least(t, n)) subtract(r, t, n);
    else memcpy(r, t, LIMBS * sizeof(uint64_t));
}

static void load(uint64_t *limbs, const uint8_t bytes[64]) {
    for (int i = 0; i < LIMBS; i++) {
        uint64_t v = 0;
        for (int j = 0; j < 8; j++) v = (v << 8) | bytes[(LIMBS - 1 - i) * 8 + j];
        limbs[i] = v;
    }
}

int ts_square_repeatedly_mod(const uint8_t x_bytes[64], const uint8_t n_bytes[64], uint32_t squarings, uint8_t out[64]) {
    uint64_t x[LIMBS], n[LIMBS];
    load(x, x_bytes);
    load(n, n_bytes);
    int small = n[0] < 3;
    for (int i = 1; i < LIMBS; i++) small = small && n[i] == 0;
    if (!(n[0] & 1) || small) return 0;

    // -1/n mod 2^64 by Newton's iteration (each step doubles the correct bits, starting from 3).
    uint64_t inverse = n[0];
    for (int i = 0; i < 6; i++) inverse *= 2 - n[0] * inverse;
    uint64_t n_inverse = 0 - inverse;

    // x mod n, one bit at a time.
    uint64_t reduced[LIMBS] = {0};
    for (int bit = 64 * LIMBS - 1; bit >= 0; bit--) {
        double_mod(reduced, n, (x[bit / 64] >> (bit % 64)) & 1);
    }

    // 2^1024 mod n, to move numbers into Montgomery form.
    uint64_t r_squared[LIMBS] = {1};
    for (int i = 0; i < 2 * 64 * LIMBS; i++) double_mod(r_squared, n, 0);

    uint64_t y[LIMBS];
    montgomery_multiply(y, reduced, r_squared, n, n_inverse);
    for (uint32_t i = 0; i < squarings; i++) montgomery_multiply(y, y, y, n, n_inverse);
    uint64_t one[LIMBS] = {1};
    montgomery_multiply(y, y, one, n, n_inverse);

    for (int i = 0; i < LIMBS; i++) {
        for (int j = 0; j < 8; j++) out[(LIMBS - 1 - i) * 8 + j] = (uint8_t)(y[i] >> (56 - 8 * j));
    }
    return 1;
}
