import Foundation

/// One speaker's incoming voice: packets go in as the network delivers them (late, out of order,
/// duplicated or not at all) and come out as a steady stream of samples.
///
/// - Packets wait here still encoded and are decoded only when it is their turn to play, so a
///   packet that arrives out of order can still be put in its place.
/// - A packet that never arrives is rebuilt from the redundancy in the one after it (Opus in-band
///   FEC) or, failing that, concealed by the decoder instead of leaving a hole.
/// - How long packets wait adapts to the jitter actually measured on this speaker's packets.
///   Delay that is no longer needed (after a burst, or because the sender's clock runs fast) is
///   removed a frame at a time, preferably during a quiet moment.
///
/// Not thread-safe: the owner serialises `insert` (network) and `render` (audio thread), which is
/// what `@unchecked Sendable` stands for here. `render` does not allocate.
final class JitterBuffer: @unchecked Sendable {
    struct Stats: Equatable {
        /// Packets handed to `insert`.
        var received = 0
        /// Arrived after their place had already been played.
        var late = 0
        var duplicate = 0
        /// Never arrived in time.
        var lost = 0
        /// Lost frames rebuilt from the following packet's redundancy.
        var recovered = 0
        /// Frames invented by the decoder (a loss without redundancy, or nothing to play yet).
        var concealed = 0
        /// Frames dropped to get rid of delay.
        var dropped = 0
    }

    /// Packets that can wait at once; a packet further ahead than this restarts the stream.
    static let capacity = 64
    static let minimumDelay = 0.04
    static let maximumDelay = 0.3
    /// Kept on top of the measured jitter.
    private static let delayMargin = 0.03
    /// A sequence number this far behind is a new stream rather than a late packet.
    private static let lateWindow = 200
    /// After this long without packets the next one starts a new stream.
    private static let streamTimeout = 1.0
    /// With nothing to play, conceal this many frames (the decoder fades out), then go silent.
    private static let maximumConcealRun = 5
    private static let sampleRate = Double(OpusConstants.sampleRate)

    private struct Slot {
        var sequence: UInt16 = 0
        var data: [UInt8] = []
        var filled = false
    }

    private let decoder: any VoiceFrameDecoder
    private var slots = [Slot](repeating: Slot(), count: capacity)

    // Sequencing
    /// False until the first packet, and again after a transmission has ended and played out.
    private var anchored = false
    /// The packet whose turn it is to play.
    private var nextSequence: UInt16 = 0
    private var newestSequence: UInt16 = 0
    private var frameSamples = OpusConstants.frameSamples
    private var pendingEnd = false

    // Playout
    private var playing = false
    /// Silence played while packets were waiting for the buffer to fill.
    private var waitedSamples = 0
    /// Output time that has passed without moving on to the next packet (concealment and silence).
    private var stallSamples = 0
    private var concealRun = 0
    /// Consecutive frames played with clearly more delay than needed.
    private var framesOverTarget = 0

    // Decoded audio not yet handed out
    private var frame = [Float](repeating: 0, count: OpusDecoderBox.maxFrameSamples)
    private var frameStart = 0
    private var frameCount = 0
    private var fadeFrom = [Float](repeating: 0, count: JitterBuffer.fadeSamples)
    private static let fadeSamples = 240 // 5 ms

    // Arrival timing
    private var lastArrival = -Double.infinity
    private var timingValid = false
    private var referenceSequence: UInt16 = 0
    /// When `referenceSequence` would have arrived with the least delay seen so far.
    private var referenceArrival = 0.0
    /// Recent packet delays in 10 ms steps, older packets counting less.
    private var delayHistogram = [Float](repeating: 0, count: 40)
    private(set) var targetDelay = JitterBuffer.minimumDelay
    private var targetSamples = Int(JitterBuffer.minimumDelay * JitterBuffer.sampleRate)

    // Gains
    /// The listener's own volume for this speaker.
    var userGain: Float = 1
    /// Automatic voice leveling: nudges the speaker toward about −23 dBFS RMS, within ±12 dB.
    var leveling = true
    private var levelingGain: Float = 1

    private(set) var stats = Stats()

    init(decoder: any VoiceFrameDecoder) {
        self.decoder = decoder
    }

    /// Whether there is anything playing or waiting to play.
    var isActive: Bool { playing || bufferedFrames > 0 || frameCount > 0 }

    /// Packets waiting, counted from the one due next to the newest (gaps included).
    private var bufferedFrames: Int {
        anchored ? max(0, Int(Int16(bitPattern: newestSequence &- nextSequence)) + 1) : 0
    }

    private func slotIndex(_ sequence: UInt16) -> Int { Int(sequence) % Self.capacity }

    // MARK: - Network side

