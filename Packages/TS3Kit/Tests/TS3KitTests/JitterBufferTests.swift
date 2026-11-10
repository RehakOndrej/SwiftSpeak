import Foundation
import Testing
@testable import TS3Audio

/// Decodes a packet to a constant: its sequence number + 1. A frame rebuilt from the following
/// packet's redundancy comes out negative, a concealed one as 0.5, so tests can tell them apart.
private final class FakeDecoder: VoiceFrameDecoder {
    static func packet(_ sequence: UInt16) -> [UInt8] { [UInt8(sequence >> 8), UInt8(sequence & 0xFF)] }
    static func value(_ sequence: UInt16) -> Float { Float(sequence) + 1 }
    private func sequence(_ packet: [UInt8]) -> UInt16 { UInt16(packet[0]) << 8 | UInt16(packet[1]) }

    func sampleCount(of packet: [UInt8]) -> Int { packet.count == 2 ? 960 : 0 }
    func decode(_ packet: [UInt8], into out: UnsafeMutableBufferPointer<Float>) -> Int {
        for i in 0..<960 { out[i] = Self.value(sequence(packet)) }
        return 960
    }
    func recover(from next: [UInt8], count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int {
        for i in 0..<count { out[i] = -Self.value(sequence(next) &- 1) }
        return count
    }
    func conceal(count: Int, into out: UnsafeMutableBufferPointer<Float>) -> Int {
        for i in 0..<count { out[i] = 0.5 }
        return count
    }
}

private struct Arrival {
    var ms: Int
    var sequence: UInt16
    var end = false
}

/// Feeds packets at their arrival times while pulling audio every 10 ms, like the render thread.
private struct Simulation {
    let buffer: JitterBuffer
    var out: [Float] = []
    private var ms = 0

    init(decoder: any VoiceFrameDecoder = FakeDecoder()) {
        buffer = JitterBuffer(decoder: decoder)
        buffer.leveling = false
    }

    mutating func run(_ arrivals: [Arrival], untilMs: Int, data: (UInt16) -> [UInt8] = FakeDecoder.packet) {
        // Stable by time, so packets given the same time keep the order they are listed in.
        var queue = arrivals.enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }.map(\.element)[...]
        while ms < untilMs {
            while let a = queue.first, a.ms <= ms {
                buffer.insert(sequence: a.sequence, data: a.end ? [] : data(a.sequence), now: Double(a.ms) / 1000)
                queue.removeFirst()
            }
            var block = [Float](repeating: 0, count: 480)
            block.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, count: 480, gain: 1) }
            out += block
            ms += 10
        }
    }

    /// The values played, in order, without silence and without repeats.
    var played: [Float] {
        var result: [Float] = []
        for s in out where s != 0 && s != result.last { result.append(s) }
        return result
    }

    /// Milliseconds from `arrivalMs` until the packet started playing.
    func latency(of sequence: UInt16, arrivedMs: Int) -> Double? {
        out.firstIndex(of: FakeDecoder.value(sequence)).map { Double($0) / 48 - Double(arrivedMs) }
    }
}

/// One transmission: a packet every `intervalMs`, then the end marker.
private func steady(_ range: Range<Int>, intervalMs: Double = 20, first: UInt16 = 0) -> [Arrival] {
    range.map { Arrival(ms: Int(Double($0) * intervalMs), sequence: first &+ UInt16($0)) }
        + [Arrival(ms: Int(Double(range.upperBound) * intervalMs), sequence: first &+ UInt16(range.upperBound), end: true)]
}

@Suite struct JitterBufferTests {
    @Test func playsSteadyStreamInOrderWithLittleDelay() throws {
        var sim = Simulation()
        sim.run(steady(0..<50), untilMs: 1_200)
        #expect(sim.played == (0..<50).map { FakeDecoder.value(UInt16($0)) })
        #expect(sim.out.filter { $0 != 0 }.count == 50 * 960)
        var expected = JitterBuffer.Stats()
        expected.received = 51
        #expect(sim.buffer.stats == expected)
        #expect(try #require(sim.latency(of: 30, arrivedMs: 600)) <= 60)
    }

