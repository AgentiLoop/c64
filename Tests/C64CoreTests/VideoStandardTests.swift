import XCTest
@testable import C64Core

final class VideoStandardTests: XCTestCase {
    func machine(_ s: VideoStandard) throws -> C64 {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        if s != .pal { c64.standard = s }
        for _ in 0..<180 { c64.runFrame() }
        return c64
    }

    func testPALDefault() throws {
        let c64 = try machine(.pal)
        XCTAssertEqual(c64.vic.linesPerFrame, 312)
        XCTAssertEqual(c64.frameCycles, 19_656)
        XCTAssertEqual(c64.ram[0x2A6], 1, "KERNAL should detect PAL")
        XCTAssertTrue(c64.screenText().joined().contains("READY."))
    }

    func testNTSCBootsAndIsDetected() throws {
        let c64 = try machine(.ntsc)
        XCTAssertEqual(c64.vic.cyclesPerLine, 65)
        XCTAssertEqual(c64.vic.linesPerFrame, 263)
        XCTAssertEqual(c64.clockHz, 1_022_727)
        XCTAssertEqual(c64.ram[0x2A6], 0, "KERNAL should detect NTSC")
        let screen = c64.screenText().joined(separator: "\n")
        XCTAssertTrue(screen.contains("38911 BASIC BYTES FREE"), screen)
        // About 60 frames per emulated second.
        let fps = Double(c64.clockHz) / Double(c64.frameCycles)
        XCTAssertEqual(fps, 59.83, accuracy: 0.05)
        // BASIC and the keyboard work.
        c64.queueTyping("PRINT 6*7\n")
        for _ in 0..<30 { c64.runFrame() }
        XCTAssertTrue(c64.screenText().joined().contains(" 42"))
    }

