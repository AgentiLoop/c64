import XCTest
@testable import C64Core
final class TmpParts: XCTestCase {
    func testParts() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip() }
        let c64 = C64(roms: roms); c64.standard = .ntsc; c64.fastLoad = true
        if ProcessInfo.processInfo.environment["C128"] != nil, let r = roms.c128 { c64.setC128(r); c64.vdcDrawing = false }
        for _ in 0..<900 { c64.runFrame() }
        let n = ProcessInfo.processInfo.environment["LONG"] != nil ? 900_000_000 : 20_000_000
        let t = Date(); c64.run(cycles: n)
        print("PART whole \(String(format: "%.1f", Date().timeIntervalSince(t) * 1e9 / Double(n))) ns/cycle asleep=\(c64.drive8?.asleep ?? false)")
    }
}
