#ifndef TS_ED25519_H
#define TS_ED25519_H

/// Thin wrapper over the ref10 Ed25519 group operations needed by the
/// TeamSpeak license chain and ephemeral key exchange.
/// All points are 32-byte compressed Edwards points, all scalars 32 bytes little endian.

/// out = scalar * B (base point). `scalar` must be reduced (scalar[31] <= 127).
void ts_ed_scalarmult_base(unsigned char out[32], const unsigned char scalar[32]);

/// out = scalar * point. Returns 0 on success, -1 if `point` is not a valid point.
int ts_ed_scalarmult(unsigned char out[32], const unsigned char scalar[32], const unsigned char point[32]);

/// out = scalar * point + addend. Returns 0 on success, -1 on an invalid point.
int ts_ed_scalarmult_add(unsigned char out[32], const unsigned char scalar[32],
                         const unsigned char point[32], const unsigned char addend[32]);

/// out = in mod l, for a 32-byte little-endian input.
void ts_ed_sc_reduce32(unsigned char out[32], const unsigned char in[32]);

/// out = in mod l, for a 64-byte little-endian input.
void ts_ed_sc_reduce64(unsigned char out[32], const unsigned char in[64]);

#endif