    /// The 1541 must keep working: its 1 MHz clock is tied to the NTSC C64 clock.
    func testNTSCDiskLoad() throws {
        let c64 = try machine(.ntsc)
        guard c64.drive8 != nil else { throw XCTSkip("no 1541 ROM") }
        let d = D64Image.blank(name: "NTSC", id: "01")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("NTSC OK"))
        c64.drive8!.insert(GCRDisk(d64: d))
        c64.queueTyping("LOAD\"HELLO\",8\nRUN\n")
        for _ in 0..<3000 where !c64.screenText().joined().contains("NTSC OK ") { c64.runFrame() }
        XCTAssertTrue(c64.screenText().joined(separator: "\n").contains("\nNTSC OK"),
                      c64.screenText().joined(separator: "\n"))
    }

    func testSwitchBackToPAL() throws {
        let c64 = try machine(.ntsc)
        c64.standard = .pal
        for _ in 0..<180 { c64.runFrame() }
        XCTAssertEqual(c64.ram[0x2A6], 1)
        XCTAssertEqual(c64.clockHz, C64.palClock)
    }

    /// $C100: raster IRQ on line 280 (PAL only), counting IRQs in $C000; CIA IRQs off.
    static let lateRasterIRQ: [UInt8] = [0x00, 0xC1,
        0x78, 0xA9, 0x7F, 0x8D, 0x0D, 0xDC, 0xAD, 0x0D, 0xDC,           // SEI, CIA1 IRQs off
        0xA9, 0x26, 0x8D, 0x14, 0x03, 0xA9, 0xC1, 0x8D, 0x15, 0x03,     // vector → $C126
        0xA9, 0x9B, 0x8D, 0x11, 0xD0, 0xA9, 0x18, 0x8D, 0x12, 0xD0,     // compare line $118 = 280
        0xA9, 0x01, 0x8D, 0x1A, 0xD0, 0x58, 0x4C, 0x23, 0xC1,           // raster IRQ on, CLI, loop
        0xEE, 0x00, 0xC0, 0xA9, 0xFF, 0x8D, 0x19, 0xD0, 0x4C, 0x81, 0xEA, // IRQ: INC $C000, ack, exit
    ]

    /// Auto: a raster IRQ on a line only PAL has switches the running machine to PAL (without a
    /// reset, so the program keeps running and its IRQ fires); NTSC returns once the program stops
    /// using such lines, and on reset.
    func testAutoStandardFollowsTheProgram() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.autoStandard = true
        for _ in 0..<180 { c64.runFrame() }
        XCTAssertEqual(c64.standard, .ntsc, "BASIC alone stays NTSC")
        XCTAssertEqual(c64.ram[0x2A6], 0)

        c64.loadPRG(VideoStandardTests.lateRasterIRQ)
        c64.queueTyping("SYS49408\n")
        for _ in 0..<30 { c64.runFrame() }
        XCTAssertEqual(c64.standard, .pal)
        XCTAssertEqual(c64.clockHz, C64.palClock)
        XCTAssertEqual(c64.sid.clockHz, C64.palClock)
        let before = c64.ram[0xC000]
        for _ in 0..<10 { c64.runFrame() }
        XCTAssertEqual(c64.ram[0xC000] &- before, 10, "one line-280 IRQ per PAL frame")

        c64.poke(0xD01A, 0)                                   // the program moves on
        for _ in 0..<160 { c64.runFrame() }
        XCTAssertEqual(c64.standard, .ntsc)
        XCTAssertEqual(c64.clockHz, C64.ntscClock)

        c64.poke(0xD01A, 1)
        for _ in 0..<5 { c64.runFrame() }
        XCTAssertEqual(c64.standard, .pal)
        c64.reset()
        XCTAssertEqual(c64.standard, .ntsc, "reset starts as NTSC again")
        XCTAssertTrue(c64.autoStandard)
    }

    /// Auto: the same late raster IRQ armed while interrupts stay off (loaders leave junk in
    /// $D01A/$D012 under SEI) is not a program waiting for a PAL line: stays NTSC.
    func testAutoIgnoresRasterIRQArmedWithInterruptsOff() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.autoStandard = true
        for _ in 0..<180 { c64.runFrame() }
        var prg = VideoStandardTests.lateRasterIRQ
        XCTAssertEqual(prg[2 + 0x22], 0x58)
        prg[2 + 0x22] = 0xEA                                    // CLI -> NOP
        c64.loadPRG(prg)
        c64.queueTyping("SYS49408\n")
        for _ in 0..<60 { c64.runFrame() }
        XCTAssertTrue(c64.cpu.i)
        XCTAssertEqual(c64.standard, .ntsc)
        XCTAssertFalse(c64.cpu.jammed)
    }

    /// $C000: screen off, then every frame from line 50 a 100-line raster-bar loop that writes $D020
    /// every `lineCycles` cycles (cycle-counted for a PAL (63) or NTSC (65) machine).
    static func rasterBars(lineCycles: Int) -> [UInt8] {
        let nops = (lineCycles - 9) / 2                          // STX abs 4 + DEX 2 + BNE 3, NOP 2
        var p: [UInt8] = [0x00, 0xC0, 0x78, 0xA9, 0x0B, 0x8D, 0x11, 0xD0]
        p += [0xAD, 0x12, 0xD0, 0xC9, 0x32, 0xD0, 0xF9]          // $C006: LDA $D012, CMP #50, BNE
        p += [0xA2, 0x64, 0x8E, 0x20, 0xD0] + [UInt8](repeating: 0xEA, count: nops)
        p += [0xCA, 0xD0, UInt8(256 - (nops + 6)), 0x4C, 0x06, 0xC0]
        return p
    }

    /// Auto recognises cycle-counted raster bars: PAL-timed bars on the NTSC machine switch it to
    /// PAL (and it stays there); NTSC-timed bars keep NTSC.
    func testAutoStandardRecognisesRasterBarTiming() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        for (cycles, expected) in [(63, VideoStandard.pal), (65, .ntsc)] {
            let c64 = C64(roms: roms)
            c64.autoStandard = true
            for _ in 0..<120 { c64.runFrame() }
            c64.loadPRG(VideoStandardTests.rasterBars(lineCycles: cycles))
            c64.queueTyping("SYS49152\n")
            for _ in 0..<300 { c64.runFrame() }
            XCTAssertEqual(c64.standard, expected, "\(cycles)-cycle bars")
        }
    }
}
