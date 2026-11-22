import XCTest
@testable import C64Core

final class UserDiskTests: XCTestCase {
    /// Runs a D64 from $C64_D64 for ~60 emulated seconds (autostart LOAD"*",8,1 + RUN).
    func testRunUserDisk() throws {
        guard let path = ProcessInfo.processInfo.environment["C64_D64"],
              let data = FileManager.default.contents(atPath: path),
              let img = D64Image(data: [UInt8](data)),
              let roms = ROMSet.load() else { throw XCTSkip("no disk") }
        print("DIR", img.directory().map { "\($0.name) \($0.blocks)" })
        let c64 = C64(roms: roms)
        c64.drive8!.insert(GCRDisk(d64: img))
        C64Autostart.ensureBooted(c64)
        c64.queueTyping("LOAD\"*\",8,1\nRUN\n")
        for f in 0..<16000 {
            // After loading: press fire / space to leave the title screen, then play a bit.
            if f >= 7500 && f % 200 == 0 { c64.joystick2 = 0x10; c64.setKey(.space, pressed: true) }
            if f >= 7500 && f % 200 == 20 { c64.joystick2 = 0; c64.setKey(.space, pressed: false) }
            if f >= 9000 && f % 100 == 50 { c64.joystick2 = [0x01, 0x02, 0x04, 0x08, 0x14][(f / 100) % 5] }
            c64.runFrame()
            if f % 1000 == 0 { print("F\(f) pc=\(String(c64.cpu.pc, radix: 16)) jam=\(c64.cpu.jammed)") }
        }
        print("SCREEN\n" + c64.screenText().joined(separator: "\n"))
    }
}
