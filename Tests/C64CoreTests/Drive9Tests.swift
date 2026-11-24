import XCTest
@testable import C64Core

/// Two 1541s (devices 8 and 9) on the bus at the same time, for games that come on two disks.
final class Drive9Tests: XCTestCase {
    private func disk(_ name: String, _ marker: UInt8) -> GCRDisk {
        let img = D64Image.blank(name: name)
        XCTAssertTrue(img.addFile(name: "DATA", contents: [0x00, 0xC0, marker, marker &+ 1, marker &+ 2]))
        return GCRDisk(d64: img)
    }

    private func load(_ c64: C64, device: Int) {
        c64.ram[0xC000] = 0; c64.ram[0xC001] = 0
        c64.queueTyping("LOAD\"DATA\",\(device),1\nNEW\n")   // NEW: LOAD,1 above BASIC moves its end pointer
        for _ in 0..<1500 { c64.runFrame() }
    }

    func testSecond1541OnDevice9() throws {
        guard let roms = ROMSet.load(), roms.drive1541 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = false
        XCTAssertTrue(c64.setDrive9Is1541(true))
        XCTAssertEqual(c64.drive9_1541?.deviceNumber, 9)
        XCTAssertNil(c64.drive9, "no 1581 on device 9 at the same time")
        c64.drive8!.insert(disk("DISK ONE", 0x11))
        c64.drive9_1541!.insert(disk("DISK TWO", 0x22))
        C64Autostart.ensureBooted(c64)

        load(c64, device: 9)
        XCTAssertEqual([c64.ram[0xC000], c64.ram[0xC001]], [0x22, 0x23], "loaded from the 1541 on device 9")
        load(c64, device: 8)
        XCTAssertEqual([c64.ram[0xC000], c64.ram[0xC001]], [0x11, 0x12], "drive 8 still answers as device 8")

        c64.fastLoad = true
        load(c64, device: 9)
        XCTAssertEqual([c64.ram[0xC000], c64.ram[0xC001]], [0x22, 0x23], "instant load reads drive 9's disk")

        c64.attach1581()
        XCTAssertNil(c64.drive9_1541, "plugging the 1581 in on device 9 unplugs the 1541")
    }
}
