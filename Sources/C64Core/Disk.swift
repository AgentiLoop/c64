import Foundation

/// A D64 disk image (35/40/42 tracks, optional error bytes) with helpers to read the
/// directory, create blank disks and add files.
public final class D64Image {
    public private(set) var tracks: Int
    /// Raw sector data, 256 bytes per sector, track 1 sector 0 first.
    public var data: [UInt8]

    public static func sectors(onTrack t: Int) -> Int {
        switch t {
        case ...17: return 21
        case 18...24: return 19
        case 25...30: return 18
        default: return 17
        }
    }

    static func sectorCount(tracks: Int) -> Int { (1...tracks).reduce(0) { $0 + sectors(onTrack: $1) } }

    public init?(data raw: [UInt8]) {
        for t in [35, 40, 42] {
            let n = D64Image.sectorCount(tracks: t)
            if raw.count == n * 256 || raw.count == n * 257 {
                tracks = t
                data = Array(raw.prefix(n * 256))
                return
            }
        }
        return nil
    }

    public init(tracks: Int = 35) {
        self.tracks = tracks
        data = [UInt8](repeating: 0, count: D64Image.sectorCount(tracks: tracks) * 256)
    }

    public func offset(track: Int, sector: Int) -> Int {
        var o = 0
        for t in 1..<track { o += D64Image.sectors(onTrack: t) }
        return (o + sector) * 256
    }

    public func sector(_ t: Int, _ s: Int) -> [UInt8] {
        let o = offset(track: t, sector: s)
        return Array(data[o..<o + 256])
    }

    public func setSector(_ t: Int, _ s: Int, _ bytes: [UInt8]) {
        let o = offset(track: t, sector: s)
        for i in 0..<256 { data[o + i] = i < bytes.count ? bytes[i] : 0 }
    }

    /// The two disk ID characters stored in the BAM.
    public var diskID: (UInt8, UInt8) {
        let o = offset(track: 18, sector: 0)
        return (data[o + 0xA2], data[o + 0xA3])
    }

    public var diskName: String {
        let o = offset(track: 18, sector: 0)
        return D64Image.petsciiString(Array(data[o + 0x90..<o + 0xA0]))
    }

    static func petsciiString(_ b: [UInt8]) -> String {
        String(b.prefix { $0 != 0xA0 }.map { Character(UnicodeScalar($0 & 0x7F)) })
    }

    static func petscii(_ s: String, length: Int) -> [UInt8] {
        var out = s.uppercased().unicodeScalars.prefix(length).map { UInt8(truncatingIfNeeded: $0.value) }
        while out.count < length { out.append(0xA0) }
        return out
    }

    // MARK: - Formatting / files

    /// A freshly formatted disk with an empty directory.
    public static func blank(name: String, id: String = "01") -> D64Image {
        let d = D64Image()
        var bam = [UInt8](repeating: 0, count: 256)
        bam[0] = 18; bam[1] = 1; bam[2] = 0x41
        for t in 1...35 {
            let n = sectors(onTrack: t)
            let bits = UInt32((1 << n) - 1)
            bam[4 * t] = UInt8(n)
            bam[4 * t + 1] = UInt8(bits & 0xFF)
            bam[4 * t + 2] = UInt8((bits >> 8) & 0xFF)
            bam[4 * t + 3] = UInt8(bits >> 16)
        }
        let nameBytes = petscii(name, length: 16)
        for i in 0..<16 { bam[0x90 + i] = nameBytes[i] }
        bam[0xA0] = 0xA0; bam[0xA1] = 0xA0
        let idBytes = petscii(id, length: 2)
        bam[0xA2] = idBytes[0]; bam[0xA3] = idBytes[1]
        bam[0xA4] = 0xA0; bam[0xA5] = 0x32; bam[0xA6] = 0x41
        for i in 0xA7...0xAA { bam[i] = 0xA0 }
        d.setSector(18, 0, bam)
        var dir = [UInt8](repeating: 0, count: 256)
        dir[1] = 0xFF
        d.setSector(18, 1, dir)
        d.allocate(18, 0)
        d.allocate(18, 1)
        return d
    }

    func isFree(_ t: Int, _ s: Int) -> Bool {
        let o = offset(track: 18, sector: 0) + 4 * t + 1 + s / 8
        return data[o] & (1 << (s % 8)) != 0
    }

    func allocate(_ t: Int, _ s: Int) {
        guard isFree(t, s) else { return }
        let b = offset(track: 18, sector: 0) + 4 * t
        data[b + 1 + s / 8] &= ~(1 << (s % 8))
        data[b] &-= 1
    }

