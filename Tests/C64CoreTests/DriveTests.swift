import XCTest
@testable import C64Core

final class DriveTests: XCTestCase {
    /// Tokenized `10 PRINT "<text>"` at $0801.
    static func helloPRG(_ text: String) -> [UInt8] {
        let body: [UInt8] = [0x99, 0x20, 0x22] + Array(text.utf8) + [0x22, 0x00]
        let next = 0x0801 + 4 + body.count
        return [0x01, 0x08, UInt8(next & 0xFF), UInt8(next >> 8), 10, 0] + body + [0, 0]
    }

    func testD64FileRoundTrip() {
        let d = D64Image.blank(name: "TEST DISK", id: "AB")
        let big = [UInt8](0..<255) + [UInt8](repeating: 7, count: 3000)
        XCTAssertTrue(d.addFile(name: "HELLO", contents: DriveTests.helloPRG("HI")))
        XCTAssertTrue(d.addFile(name: "BIG", contents: big))
        let dir = d.directory()
        XCTAssertEqual(dir.map(\.name), ["HELLO", "BIG"])
        XCTAssertEqual(d.readFile(dir[1]), big)
        XCTAssertEqual(d.diskName, "TEST DISK")
    }

    func testGCRRoundTrip() {
        let d = D64Image.blank(name: "GCR", id: "XY")
        d.addFile(name: "DATA", contents: (0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let g = GCRDisk(d64: d)
        XCTAssertEqual(g.tracks[1].count, 7692)
        XCTAssertEqual(g.tracks[35].count, 6250)
        // Wipe the source image to prove every sector really decodes from GCR.
        let original = d.data
        for i in 0..<d.data.count { d.data[i] = 0 }
        XCTAssertEqual(g.toD64().data, original)
    }

    // MARK: - Full machine with true drive emulation

    func makeMachine() throws -> C64 {
        guard let roms = ROMSet.load(), roms.drive1541 != nil else { throw XCTSkip("ROMs not installed") }
        let c64 = C64(roms: roms)
        for _ in 0..<150 { c64.runFrame() }
        return c64
    }

    /// Types a line and runs until a new READY. prompt appears (or the frame limit).
    func run(_ c64: C64, _ line: String, frames: Int = 3000) -> String {
        let before = c64.screenText().joined(separator: "\n").components(separatedBy: "READY.").count
        c64.queueTyping(line + "\n")
        for _ in 0..<frames {
            c64.runFrame()
            let s = c64.screenText().joined(separator: "\n")
            if s.components(separatedBy: "READY.").count > before || (before > 20) { break }
        }
        return c64.screenText().joined(separator: "\n")
    }

    func testLoadDirectoryAndProgram() throws {
        let c64 = try makeMachine()
        let d = D64Image.blank(name: "MY DISK", id: "42")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("DISK OK"))
        c64.drive8!.insert(GCRDisk(d64: d))
        var screen = run(c64, "LOAD\"$\",8")
        XCTAssertTrue(screen.contains("LOADING"), screen)
        screen = run(c64, "LIST", frames: 200)
        XCTAssertTrue(screen.contains("MY DISK"), screen)
        XCTAssertTrue(screen.contains("\"HELLO\""), screen)
        XCTAssertTrue(screen.contains("BLOCKS FREE"), screen)
        screen = run(c64, "LOAD\"HELLO\",8")
        screen = run(c64, "RUN", frames: 200)
        XCTAssertTrue(screen.contains("DISK OK"), screen)
    }

    /// An idle drive stops running its CPU; the C64 talking on the bus wakes it, so a LOAD after a
    /// long idle still works, and after the load the drive goes back to sleep.
    func testIdleDriveSleepsAndWakes() throws {
        let c64 = try makeMachine()
        c64.fastLoad = false
        let d = D64Image.blank(name: "SLEEPY", id: "42")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("AWAKE"))
        c64.drive8!.insert(GCRDisk(d64: d))
        for _ in 0..<300 { c64.runFrame() }
        XCTAssertTrue(c64.drive8!.asleep)
        _ = run(c64, "LOAD\"HELLO\",8")
        let screen = run(c64, "RUN", frames: 200)
        XCTAssertTrue(screen.contains("AWAKE"), screen)
        for _ in 0..<300 { c64.runFrame() }
        XCTAssertTrue(c64.drive8!.asleep)
    }

