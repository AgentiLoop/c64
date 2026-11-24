import Foundation

/// MOS 6581 SID: three voices (saw/triangle/pulse/noise, sync, ring modulation), ADSR envelopes
/// with the real rate tables, multimode resonant filter and master volume (incl. the volume
/// register DC offset used by sample players). Clocked every CPU cycle; produces Float samples.
public final class SID {
    final class Voice {
        var freq: UInt32 = 0
        var pw: UInt32 = 0
        var control: UInt8 = 0
        var attackDecay: UInt8 = 0
        var sustainRelease: UInt8 = 0

        var acc: UInt32 = 0
        var msbRising = false
        var noise: UInt32 = 0x7FFFF8
        var prevBit19 = false

        // Envelope
        enum State { case attack, decaySustain, release }
        var state = State.release
        var level: UInt32 = 0
        var rateCounter: UInt32 = 0
        var expCounter: UInt32 = 0
        var expPeriod: UInt32 = 1
        var holdZero = true

        var gate: Bool { control & 0x01 != 0 }
        var sync: Bool { control & 0x02 != 0 }
        var ring: Bool { control & 0x04 != 0 }
        var test: Bool { control & 0x08 != 0 }

        static let ratePeriods: [UInt32] = [9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11720, 19532, 31251]

        func reset() {
            freq = 0; pw = 0; control = 0; attackDecay = 0; sustainRelease = 0
            acc = 0; noise = 0x7FFFF8; state = .release; level = 0; rateCounter = 0
            expCounter = 0; expPeriod = 1; holdZero = true
        }

        func writeControl(_ v: UInt8) {
            let gateOn = v & 1 != 0 && control & 1 == 0
            let gateOff = v & 1 == 0 && control & 1 != 0
            control = v
            if gateOn { state = .attack; holdZero = false }
            if gateOff { state = .release }
            if test { acc = 0; noise = 0x7FFFF8 }
        }

        @inline(__always) func clockOscillator() {
            if test { msbRising = false; return }
            let old = acc
            acc = (acc &+ freq) & 0xFFFFFF
            msbRising = old & 0x800000 == 0 && acc & 0x800000 != 0
            let bit19 = acc & 0x080000 != 0
            if bit19 && !prevBit19 {
                let b = ((noise >> 22) ^ (noise >> 17)) & 1
                noise = ((noise << 1) | b) & 0x7FFFFF
            }
            prevBit19 = bit19
        }

        /// Advances a voice that is silent and idle (gate off, level 0) by `n` cycles at once:
        /// same accumulator, noise and rate-counter state as `n` single cycles.
        func skip(_ n: Int) {
            if !test {
                let a0 = UInt64(acc), d = UInt64(freq) * UInt64(n)
                let half: UInt64 = 0x80000, full: UInt64 = 0x100000
                // Rising edges of bit 19 = crossings of 2^19 + k·2^20.
                let edges = (a0 + d + full - half) / full - (a0 + full - half) / full
                for _ in 0..<min(edges, 1 << 20) {
                    let b = ((noise >> 22) ^ (noise >> 17)) & 1
                    noise = ((noise << 1) | b) & 0x7FFFFF
                }
                acc = UInt32((a0 + d) & 0xFFFFFF)
                prevBit19 = acc & 0x080000 != 0
            }
            msbRising = false
            let period = Voice.ratePeriods[Int(sustainRelease & 0x0F)]
            let r = rateCounter
            let toHit = r < period ? Int(period - r) : Int(0x8000 - r + period)
            rateCounter = n < toHit ? (r + UInt32(n)) & 0x7FFF : UInt32((n - toHit) % Int(period))
        }

        @inline(__always) func clockEnvelope() {
            let period: UInt32
            switch state {
            case .attack: period = Voice.ratePeriods[Int(attackDecay >> 4)]
            case .decaySustain: period = Voice.ratePeriods[Int(attackDecay & 0x0F)]
            case .release: period = Voice.ratePeriods[Int(sustainRelease & 0x0F)]
            }
            rateCounter = (rateCounter + 1) & 0x7FFF
            if rateCounter != period { return }
            rateCounter = 0
            if state != .attack {
                expCounter += 1
                if expCounter < expPeriod { return }
            }
            expCounter = 0
            if holdZero { return }
            switch state {
            case .attack:
                level = (level &+ 1) & 0xFF
                if level == 0xFF { state = .decaySustain }
            case .decaySustain:
                if level != UInt32(sustainRelease >> 4) * 0x11 && level > 0 { level = (level &- 1) & 0xFF }
            case .release:
                if level > 0 { level = (level &- 1) & 0xFF }
            }
            switch level {
            case 0xFF: expPeriod = 1
            case 0x5D: expPeriod = 2
            case 0x36: expPeriod = 4
            case 0x1A: expPeriod = 8
            case 0x0E: expPeriod = 16
            case 0x06: expPeriod = 30
            case 0x00: expPeriod = 1; holdZero = true
            default: break
            }
        }

