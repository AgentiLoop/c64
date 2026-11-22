import XCTest
@testable import C64Core

final class SIDTests: XCTestCase {
    func testSawtoothProducesSignal() {
        let sid = SID()
        sid.write(0x18, 0x0F)        // volume 15
        sid.write(0x00, 0x00); sid.write(0x01, 0x1C)   // ~440 Hz
        sid.write(0x05, 0x00); sid.write(0x06, 0xF0)   // A=0 D=0 S=15 R=0
        sid.write(0x04, 0x21)        // sawtooth + gate
        for _ in 0..<98_524 { sid.tick() }   // 0.1 s
        let s = sid.takeSamples()
        XCTAssertEqual(s.count, 4410, accuracy: 2)
        let peak = s.suffix(2000).map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertFalse(s.contains { $0.isNaN })
    }

    func testEnvelopeReleasesToSilence() {
        let sid = SID()
        sid.write(0x18, 0x0F)
        sid.write(0x01, 0x1C)
        sid.write(0x06, 0xF0)
        sid.write(0x04, 0x11)        // triangle + gate
        for _ in 0..<20_000 { sid.tick() }
        XCTAssertEqual(sid.voices[0].level, 0xFF)
        sid.write(0x04, 0x10)        // gate off, release 0 (6 ms)
        for _ in 0..<50_000 { sid.tick() }
        XCTAssertEqual(sid.voices[0].level, 0)
    }
}
