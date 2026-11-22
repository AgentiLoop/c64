import XCTest
@testable import C64Core

final class C128Tests: XCTestCase {
    func makeMachine() throws -> C64 {
        guard let roms = ROMSet.load(), let c128 = roms.c128 else { throw XCTSkip("C128 ROMs not installed") }
        let c64 = C64(basic: roms.basic, kernal: roms.kernal, chargen: roms.chargen)   // no drives: no boot attempt
        c64.setC128(c128)
        return c64
    }

    func screen(_ c64: C64) -> String { c64.screenText().joined(separator: "\n") }

    func testBootsToBASIC7() throws {
        let c64 = try makeMachine()
        XCTAssertTrue(c64.isC128)
        for _ in 0..<300 { c64.runFrame() }
        let s = screen(c64)
        XCTAssertTrue(s.contains("COMMODORE BASIC V7.0 122365 BYTES FREE"), s)
        XCTAssertTrue(s.contains("READY."), s)
    }

    func testBASIC7RunsAndUsesBothBanks() throws {
        let c64 = try makeMachine()
        for _ in 0..<300 { c64.runFrame() }
        c64.queueTyping("10 A$=\"C128 MODE\":PRINT A$;6*7\nRUN\n")
        for _ in 0..<200 { c64.runFrame() }
        XCTAssertTrue(screen(c64).contains("C128 MODE 42"), screen(c64))
        // BASIC 7 keeps program text in bank 0 and variables in bank 1.
        let m = c64.c128!
        XCTAssertTrue(m.ram1.indices.contains { i in i + 1 < m.ram1.count && m.ram1[i] == 0x41 && m.ram1[i + 1] == 0x80 },
                      "string variable A$ not found in bank 1")
        // Switching back to the C64 boots BASIC V2.
        c64.setC128(nil)
        for _ in 0..<150 { c64.runFrame() }
        XCTAssertTrue(screen(c64).contains("38911 BASIC BYTES FREE"), screen(c64))
    }

    func testMMURegisters() throws {
        let c64 = try makeMachine()
        for _ in 0..<300 { c64.runFrame() }
        c64.poke(0xD501, 0x3F)                    // preset A: all RAM, bank 0
        c64.poke(0xFF01, 0)                       // load it (any value)
        XCTAssertEqual(c64.peek(0xFF00), 0x3F)
        c64.ram[0x9000] = 0x5A
        XCTAssertEqual(c64.peek(0x9000), 0x5A)    // RAM, not BASIC ROM
        c64.poke(0xFF00, 0x7F)                    // bank 1
        c64.poke(0x9000, 0xA5)
        XCTAssertEqual(c64.c128!.ram1[0x9000], 0xA5)
        XCTAssertEqual(c64.ram[0x9000], 0x5A)
        c64.poke(0xFF00, 0)
        XCTAssertEqual(c64.peek(0xD50B), 0x20)    // MMU version: 128K
    }
}
