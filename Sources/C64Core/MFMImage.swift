import Foundation

/// A raw MFM disk image (sector dump: cylinder by cylinder, side 0 then side 1, sectors in
/// order) for the 1571's WD1770, as used by CP/M on the C128. The geometry comes from the file
/// size: the 5.25" 40-track formats the C128's CP/M reads.
public final class MFMImage {
    public struct Geometry: Equatable {
        public let name: String
        public let cylinders: Int, sides: Int, sectors: Int, sectorSize: Int
        /// Number of the first sector on side 0 and on side 1 (Kaypro IV numbers side 1 on from 10).
        public let firstSector: Int, firstSectorSide1: Int
        public var size: Int { cylinders * sides * sectors * sectorSize }
        public var sizeCode: Int { sectorSize == 128 ? 0 : sectorSize == 256 ? 1 : sectorSize == 512 ? 2 : 3 }
    }

    public static let formats: [Geometry] = [
        Geometry(name: "Kaypro II", cylinders: 40, sides: 1, sectors: 10, sectorSize: 512, firstSector: 0, firstSectorSide1: 0),
        Geometry(name: "Kaypro IV", cylinders: 40, sides: 2, sectors: 10, sectorSize: 512, firstSector: 0, firstSectorSide1: 10),
        Geometry(name: "IBM-8 SS (CP/M-86)", cylinders: 40, sides: 1, sectors: 8, sectorSize: 512, firstSector: 1, firstSectorSide1: 1),
        Geometry(name: "IBM-8 DS (CP/M-86)", cylinders: 40, sides: 2, sectors: 8, sectorSize: 512, firstSector: 1, firstSectorSide1: 1),
        Geometry(name: "IBM-9 SS", cylinders: 40, sides: 1, sectors: 9, sectorSize: 512, firstSector: 1, firstSectorSide1: 1),
        Geometry(name: "IBM-9 DS", cylinders: 40, sides: 2, sectors: 9, sectorSize: 512, firstSector: 1, firstSectorSide1: 1),
    ]

    public let geometry: Geometry
    public private(set) var data: [UInt8]
    public private(set) var dirty = false
    public var writeProtected = false

    public init?(data raw: [UInt8]) {
        guard let g = MFMImage.formats.first(where: { $0.size == raw.count }) else { return nil }
        geometry = g
        data = raw
    }

    public init(geometry g: Geometry) {
        geometry = g
        data = [UInt8](repeating: 0xE5, count: g.size)
    }

    public func firstSector(side: Int) -> Int { side == 0 ? geometry.firstSector : geometry.firstSectorSide1 }

    private func offset(_ cyl: Int, _ side: Int, _ sector: Int) -> Int? {
        let g = geometry
        let s = sector - firstSector(side: side)
        guard cyl >= 0, cyl < g.cylinders, side >= 0, side < g.sides, s >= 0, s < g.sectors else { return nil }
        return ((cyl * g.sides + side) * g.sectors + s) * g.sectorSize
    }

    public func sector(cyl: Int, side: Int, sector: Int) -> [UInt8]? {
        guard let o = offset(cyl, side, sector) else { return nil }
        return Array(data[o..<o + geometry.sectorSize])
    }

    public func setSector(cyl: Int, side: Int, sector: Int, _ bytes: [UInt8]) {
        guard let o = offset(cyl, side, sector) else { return }
        for i in 0..<min(bytes.count, geometry.sectorSize) { data[o + i] = bytes[i] }
        dirty = true
    }
}
