import XCTest
@testable import C64Core

/// Speed measurements, not correctness tests: they only run with BENCH set
/// (`BENCH=1 swift test -c release -Xswiftc -enable-testing --filter Benchmarks`; add LONG=1 for longer runs,
/// C128=1 to time C128 mode in `testCycleCost`).
final class Benchmarks: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["BENCH"] == nil { throw XCTSkip("set BENCH to run benchmarks") }
    }

    func cpuTime() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6 + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6 }

    /// CPU time for 10 emulated seconds flat out, then the CPU share when paced to real time.
    func testCPUShare() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip() }
        let c64 = C64(roms: roms); c64.standard = .ntsc; c64.fastLoad = true
        for _ in 0..<120 { c64.runFrame() }
        var c0 = cpuTime(); var t = Date()
        for _ in 0..<(ProcessInfo.processInfo.environment["LONG"] != nil ? 6000 : 600) { _ = c64.sid.takeSamples(); c64.runFrame() }
        print("BENCH flat-out cpu=\(cpuTime() - c0) wall=\(Date().timeIntervalSince(t)) for 10 s")
        var used = 0.0
        let th = Thread {
            c0 = self.cpuTime(); t = Date()
            let start = Date()
            var cycles = 0
            while Date().timeIntervalSince(start) < 10 {
                c64.run(cycles: c64.frameCycles); cycles += c64.frameCycles
                _ = c64.sid.takeSamples()
                let target = Double(cycles) / Double(c64.clockHz)
                let now = Date().timeIntervalSince(start)
                if target > now { Thread.sleep(forTimeInterval: target - now) }
            }
            used = self.cpuTime() - c0
        }
        th.qualityOfService = .userInteractive
        th.start()
        while !th.isFinished { Thread.sleep(forTimeInterval: 0.2) }
        print("BENCH paced cpu=\(used) => \(Int(used * 10))%")
    }

    /// Nanoseconds per emulated cycle for the whole machine.
    func testCycleCost() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip() }
        let c64 = C64(roms: roms); c64.standard = .ntsc; c64.fastLoad = true
        if ProcessInfo.processInfo.environment["C128"] != nil, let r = roms.c128 { c64.setC128(r); c64.vdcDrawing = false }
        for _ in 0..<900 { c64.runFrame() }
        let n = ProcessInfo.processInfo.environment["LONG"] != nil ? 900_000_000 : 20_000_000
        let t = Date(); c64.run(cycles: n)
        print("BENCH \(String(format: "%.1f", Date().timeIntervalSince(t) * 1e9 / Double(n))) ns/cycle asleep=\(c64.drive8?.asleep ?? false)")
    }
}
