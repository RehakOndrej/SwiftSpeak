#include "include/ts_ed25519.h"
#include "ge.h"
#include "sc.h"
#include <string.h>

/// Decodes a compressed point. ref10 only offers the negating decoder, so negate back.
static int decode_point(ge_p3 *p, const unsigned char s[32]) {
    if (ge_frombytes_negate_vartime(p, s) != 0) {
        return -1;
    }
    fe_neg(p->X, p->X);
    fe_neg(p->T, p->T);
    return 0;
}

void ts_ed_scalarmult_base(unsigned char out[32], const unsigned char scalar[32]) {
    ge_p3 h;
    ge_scalarmult_base(&h, scalar);
    ge_p3_tobytes(out, &h);
}

int ts_ed_scalarmult(unsigned char out[32], const unsigned char scalar[32], const unsigned char point[32]) {
    ge_p3 a;
    if (decode_point(&a, point) != 0) {
        return -1;
    }
    unsigned char zero[32] = {0};
    ge_p2 r;
    ge_double_scalarmult_vartime(&r, scalar, &a, zero);
    ge_tobytes(out, &r);
    return 0;
}

int ts_ed_scalarmult_add(unsigned char out[32], const unsigned char scalar[32],
                         const unsigned char point[32], const unsigned char addend[32]) {
    unsigned char product[32];
    if (ts_ed_scalarmult(product, scalar, point) != 0) {
        return -1;
    }
    ge_p3 p, q;
    if (decode_point(&p, product) != 0 || decode_point(&q, addend) != 0) {
        return -1;
    }
    ge_cached qc;
    ge_p3_to_cached(&qc, &q);
    ge_p1p1 sum;
    ge_add(&sum, &p, &qc);
    ge_p2 r;
    ge_p1p1_to_p2(&r, &sum);
    ge_tobytes(out, &r);
    return 0;
}

void ts_ed_sc_reduce32(unsigned char out[32], const unsigned char in[32]) {
    unsigned char t[64] = {0};
    memcpy(t, in, 32);
    sc_reduce(t);
    memcpy(out, t, 32);
}

void ts_ed_sc_reduce64(unsigned char out[32], const unsigned char in[64]) {
    unsigned char t[64];
    memcpy(t, in, 64);
    sc_reduce(t);
    memcpy(out, t, 32);
}
