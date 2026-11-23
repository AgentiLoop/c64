import XCTest
@testable import C64Core

/// Regression tests for live input and independent video timing.
final class ResponsivenessTests: XCTestCase {
    func roms() throws -> ROMSet {
        guard let r = ROMSet.load() else { throw XCTSkip("C64 ROMs not installed") }
        return r
    }

    func testLiveKeysApplyImmediately() throws {
        let c64 = C64(roms: try roms())
        c64.setKey(.a, pressed: true)
        c64.setKey(.b, pressed: true)
        for k in [C64Key.a, .b] {
            let (row, col) = k.matrix
            XCTAssertNotEqual(c64.keyMatrix[row] & (1 << col), 0, "\(k) not pressed immediately")
        }
        c64.setKey(.a, pressed: false)
        let (row, col) = C64Key.a.matrix
        XCTAssertEqual(c64.keyMatrix[row] & (1 << col), 0, "release delayed")
    }

    func testQueuedTypingWorksWithCycleSlices() throws {
        let c64 = C64(roms: try roms())
        for _ in 0..<150 { c64.runFrame() }
        c64.queueTyping("PRINT 6*7\n")
        for _ in 0..<(20 * 8) { c64.run(cycles: c64.frameCycles / 8) }
        XCTAssertTrue(c64.screenText().joined(separator: "\n").contains(" 42"))
    }

    func testVDCPictureCountAdvancesOnItsOwnCadence() throws {
        let r = try roms()
        guard let c128 = r.c128 else { throw XCTSkip("C128 ROMs not installed") }
        let c = C64(roms: r)
        c.setC128(c128)
        c.key4080Down = true
        c.reset()
        for _ in 0..<60 { c.runFrame() }
        let vic0 = c.vic.frameCount, vdc0 = c.vdcPictureCount
        for _ in 0..<100 { c.runFrame() }
        XCTAssertEqual(c.vic.frameCount - vic0, 100)
        let pictures = c.vdcPictureCount - vdc0
        XCTAssertGreaterThan(pictures, 0)
        print("VIC frames 100, VDC pictures \(pictures)")
    }
}
