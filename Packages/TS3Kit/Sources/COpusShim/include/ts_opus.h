#ifndef TS_OPUS_H
#define TS_OPUS_H
#include <opus.h>

/// Non-variadic wrappers for opus_encoder_ctl, which Swift cannot call directly.
int ts_opus_set_bitrate(OpusEncoder *enc, int bitrate);
int ts_opus_set_complexity(OpusEncoder *enc, int complexity);
int ts_opus_set_signal_voice(OpusEncoder *enc, int voice);
int ts_opus_set_inband_fec(OpusEncoder *enc, int enabled);
int ts_opus_set_packet_loss_perc(OpusEncoder *enc, int percent);

#endif
