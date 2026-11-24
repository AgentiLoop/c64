import XCTest
@testable import C64Core

final class Z80Tests: XCTestCase {
    func makeCPU(_ program: [UInt8], at org: Int = 0) -> (Z80, UnsafeMutablePointer<UInt8>) {
        let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
        mem.initialize(repeating: 0, count: 0x10000)
        for (i, b) in program.enumerated() { mem[org + i] = b }
        let z = Z80()
        z.readMem = { mem[Int($0)] }
        z.writeMem = { mem[Int($0)] = $1 }
        z.pc = UInt16(org)
        return (z, mem)
    }

    func testBasicInstructions() {
        // LD A,$12; ADD A,$F0; LD HL,$1234; LD (HL),A; INC (HL); LD B,3; DJNZ -2; HALT
        let (z, mem) = makeCPU([0x3E, 0x12, 0xC6, 0xF0, 0x21, 0x34, 0x12, 0x77, 0x34, 0x06, 0x03, 0x10, 0xFE, 0x76])
        defer { mem.deallocate() }
        for _ in 0..<20 where !z.halted { _ = z.step() }
        XCTAssertTrue(z.halted)
        XCTAssertEqual(z.a, 0x02)
        XCTAssertEqual(z.f & Z80.fC, Z80.fC)
        XCTAssertEqual(mem[0x1234], 0x03)
        XCTAssertEqual(z.b, 0)
    }

    func testIndexedAndBlock() {
        // LD IX,$2000; LD (IX+5),$AA; LD A,(IX+5); LD HL,$2005; LD DE,$3000; LD BC,2; LDIR; HALT
        let (z, mem) = makeCPU([0xDD, 0x21, 0x00, 0x20, 0xDD, 0x36, 0x05, 0xAA, 0xDD, 0x7E, 0x05,
                                0x21, 0x05, 0x20, 0x11, 0x00, 0x30, 0x01, 0x02, 0x00, 0xED, 0xB0, 0x76])
        defer { mem.deallocate() }
        for _ in 0..<40 where !z.halted { _ = z.step() }
        XCTAssertEqual(z.a, 0xAA)
        XCTAssertEqual(mem[0x3000], 0xAA)
        XCTAssertEqual(z.bc, 0)
        XCTAssertEqual(z.de, 0x3002)
    }

    func testInterruptMode1() {
        // EI; IM 1; HALT at 0, handler at $38: LD A,$55; HALT
        var prog = [UInt8](repeating: 0, count: 0x40)
        prog[0] = 0xFB; prog[1] = 0xED; prog[2] = 0x56; prog[3] = 0x76
        prog[0x38] = 0x3E; prog[0x39] = 0x55; prog[0x3A] = 0x76
        let (z, mem) = makeCPU(prog)
        defer { mem.deallocate() }
        z.sp = 0x8000
        for _ in 0..<5 { _ = z.step() }
        XCTAssertTrue(z.halted)
        z.intLine = true
        _ = z.step()
        z.intLine = false
        for _ in 0..<3 { _ = z.step() }
        XCTAssertEqual(z.a, 0x55)
        XCTAssertEqual(z.pc, 0x3B)
    }

    /// Frank Cringle's instruction exerciser (documented flags) under a minimal CP/M BDOS.
    /// Set Z80_ZEXDOC to the path of zexdoc.com; takes minutes in a release build.
    func testZEXDOC() throws {
        guard let path = ProcessInfo.processInfo.environment["Z80_ZEXDOC"],
              let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("Z80_ZEXDOC not set") }
        let (z, mem) = makeCPU([UInt8](data), at: 0x100)
        defer { mem.deallocate() }
        mem[5] = 0xC9                              // BDOS entry: RET (trapped below)
        mem[6] = 0x00; mem[7] = 0xF0               // top of TPA for the stack
        z.sp = 0xF000
        var out = "", all = ""
        while true {
            if z.pc == 0 { break }
            if z.pc == 5 {
                if z.c == 2 { out.append(Character(UnicodeScalar(z.e))) }
                if z.c == 9 {
                    var p = Int(z.de)
                    while mem[p] != 0x24 { out.append(Character(UnicodeScalar(mem[p]))); p += 1 }
                }
                if out.hasSuffix("\n") { print(out, terminator: ""); all += out; out = "" }
            }
            _ = z.step()
        }
        print(out)
        all += out
        XCTAssertFalse(all.contains("ERROR"), all)
        XCTAssertTrue(all.contains("Tests complete"), all)
    }
}