    func testSaveToDisk() throws {
        let c64 = try makeMachine()
        let disk = GCRDisk(d64: D64Image.blank(name: "SAVE TEST", id: "01"))
        c64.drive8!.insert(disk)
        _ = run(c64, "10 PRINT \"SAVED\"", frames: 50)
        let screen = run(c64, "SAVE\"MYPROG\",8")
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertTrue(disk.dirty)
        let img = disk.toD64()
        let entries = img.directory()
        XCTAssertEqual(entries.first?.name, "MYPROG", screen)
        if let e = entries.first {
            XCTAssertEqual(Array(img.readFile(e).prefix(2)), [0x01, 0x08])
        }
    }

    func testLoadMultiBlockBinary() throws {
        let c64 = try makeMachine()
        let payload = (0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let d = D64Image.blank(name: "BIN", id: "07")
        d.addFile(name: "CODE", contents: [0x00, 0x90] + payload)   // loads at $9000
        c64.drive8!.insert(GCRDisk(d64: d))
        let screen = run(c64, "LOAD\"*\",8,1", frames: 6000)
        XCTAssertFalse(screen.contains("ERROR"), screen)
        XCTAssertEqual(Array(c64.ram[0x9000..<0x9000 + payload.count]), payload)
    }
}

extension DriveTests {
    /// G64: a D64 encoded to raw GCR and back keeps its sectors and half-tracks, and the true
    /// drive loads a program from it.
    func testG64RoundTripAndLoad() throws {
        let d = D64Image.blank(name: "G64 DISK", id: "64")
        d.addFile(name: "HELLO", contents: DriveTests.helloPRG("G64 OK"))
        let g64 = GCRDisk(d64: d).toG64()
        XCTAssertEqual(Array(g64[0..<8]), Array("GCR-1541".utf8))
        var g = try XCTUnwrap(GCRDisk(g64: g64))
        XCTAssertTrue(g.isG64)
        XCTAssertEqual(g.toD64().data, d.data)
        // A half-track survives a save/load cycle.
        var raw = g64
        let half = 12 + 34 * 4 + 4                        // offset entry of half-track 37 (18.5)
        let extra = [UInt8](repeating: 0x52, count: 100)
        let off = raw.count
        raw += [100, 0] + extra
        raw[half] = UInt8(off & 0xFF); raw[half + 1] = UInt8(off >> 8 & 0xFF); raw[half + 2] = UInt8(off >> 16)
        g = try XCTUnwrap(GCRDisk(g64: raw))
        XCTAssertEqual(g.track(half: 37), extra)
        XCTAssertEqual(GCRDisk(g64: g.toG64())?.track(half: 37), extra)

        let c64 = try makeMachine()
        c64.fastLoad = false
        c64.drive8!.insert(try XCTUnwrap(GCRDisk(g64: g64)))
        _ = run(c64, "LOAD\"HELLO\",8")
        let screen = run(c64, "RUN", frames: 200)
        XCTAssertTrue(screen.contains("G64 OK"), screen)
    }
}

extension DriveTests {
    func testMFMImageGeometry() {
        XCTAssertEqual(MFMImage(data: [UInt8](repeating: 0, count: 204_800))?.geometry.name, "Kaypro II")
        XCTAssertEqual(MFMImage(data: [UInt8](repeating: 0, count: 409_600))?.geometry.name, "Kaypro IV")
        XCTAssertEqual(MFMImage(data: [UInt8](repeating: 0, count: 368_640))?.geometry.name, "IBM-9 DS")
        XCTAssertNil(MFMImage(data: [UInt8](repeating: 0, count: 1000)))
        let k4 = MFMImage(geometry: MFMImage.formats[1])
        k4.setSector(cyl: 3, side: 1, sector: 12, [7, 8, 9])
        XCTAssertEqual(k4.sector(cyl: 3, side: 1, sector: 12)?.prefix(3), [7, 8, 9])
        XCTAssertNil(k4.sector(cyl: 3, side: 1, sector: 2))                  // side 1 numbers 10-19
        XCTAssertEqual(k4.data[((3 * 2 + 1) * 10 + 2) * 512], 7)
    }
}
