#include "include/ts_opus.h"

int ts_opus_set_bitrate(OpusEncoder *enc, int bitrate) { return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate)); }
int ts_opus_set_complexity(OpusEncoder *enc, int complexity) { return opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity)); }
int ts_opus_set_signal_voice(OpusEncoder *enc, int voice) {
    return opus_encoder_ctl(enc, OPUS_SET_SIGNAL(voice ? OPUS_SIGNAL_VOICE : OPUS_SIGNAL_MUSIC));
}
int ts_opus_set_inband_fec(OpusEncoder *enc, int enabled) { return opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(enabled)); }
int ts_opus_set_packet_loss_perc(OpusEncoder *enc, int percent) { return opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(percent)); }
