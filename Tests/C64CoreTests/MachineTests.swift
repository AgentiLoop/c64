import XCTest
@testable import C64Core

final class MachineTests: XCTestCase {
    func makeMachine() throws -> C64 {
        guard let roms = ROMSet.load() else { throw XCTSkip("C64 ROMs not installed") }
        return C64(roms: roms)
    }

    func testBootsToBASIC() throws {
        let c64 = try makeMachine()
        for _ in 0..<150 { c64.runFrame() }
        let screen = c64.screenText().joined(separator: "\n")
        XCTAssertTrue(screen.contains("**** COMMODORE 64 BASIC V2 ****"), screen)
        XCTAssertTrue(screen.contains("38911 BASIC BYTES FREE"), screen)
        XCTAssertTrue(screen.contains("READY."), screen)
    }

    func testTypingBASIC() throws {
        let c64 = try makeMachine()
        for _ in 0..<150 { c64.runFrame() }
        c64.typeIntoBuffer("PRINT 6*7\n")
        for _ in 0..<20 { c64.runFrame() }
        let screen = c64.screenText().joined(separator: "\n")
        XCTAssertTrue(screen.contains(" 42"), screen)
    }

    func testKeyboardMatrix() throws {
        let c64 = try makeMachine()
        for _ in 0..<150 { c64.runFrame() }
        for key in [C64Key.h, .i] {
            c64.setKey(key, pressed: true)
            for _ in 0..<3 { c64.runFrame() }
            c64.setKey(key, pressed: false)
            for _ in 0..<3 { c64.runFrame() }
        }
        let screen = c64.screenText().joined(separator: "\n")
        XCTAssertTrue(screen.contains("HI"), screen)
    }

    func testFrameSpeed() throws {
        let c64 = try makeMachine()
        let t = Date()
        for _ in 0..<250 { c64.runFrame() }
        let secs = Date().timeIntervalSince(t)
        print("250 frames (5 s emulated) took \(secs) s")
        XCTAssertLessThan(secs, 5)
    }
}
