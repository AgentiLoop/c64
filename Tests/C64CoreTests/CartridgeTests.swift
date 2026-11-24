import XCTest
@testable import C64Core

final class CartridgeTests: XCTestCase {
    /// Builds a CRT file: header with type and EXROM/GAME, then one CHIP packet per (bank, load, data).
    static func crt(type: Int, exrom: UInt8, game: UInt8, chips: [(Int, Int, [UInt8])]) -> [UInt8] {
        var d = Array("C64 CARTRIDGE   ".utf8) + [0, 0, 0, 0x40, 1, 0, UInt8(type >> 8), UInt8(type & 0xFF), exrom, game]
        d += [UInt8](repeating: 0, count: 6)
        d += Array("TEST".utf8) + [UInt8](repeating: 0, count: 28)
        for (bank, load, rom) in chips {
            let total = 0x10 + rom.count
            d += Array("CHIP".utf8) + [0, 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0,
                                       UInt8(bank >> 8), UInt8(bank & 0xFF), UInt8(load >> 8), UInt8(load & 0xFF),
                                       UInt8(rom.count >> 8), UInt8(rom.count & 0xFF)] + rom
        }
        return d
    }

    /// An 8K ROM at $8000 that autostarts (CBM80) and stores $42 at $C000, then loops.
    static func autostartROM() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 0x2000)
        let code: [UInt8] = [0x09, 0x80, 0x09, 0x80, 0xC3, 0xC2, 0xCD, 0x38, 0x30,
                             0xA9, 0x42, 0x8D, 0x00, 0xC0, 0x4C, 0x0E, 0x80]
        r.replaceSubrange(0..<code.count, with: code)
        return r
    }

    func machine() throws -> C64 {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        return C64(basic: roms.basic, kernal: roms.kernal, chargen: roms.chargen)
    }

    func testParseAndUnsupported() throws {
        let c = try Cartridge(crt: CartridgeTests.crt(type: 0, exrom: 0, game: 1, chips: [(0, 0x8000, CartridgeTests.autostartROM())]))
        XCTAssertEqual(c.name, "TEST")
        XCTAssertEqual(c.mode, .k8)
        XCTAssertThrowsError(try Cartridge(crt: CartridgeTests.crt(type: 1, exrom: 0, game: 0, chips: [(0, 0x8000, [0])])))
        XCTAssertThrowsError(try Cartridge(crt: [1, 2, 3]))
    }

    func testNormal8KAutostarts() throws {
        let c64 = try machine()
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 0, exrom: 0, game: 1,
                                                                   chips: [(0, 0x8000, CartridgeTests.autostartROM())])))
        for _ in 0..<20 { c64.runFrame() }
        XCTAssertEqual(c64.ram[0xC000], 0x42)
        XCTAssertEqual(c64.cpu.pc & 0xE000, 0x8000)
        c64.poke(0x8000, 0x99)                                    // writes go to the RAM below
        XCTAssertEqual(c64.ram[0x8000], 0x99)
        XCTAssertEqual(c64.peek(0x8004), 0xC3)
        c64.attachCartridge(nil)
        for _ in 0..<150 { c64.runFrame() }
        XCTAssertTrue(c64.screenText().joined().contains("BASIC BYTES FREE"))
    }

    func testUltimaxBootsFromROMH() throws {
        var rom = [UInt8](repeating: 0xEA, count: 0x2000)
        let code: [UInt8] = [0xA9, 0x42, 0x8D, 0x00, 0x08, 0x4C, 0x05, 0xE0]  // LDA #$42; STA $0800; JMP *
        rom.replaceSubrange(0..<code.count, with: code)
        rom[0x1FFC] = 0x00; rom[0x1FFD] = 0xE0
        rom[0x1000] = 0x5C
        let c64 = try machine()
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 0, exrom: 1, game: 0, chips: [(0, 0xE000, rom)])))
        for _ in 0..<5 { c64.runFrame() }
        XCTAssertEqual(c64.ram[0x0800], 0x42)
        XCTAssertEqual(c64.peek(0x4000), 0xFF)                     // open bus in Ultimax
        XCTAssertEqual(c64.vicFetch(0x3000), 0x5C)                 // the VIC sees ROMH $F000-$FFFF at $3000
    }

    func testBankSwitchingTypes() throws {
        func banks(_ n: Int, at load: Int) -> [(Int, Int, [UInt8])] {
            (0..<n).map { b in (b, load, [UInt8](repeating: UInt8(0x10 + b), count: 0x2000)) }
        }
        let c64 = try machine()
        // Ocean (16K, 32 banks): ROMH shows the same bank as ROML.
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 5, exrom: 0, game: 0, chips: banks(32, at: 0x8000))))
        c64.poke(0xDE00, 3)
        XCTAssertEqual(c64.peek(0x8000), 0x13)
        XCTAssertEqual(c64.peek(0xA000), 0x13)
        // Magic Desk: bit 7 switches the cartridge off.
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 19, exrom: 0, game: 1, chips: banks(8, at: 0x8000))))
        c64.poke(0xDE00, 5)
        XCTAssertEqual(c64.peek(0x9000), 0x15)
        c64.ram[0x9000] = 0x77
        c64.poke(0xDE00, 0x80)
        XCTAssertEqual(c64.peek(0x9000), 0x77)
        // EasyFlash: Ultimax at reset, 16K and banks through $DE00/$DE02, RAM at $DF00.
        let ef = banks(4, at: 0x8000) + (0..<4).map { b in (b, 0xA000, [UInt8](repeating: UInt8(0x20 + b), count: 0x2000)) }
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 32, exrom: 1, game: 0, chips: ef)))
        XCTAssertEqual(c64.cartridge?.mode, .ultimax)
        c64.poke(0xDE02, 0x07)
        c64.poke(0xDE00, 2)
        XCTAssertEqual(c64.peek(0x8000), 0x12)
        XCTAssertEqual(c64.peek(0xA000), 0x22)
        c64.poke(0xDF10, 0x5A)
        XCTAssertEqual(c64.peek(0xDF10), 0x5A)
        c64.poke(0xDE02, 0x04)
        XCTAssertEqual(c64.cartridge?.mode, .off)
    }

    /// A C64 cartridge in a C128: the KERNAL sees GAME/EXROM through $D505 and starts C64 mode.
    func testC128GoesToC64ModeWithCartridge() throws {
        guard let roms = ROMSet.load(), let c128 = roms.c128 else { throw XCTSkip("C128 ROMs not installed") }
        let c64 = C64(basic: roms.basic, kernal: roms.kernal, chargen: roms.chargen)
        c64.setC128(c128)
        c64.attachCartridge(try Cartridge(crt: CartridgeTests.crt(type: 0, exrom: 0, game: 1,
                                                                   chips: [(0, 0x8000, CartridgeTests.autostartROM())])))
        for _ in 0..<60 { c64.runFrame() }
        XCTAssertFalse(c64.isC128)
        XCTAssertEqual(c64.ram[0xC000], 0x42)
    }
}