    /// Adds one packet. Empty `data` marks the end of a transmission. `now` is a monotonic clock in seconds.
    func insert(sequence: UInt16, data: [UInt8], now: Double) {
        stats.received += 1
        let sinceLast = now - lastArrival
        lastArrival = now

        if !data.isEmpty {
            let samples = decoder.sampleCount(of: data)
            guard samples > 0, samples <= OpusDecoderBox.maxFrameSamples else { return }
            if samples != frameSamples {
                frameSamples = samples
                timingValid = false
            }
        }

        var offset = Int(Int16(bitPattern: sequence &- nextSequence))
        if !anchored || sinceLast > Self.streamTimeout || offset >= Self.capacity || offset < -Self.lateWindow {
            restart(at: sequence)
            offset = 0
        }
        guard offset >= 0 else {
            stats.late += 1
            return
        }
        let index = slotIndex(sequence)
        if slots[index].filled && slots[index].sequence == sequence {
            stats.duplicate += 1
            return
        }
        slots[index] = Slot(sequence: sequence, data: data, filled: true)
        if Int16(bitPattern: sequence &- newestSequence) > 0 { newestSequence = sequence }

        if data.isEmpty {
            pendingEnd = true
            timingValid = false // the pause before the next transmission is not network delay
        } else {
            noteArrival(sequence: sequence, now: now)
        }
    }

    private func restart(at sequence: UInt16) {
        for i in slots.indices { slots[i].filled = false }
        anchored = true
        nextSequence = sequence
        newestSequence = sequence &- 1
        pendingEnd = false
        playing = false
        waitedSamples = 0
        stallSamples = 0
        concealRun = 0
        framesOverTarget = 0
        timingValid = false
    }

    /// Measures how much later than the fastest recent packet this one arrived and keeps the
    /// target delay just above what nearly all recent packets needed.
    private func noteArrival(sequence: UInt16, now: Double) {
        guard timingValid else {
            timingValid = true
            referenceSequence = sequence
            referenceArrival = now
            return
        }
        let frameDuration = Double(frameSamples) / Self.sampleRate
        let ahead = Int(Int16(bitPattern: sequence &- referenceSequence))
        var delay = now - (referenceArrival + Double(ahead) * frameDuration)
        if delay > Self.streamTimeout {
            // A pause in sending (the end marker was lost), not network delay.
            referenceSequence = sequence
            referenceArrival = now
            return
        }
        if delay < 0 {
            referenceArrival += delay // the fastest packet so far
            delay = 0
        }
        // Let the reference creep later, so it follows clock drift and routes that got slower.
        referenceArrival += 0.000_05
        if ahead > 0 {
            referenceSequence = sequence
            referenceArrival += Double(ahead) * frameDuration
        }

        let last = delayHistogram.count - 1
        var total: Float = 0
        for i in 0...last {
            delayHistogram[i] *= 0.995 // half the weight after about 3 s of speech
            total += delayHistogram[i]
        }
        delayHistogram[min(last, Int(delay * 100))] += 1
        total += 1
        var bucket = 0
        var below = delayHistogram[0]
        while bucket < last && below < total * 0.97 {
            bucket += 1
            below += delayHistogram[bucket]
        }
        targetDelay = min(Self.maximumDelay, max(Self.minimumDelay, Double(bucket + 1) * 0.01 + Self.delayMargin))
        targetSamples = Int(targetDelay * Self.sampleRate)
    }

    // MARK: - Audio side

    /// Adds this speaker's next `count` samples to `out` (which already holds the mix so far).
    func render(into out: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        var written = 0
        while written < count {
            if frameCount == 0 && !produceFrame() { break }
            let n = min(count - written, frameCount)
            let start = frameStart
            frame.withUnsafeBufferPointer { f in
                for i in 0..<n { out[written + i] += f[start + i] * gain }
            }
            frameStart += n
            frameCount -= n
            written += n
        }
        if written < count && anchored {
            let silent = count - written
            stallSamples = min(stallSamples + silent, OpusConstants.sampleRate * 10)
            if bufferedFrames > 0 { waitedSamples += silent }
        }
    }

