import Foundation

/// Commodore 1530 Datasette. A tape is a list of pulse lengths in C64 cycles (the TAP
/// format). Playing, each pulse end produces a falling edge on CIA1's FLAG pin; recording,
/// the time between rising edges of the cassette write line is stored as a pulse.
public final class Datasette {
    public enum Mode { case stopped, playing, recording }

    public private(set) var pulses: [UInt32] = []
    public var position = 0
    public var mode = Mode.stopped { didSet { lastWriteEdge = nil } }
    public private(set) var dirty = false
    var countdown = 0
    var lastWriteEdge: UInt64?

    public init() {}

    public func insert(pulses p: [UInt32]) {
        pulses = p
        position = 0
        countdown = 0
        mode = .stopped
        dirty = false
    }

    public func rewind() { position = 0; countdown = 0 }

    public var atEnd: Bool { position >= pulses.count }

    /// One C64 cycle.
    @inline(__always) func tick(motor: Bool, cia: CIA6526) {
        guard mode == .playing, motor else { return }
        if countdown == 0 {
            guard position < pulses.count else { return }
            countdown = Int(pulses[position])
            position += 1
        }
        countdown -= 1
        if countdown == 0 { cia.triggerFlag() }
    }

    /// Rising edge of the write line at the given machine cycle.
    func writeEdge(at cycle: UInt64, motor: Bool) {
        guard mode == .recording, motor else { lastWriteEdge = nil; return }
        if let last = lastWriteEdge {
            if position < pulses.count { pulses.removeSubrange(position...) }
            pulses.append(UInt32(min(cycle - last, 0xFF_FFFF)))
            position += 1
            dirty = true
        }
        lastWriteEdge = cycle
    }

    // MARK: - TAP files

    /// Parses a C64 TAP file (version 0 or 1).
    public static func parseTAP(_ d: [UInt8]) -> [UInt32]? {
        guard d.count >= 20, String(decoding: d[0..<12], as: UTF8.self) == "C64-TAPE-RAW" else { return nil }
        let version = d[12]
        var out: [UInt32] = []
        out.reserveCapacity(d.count)
        var i = 20
        while i < d.count {
            let b = d[i]
            i += 1
            if b != 0 {
                out.append(UInt32(b) * 8)
            } else if version == 0 {
                out.append(256 * 8)
            } else {
                guard i + 3 <= d.count else { break }
                let v = UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16
                i += 3
                out.append(max(v, 8))
            }
        }
        return out
    }

    /// Encodes pulses as a version 1 TAP file.
    public static func makeTAP(_ pulses: [UInt32]) -> [UInt8] {
        var body: [UInt8] = []
        body.reserveCapacity(pulses.count)
        for p in pulses {
            let v = (p + 4) / 8
            if v >= 1 && v <= 255 {
                body.append(UInt8(v))
            } else {
                body += [0, UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF)]
            }
        }
        let n = body.count
        return Array("C64-TAPE-RAW".utf8) + [1, 0, 0, 0,
                UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)] + body
    }

    public func tapData() -> [UInt8] { Datasette.makeTAP(pulses) }
}

/// T64 tape archive: returns the programs it contains as PRG data (load address first).
public enum T64Archive {
    public struct File { public let name: String; public let prg: [UInt8] }

    public static func files(_ d: [UInt8]) -> [File]? {
        guard d.count >= 64, String(decoding: d[0..<3], as: UTF8.self) == "C64" else { return nil }
        let maxEntries = max(1, Int(d[0x22]) | Int(d[0x23]) << 8)
        var out: [File] = []
        for e in 0..<maxEntries {
            let o = 0x40 + e * 32
            guard o + 32 <= d.count else { break }
            guard d[o] != 0 else { continue }
            let start = Int(d[o + 2]) | Int(d[o + 3]) << 8
            let end = Int(d[o + 4]) | Int(d[o + 5]) << 8
            let off = Int(d[o + 8]) | Int(d[o + 9]) << 8 | Int(d[o + 10]) << 16 | Int(d[o + 11]) << 24
            guard off < d.count else { continue }
            // Many T64 files carry a wrong end address; never read past the file.
            var size = end > start ? end - start : d.count - off
            size = min(size, d.count - off)
            let name = String(d[o + 16..<o + 32].map { Character(UnicodeScalar(($0 == 0xA0 || $0 == 0) ? 0x20 : $0 & 0x7F)) })
                .trimmingCharacters(in: .whitespaces)
            out.append(File(name: name, prg: [UInt8(start & 0xFF), UInt8(start >> 8)] + d[off..<off + size]))
        }
        return out
    }
}
