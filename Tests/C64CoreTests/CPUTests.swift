import XCTest
@testable import C64Core

final class FlatBus: CPUBus {
    var mem = [UInt8](repeating: 0, count: 65536)
    var cycles = 0
    func read(_ address: UInt16) -> UInt8 { cycles += 1; return mem[Int(address)] }
    func write(_ address: UInt16, _ value: UInt8) { cycles += 1; mem[Int(address)] = value }
}

final class CPUTests: XCTestCase {
    func testCycleCounts() {
        let bus = FlatBus()
        let cpu = CPU6502(bus: bus)
        // LDA #$01 (2), STA $0200 (4), LDA $01FF,X with X=1 (5, page cross), JSR (6), RTS (6), INC $10 (5)
        let prog: [UInt8] = [0xA9, 0x01, 0x8D, 0x00, 0x02, 0xA2, 0x01, 0xBD, 0xFF, 0x01,
                             0x20, 0x20, 0x10, 0xE6, 0x10]
        for (k, b) in prog.enumerated() { bus.mem[0x1000 + k] = b }
        bus.mem[0x1020] = 0x60
        cpu.pc = 0x1000
        let expected = [2, 4, 2, 5, 6, 6, 5]
        for e in expected {
            bus.cycles = 0
            cpu.step()
            XCTAssertEqual(bus.cycles, e)
        }
        XCTAssertEqual(bus.mem[0x10], 1)
    }

    /// Klaus Dormann's 6502 functional test. Supply the binary via
    /// C64_FUNCTIONAL_TEST=/path/6502_functional_test.bin (skipped otherwise).
    func testKlausFunctional() throws {
        let path = ProcessInfo.processInfo.environment["C64_FUNCTIONAL_TEST"] ?? "/tmp/c64test/6502_functional_test.bin"
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("functional test binary not found") }
        let bus = FlatBus()
        bus.mem = [UInt8](data)
        let cpu = CPU6502(bus: bus)
        cpu.pc = 0x0400
        var last: UInt16 = 0
        for _ in 0..<100_000_000 {
            last = cpu.pc
            cpu.step()
            if cpu.pc == last { break }
        }
        XCTAssertEqual(cpu.pc, 0x3469, String(format: "trapped at $%04X", cpu.pc))
    }
}
