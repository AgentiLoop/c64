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

    func testGO64SwitchesToC64() throws {
        let c64 = try makeMachine()
        var changed = false
        c64.onModelChanged = { changed = true }
        for _ in 0..<300 { c64.runFrame() }
        c64.queueTyping("GO64\nY\n")
        for _ in 0..<300 { c64.runFrame() }
        XCTAssertTrue(changed)
        XCTAssertFalse(c64.isC128)
        XCTAssertTrue(screen(c64).contains("38911 BASIC BYTES FREE"), screen(c64))
    }

    /// With the 40/80 key down the C128 starts on the VDC; BASIC works there and the picture is drawn.
    func testBootsIn80Columns() throws {
        let c64 = try makeMachine()
        c64.key4080Down = true
        c64.reset()
        for _ in 0..<300 { c64.runFrame() }
        XCTAssertTrue(c64.showing80Columns)
        var text = c64.vdcText().joined(separator: "\n")
        XCTAssertTrue(text.contains("COMMODORE BASIC V7.0 122365 BYTES FREE"), text)
        c64.queueTyping("PRINT \"EIGHTY COLUMNS\";6*7\n")
        for _ in 0..<100 { c64.runFrame() }
        text = c64.vdcText().joined(separator: "\n")
        XCTAssertTrue(text.contains("EIGHTY COLUMNS 42"), text)
        var frame: [UInt32] = []
        c64.renderVDC(into: &frame)
        XCTAssertEqual(frame.count, C64.vdcWidth * C64.vdcHeight)
        XCTAssertGreaterThan(Set(frame).count, 1)                     // text was drawn
        // The 40-column screen is still the VIC-II's; ESC X switches between them.
        c64.typeIntoBuffer("\u{1B}X")
        for _ in 0..<60 { c64.runFrame() }
        XCTAssertFalse(c64.showing80Columns)
    }

    /// FAST doubles the CPU speed (2 MHz), SLOW goes back to 1 MHz.
    func testFastRunsTwiceAsFast() throws {
        let c64 = try makeMachine()
        c64.key4080Down = true                                     // 80 columns, like FAST is used
        c64.reset()
        for _ in 0..<300 { c64.runFrame() }
        func frames(for command: String) -> Int {
            c64.queueTyping(command + ":FOR I=1 TO 1500:NEXT:PRINT \"DO\";\"NE\"\n")
            for f in 0..<2000 {
                c64.runFrame()
                if c64.vdcText().joined().contains("DONE") {
                    c64.typeIntoBuffer("\u{93}")                  // clear screen
                    for _ in 0..<20 { c64.runFrame() }
                    return f
                }
            }
            return 2000
        }
        let slow = frames(for: "SLOW")
        let fast = frames(for: "FAST")
        XCTAssertEqual(c64.peek(0xD030) & 1, 1)
        XCTAssertLessThan(Double(fast), Double(slow) * 0.65, "slow \(slow) fast \(fast)")
        _ = frames(for: "SLOW")
        XCTAssertEqual(c64.peek(0xD030) & 1, 0)
    }
}