        /// 12-bit waveform output. `ringSource` is the accumulator of the modulating voice.
        @inline(__always) func waveform(ringSource: UInt32) -> UInt32 {
            let wave = control >> 4
            if wave == 0 { return 0 }
            var out: UInt32 = 0xFFF
            if wave & 1 != 0 {
                var msb = acc & 0x800000 != 0
                if ring { msb = msb != (ringSource & 0x800000 != 0) }
                let t = msb ? ~acc : acc
                out &= (t >> 11) & 0xFFF
            }
            if wave & 2 != 0 { out &= acc >> 12 }
            if wave & 4 != 0 { out &= (test || (acc >> 12) >= pw) ? 0xFFF : 0 }
            if wave & 8 != 0 {
                let n = noise
                let o = ((n >> 11) & 0x800) | ((n >> 10) & 0x400) | ((n >> 7) & 0x200) | ((n >> 5) & 0x100)
                    | ((n >> 4) & 0x080) | ((n >> 1) & 0x040) | ((n << 1) & 0x020) | ((n << 2) & 0x010)
                out &= o
            }
            return out
        }
    }

    // Three separate references: the per-cycle code then doesn't retain an array element every cycle.
    private let v0 = Voice(), v1 = Voice(), v2 = Voice()
    var voices: [Voice] { [v0, v1, v2] }
    var filterCutoff: UInt32 = 0
    var filterResonance: UInt8 = 0
    var filterRouting: UInt8 = 0
    var modeVolume: UInt8 = 0
    var lastWrite: UInt8 = 0

    // Filter state (Chamberlin state variable)
    var low: Float = 0, band: Float = 0
    var filterF: Float = 0
    var filterDamp: Float = 1.4

    // Sample output
    public var sampleRate: Double = 44_100 { didSet { cyclesPerSample = Double(clockHz) / sampleRate } }
    /// Chip clock; the same register values give ~4% higher pitch on NTSC machines.
    public var clockHz = C64.palClock {
        didSet { cyclesPerSample = Double(clockHz) / sampleRate; updateFilter() }
    }
    var cyclesPerSample = Double(C64.palClock) / 44_100
    var sampleClock: Double = 0
    var accumulator: Float = 0
    var accumulated = 0
    var mixCounter = 0
    var dcBlockPrevIn: Float = 0
    var dcBlockPrevOut: Float = 0
    public var samples: [Float] = []

    public init() {
        samples.reserveCapacity(4096)
        updateFilter()
    }

    public func reset() {
        silent = false; skippedCycles = 0
        for v in voices { v.reset() }
        filterCutoff = 0; filterResonance = 0; filterRouting = 0; modeVolume = 0
        low = 0; band = 0
        updateFilter()
    }

    private func updateFilter() {
        // 6581-like mapping from the 11-bit register to a cutoff frequency.
        let fc = Float(filterCutoff) / 2047
        let hz = 200 + 17_800 * fc * fc * (0.4 + 0.6 * fc) + 3000 * fc
        filterF = min(2 * sinf(Float.pi * hz / (Float(clockHz) / 4)), 1.2)
        filterDamp = 1.4 - Float(filterResonance) * (1.15 / 15)
    }

    /// Silent and idle: every voice released to level 0 and the filter settled, so the output is a
    /// constant and the voices are clocked in bulk (`skippedCycles`) instead of every cycle.
    private var silent = false
    /// True while the chip outputs a constant level (see `silent`).
    public var isSilent: Bool { silent }
    private var skippedCycles = 0

    /// Brings the voices and the (constant) output samples up to date after silent cycles.
    private func catchUp() {
        guard skippedCycles > 0 else { return }
        v0.skip(skippedCycles); v1.skip(skippedCycles); v2.skip(skippedCycles)
        sampleClock += Double(skippedCycles)
        skippedCycles = 0
        while sampleClock >= cyclesPerSample { emitSample() }
    }

    /// Output while silent: the volume register's DC offset (constant, so the DC blocker removes it).
    private var silentLevel: Float = 0

    private func checkSilent() -> Bool {
        v0.holdZero && v1.holdZero && v2.holdZero
            && v0.state == .release && v1.state == .release && v2.state == .release
            && abs(low) < 1e-6 && abs(band) < 1e-6
    }

