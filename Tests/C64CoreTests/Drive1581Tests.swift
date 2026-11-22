import XCTest
@testable import C64Core

final class Drive1581Tests: XCTestCase {
    func testD81Image() {
        let d = D81Image.blank(name: "THREE INCH", id: "81")
        let big = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        XCTAssertTrue(d.addFile(name: "HELLO", contents: DriveTests.helloPRG("HI")))
        XCTAssertTrue(d.addFile(name: "BIG", contents: big))
        XCTAssertEqual(d.directory().map(\.name), ["HELLO", "BIG"])
        XCTAssertEqual(d.readFile(d.directory()[1]), big)
        XCTAssertEqual(d.diskName, "THREE INCH")
        XCTAssertNotNil(D81Image(data: d.data))
    }

    func makeMachine() throws -> C64 {
        guard let roms = ROMSet.load(), roms.drive1581 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        c64.drive8 = nil
        XCTAssertNotNil(c64.attach1581())
        for _ in 0..<150 { c64.runFrame() }
        return c64
    }

    func run(_ c64: C64, _ line: String, frames: Int = 3000) -> String {
        let count = { c64.screenText().joined(separator: "\n").components(separatedBy: "READY.").count }
        let before = count()
        c64.queueTyping(line + "\n")
        for _ in 0..<frames {
            c64.runFrame()
            if count() > before { break }
        }
        return c64.screenText().joined(separator: "\n")
    }

    func testLoadDirectoryAndProgram() throws {
        let c64 = try makeMachine()
        let d = D81Image.blank(name: "MY 1581", id: "81")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("1581 OK"))
        c64.drive9!.insert(d)
        var screen = run(c64, "LOAD\"$\",9")
        XCTAssertTrue(screen.contains("LOADING"), screen)
        screen = run(c64, "LIST", frames: 200)
        XCTAssertTrue(screen.contains("MY 1581"), screen)
        XCTAssertTrue(screen.contains("\"HELLO\""), screen)
        XCTAssertTrue(screen.contains("3159 BLOCKS FREE"), screen)
        _ = run(c64, "LOAD\"HELLO\",9")
        screen = run(c64, "RUN", frames: 200)
        XCTAssertTrue(screen.contains("1581 OK"), screen)
    }

    func testLoadBinaryAndSave() throws {
        let c64 = try makeMachine()
        let payload = (0..<12_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let d = D81Image.blank(name: "BIN", id: "07")
        d.addFile(name: "CODE", contents: [0x00, 0x40] + payload)
        c64.drive9!.insert(d)
        var screen = run(c64, "LOAD\"CODE\",9,1", frames: 8000)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertEqual(Array(c64.ram[0x4000..<0x4000 + payload.count]), payload)

        _ = run(c64, "NEW", frames: 50)
        _ = run(c64, "10 PRINT \"SAVED 1581\"", frames: 50)
        screen = run(c64, "SAVE\"MYPROG\",9", frames: 4000)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertTrue(d.dirty)
        let e = d.directory().first { $0.name == "MYPROG" }
        XCTAssertNotNil(e, screen)
        if let e = e { XCTAssertEqual(Array(d.readFile(e).prefix(2)), [0x01, 0x08]) }
    }

    /// Formats a blank disk with the drive's own NEW command (WD1772 write track).
    /// Takes ~80 s (a real 1581 format is ~1.5 min); set C64_SLOW_TESTS=1 to run it.
    func testFormat() throws {
        guard ProcessInfo.processInfo.environment["C64_SLOW_TESTS"] != nil else { throw XCTSkip("slow") }
        let c64 = try makeMachine()
        let d = D81Image()
        c64.drive9!.insert(d)
        _ = run(c64, "OPEN1,9,15,\"N:FORMATTED,FM\":CLOSE1", frames: 100)
        for _ in 0..<8000 where d.diskName != "FORMATTED" { c64.runFrame() }
        for _ in 0..<250 { c64.runFrame() }
        _ = run(c64, "LOAD\"$\",9", frames: 3000)
        let screen = run(c64, "LIST", frames: 200)
        XCTAssertEqual(d.diskName, "FORMATTED", screen)
        XCTAssertTrue(d.directory().isEmpty)
        XCTAssertTrue(screen.contains("3160 BLOCKS FREE"), screen)
    }

    /// Writes a sample D81 to $C64_WRITE_D81 (used to make app test media).
    func testWriteSampleD81() throws {
        guard let path = ProcessInfo.processInfo.environment["C64_WRITE_D81"] else { throw XCTSkip("no output path") }
        let d = D81Image.blank(name: "APP 1581", id: "81")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("LOADED FROM D81"))
        try Data(d.data).write(to: URL(fileURLWithPath: path))
    }
}
