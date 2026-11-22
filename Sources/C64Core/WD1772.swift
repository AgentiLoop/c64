/// Western Digital WD1772 floppy controller (as used in the 1581), clocked at 2 MHz.
/// Double density MFM: one byte every 32 µs (64 cycles), 300 rpm.
public final class WD1772 {
    public var trackReg: UInt8 = 0
    public var sectorReg: UInt8 = 1
    public var dataReg: UInt8 = 0
    public private(set) var cylinder = 0
    public private(set) var motorOn = false
    public private(set) var busy = false
    var drq = false
    var typeI = true
    var spunUp = false
    var seekError = false, rnf = false, lostData = false, writeProtectFault = false
    var command: UInt8 = 0
    var stepDir = 1
    enum Phase { case idle, spinUp, typeIDone, findSector, reading, writing, writeTrack, crc }
    var phase = Phase.idle
    var timer = 0
    var buffer: [UInt8] = []
    var pos = 0
    var revCycle = 0
    var idleCycles = 0
    var nextID = 1

    static let revolution = 400_000
    static let byteCycles = 64

    public var hasDisk: () -> Bool = { false }
    public var spinning: () -> Bool = { false }
    public var writeProtected: () -> Bool = { false }
    public var side: () -> Int = { 0 }
    public var readSector: (_ cyl: Int, _ side: Int, _ sector: Int) -> [UInt8]? = { _, _, _ in nil }
    public var writeSector: (_ cyl: Int, _ side: Int, _ sector: Int, _ data: [UInt8]) -> Void = { _, _, _, _ in }
    /// Called when the head steps (clears the drive's disk-change latch).
    public var stepped: () -> Void = {}

    public init() {}

    public func reset() {
        busy = false; drq = false; phase = .idle; typeI = true
        seekError = false; rnf = false; lostData = false; writeProtectFault = false
        motorOn = false; spunUp = false; sectorReg = 1
    }

    var status: UInt8 {
        var s: UInt8 = 0
        if motorOn { s |= 0x80 }
        if typeI {
            if writeProtected() { s |= 0x40 }
            if spunUp { s |= 0x20 }
            if seekError { s |= 0x10 }
            if cylinder == 0 { s |= 0x04 }
            if spinning() && hasDisk() && revCycle < 8000 { s |= 0x02 }
        } else {
            if writeProtectFault { s |= 0x40 }
            if rnf { s |= 0x10 }
            if lostData { s |= 0x04 }
            if drq { s |= 0x02 }
        }
        if busy { s |= 0x01 }
        return s
    }

    public func read(_ reg: Int) -> UInt8 {
        switch reg & 3 {
        case 0: return status
        case 1: return trackReg
        case 2: return sectorReg
        default: drq = false; return dataReg
        }
    }

    public func write(_ reg: Int, _ v: UInt8) {
        switch reg & 3 {
        case 0: startCommand(v)
        case 1: trackReg = v
        case 2: sectorReg = v
        default: dataReg = v; drq = false
        }
    }

    private func startCommand(_ v: UInt8) {
        if v & 0xF0 == 0xD0 {   // force interrupt
            if !busy { typeI = true; seekError = false }
            busy = false; drq = false; phase = .idle
            return
        }
        if busy { return }
        command = v
        busy = true; drq = false
        seekError = false; rnf = false; lostData = false; writeProtectFault = false
        typeI = v & 0x80 == 0
        idleCycles = 0
        if !motorOn && v & 0x08 == 0 {
            motorOn = true; spunUp = false
            phase = .spinUp; timer = 50_000
        } else {
            motorOn = true; spunUp = true
            begin()
        }
    }

    private func move(_ d: Int) {
        cylinder = min(max(cylinder + d, 0), 81)
    }

