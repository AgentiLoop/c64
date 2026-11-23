import XCTest
@testable import C64Core

/// Diagnostic (runs only with C128_BOOT_D64 set to a C128 boot disk): inserts the disk into a C128
/// that is already at READY and types BOOT, as the app does, then prints the 40- and 80-column screens.
/// Slow in debug builds; use `swift test -c release -Xswiftc -enable-testing --filter TmpBucketProbe`.
final class TmpBucketProbe: XCTestCase {
    func testBootDiskOnRunningC128() throws {
        guard let path = ProcessInfo.processInfo.environment["C128_BOOT_D64"] else { throw XCTSkip("C128_BOOT_D64 not set") }
        guard let roms = ROMSet.load(), let c128 = roms.c128 else { throw XCTSkip("C128 ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = true
        c64.setC128(c128)
        for _ in 0..<300 { c64.runFrame() }
        let img = try XCTUnwrap(D64Image(data: [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))))
        c64.drive8?.insert(GCRDisk(d64: img), side1: nil)
        C64Autostart.ensureBooted(c64)
        c64.queueTyping("BOOT\n")
        for _ in 0..<(60 * 45) { c64.runFrame() }
        print("40 COLUMNS:\n" + c64.screenText().joined(separator: "\n"))
        print("80 COLUMNS:\n" + c64.vdcText().joined(separator: "\n"))
        XCTAssertTrue(c64.screenText().joined().contains("BOOTING"))
    }
}
