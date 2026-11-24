import Foundation

/// A C64 expansion-port cartridge loaded from a CRT file: ROML ($8000) and ROMH ($A000, or
/// $E000 in Ultimax mode) in 8K banks, the GAME/EXROM lines and the bank-switching hardware of
/// the common cartridge types, by CRT hardware type number:
/// 0 normal 8K/16K/Ultimax, 4 Simons' BASIC, 5 Ocean, 10 Epyx FastLoad, 15 C64 Game System /
/// System 3, 17 Dinamic, 19 Magic Desk / Domark / HES Australia, 32 EasyFlash (flash read-only).
public final class Cartridge {
    public enum Mode { case off, k8, k16, ultimax }

    public static let supportedTypes: [Int: String] = [
        0: "Normal", 4: "Simons' BASIC", 5: "Ocean", 10: "Epyx FastLoad", 15: "C64 Game System",
        17: "Dinamic", 19: "Magic Desk", 32: "EasyFlash",
    ]

    public let type: Int
    public let name: String
    var roml: [[UInt8]]
    var romh: [[UInt8]]
    let startMode: Mode
    public private(set) var mode: Mode
    public private(set) var bank = 0
    /// EasyFlash: 256 bytes of RAM at $DF00.
    var ram = [UInt8](repeating: 0, count: 256)
    var epyxTimer = 0

    /// GAME and EXROM as the PLA sees them (true = pulled low by the cartridge).
    public var gameLow: Bool { mode == .k16 || mode == .ultimax }
    public var exromLow: Bool { mode == .k8 || mode == .k16 }

    public enum LoadError: Error { case notCRT, unsupportedType(Int), noROM }

    public init(crt d: [UInt8]) throws {
        guard d.count >= 0x40, d[0..<16].elementsEqual(Array("C64 CARTRIDGE   ".utf8)) else { throw LoadError.notCRT }
        func be32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func be16(_ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
        type = be16(0x16)
        guard Cartridge.supportedTypes[type] != nil else { throw LoadError.unsupportedType(type) }
        name = String(decoding: d[0x20..<0x40].prefix { $0 != 0 }, as: UTF8.self)
        let exrom = d[0x18] == 0, game = d[0x19] == 0               // 0 = line pulled low
        var lo: [Int: [UInt8]] = [:], hi: [Int: [UInt8]] = [:]
        var o = max(0x40, be32(0x10))
        while o + 0x10 <= d.count, d[o..<o + 4].elementsEqual(Array("CHIP".utf8)) {
            let total = be32(o + 4), bank = be16(o + 0x0A), load = be16(o + 0x0C), size = be16(o + 0x0E)
            guard total >= 0x10, o + 0x10 + size <= d.count else { break }
            var rom = Array(d[o + 0x10..<o + 0x10 + size])
            while rom.count < 0x2000 { rom += rom.isEmpty ? [0xFF] : rom }   // 2K/4K chips mirror
            switch load {
            case 0x8000:
                lo[bank] = Array(rom[0..<0x2000])
                if rom.count >= 0x4000 { hi[bank] = Array(rom[0x2000..<0x4000]) }
            case 0xA000, 0xE000: hi[bank] = Array(rom[0..<0x2000])
            case 0xF000: hi[bank] = Array(rom[0..<0x2000])
            default: break
            }
            o += total
        }
        guard !lo.isEmpty || !hi.isEmpty else { throw LoadError.noROM }
        let banks = max((lo.keys.max() ?? 0), (hi.keys.max() ?? 0)) + 1
        let empty = [UInt8](repeating: 0xFF, count: 0x2000)
        roml = (0..<banks).map { lo[$0] ?? empty }
        romh = (0..<banks).map { hi[$0] ?? empty }
        switch type {
        case 0: startMode = game && !exrom ? .ultimax : game ? .k16 : exrom ? .k8 : .off
        case 4: startMode = .k16
        case 5: startMode = banks == 64 ? .k8 : .k16                    // 512K Ocean carts are 8K
        case 32: startMode = .ultimax
        default: startMode = .k8
        }
        mode = startMode
    }

    public func reset() {
        mode = startMode
        bank = 0
        epyxTimer = Cartridge.epyxCycles
    }

    static let epyxCycles = 512

    // MARK: - ROM areas

    @inline(__always) func readROML(_ a: Int) -> UInt8 {
        if type == 10 { epyxTimer = Cartridge.epyxCycles }
        return roml[bank % roml.count][a & 0x1FFF]
    }

    @inline(__always) func readROMH(_ a: Int) -> UInt8 {
        if type == 5 { return roml[bank % roml.count][a & 0x1FFF] }      // Ocean: ROMH = same bank
        return romh[bank % romh.count][a & 0x1FFF]
    }

    /// One system cycle (Epyx FastLoad's capacitor switches the ROM off when it is not read).
    @inline(__always) func tick() {
        guard type == 10, mode != .off else { return }
        epyxTimer -= 1
        if epyxTimer <= 0 { mode = .off }
    }

    // MARK: - I/O 1 ($DE00) and I/O 2 ($DF00)

    func io1Read(_ a: Int) -> UInt8 {
        switch type {
        case 4: mode = .k8; return 0
        case 10: mode = .k8; epyxTimer = Cartridge.epyxCycles; return 0xFF
        case 15: bank = 0; return 0xFF
        case 17:
            if a & 0xFF < 16 { bank = a & 0x0F }
            return 0xFF
        case 32: return 0xFF
        default: return 0xFF
        }
    }

    func io1Write(_ a: Int, _ v: UInt8) {
        switch type {
        case 4: mode = .k16
        case 5: bank = Int(v & 0x3F)
        case 15: bank = a & 0x3F
        case 19:
            bank = Int(v & 0x7F)
            mode = v & 0x80 != 0 ? .off : .k8
        case 32:
            if a & 2 == 0 {
                bank = Int(v & 0x3F)
            } else {
                // bit 2 = mode, bit 1 = EXROM, bit 0 = GAME (1 = asserted); mode 0 forces GAME.
                switch v & 7 {
                case 0, 1, 5: mode = .ultimax
                case 2, 3, 7: mode = .k16
                case 6: mode = .k8
                default: mode = .off
                }
            }
        default: break
        }
    }

    func io2Read(_ a: Int) -> UInt8 {
        switch type {
        case 10: return roml[0][0x1F00 | (a & 0xFF)]                   // Epyx: last page of the ROM
        case 32: return ram[a & 0xFF]
        default: return 0xFF
        }
    }

    func io2Write(_ a: Int, _ v: UInt8) {
        if type == 32 { ram[a & 0xFF] = v }
    }
}
