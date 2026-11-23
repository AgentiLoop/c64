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

    /// Boots in 80 columns and returns the machine with the VDC set up by the KERNAL.
    func make80() throws -> (C64, VDC8563) {
        let c64 = try makeMachine()
        c64.key4080Down = true
        c64.reset()
        for _ in 0..<300 { c64.runFrame() }
        return (c64, c64.c128!.vdc)
    }

    /// Two completed VDC frames after a change (the picture is drawn line by line as the beam runs).
    func settle(_ c64: C64) {
        let v = c64.c128!.vdc, start = v.frameCount
        while v.frameCount < start + 2 { c64.run(cycles: 100) }
    }

    /// VDC character height (R9/R23) and smooth scrolling (R24 vertical, R25 horizontal).
    func testVDCTallCharactersAndSmoothScroll() throws {
        let (c64, v) = try make80()
        XCTAssertEqual(c64.vdcPictureSize.width, 640)
        XCTAssertEqual(c64.vdcPictureSize.height, 200)
        // Stop the KERNAL from redrawing: SEI and an endless loop.
        c64.cpu.i = true
        let charset = Int(v.regs[28] & 0xE0) << 8
        let screen = Int(v.regs[12]) << 8 | Int(v.regs[13])
        let attrs = Int(v.regs[20]) << 8 | Int(v.regs[21])
        for i in 0..<2000 { v.poke(screen + i, 0x20); v.poke(attrs + i, 0x0F) }
        v.poke(screen, 1)
        for l in 0..<16 { v.poke(charset + 16 + l, l == 12 ? 0xFF : 0) }
        v.regs[9] = 15; v.regs[23] = 15
        settle(c64)
        var frame: [UInt32] = []
        c64.renderVDC(into: &frame)
        let w = c64.vdcPictureSize.width
        let white = VDC8563.rgbi[15]
        XCTAssertEqual(c64.vdcPictureSize.height, Int(v.regs[6]) * 16)
        XCTAssertEqual(frame[12 * w], white)
        XCTAssertNotEqual(frame[11 * w], white)
        // Vertical smooth scroll by 4 lines moves it up.
        v.regs[24] = (v.regs[24] & 0xE0) | 4
        settle(c64); c64.renderVDC(into: &frame)
        XCTAssertEqual(frame[8 * w], white)
        XCTAssertNotEqual(frame[12 * w], white)
        // Horizontal: two less than the cell width - 1 moves it 2 pixels left.
        let cellW = Int(v.regs[22] >> 4) + 1
        v.regs[25] = (v.regs[25] & 0xF0) | UInt8(cellW - 3)
        settle(c64); c64.renderVDC(into: &frame)
        XCTAssertEqual(frame[8 * w + 5], white)
        XCTAssertNotEqual(frame[8 * w + 6], white)
    }

    /// 40-column double-pixel bitmap mode with attribute colours, as Bucket Wars 128 uses it
    /// (R0 $3F, R1 40, R22 $89, R25 $D7, 100 rows of 2 lines): cells are 8 pixels (16 dots) wide
    /// with no gap, so a solid bitmap has no vertical stripes.
    func testVDCDoublePixelBitmapHasNoGaps() throws {
        let (c64, v) = try make80()
        c64.cpu.i = true
        let regs: [Int: UInt8] = [0: 0x3F, 1: 40, 2: 0x37, 4: 0x9F, 5: 0, 6: 100, 9: 1, 12: 0, 13: 0,
                                  20: 0x20, 21: 0, 22: 0x89, 23: 8, 24: 0, 25: 0xD7, 26: 0x00, 27: 0, 28: 0x20]
        for (r, x) in regs { v.regs[r] = x }
        for i in 0..<8000 { v.poke(i, 0xFF) }                       // solid bitmap
        for i in 0..<4000 { v.poke(0x2000 + i, 0x0D) }              // yellow on black
        settle(c64)
        var frame: [UInt32] = []
        c64.renderVDC(into: &frame)
        XCTAssertEqual(c64.vdcPictureSize.width, 640)
        XCTAssertEqual(c64.vdcPictureSize.height, 200)
        let yellow = VDC8563.rgbi[13]
        let gaps = frame.indices.filter { frame[$0] != yellow }.count
        XCTAssertEqual(gaps, 0, "non-yellow pixels in a solid double-pixel bitmap")
        // Attribute high nibble is the background colour in bitmap mode.
        for i in 0..<8000 { v.poke(i, 0x00) }
        for i in 0..<4000 { v.poke(0x2000 + i, 0x4D) }              // background green
        settle(c64); c64.renderVDC(into: &frame)
        XCTAssertTrue(frame.allSatisfy { $0 == VDC8563.rgbi[4] })
    }

    /// The beam: register changes take effect on the raster line they happen (a mid-frame colour
    /// split), and the status register reports vertical blank only outside the displayed rows.
    func testVDCRasterTiming() throws {
        let (c64, v) = try make80()
        c64.cpu.i = true
        v.regs[25] = 0x07                                           // text, no attributes
        v.regs[26] = 0x00                                           // black background
        settle(c64)
        // Wait for the start of a frame, run to about the middle of the displayed area, change R26.
        let start = v.frameCount
        while v.frameCount == start { c64.run(cycles: 1) }
        let lineCycles = Double(v.lineDots) / 16_000_000 * Double(c64.clockHz)
        c64.run(cycles: Int(lineCycles * 100))
        v.regs[26] = 0x04                                           // green background from here on
        let mid = v.frameCount
        while v.frameCount == mid { c64.run(cycles: 1) }
        var frame: [UInt32] = []
        c64.renderVDC(into: &frame)
        let w = c64.vdcPictureSize.width
        XCTAssertEqual(frame[10 * w + 600], VDC8563.rgbi[0], "top half keeps the old background")
        XCTAssertEqual(frame[190 * w + 600], VDC8563.rgbi[4], "bottom half has the new background")
        // Vertical blank flag: clear while displaying, set in the bottom border.
        var sawDisplay = false, sawBlank = false
        for _ in 0..<20000 {
            c64.run(cycles: 1)
            let st = v.read(0)
            if st & 0x20 == 0 { sawDisplay = true } else { sawBlank = true }
        }
        XCTAssertTrue(sawDisplay && sawBlank)
    }

    /// C128 + 1581: the KERNAL detects the fast drive and LOAD uses the fast serial (burst) bus
    /// (CIA serial registers on SRQ/DATA) instead of the bit-banged slow protocol.
    func testFastSerialLoadFrom1581() throws {
        guard let roms = ROMSet.load(), let c128 = roms.c128, roms.drive1581 != nil else {
            throw XCTSkip("C128 or 1581 ROMs not installed")
        }
        let payload = (0..<12000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }
        let d = D81Image.blank(name: "FAST", id: "81")
        XCTAssertTrue(d.addFile(name: "DATA", contents: [0x00, 0x30] + payload))   // loads at $3000
        let c64 = C64(roms: roms)
        c64.setC128(c128)
        XCTAssertNotNil(c64.attach1581())
        c64.drive9!.insert(d)
        var fastBytes = 0
        let host = c64.iec.hostFastSerialIn
        c64.iec.hostFastSerialIn = { b in fastBytes += 1; host?(b) }
        for _ in 0..<300 { c64.runFrame() }
        c64.queueTyping("BLOAD\"DATA\",U9,B0\n")
        var frames = 0
        for f in 0..<6000 {
            c64.runFrame()
            let s = screen(c64)
            if s.components(separatedBy: "READY.").count > 2 { frames = f; break }
        }
        let loaded = Array(c64.ram[0x3000..<0x3000 + payload.count])
        XCTAssertEqual(loaded, payload, screen(c64))
        XCTAssertGreaterThan(fastBytes, payload.count, "loaded over the slow bus (\(fastBytes) fast bytes)")
        print("1581 fast load: \(payload.count) bytes in \(frames) frames, \(fastBytes) fast serial bytes")
    }

    func make128With1571() throws -> C64 {
        guard let roms = ROMSet.load(), let c128 = roms.c128, roms.drive1571 != nil else {
            throw XCTSkip("C128 or 1571 ROMs not installed")
        }
        let c64 = C64(roms: roms)
        c64.setC128(c128)
        XCTAssertTrue(c64.drive8?.is1571 ?? false)                // a C128 has a 1571 on drive 8
        return c64
    }

    /// C128 + 1571: LOAD goes over the fast serial (burst) bus and the 1571 switches to 2 MHz.
    func testFastLoadFrom1571() throws {
        let c64 = try make128With1571()
        let payload = (0..<12000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        let d = D64Image.blank(name: "FAST 1571", id: "71")
        XCTAssertTrue(d.addFile(name: "DATA", contents: [0x00, 0x30] + payload))
        c64.drive8!.insert(GCRDisk(d64: d))
        var fastBytes = 0
        let host = c64.iec.hostFastSerialIn
        c64.iec.hostFastSerialIn = { b in fastBytes += 1; host?(b) }
        for _ in 0..<400 { c64.runFrame() }
        c64.queueTyping("BLOAD\"DATA\",B0\n")
        var frames = 0
        var saw2MHz = false
        for f in 0..<9000 {
            c64.runFrame()
            saw2MHz = saw2MHz || c64.drive8!.twoMHz
            if screen(c64).components(separatedBy: "READY.").count > 2 { frames = f; break }
        }
        XCTAssertEqual(Array(c64.ram[0x3000..<0x3000 + payload.count]), payload, screen(c64))
        XCTAssertGreaterThan(fastBytes, payload.count, "loaded over the slow bus (\(fastBytes) fast bytes)")
        XCTAssertTrue(saw2MHz)
        print("1571 fast load: \(payload.count) bytes in \(frames) frames, \(fastBytes) fast serial bytes")
    }

    /// D71: the 1571 reads the second side (track 36+ is head 1).
    func testD71SecondSide() throws {
        let c64 = try make128With1571()
        let side0 = D64Image.blank(name: "DOUBLE", id: "71")
        var bam = side0.sector(18, 0)
        bam[3] = 0x80                                              // double-sided disk
        side0.setSector(18, 0, bam)
        let side1 = D64Image(tracks: 35)
        side1.setSector(1, 0, [0x42, 0x43, 0x44] + [UInt8](repeating: 0x99, count: 253))  // track 36, sector 0
        let d71 = D71Image(side0: side0, side1: side1)
        XCTAssertNotNil(D71Image(data: d71.data))
        let (g0, g1) = d71.gcrSides()
        c64.drive8!.insert(g0, side1: g1)
        for _ in 0..<400 { c64.runFrame() }
        c64.queueTyping("10 OPEN15,8,15,\"I0\":OPEN2,8,2,\"#\":PRINT#15,\"U1 2 0 36 0\"\n"
                        + "20 INPUT#15,E:GET#2,A$,B$:PRINT \"SIDE1\";E;ASC(A$);ASC(B$):CLOSE2:CLOSE15\nRUN\n")
        for _ in 0..<2500 { c64.runFrame() }
        XCTAssertTrue(screen(c64).contains("SIDE1 0  66  67"), screen(c64))
    }

    /// A 1571 on a C64: it runs in 1541 mode, so a normal LOAD over the slow serial bus works.
    func test1571OnC64() throws {
        guard let roms = ROMSet.load(), roms.drive1571 != nil else { throw XCTSkip("1571 ROM not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = false
        c64.use1571OnC64 = true
        XCTAssertTrue(c64.drive8?.is1571 ?? false)
        let d = D64Image.blank(name: "C64 1571", id: "71")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("1571 ON C64"))
        c64.drive8!.insert(GCRDisk(d64: d))
        for _ in 0..<200 { c64.runFrame() }
        c64.queueTyping("LOAD\"HELLO\",8\n")
        for _ in 0..<3000 { c64.runFrame(); if screen(c64).components(separatedBy: "READY.").count > 2 { break } }
        c64.queueTyping("RUN\n")
        for _ in 0..<100 { c64.runFrame() }
        XCTAssertTrue(screen(c64).contains("1571 ON C64"), screen(c64))
        c64.use1571OnC64 = false
        XCTAssertFalse(c64.drive8?.is1571 ?? true)
    }
}
