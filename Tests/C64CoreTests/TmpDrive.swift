import XCTest
@testable import C64Core
final class TmpDrive: XCTestCase {
    func testDrive() throws {
        guard let roms = ROMSet.load(), let r = roms.c128 else { throw XCTSkip() }
        let c64 = C64(roms: roms); c64.fastLoad = true; c64.standard = .ntsc; c64.setC128(r)
        for _ in 0..<900 { c64.runFrame() }
        let d = c64.drive8!
        let a0 = c64.iec.activity
        var pcs = [UInt16: Int]()
        for _ in 0..<2_000_000 { c64.run(cycles: 1); pcs[d.cpu.pc & 0xFFF0, default: 0] += 1 }
        print("DRV asleep=\(d.asleep) motor=\(d.motorOn) led=\(d.ledOn) is1571=\(d.is1571) activity+\(c64.iec.activity - a0) pcs=\(pcs.sorted { $0.key < $1.key }.prefix(4).map { String($0.key, radix: 16) + ":\($0.value)" })")
    }
}