    /// Fills `frame` with what plays next. False when there is nothing to play right now.
    private func produceFrame() -> Bool {
        guard anchored else { return false }
        let buffered = bufferedFrames

        if !playing {
            // Start once enough has arrived to ride out the measured jitter, or the first packet has
            // waited that long, or the whole (short) transmission is already here.
            guard buffered > 0,
                  buffered * frameSamples >= targetSamples || waitedSamples >= targetSamples || pendingEnd else { return false }
            playing = true
            waitedSamples = 0
            framesOverTarget = 0
        }

        if buffered == 0 {
            // The next packet is late. Bridge the gap without moving on, so it still plays when it
            // comes; the delay this adds is exactly what the jitter turned out to need.
            guard concealRun < Self.maximumConcealRun else {
                playing = false
                waitedSamples = 0
                return false
            }
            concealRun += 1
            stallSamples += frameSamples
            conceal()
            return true
        }

        if !slots[slotIndex(nextSequence)].filled {
            var missing = 1
            while missing < buffered && !slots[slotIndex(nextSequence &+ UInt16(missing))].filled { missing += 1 }
            // Time already spent waiting stands in for lost packets: don't play the outage twice.
            let skipped = min(missing, stallSamples / frameSamples)
            if skipped > 0 {
                nextSequence &+= UInt16(skipped)
                stats.lost += skipped
                stallSamples = 0
            }
            if skipped < missing {
                stats.lost += 1
                let following = slotIndex(nextSequence &+ 1)
                nextSequence &+= 1
                if slots[following].filled && !slots[following].data.isEmpty {
                    let count = frameSamples
                    let n = frame.withUnsafeMutableBufferPointer { decoder.recover(from: slots[following].data, count: count, into: $0) }
                    if n > 0 {
                        stats.recovered += 1
                        finishFrame(n, adaptLeveling: true)
                        return true
                    }
                }
                conceal()
                return true
            }
        }

        let index = slotIndex(nextSequence)
        slots[index].filled = false
        nextSequence &+= 1
        if slots[index].data.isEmpty {
            // End of a transmission. If the speaker has already started again, gather a full
            // buffer first: the pause between the two is the best place to wait.
            pendingEnd = false
            playing = false
            waitedSamples = 0
            concealRun = 0
            if bufferedFrames == 0 { anchored = false }
            return false
        }

        var n = frame.withUnsafeMutableBufferPointer { decoder.decode(slots[index].data, into: $0) }
        guard n > 0 else {
            conceal()
            return true
        }
        concealRun = 0
        stallSamples = 0
        n = dropFrameIfDelayed(n)
        finishFrame(n, adaptLeveling: true)
        return true
    }

    /// Removes delay that is no longer needed: when the buffer has held clearly more than the
    /// target for a while, the frame just decoded (`n` samples) is replaced by the one after it,
    /// with a short crossfade. Waits for a quiet frame unless the delay is large or has lasted long.
    private func dropFrameIfDelayed(_ n: Int) -> Int {
        let excess = bufferedFrames * frameSamples - targetSamples
        framesOverTarget = excess >= 2 * frameSamples ? framesOverTarget + 1 : 0
        let index = slotIndex(nextSequence)
        guard framesOverTarget >= 25, slots[index].filled, !slots[index].data.isEmpty else { return n }

        var power: Float = 0
        for i in 0..<n { power += frame[i] * frame[i] }
        let quiet = power / Float(n) < 0.005 * 0.005 // below about −46 dBFS
        guard quiet || framesOverTarget >= 150 || excess >= 12 * frameSamples else { return n }

        let fade = min(Self.fadeSamples, n)
        for i in 0..<fade { fadeFrom[i] = frame[i] }
        let m = frame.withUnsafeMutableBufferPointer { decoder.decode(slots[index].data, into: $0) }
        slots[index].filled = false
        nextSequence &+= 1
        stats.dropped += 1
        framesOverTarget = 20 // at most one frame in five
        guard m > 0 else {
            let count = frameSamples
            let c = frame.withUnsafeMutableBufferPointer { decoder.conceal(count: count, into: $0) }
            if c == 0 { for i in 0..<count { frame[i] = 0 } }
            return c > 0 ? c : count
        }
        // Start where the dropped frame started (which follows on from what was just played) and
        // blend into the new one.
        let blend = min(fade, m)
        for i in 0..<blend {
            let w = Float(i) / Float(blend)
            frame[i] = fadeFrom[i] * (1 - w) + frame[i] * w
        }
        return m
    }

    private func conceal() {
        stats.concealed += 1
        let count = frameSamples
        let n = frame.withUnsafeMutableBufferPointer { decoder.conceal(count: count, into: $0) }
        if n == 0 {
            for i in 0..<count { frame[i] = 0 }
        }
        finishFrame(n > 0 ? n : count, adaptLeveling: false)
    }

    /// Applies leveling and the listener's volume to the `n` samples in `frame` and queues them.
    private func finishFrame(_ n: Int, adaptLeveling: Bool) {
        var from = userGain, to = userGain
        if leveling {
            var gain = levelingGain
            if adaptLeveling {
                var sum: Float = 0
                for i in 0..<n { sum += frame[i] * frame[i] }
                let db = 10 * log10f(max(sum / Float(n), 1e-10))
                if db > -50 { // only adapt on speech, not on silence
                    let desired = max(0.25, min(4, powf(10, (-23 - db) / 20)))
                    gain += (desired - gain) * 0.1
                }
            }
            from *= levelingGain
            to *= gain
            levelingGain = gain
        }
        if from != 1 || to != 1 {
            // Ramp across the frame so a gain change is never a step.
            let step = (to - from) / Float(n)
            for i in 0..<n { frame[i] *= from + step * Float(i) }
        }
        frameStart = 0
        frameCount = n
    }
}