    /// Adds a file (PRG by default). `contents` includes the 2-byte load address for PRGs.
    /// Returns false when the disk or directory is full.
    @discardableResult
    public func addFile(name: String, contents: [UInt8], type: UInt8 = 0x82) -> Bool {
        // Collect free sectors with an interleave of 10, nearest to the directory first.
        let trackOrder = Array((1...17).reversed()) + Array(19...35)
        var chain: [(Int, Int)] = []
        let needed = max(1, (contents.count + 253) / 254)
        for t in trackOrder where chain.count < needed {
            let n = D64Image.sectors(onTrack: t)
            var s = 0
            var tried = 0
            while tried < n && chain.count < needed {
                var probe = s
                while !isFree(t, probe) || chain.contains(where: { $0 == (t, probe) }) {
                    probe = (probe + 1) % n
                    if probe == s { break }
                }
                if isFree(t, probe) && !chain.contains(where: { $0 == (t, probe) }) {
                    chain.append((t, probe))
                }
                s = (probe + 10) % n
                tried += 1
            }
        }
        guard chain.count == needed else { return false }
        guard let (dt, ds, slot) = freeDirectorySlot() else { return false }
        for (i, (t, s)) in chain.enumerated() {
            allocate(t, s)
            let part = Array(contents[min(contents.count, i * 254)..<min(contents.count, (i + 1) * 254)])
            var block = [UInt8](repeating: 0, count: 256)
            if i + 1 < chain.count {
                block[0] = UInt8(chain[i + 1].0); block[1] = UInt8(chain[i + 1].1)
            } else {
                block[0] = 0; block[1] = UInt8(part.count + 1)
            }
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
        var t = 18, s = 1
        for _ in 0..<18 {
            let o = offset(track: t, sector: s)
            for slot in 0..<8 where data[o + slot * 32 + 2] == 0 { return (t, s, slot) }
            if data[o] == 0 {
                // Extend the directory chain on track 18 (interleave 3).
                var ns = (s + 3) % 19
                while !isFree(18, ns) { ns = (ns + 1) % 19; if ns == s { return nil } }
                allocate(18, ns)
                data[o] = 18; data[o + 1] = UInt8(ns)
                var dir = [UInt8](repeating: 0, count: 256)
                dir[1] = 0xFF
                setSector(18, ns, dir)
                return (18, ns, 0)
            }
            t = Int(data[o]); s = Int(data[o + 1])
        }
        return nil
    }

    public struct Entry { public let name: String; public let type: UInt8; public let blocks: Int; public let track: Int; public let sector: Int }

    public func directory() -> [Entry] {
        var out: [Entry] = []
        var t = 18, s = 1
        var visited = Set<Int>()
        while t != 0 && t <= tracks && visited.insert(t * 64 + s).inserted {
            let o = offset(track: t, sector: s)
            for slot in 0..<8 {
                let e = o + slot * 32
                guard data[e + 2] != 0 else { continue }
                out.append(Entry(name: D64Image.petsciiString(Array(data[e + 5..<e + 21])), type: data[e + 2],
                                 blocks: Int(data[e + 30]) | Int(data[e + 31]) << 8,
                                 track: Int(data[e + 3]), sector: Int(data[e + 4])))
            }
            t = Int(data[o]); s = Int(data[o + 1])
        }
        return out
    }

    /// Reads a file's contents by following its sector chain.
    public func readFile(_ entry: Entry) -> [UInt8] {
        var out: [UInt8] = []
        var t = entry.track, s = entry.sector
        var guardCount = 0
        while t != 0 && t <= tracks && guardCount < 800 {
            let b = sector(t, s)
            if b[0] == 0 { out += b[2..<min(256, Int(b[1]) + 1)]; break }
            out += b[2..<256]
            t = Int(b[0]); s = Int(b[1])
            guardCount += 1
        }
        return out
    }
}

/// A disk as the 1541 head sees it: one GCR-encoded byte stream per track.
public final class GCRDisk {
    /// tracks[t] for t in 1...count; index 0 unused.
    public private(set) var tracks: [[UInt8]]
    public private(set) var dirty = false
    public var writeProtected = false
    let trackCount: Int
    let diskID: (UInt8, UInt8)
    /// The image the disk was made from; sectors that can't be decoded keep their old data.
    let source: D64Image

