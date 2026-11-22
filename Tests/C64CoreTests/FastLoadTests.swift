import XCTest
@testable import C64Core

final class FastLoadTests: XCTestCase {
    func testPatternMatching() {
        XCTAssertTrue(C64.matches("HELLO", "*"))
        XCTAssertTrue(C64.matches("HELLO", "HE*"))
        XCTAssertTrue(C64.matches("HELLO", "H?LLO"))
        XCTAssertFalse(C64.matches("HELLO", "HELL"))
        XCTAssertFalse(C64.matches("HELLO", "WORLD"))
    }

    func machine() throws -> C64 {
        guard let roms = ROMSet.load(), roms.drive1541 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.fastLoad = true
        C64Autostart.ensureBooted(c64)
        return c64
    }

    func runUntilReady(_ c64: C64, _ line: String, frames: Int) -> (String, Int) {
        let count = { c64.screenText().joined(separator: "\n").components(separatedBy: "READY.").count }
        let before = count()
        c64.queueTyping(line + "\n")
        for f in 0..<frames {
            c64.runFrame()
            if count() > before { return (c64.screenText().joined(separator: "\n"), f) }
        }
        return (c64.screenText().joined(separator: "\n"), frames)
    }

    func testInstantBasicLoadAndRun() throws {
        let c64 = try machine()
        let d = D64Image.blank(name: "FAST", id: "01")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("FAST OK"))
        c64.drive8!.insert(GCRDisk(d64: d))
        let (_, frames) = runUntilReady(c64, "LOAD\"HEL*\",8", frames: 500)
        XCTAssertLessThan(frames, 50)     // typing + load, no serial transfer
        let (screen, _) = runUntilReady(c64, "RUN", frames: 100)
        XCTAssertTrue(screen.contains("FAST OK"), screen)
    }

    func testInstantBinaryLoadD64AndD81() throws {
        let c64 = try machine()
        let payload = (0..<12_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let d = D64Image.blank(name: "BIN", id: "01")
        d.addFile(name: "CODE", contents: [0x00, 0x30] + payload)
        c64.drive8!.insert(GCRDisk(d64: d))
        var (screen, frames) = runUntilReady(c64, "LOAD\"*\",8,1", frames: 500)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertLessThan(frames, 50)
        XCTAssertTrue(Array(c64.ram[0x3000..<0x3000 + payload.count]) == payload)

        guard c64.attach1581() != nil else { throw XCTSkip("no 1581 ROM") }
        let d81 = D81Image.blank(name: "B81", id: "81")
        let p2 = payload.reversed() as [UInt8]
        d81.addFile(name: "CODE2", contents: [0x00, 0x30] + p2)
        c64.drive9!.insert(d81)
        (screen, frames) = runUntilReady(c64, "LOAD\"CODE2\",9,1", frames: 500)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertTrue(Array(c64.ram[0x3000..<0x3000 + p2.count]) == p2)
    }

    /// Directory and missing files still go through the real drive.
    func testDirectoryAndMissingFileUseDrive() throws {
        let c64 = try machine()
        let d = D64Image.blank(name: "DIRTEST", id: "01")
        d.addFile(name: "A", contents: DriveTests.helloPRG("A"))
        c64.drive8!.insert(GCRDisk(d64: d))
        _ = runUntilReady(c64, "LOAD\"$\",8", frames: 3000)
        var (screen, _) = runUntilReady(c64, "LIST", frames: 200)
        XCTAssertTrue(screen.contains("DIRTEST"), screen)
        (screen, _) = runUntilReady(c64, "LOAD\"NOPE\",8", frames: 3000)
        XCTAssertTrue(screen.contains("FILE NOT FOUND"), screen)
    }
}
