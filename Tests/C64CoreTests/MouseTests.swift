import XCTest
@testable import C64Core

/// The 1351 mouse in port 1: POT registers carry the position (bits 1–6), handed out at most 31
/// counts per read so a driver never sees a wrap-around; the buttons are port 1's fire and up lines.
final class MouseTests: XCTestCase {
    func testPotRegistersAndButtons() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        for _ in 0..<120 { c64.runFrame() }
        XCTAssertEqual(c64.peek(0xD419), 0xFF, "no mouse: POTs float high")

        c64.mouse1351 = true
        XCTAssertEqual(c64.peek(0xD419), 0)
        c64.moveMouse(dx: 5, dy: -3)
        XCTAssertEqual(c64.peek(0xD419), 10)                  // 5 << 1
        XCTAssertEqual(c64.peek(0xD41A), UInt8(((-3) << 1) & 0x7E))

        // A fast sweep arrives in steps a driver can follow: every read moves at most 31 counts.
        c64.moveMouse(dx: 100, dy: 0)
        var last: UInt8 = 10, total = 0                     // the last read above
        for _ in 0..<5 {
            let v = c64.peek(0xD419)
            let d = Int((v &- last) & 0x7F) >> 1
            XCTAssertLessThanOrEqual(d, 31)
            total += d; last = v
        }
        XCTAssertEqual(total, 100)

        // Left button = fire (bit 4), right button = up (bit 0) on $DC01 with no key row selected.
        c64.poke(0xDC00, 0xFF)
        XCTAssertEqual(c64.peek(0xDC01) & 0x11, 0x11)
        c64.mouseLeft = true
        XCTAssertEqual(c64.peek(0xDC01) & 0x11, 0x01)
        c64.mouseLeft = false; c64.mouseRight = true
        XCTAssertEqual(c64.peek(0xDC01) & 0x11, 0x10)
        c64.mouse1351 = false
        XCTAssertEqual(c64.peek(0xDC01) & 0x11, 0x11, "buttons belong to the mouse")
    }
}