    static let encodeTable: [UInt8] = [0x0A, 0x0B, 0x12, 0x13, 0x0E, 0x0F, 0x16, 0x17,
                                       0x09, 0x19, 0x1A, 0x1B, 0x0D, 0x1D, 0x1E, 0x15]
    static let decodeTable: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 32)
        for (n, c) in encodeTable.enumerated() { t[Int(c)] = UInt8(n) }
        return t
    }()

    public static func zone(track: Int) -> Int {
        switch track {
        case ...17: return 3
        case 18...24: return 2
        case 25...30: return 1
        default: return 0
        }
    }

    static let trackCapacity = [6250, 6666, 7142, 7692]

    public init(d64: D64Image) {
        source = d64
        trackCount = d64.tracks
        diskID = d64.diskID
        tracks = [[]]
        for t in 1...d64.tracks { tracks.append(encodeTrack(t, d64)) }
    }

    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 5 / 4)
        var i = 0
        while i < bytes.count {
            var bits: UInt64 = 0
            for k in 0..<4 {
                let b = i + k < bytes.count ? bytes[i + k] : 0
                bits = bits << 10 | UInt64(encodeTable[Int(b >> 4)]) << 5 | UInt64(encodeTable[Int(b & 0x0F)])
            }
            for k in (0..<5).reversed() { out.append(UInt8((bits >> UInt64(k * 8)) & 0xFF)) }
            i += 4
        }
        return out
    }

    /// Decodes `groups` groups of 5 GCR bytes starting at `start` (wrapping); nil on bad code.
    static func decode(_ src: [UInt8], from start: Int, groups: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(groups * 4)
        let n = src.count
        for g in 0..<groups {
            var bits: UInt64 = 0
            for k in 0..<5 { bits = bits << 8 | UInt64(src[(start + g * 5 + k) % n]) }
            for k in (0..<4).reversed() {
                let hi = decodeTable[Int((bits >> UInt64(k * 10 + 5)) & 0x1F)]
                let lo = decodeTable[Int((bits >> UInt64(k * 10)) & 0x1F)]
                if hi == 0xFF || lo == 0xFF { return nil }
                out.append(hi << 4 | lo)
            }
        }
        return out
    }

    private func encodeTrack(_ t: Int, _ d64: D64Image) -> [UInt8] {
        let n = D64Image.sectors(onTrack: t)
        let capacity = GCRDisk.trackCapacity[GCRDisk.zone(track: t)]
        let perSector = 5 + 10 + 9 + 5 + 325
        let gap = max(4, (capacity - n * perSector) / n)
        var out: [UInt8] = []
        out.reserveCapacity(capacity)
        for s in 0..<n {
            let (id1, id2) = diskID
            let header: [UInt8] = [0x08, UInt8(s) ^ UInt8(t) ^ id1 ^ id2, UInt8(s), UInt8(t), id2, id1, 0x0F, 0x0F]
            out += [UInt8](repeating: 0xFF, count: 5)
            out += GCRDisk.encode(header)
            out += [UInt8](repeating: 0x55, count: 9)
            out += [UInt8](repeating: 0xFF, count: 5)
            let data = d64.sector(t, s)
            let sum = data.reduce(0, ^)
            out += GCRDisk.encode([0x07] + data + [sum, 0, 0])
            out += [UInt8](repeating: 0x55, count: gap)
        }
        while out.count < capacity { out.append(0x55) }
        return out
    }

    @inline(__always) public func write(track: Int, position: Int, _ value: UInt8) {
        tracks[track][position] = value
        dirty = true
    }

    /// Converts the (possibly written) GCR tracks back into a D64 image.
    public func toD64() -> D64Image {
        let out = D64Image(tracks: trackCount)
        out.data = source.data
        for t in 1...trackCount {
            let tr = tracks[t]
            let n = tr.count
            var i = 0
            while i < n {
                // End of a sync mark: an 0xFF followed by a non-0xFF byte.
                if tr[i] == 0xFF && tr[(i + 1) % n] != 0xFF,
                   let hdr = GCRDisk.decode(tr, from: i + 1, groups: 2), hdr[0] == 0x08,
                   Int(hdr[3]) == t, Int(hdr[2]) < D64Image.sectors(onTrack: t) {
                    // Find the data block's sync.
                    var j = i + 11
                    var found = false
                    for _ in 0..<60 {
                        if tr[j % n] == 0xFF && tr[(j + 1) % n] != 0xFF { found = true; break }
                        j += 1
                    }
                    if found, let blk = GCRDisk.decode(tr, from: j + 1, groups: 65), blk[0] == 0x07 {
                        out.setSector(t, Int(hdr[2]), Array(blk[1...256]))
                    }
                    i += 11
                } else {
                    i += 1
                }
            }
        }
        return out
    }
}
