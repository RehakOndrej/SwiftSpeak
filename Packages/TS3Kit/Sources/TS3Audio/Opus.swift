import Copus
import COpusShim
import Foundation

/// TeamSpeak codec ids (Enums.toml `Codec`). Only Opus is supported.
public enum VoiceCodec: UInt8, Sendable {
    case opusVoice = 4
    case opusMusic = 5
}

public enum OpusConstants {
    public static let sampleRate = 48_000
    public static let frameSamples = 960 // 20 ms
}

final class OpusEncoderBox {
    private let encoder: OpaquePointer
    private var buffer = [UInt8](repeating: 0, count: 1500)

    init?(codec: VoiceCodec, quality: Int) {
        var error: Int32 = 0
        let app = codec == .opusVoice ? OPUS_APPLICATION_VOIP : OPUS_APPLICATION_AUDIO
        guard let enc = opus_encoder_create(Int32(OpusConstants.sampleRate), 1, app, &error), error == OPUS_OK else { return nil }
        encoder = enc
        // channel_codec_quality 0…10 → roughly 8…56 kbit/s
        _ = ts_opus_set_bitrate(enc, Int32(8_000 + max(0, min(quality, 10)) * 4_800))
        _ = ts_opus_set_complexity(enc, 10)
        _ = ts_opus_set_signal_voice(enc, codec == .opusVoice ? 1 : 0)
        _ = ts_opus_set_inband_fec(enc, 1)
        _ = ts_opus_set_packet_loss_perc(enc, 5)
    }

    deinit { opus_encoder_destroy(encoder) }

    func encode(_ samples: [Float]) -> [UInt8]? {
        precondition(samples.count == OpusConstants.frameSamples)
        let n = samples.withUnsafeBufferPointer { pcm in
            buffer.withUnsafeMutableBufferPointer { out in
                opus_encode_float(encoder, pcm.baseAddress!, Int32(OpusConstants.frameSamples), out.baseAddress!, Int32(out.count))
            }
        }
        guard n > 0 else { return nil }
        return Array(buffer[0..<Int(n)])
    }
}

/// What the jitter buffer needs from a decoder. All calls come from one thread at a time and must
/// not allocate: they run on the audio render thread.
protocol VoiceFrameDecoder: AnyObject {
    /// Samples (at 48 kHz) the packet decodes to, or 0 when it is not a valid packet.
    func sampleCount(of packet: [UInt8]) -> Int
    /// Decodes `packet` into `out`; returns the number of samples written (0 on failure).
    func decode(_ packet: [UInt8], into out: UnsafeMutableBufferPointer<Float>) -> Int
    /// Rebuilds the frame lost just before `next` from the redundancy `next` carries (falls back to
    /// concealment when it carries none). Writes exactly `count` samples.
    func recover(from next: [UInt8], count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int
    /// Invents `count` samples that continue the previous audio, fading out over repeated calls.
    func conceal(count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int
}

final class OpusDecoderBox: VoiceFrameDecoder {
    /// The longest Opus packet: 120 ms at 48 kHz.
    static let maxFrameSamples = 5760
    private let decoder: OpaquePointer

    init?() {
        var error: Int32 = 0
        // Mono output; stereo (Opus Music) streams are downmixed by the decoder.
        guard let dec = opus_decoder_create(Int32(OpusConstants.sampleRate), 1, &error), error == OPUS_OK else { return nil }
        decoder = dec
    }

    deinit { opus_decoder_destroy(decoder) }

    func sampleCount(of packet: [UInt8]) -> Int {
        guard !packet.isEmpty else { return 0 }
        let n = packet.withUnsafeBufferPointer {
            opus_packet_get_nb_samples($0.baseAddress!, Int32($0.count), Int32(OpusConstants.sampleRate))
        }
        return max(0, Int(n))
    }

    func decode(_ packet: [UInt8], into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let n = packet.withUnsafeBufferPointer { input in
            opus_decode_float(decoder, input.baseAddress, Int32(input.count), out.baseAddress!, Int32(out.count), 0)
        }
        return max(0, Int(n))
    }

    func recover(from next: [UInt8], count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let n = next.withUnsafeBufferPointer { input in
            opus_decode_float(decoder, input.baseAddress, Int32(input.count), out.baseAddress!, Int32(min(count, out.count)), 1)
        }
        return max(0, Int(n))
    }

    func conceal(count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let n = opus_decode_float(decoder, nil, 0, out.baseAddress!, Int32(min(count, out.count)), 0)
        return max(0, Int(n))
    }

    /// Convenience for tests and one-off decoding.
    func decode(_ data: [UInt8]) -> [Float] {
        var pcm = [Float](repeating: 0, count: Self.maxFrameSamples)
        let n = pcm.withUnsafeMutableBufferPointer { decode(data, into: $0) }
        return Array(pcm[0..<n])
    }
}
