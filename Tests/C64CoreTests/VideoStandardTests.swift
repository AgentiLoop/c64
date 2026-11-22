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
}
