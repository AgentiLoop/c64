import XCTest
@testable import C64Core

/// The app runs the machine in slices that end anywhere in a frame. The picture it hands to the
/// screen must be one whole frame: never the top of the frame being drawn over the bottom of the
/// last one (a moving scroller would look slanted at the split line).
final class FrameTearTests: XCTestCase {
    func testPublishedFrameIsNeverHalfDrawn() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        for _ in 0..<120 { c64.runFrame() }
        // $C000: SEI; wait for raster line 0; INC $D020; loop — a new border colour every frame.
        c64.loadPRG([0x00, 0xC0, 0x78,
                     0xAD, 0x12, 0xD0, 0xD0, 0xFB,         // $C001: LDA $D012 / BNE $C001
                     0xAD, 0x11, 0xD0, 0x30, 0xF6,         // LDA $D011 / BMI $C001 (line 256+)
                     0xEE, 0x20, 0xD0,                     // INC $D020
                     0xAD, 0x12, 0xD0, 0xF0, 0xFB,         // LDA $D012 / BEQ (leave line 0)
                     0x4C, 0x01, 0xC0])
        c64.queueTyping("SYS49152\n")
        for _ in 0..<30 { c64.runFrame() }
        c64.run(cycles: c64.frameCycles / 2)              // the slices now end mid-frame
        var frame = [UInt32]()
        for _ in 0..<5 {
            c64.run(cycles: c64.frameCycles)
            c64.vic.copyFrame(into: &frame)
            let top = frame[2 * VICII.screenWidth + 2]
            let bottom = frame[(VICII.screenHeight - 40) * VICII.screenWidth + 2]
            XCTAssertEqual(top, bottom, "border colours from two different frames")
        }
    }
}
