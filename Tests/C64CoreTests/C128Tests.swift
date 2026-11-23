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

    /// Disk access in C128 mode goes through the true-emulated 1541 (no Instant Load): a C64 BASIC
    /// program loads (relocated to $1C01) and runs, a new program saves, and DIRECTORY lists both.
    func testDiskLoadSaveInC128Mode() throws {
        guard let roms = ROMSet.load(), let c128 = roms.c128, roms.drive1541 != nil else {
            throw XCTSkip("C128 or 1541 ROMs not installed")
        }
        let c64 = C64(roms: roms)
        let disk = GCRDisk(d64: {
            let d = D64Image.blank(name: "C128 DISK", id: "28")
            d.addFile(name: "HELLO", contents: DriveTests.helloPRG("LOADED ON 128"))
            return d
        }())
        c64.drive8!.insert(disk)
        c64.setC128(c128)                                      // boots, checks drive 8 for a boot disk
        /// Types a command and runs until a new READY. appears (and `text` shows, if given).
        func run(_ command: String, expect text: String? = nil, frames: Int = 4000) -> Bool {
            let before = screen(c64).components(separatedBy: "READY.").count
            c64.queueTyping(command + "\n")
            for _ in 0..<frames {
                c64.runFrame()
                let s = screen(c64)
                if s.components(separatedBy: "READY.").count > before && (text.map(s.contains) ?? true) { return true }
            }
            return false
        }
        for _ in 0..<600 { c64.runFrame() }
        XCTAssertTrue(screen(c64).contains("READY."), screen(c64))
        XCTAssertTrue(run("LOAD\"HELLO\",8", expect: "LOADING"), screen(c64))
        XCTAssertTrue(run("RUN", expect: "LOADED ON 128"), screen(c64))
        c64.typeIntoBuffer("\u{93}")                                // clear screen
        for _ in 0..<20 { c64.runFrame() }
        XCTAssertTrue(run("NEW"), screen(c64))
        c64.queueTyping("10 PRINT\"SAVED ON 128\"\n")           // a program line prints no READY.
        for _ in 0..<100 { c64.runFrame() }
        XCTAssertTrue(run("SAVE\"MY128\",8", expect: "SAVING"), screen(c64))
        XCTAssertFalse(screen(c64).contains("ERROR"), screen(c64))
        let entries = disk.toD64().directory()
        XCTAssertEqual(entries.map(\.name), ["HELLO", "MY128"], screen(c64))
        if let e = entries.last {
            XCTAssertEqual(Array(disk.toD64().readFile(e).prefix(2)), [0x01, 0x1C])     // C128 BASIC start
        }
    }

    /// A disk with a C128 boot sector (track 1 sector 0, "CBM") auto-starts at power-on:
    /// the KERNAL prints "BOOTING <name>..." and runs the boot code in the sector.
    func testAutobootDisk() throws {
        guard let roms = ROMSet.load(), let c128 = roms.c128, roms.drive1541 != nil else {
            throw XCTSkip("C128 or 1541 ROMs not installed")
        }
        let d = D64Image.blank(name: "BOOT DISK", id: "28")
        var sector = [UInt8](repeating: 0, count: 256)
        let header: [UInt8] = [0x43, 0x42, 0x4D, 0, 0, 0, 0] + Array("AUTO".utf8) + [0] + [0]   // CBM, no load, title, no file
        sector.replaceSubrange(0..<header.count, with: header)
        // Boot code: print "BOOT OK" and return to BASIC.
        let message = Array("BOOT OK".utf8) + [13]
        var code: [UInt8] = []
        for ch in message { code += [0xA9, ch, 0x20, 0xD2, 0xFF] }     // LDA #ch / JSR CHROUT
        code.append(0x60)                                              // RTS
        sector.replaceSubrange(header.count..<header.count + code.count, with: code)
        d.setSector(1, 0, sector)
        let c64 = C64(roms: roms)
        c64.drive8!.insert(GCRDisk(d64: d))
        c64.setC128(c128)
        var s = ""
        for _ in 0..<1500 {
            c64.runFrame()
            s = screen(c64)
            if s.contains("BOOT OK") { break }
        }
        XCTAssertTrue(s.contains("BOOTING AUTO"), s)
        XCTAssertTrue(s.contains("BOOT OK"), s)
    }
}
