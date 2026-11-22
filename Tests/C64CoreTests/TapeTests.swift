import XCTest
@testable import C64Core

final class TapeTests: XCTestCase {
    func testTAPRoundTrip() {
        let pulses: [UInt32] = [384, 536, 696, 2048, 100_000, 8]
        let tap = Datasette.makeTAP(pulses)
        XCTAssertEqual(Datasette.parseTAP(tap), pulses)
    }

    func testT64Parse() {
        var d = [UInt8](repeating: 0, count: 0x60)
        for (i, c) in "C64 tape image file".utf8.enumerated() { d[i] = c }
        d[0x22] = 1; d[0x24] = 1
        d[0x40] = 1; d[0x41] = 0x82
        d[0x42] = 0x01; d[0x43] = 0x08; d[0x44] = 0x05; d[0x45] = 0x08
        d[0x48] = 0x60
        for (i, c) in "GAME".utf8.enumerated() { d[0x50 + i] = c }
        d += [1, 2, 3, 4]
        let files = T64Archive.files(d)
        XCTAssertEqual(files?.first?.name, "GAME")
        XCTAssertEqual(files?.first?.prg, [0x01, 0x08, 1, 2, 3, 4])
    }

    func makeMachine() throws -> C64 {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.drive8 = nil          // tape only: faster
        for _ in 0..<150 { c64.runFrame() }
        return c64
    }

    func run(_ c64: C64, _ line: String, frames: Int) -> String {
        let count = { c64.screenText().joined(separator: "\n").components(separatedBy: "READY.").count }
        let before = count()
        c64.queueTyping(line + "\n")
        for _ in 0..<frames {
            c64.runFrame()
            if count() > before { break }
        }
        return c64.screenText().joined(separator: "\n")
    }

    /// SAVE a BASIC program to tape through the KERNAL, rewind, NEW, LOAD it back, RUN.
    func testSaveAndLoadThroughKERNAL() throws {
        let c64 = try makeMachine()
        c64.datasette.insert(pulses: [])
        _ = run(c64, "10 PRINT \"TAPE OK\"", frames: 50)
        c64.datasette.mode = .recording
        var screen = run(c64, "SAVE\"PROG\"", frames: 4000)
        XCTAssertTrue(screen.contains("SAVING PROG"), screen)
        XCTAssertGreaterThan(c64.datasette.pulses.count, 10_000)
        XCTAssertTrue(c64.datasette.dirty)

        // Survive a trip through the TAP file format too.
        let pulses = Datasette.parseTAP(c64.datasette.tapData())!
        c64.datasette.insert(pulses: pulses)
        _ = run(c64, "NEW", frames: 50)
        c64.datasette.mode = .playing
        screen = run(c64, "LOAD", frames: 5000)
        XCTAssertTrue(screen.contains("FOUND PROG"), screen)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        screen = run(c64, "RUN", frames: 100)
        XCTAssertTrue(screen.contains("TAPE OK"), screen)
    }
}

extension TapeTests {
    /// The app's tape autostart: queue LOAD + RUN together with PLAY pressed.
    func testAutostartFromTape() throws {
        let c64 = try makeMachine()
        c64.datasette.insert(pulses: [])
        _ = run(c64, "10 PRINT \"AUTO RUN\"", frames: 50)
        c64.datasette.mode = .recording
        _ = run(c64, "SAVE\"A\"", frames: 4000)
        c64.datasette.rewind()
        _ = run(c64, "NEW", frames: 50)
        c64.datasette.mode = .playing
        c64.queueTyping("LOAD\nRUN\n")
        for _ in 0..<5000 {
            c64.runFrame()
            if c64.screenText().joined().contains("AUTO RUN ") { break }
        }
        let screen = c64.screenText().joined(separator: "\n")
        XCTAssertTrue(screen.contains("\nAUTO RUN"), screen)
    }
}

extension TapeTests {
    /// Writes a KERNAL-recorded TAP to $C64_WRITE_TAP (used to make app test media).
    func testWriteSampleTAP() throws {
        guard let path = ProcessInfo.processInfo.environment["C64_WRITE_TAP"] else { throw XCTSkip("no output path") }
        let c64 = try makeMachine()
        c64.datasette.insert(pulses: [])
        _ = run(c64, "10 PRINT \"LOADED FROM TAPE\"", frames: 50)
        c64.datasette.mode = .recording
        _ = run(c64, "SAVE\"TAPEPROG\"", frames: 4000)
        try Data(c64.datasette.tapData()).write(to: URL(fileURLWithPath: path))
    }
}
