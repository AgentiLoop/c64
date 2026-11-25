import XCTest
@testable import C64Core

/// Formatting and writing through the emulated 1541 (here on device 9) must leave a disk image
/// whose sectors are where the DOS put them, so it can be saved back as a D64.
final class DriveFormatTests: XCTestCase {
    private func run(_ c64: C64, _ text: String, _ frames: Int) {
        c64.queueTyping(text)
        for _ in 0..<frames { c64.runFrame() }
    }

    /// The DOS format bumps the head against the track 1 stop; the stepper phase keeps turning
    /// there, and the head must still step to the right tracks afterwards.
    func testFormatAndSaveOnDrive9() throws {
        guard let roms = ROMSet.load(), roms.drive1541 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = false
        c64.standard = .ntsc
        XCTAssertTrue(c64.setDrive9Is1541(true))
        c64.drive9_1541!.insert(GCRDisk(d64: D64Image.blank(name: "OLD")))
        C64Autostart.ensureBooted(c64)
        run(c64, "OPEN15,9,15,\"N:NEWDISK,AB\":CLOSE15\n", 6000)
        run(c64, "10 PRINT\"HELLO\"\nSAVE\"PROG\",9\n", 2000)
        let img = c64.drive9_1541!.disk!.toD64()
        XCTAssertEqual(img.diskName, "NEWDISK")
        XCTAssertEqual(img.directory().map(\.name), ["PROG"])
        XCTAssertEqual(img.directory().first.map { img.readFile($0) }?.prefix(2), [0x01, 0x08])
    }

    /// The same on drive 8: the stepper bug at the track 1 stop hit every 1541.
    func testFormatAndSaveOnDrive8() throws {
        guard let roms = ROMSet.load(), roms.drive1541 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = false
        c64.standard = .ntsc
        c64.drive8!.insert(GCRDisk(d64: D64Image.blank(name: "OLD")))
        C64Autostart.ensureBooted(c64)
        run(c64, "OPEN15,8,15,\"N:NEWDISK,AB\":CLOSE15\n", 6000)
        run(c64, "10 PRINT\"HELLO\"\nSAVE\"PROG\",8\n", 2000)
        let img = c64.drive8!.disk!.toD64()
        XCTAssertEqual(img.diskName, "NEWDISK")
        XCTAssertEqual(img.directory().map(\.name), ["PROG"])
        XCTAssertEqual(img.directory().first.map { img.readFile($0) }?.prefix(2), [0x01, 0x08])
    }
}
