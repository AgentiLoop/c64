import Foundation

/// A D81 image (1581 3.5" disk): 80 tracks × 40 logical 256-byte sectors.
public final class D81Image {
    public static let size = 80 * 40 * 256
    public var data: [UInt8]
    public private(set) var dirty = false

    public init?(data raw: [UInt8]) {
        guard raw.count == D81Image.size || raw.count == D81Image.size + 3200 else { return nil }
        data = Array(raw.prefix(D81Image.size))
    }

    public init() { data = [UInt8](repeating: 0, count: D81Image.size) }

    @inline(__always) public func offset(track: Int, sector: Int) -> Int { ((track - 1) * 40 + sector) * 256 }

    public func sector(_ t: Int, _ s: Int) -> [UInt8] {
        let o = offset(track: t, sector: s)
        return Array(data[o..<o + 256])
    }

    public func setSector(_ t: Int, _ s: Int, _ bytes: [UInt8]) {
        let o = offset(track: t, sector: s)
        for i in 0..<256 { data[o + i] = i < bytes.count ? bytes[i] : 0 }
        dirty = true
    }

    public var diskName: String {
        let o = offset(track: 40, sector: 0)
        return D64Image.petsciiString(Array(data[o + 4..<o + 20]))
    }

    // MARK: - BAM

    private func bamEntry(_ t: Int) -> Int {
        t <= 40 ? offset(track: 40, sector: 1) + 0x10 + (t - 1) * 6
                : offset(track: 40, sector: 2) + 0x10 + (t - 41) * 6
    }

    func isFree(_ t: Int, _ s: Int) -> Bool { data[bamEntry(t) + 1 + s / 8] & (1 << (s % 8)) != 0 }

    func allocate(_ t: Int, _ s: Int) {
        guard isFree(t, s) else { return }
        let e = bamEntry(t)
        data[e + 1 + s / 8] &= ~(1 << (s % 8))
        data[e] &-= 1
    }

    /// A freshly formatted 1581 disk with an empty directory.
    public static func blank(name: String, id: String = "01") -> D81Image {
        let d = D81Image()
        let nm = D64Image.petscii(name, length: 16)
        let idb = D64Image.petscii(id, length: 2)
        var hdr = [UInt8](repeating: 0, count: 256)
        hdr[0] = 40; hdr[1] = 3; hdr[2] = 0x44
        for i in 0..<16 { hdr[4 + i] = nm[i] }
        hdr[0x14] = 0xA0; hdr[0x15] = 0xA0
        hdr[0x16] = idb[0]; hdr[0x17] = idb[1]
        hdr[0x18] = 0xA0; hdr[0x19] = 0x33; hdr[0x1A] = 0x44; hdr[0x1B] = 0xA0; hdr[0x1C] = 0xA0
        d.setSector(40, 0, hdr)
        for (k, s) in [1, 2].enumerated() {
            var bam = [UInt8](repeating: 0, count: 256)
            if k == 0 { bam[0] = 40; bam[1] = 2 } else { bam[0] = 0; bam[1] = 0xFF }
            bam[2] = 0x44; bam[3] = 0xBB; bam[4] = idb[0]; bam[5] = idb[1]; bam[6] = 0xC0
            for t in 0..<40 {
                bam[0x10 + t * 6] = 40
                for b in 1...5 { bam[0x10 + t * 6 + b] = 0xFF }
            }
            d.setSector(40, s, bam)
        }
        var dir = [UInt8](repeating: 0, count: 256)
        dir[1] = 0xFF
        d.setSector(40, 3, dir)
        for s in 0...3 { d.allocate(40, s) }
        d.dirty = false
        return d
    }

    /// Adds a file (PRG by default); `contents` includes the load address for PRGs.
    @discardableResult
    public func addFile(name: String, contents: [UInt8], type: UInt8 = 0x82) -> Bool {
        let needed = max(1, (contents.count + 253) / 254)
        var chain: [(Int, Int)] = []
        let order = Array((1...39).reversed()) + Array(41...80)
        outer: for t in order {
            for s in 0..<40 where isFree(t, s) {
                chain.append((t, s))
                if chain.count == needed { break outer }
            }
        }
        guard chain.count == needed, let (dt, ds, slot) = freeDirectorySlot() else { return false }
        for (i, (t, s)) in chain.enumerated() {
            allocate(t, s)
            let part = Array(contents[min(contents.count, i * 254)..<min(contents.count, (i + 1) * 254)])
            var block = [UInt8](repeating: 0, count: 256)
            if i + 1 < chain.count { block[0] = UInt8(chain[i + 1].0); block[1] = UInt8(chain[i + 1].1) }
            else { block[1] = UInt8(part.count + 1) }
            for (k, b) in part.enumerated() { block[2 + k] = b }
            setSector(t, s, block)
        }
        let o = offset(track: dt, sector: ds) + slot * 32
        data[o + 2] = type
        data[o + 3] = UInt8(chain[0].0); data[o + 4] = UInt8(chain[0].1)
        let nm = D64Image.petscii(name, length: 16)
        for i in 0..<16 { data[o + 5 + i] = nm[i] }
        data[o + 30] = UInt8(needed & 0xFF); data[o + 31] = UInt8(needed >> 8)
        return true
    }

    private func freeDirectorySlot() -> (Int, Int, Int)? {
        var s = 3
        for _ in 0..<37 {
            let o = offset(track: 40, sector: s)
            for slot in 0..<8 where data[o + slot * 32 + 2] == 0 { return (40, s, slot) }
            if data[o] == 0 {
                guard let ns = (4..<40).first(where: { isFree(40, $0) }) else { return nil }
                allocate(40, ns)
                data[o] = 40; data[o + 1] = UInt8(ns)
                var dir = [UInt8](repeating: 0, count: 256)
                dir[1] = 0xFF
                setSector(40, ns, dir)
                return (40, ns, 0)
            }
            s = Int(data[o + 1])
        }
        return nil
    }

    public func directory() -> [D64Image.Entry] {
        var out: [D64Image.Entry] = []
        var t = 40, s = 3
        var visited = Set<Int>()
        while t >= 1 && t <= 80 && s < 40 && visited.insert(t * 64 + s).inserted {
            let o = offset(track: t, sector: s)
            for slot in 0..<8 {
                let e = o + slot * 32
                guard data[e + 2] != 0 else { continue }
                out.append(D64Image.Entry(name: D64Image.petsciiString(Array(data[e + 5..<e + 21])), type: data[e + 2],
                                          blocks: Int(data[e + 30]) | Int(data[e + 31]) << 8,
                                          track: Int(data[e + 3]), sector: Int(data[e + 4])))
            }
            t = Int(data[o]); s = Int(data[o + 1])
        }
        return out
    }

    public func readFile(_ entry: D64Image.Entry) -> [UInt8] {
        var out: [UInt8] = []
        var t = entry.track, s = entry.sector
        var n = 0
        while t >= 1 && t <= 80 && s < 40 && n < 3200 {
            let b = sector(t, s)
            if b[0] == 0 { out += b[2..<min(256, Int(b[1]) + 1)]; break }
            out += b[2..<256]
            t = Int(b[0]); s = Int(b[1])
            n += 1
        }
        return out
    }
}