    @Test func putsPacketsBackInOrder() {
        var arrivals = steady(0..<40)
        for i in stride(from: 5, to: 35, by: 6) { // packet i+1 overtakes packet i
            arrivals[i + 1].ms = arrivals[i].ms
            arrivals.swapAt(i, i + 1)
        }
        var sim = Simulation()
        sim.run(arrivals, untilMs: 1_200)
        #expect(sim.played == (0..<40).map { FakeDecoder.value(UInt16($0)) })
        #expect(sim.buffer.stats.lost == 0)
    }

    @Test func rebuildsLostPacketFromTheNextOne() {
        var sim = Simulation()
        sim.run(steady(0..<40).filter { $0.sequence != 17 }, untilMs: 1_200)
        var expected = (0..<40).map { FakeDecoder.value(UInt16($0)) }
        expected[17] = -expected[17]
        #expect(sim.played == expected)
        #expect(sim.out.filter { $0 != 0 }.count == 40 * 960, "the lost frame must take exactly its own time")
        #expect(sim.buffer.stats.lost == 1)
        #expect(sim.buffer.stats.recovered == 1)
        #expect(sim.buffer.stats.concealed == 0)
    }

    @Test func concealsWhenTwoInARowAreLost() {
        var sim = Simulation()
        sim.run(steady(0..<40).filter { $0.sequence != 17 && $0.sequence != 18 }, untilMs: 1_200)
        var expected = (0..<40).map { FakeDecoder.value(UInt16($0)) }
        expected[17] = 0.5
        expected[18] = -expected[18]
        #expect(sim.played == expected)
        #expect(sim.out.filter { $0 != 0 }.count == 40 * 960)
    }

    @Test func ignoresDuplicates() {
        var sim = Simulation()
        sim.run(steady(0..<40) + steady(0..<40).dropLast(), untilMs: 1_200)
        #expect(sim.played == (0..<40).map { FakeDecoder.value(UInt16($0)) })
        #expect(sim.buffer.stats.duplicate + sim.buffer.stats.late == 40)
    }

    @Test func dropsPacketThatComesTooLate() {
        var arrivals = steady(0..<40)
        arrivals[10].ms += 200
        var sim = Simulation()
        sim.run(arrivals, untilMs: 1_200)
        var expected = (0..<40).map { FakeDecoder.value(UInt16($0)) }
        expected[10] = -expected[10] // rebuilt from packet 11; the real one is not played on top
        #expect(sim.played == expected)
        #expect(sim.buffer.stats.late == 1)
    }

    @Test func handlesSequenceWraparound() {
        var sim = Simulation()
        sim.run(steady(0..<40, first: 65_520), untilMs: 1_200)
        #expect(sim.played == (0..<40).map { FakeDecoder.value(65_520 &+ UInt16($0)) })
        #expect(sim.buffer.stats.lost == 0)
    }

    @Test func playsShortTransmissionAtOnceAndStartsAgainLater() {
        var sim = Simulation()
        // One packet and the end marker: there will never be a full buffer to wait for.
        sim.run([Arrival(ms: 0, sequence: 0), Arrival(ms: 1, sequence: 1, end: true)], untilMs: 500)
        #expect(sim.played == [1])
        #expect(!sim.buffer.isActive)
        // The speaker's counter carries on in the next transmission.
        sim.run((0..<20).map { Arrival(ms: 5_000 + $0 * 20, sequence: UInt16(2 + $0)) }, untilMs: 6_000)
        // This one has no end marker (as when it is lost): the decoder fades the tail out.
        #expect(sim.played.filter { $0 != 0.5 } == [1] + (2..<22).map { FakeDecoder.value(UInt16($0)) })
        #expect(sim.buffer.stats.concealed <= 5)
    }

    @Test func bridgesLatePacketWithoutSkippingIt() {
        var arrivals = steady(0..<60)
        for i in 30..<60 { arrivals[i].ms += 60 } // the stream stalls for 60 ms, nothing is lost
        var sim = Simulation()
        sim.run(arrivals, untilMs: 2_000)
        #expect(sim.played.filter { $0 != 0.5 } == (0..<60).map { FakeDecoder.value(UInt16($0)) })
        #expect(sim.buffer.stats.lost == 0)
    }

    @Test func doesNotPlayAnOutageTwice() throws {
        // 300 ms without any packets: those 15 are gone, the stream then carries on.
        let arrivals = steady(0..<200).filter { !(50..<65).contains(Int($0.sequence)) }
        var sim = Simulation()
        sim.run(arrivals, untilMs: 4_500)
        let before = try #require(sim.latency(of: 40, arrivedMs: 800))
        let after = try #require(sim.latency(of: 80, arrivedMs: 1_600))
        #expect(after <= before + 45, "delay grew from \(before) to \(after) ms")
        #expect(sim.played.last == FakeDecoder.value(199))
    }