    private func begin() {
        let c = Int(command >> 4)
        if typeI {
            let rate = [6, 12, 2, 3][Int(command & 3)] * 2000
            var steps = 0
            switch c {
            case 0:
                steps = cylinder; cylinder = 0; trackReg = 0
            case 1:
                let diff = Int(dataReg) - Int(trackReg)
                if diff != 0 { stepDir = diff > 0 ? 1 : -1 }
                steps = abs(diff)
                move(diff)
                trackReg = dataReg
            default:
                if c >= 4 { stepDir = c < 6 ? 1 : -1 }
                steps = 1
                move(stepDir)
                if c & 1 != 0 { trackReg = UInt8(truncatingIfNeeded: Int(trackReg) + stepDir) }
            }
            if steps > 0 { stepped() }
            phase = .typeIDone
            timer = max(200, steps * rate) + (command & 0x04 != 0 ? 30_000 : 0)
            return
        }
        switch c {
        case 0xC:
            // Wait for the next ID field to pass under the head (10 per revolution).
            let slot = WD1772.revolution / 10
            let k = revCycle / slot
            nextID = (k + 1) % 10 + 1
            phase = .findSector
            timer = hasDisk() ? (k + 1) * slot - revCycle + 1 : WD1772.revolution * 2
        case 0x8...0xB:
            phase = .findSector
            timer = hasDisk() ? 2_000 : WD1772.revolution * 2
        case 0xF:
            if writeProtected() { writeProtectFault = true; finish(); return }
            buffer = []
            drq = true
            phase = .writeTrack
            timer = WD1772.byteCycles * 3
        default:   // read track: not supported, complete immediately
            finish()
        }
    }

    private func finish() {
        busy = false
        phase = .idle
        idleCycles = 0
    }

    @inline(__always) public func tick() {
        revCycle += 1
        if revCycle >= WD1772.revolution { revCycle = 0 }
        guard busy else {
            if motorOn {
                idleCycles += 1
                if idleCycles > 9 * WD1772.revolution { motorOn = false; spunUp = false }
            }
            return
        }
        timer -= 1
        if timer <= 0 { advance() }
    }

    private func advance() {
        let c = Int(command >> 4)
        let multiple = command & 0x10 != 0
        switch phase {
        case .idle:
            break
        case .spinUp:
            spunUp = true
            begin()
        case .typeIDone:
            if command & 0x04 != 0 && (!hasDisk() || Int(trackReg) != cylinder) { seekError = true }
            finish()
        case .findSector:
            guard hasDisk(), Int(trackReg) == cylinder || c == 0xC else { rnf = true; finish(); return }
            if c == 0xC {
                let id = [UInt8(cylinder), UInt8(side()), UInt8(nextID), 2]
                let crc = WD1772.crc16([0xA1, 0xA1, 0xA1, 0xFE] + id)
                buffer = id + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
                sectorReg = UInt8(cylinder)
                pos = 0; phase = .reading; timer = 1
                return
            }
            guard let d = readSector(cylinder, side(), Int(sectorReg)) else { rnf = true; finish(); return }
            if c < 0xA {
                buffer = d; pos = 0; phase = .reading; timer = 1
            } else {
                if writeProtected() { writeProtectFault = true; finish(); return }
                buffer = []; drq = true; phase = .writing; timer = WD1772.byteCycles * 2
            }
        case .reading:
            if pos < buffer.count {
                if drq { lostData = true }
                dataReg = buffer[pos]; pos += 1
                drq = true
                timer = WD1772.byteCycles
            } else if multiple && c != 0xC {
                sectorReg &+= 1
                phase = .findSector; timer = 1_000
            } else {
                phase = .crc; timer = WD1772.byteCycles * 2
            }
        case .writing:
            if drq { lostData = true; buffer.append(0) } else { buffer.append(dataReg) }
            if buffer.count >= 512 {
                writeSector(cylinder, side(), Int(sectorReg), buffer)
                drq = false
                if multiple { sectorReg &+= 1; phase = .findSector; timer = 1_000 }
                else { phase = .crc; timer = WD1772.byteCycles * 2 }
            } else {
                drq = true
                timer = WD1772.byteCycles
            }
        case .writeTrack:
            if drq { lostData = true; buffer.append(0x4E) } else { buffer.append(dataReg) }
            if buffer.count >= 6250 {
                drq = false
                parseTrack()
                finish()
            } else {
                drq = true
                timer = WD1772.byteCycles
            }
        case .crc:
            finish()
        }
    }

    /// CRC-CCITT as computed by the controller over address marks and fields.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Extracts the sectors from a raw track written by WRITE TRACK (format).
    private func parseTrack() {
        var i = 0
        var idSector = -1
        let n = buffer.count
        while i < n {
            guard buffer[i] == 0xF5 else { i += 1; continue }
            var j = i
            while j < n && buffer[j] == 0xF5 { j += 1 }
            guard j < n else { break }
            if buffer[j] == 0xFE && j + 4 < n {
                idSector = Int(buffer[j + 3])
                i = j + 5
            } else if buffer[j] == 0xFB && idSector > 0 && j + 512 < n {
                writeSector(cylinder, side(), idSector, Array(buffer[j + 1...j + 512]))
                idSector = -1
                i = j + 513
            } else {
                i = j
            }
        }
    }
}
