import Accelerate
import Foundation

/// Streaming noise suppressor for 48 kHz mono audio.
///
/// STFT with a 1024-sample sqrt-Hann window and 50 % overlap (21 ms latency), a minimum-tracking
/// noise estimate per frequency bin, and a decision-directed Wiener gain (Ephraim–Malah), which keeps
/// "musical noise" low. Works best on steady noise: fans, hum, hiss, air conditioning.
final class NoiseSuppressor {
    private static let size = 1024
    private static let hop = size / 2
    private static let half = size / 2
    private static let bins = size / 2 + 1
    private static let log2n = vDSP_Length(10)
    /// Per-hop rise of the noise floor while the signal stays above it: about 3 dB per second.
    private static let noiseRise: Float = 1.0074
    /// Minimum tracking underestimates the noise mean; compensate.
    private static let noiseBias: Float = 1.5

    private let setup: FFTSetup
    private let window: [Float]

    private var frame = [Float](repeating: 0, count: size)
    private var overlap = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: half)
    private var imag = [Float](repeating: 0, count: half)
    private var smoothed = [Float](repeating: 0, count: bins)
    private var noise = [Float](repeating: 0, count: bins)
    /// G² · |X|² of the previous frame, for the decision-directed SNR estimate.
    private var previousClean = [Float](repeating: 0, count: bins)
    private var gains = [Float](repeating: 1, count: bins)
    private var input: [Float] = []
    private var output = [Float](repeating: 0, count: hop)
    private var frames = 0

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = (0..<Self.size).map { sqrtf(0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(Self.size))) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Forgets the learned noise profile and buffered audio.
    func reset() {
        guard frames > 0 || !input.isEmpty else { return }
        for i in frame.indices { frame[i] = 0; overlap[i] = 0 }
        for k in 0..<Self.bins { smoothed[k] = 0; noise[k] = 0; previousClean[k] = 0; gains[k] = 1 }
        input.removeAll(keepingCapacity: true)
        output = [Float](repeating: 0, count: Self.hop)
        frames = 0
    }

    /// Returns exactly `samples.count` samples (delayed by one window).
    /// `strength` 0…1 sets how hard noise is pushed down (6…30 dB at most).
    func process(_ samples: [Float], strength: Float) -> [Float] {
        input += samples
        var consumed = 0
        while input.count - consumed >= Self.hop {
            frame.removeFirst(Self.hop)
            frame += input[consumed..<consumed + Self.hop]
            consumed += Self.hop
            processFrame(strength: max(0, min(1, strength)))
            output += overlap[0..<Self.hop]
            overlap.removeFirst(Self.hop)
            overlap += repeatElement(0, count: Self.hop)
        }
        input.removeFirst(consumed)
        let count = min(samples.count, output.count)
        let result = Array(output[0..<count])
        output.removeFirst(count)
        return result
    }

    private func processFrame(strength: Float) {
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
        let floorGain = powf(10, -(6 + 24 * strength) / 20)
        let alpha = 1 + 2 * strength
        let first = frames == 0

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.withMemoryRebound(to: DSPComplex.self) { c in
                        vDSP_ctoz(c.baseAddress!, 2, &split, 1, vDSP_Length(Self.half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

                for k in 0..<Self.bins {
                    // zrip packs DC into realp[0] and Nyquist into imagp[0].
                    let re: Float, im: Float
                    if k == 0 { re = rp[0]; im = 0 }
                    else if k == Self.half { re = ip[0]; im = 0 }
                    else { re = rp[k]; im = ip[k] }
                    let power = re * re + im * im

                    smoothed[k] = first ? power : 0.7 * smoothed[k] + 0.3 * power
                    noise[k] = first ? smoothed[k] : min(noise[k] * Self.noiseRise, smoothed[k])
                    let n = max(noise[k] * Self.noiseBias, 1e-12)

                    let posterior = power / n
                    let prior = 0.98 * previousClean[k] / n + 0.02 * max(posterior - 1, 0)
                    let gain = max(prior / (alpha + prior), floorGain)
                    previousClean[k] = gain * gain * power
                    gains[k] = gain
                }

                rp[0] *= gains[0]
                ip[0] *= gains[Self.half]
                for k in 1..<Self.half {
                    rp[k] *= gains[k]
                    ip[k] *= gains[k]
                }

                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
                windowed.withUnsafeMutableBufferPointer { w in
                    w.withMemoryRebound(to: DSPComplex.self) { c in
                        vDSP_ztoc(&split, 1, c.baseAddress!, 2, vDSP_Length(Self.half))
                    }
                }
            }
        }
        frames += 1

        // Undo zrip's 2·N round-trip scale, apply the synthesis window, overlap-add.
        var scale = 1 / Float(2 * Self.size)
        let n = vDSP_Length(Self.size)
        windowed.withUnsafeMutableBufferPointer { w in
            let p = w.baseAddress!
            vDSP_vsmul(p, 1, &scale, p, 1, n)
            vDSP_vmul(p, 1, window, 1, p, 1, n)
            overlap.withUnsafeMutableBufferPointer { o in
                vDSP_vadd(o.baseAddress!, 1, p, 1, o.baseAddress!, 1, n)
            }
        }
    }
}