    @Test func growsWithJitterAndShrinksAgain() throws {
        var generator: UInt64 = 7
        func random(_ limit: Int) -> Int {
            generator = generator &* 6364136223846793005 &+ 1442695040888963407
            return Int(generator >> 33) % limit
        }
        // 10 s where packets are held up by 0…100 ms, then 20 s of a clean connection.
        var arrivals = Array(steady(0..<1_500).dropLast())
        for i in 0..<500 { arrivals[i].ms += random(100) }
        var sim = Simulation()
        sim.run(arrivals.filter { $0.sequence < 500 }, untilMs: 10_000)
        #expect(sim.buffer.targetDelay >= 0.1, "target \(sim.buffer.targetDelay) s under 100 ms of jitter")
        let jittery = sim.buffer.stats
        #expect(jittery.lost + jittery.late <= 15, "\(jittery)")

        sim.run(arrivals.filter { $0.sequence >= 500 }, untilMs: 30_500)
        #expect(sim.buffer.targetDelay == JitterBuffer.minimumDelay)
        #expect(sim.buffer.stats.dropped > 0)
        #expect(try #require(sim.latency(of: 1_450, arrivedMs: 29_000)) <= 90)
    }

    @Test func followsSenderWhoseClockRunsFast() throws {
        // 0.2 % fast (a poor sound card) for two minutes would pile up 240 ms of delay if nothing
        // were dropped. Nothing here is quiet, so frames are dropped from sounding audio.
        var sim = Simulation()
        sim.run(steady(0..<6_010, intervalMs: 19.96), untilMs: 120_500)
        // Any single packet may be one of the dropped ones, so look at the last few.
        let latencies = (5_990..<6_000).compactMap { sim.latency(of: UInt16($0), arrivedMs: Int(Double($0) * 19.96)) }
        let latest = try #require(latencies.max())
        #expect(latest <= 120, "delay after two minutes: \(latest) ms")
        #expect(sim.buffer.stats.dropped >= 8)
        #expect(sim.buffer.stats.lost == 0)
        #expect(sim.buffer.stats.concealed == 0)
    }

    /// End to end with real Opus at a typical channel quality: with every seventh packet lost, what
    /// plays must stay close to the loss-free stream, because the lost frames are rebuilt from the
    /// redundancy in the packets after them. (Concealment alone gets to about −14 dB here.)
    @Test func realOpusStreamSurvivesLoss() throws {
        // Speech-like: harmonics of a gliding pitch with a syllable-rate envelope.
        var phase: Float = 0
        let signal = (0..<(200 * 960)).map { i -> Float in
            let t = Float(i) / 48_000
            phase += 2 * .pi * (120 + 40 * sinf(2 * .pi * 0.7 * t)) / 48_000
            var s: Float = 0
            for h in 1...15 { s += sinf(phase * Float(h)) / Float(h) }
            let envelope = max(0, sinf(2 * .pi * 3 * t))
            return s * 0.15 * envelope * envelope
        }
        let encoder = try #require(OpusEncoderBox(codec: .opusVoice, quality: 6))
        let packets = try (0..<200).map { try #require(encoder.encode(Array(signal[$0 * 960..<($0 + 1) * 960]))) }

        var clean = Simulation(decoder: try #require(OpusDecoderBox()))
        clean.run(steady(0..<200), untilMs: 4_500) { packets[Int($0)] }
        var lossy = Simulation(decoder: try #require(OpusDecoderBox()))
        lossy.run(steady(0..<200).filter { $0.sequence % 7 != 6 || $0.sequence < 20 }, untilMs: 4_500) { packets[Int($0)] }

        #expect(lossy.buffer.stats.lost == 26)
        #expect(lossy.buffer.stats.recovered == 26)
        var power: Float = 0, difference: Float = 0
        for i in clean.out.indices {
            power += clean.out[i] * clean.out[i]
            difference += (lossy.out[i] - clean.out[i]) * (lossy.out[i] - clean.out[i])
        }
        #expect(power > 0)
        let error = 10 * log10f(difference / power)
        #expect(error < -20, "difference to the loss-free stream: \(error) dB")
    }
}