    public func read(_ reg: Int) -> UInt8 {
        catchUp()
        switch reg {
        case 0x19, 0x1A: return 0xFF
        case 0x1B: return UInt8(voices[2].waveform(ringSource: voices[1].acc) >> 4)
        case 0x1C: return UInt8(voices[2].level)
        default: return lastWrite
        }
    }

    public func write(_ reg: Int, _ value: UInt8) {
        catchUp()
        silent = false
        lastWrite = value
        if reg < 21 {
            let v = voices[reg / 7]
            switch reg % 7 {
            case 0: v.freq = (v.freq & 0xFF00) | UInt32(value)
            case 1: v.freq = (v.freq & 0x00FF) | UInt32(value) << 8
            case 2: v.pw = (v.pw & 0xF00) | UInt32(value)
            case 3: v.pw = (v.pw & 0x0FF) | UInt32(value & 0x0F) << 8
            case 4: v.writeControl(value)
            case 5: v.attackDecay = value
            default: v.sustainRelease = value
            }
            return
        }
        switch reg {
        case 0x15: filterCutoff = (filterCutoff & 0x7F8) | UInt32(value & 7); updateFilter()
        case 0x16: filterCutoff = (filterCutoff & 7) | UInt32(value) << 3; updateFilter()
        case 0x17: filterResonance = value >> 4; filterRouting = value & 0x0F; updateFilter()
        case 0x18: modeVolume = value
        default: break
        }
    }

    /// One PHI2 cycle.
    @inline(__always) public func tick() {
        if silent { skippedCycles += 1; return }
        v0.clockOscillator(); v1.clockOscillator(); v2.clockOscillator()
        // Hard sync: voice n is reset when voice n-1's MSB rises.
        if v0.sync && v2.msbRising { v0.acc = 0 }
        if v1.sync && v0.msbRising { v1.acc = 0 }
        if v2.sync && v1.msbRising { v2.acc = 0 }
        v0.clockEnvelope(); v1.clockEnvelope(); v2.clockEnvelope()

        sampleClock += 1
        // Mix (and run the filter) once every 4 cycles to keep the cost down.
        mixCounter += 1
        if mixCounter == 4 {
            mixCounter = 0
            accumulator += mix()
            accumulated += 1
            if checkSilent() {
                silent = true
                silentLevel = Float(modeVolume & 0x0F) / 15 * 0.25
            }
        }
        if sampleClock >= cyclesPerSample { emitSample() }
    }

    private func emitSample() {
        do {
            sampleClock -= cyclesPerSample
            let s = accumulated > 0 ? accumulator / Float(accumulated) : silent ? silentLevel : 0
            accumulator = 0
            accumulated = 0
            // DC blocker
            let out = s - dcBlockPrevIn + 0.995 * dcBlockPrevOut
            dcBlockPrevIn = s
            dcBlockPrevOut = out
            samples.append(out)
        }
    }

    @inline(__always) private func voiceOut(_ v: Voice, _ ringSrc: Voice) -> Float {
        let w = Int32(v.waveform(ringSource: ringSrc.acc)) - 0x800
        return Float(w * Int32(v.level)) / Float(0x800 * 0xFF)
    }

    private func mix() -> Float {
        let o0 = voiceOut(v0, v2)
        let o1 = voiceOut(v1, v0)
        let o2 = voiceOut(v2, v1)
        var filtIn: Float = 0, direct: Float = 0
        if filterRouting & 1 != 0 { filtIn += o0 } else { direct += o0 }
        if filterRouting & 2 != 0 { filtIn += o1 } else { direct += o1 }
        if filterRouting & 4 != 0 { filtIn += o2 } else if modeVolume & 0x80 == 0 { direct += o2 }

        let high = filtIn - low - filterDamp * band
        band += filterF * high
        low += filterF * band
        if band.isNaN || abs(band) > 8 { band = 0; low = 0 }
        var out: Float = 0
        if modeVolume & 0x10 != 0 { out += low }
        if modeVolume & 0x20 != 0 { out += band }
        if modeVolume & 0x40 != 0 { out += high }
        let vol = Float(modeVolume & 0x0F) / 15
        // 6581 DC offset makes $D418 writes audible (digi samples).
        return (direct + out) * vol * 0.33 + vol * 0.25
    }

    /// Removes and returns the generated samples.
    public func takeSamples() -> [Float] {
        catchUp()
        let s = samples
        samples.removeAll(keepingCapacity: true)
        return s
    }
}
