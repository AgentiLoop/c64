import XCTest
@testable import C64Core
final class TmpBench: XCTestCase {
    func cpuTime() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6 + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6 }
    func testBench() throws {
        guard let roms = ROMSet.load() else { throw XCTSkip() }
        let c64 = C64(roms: roms); c64.standard = .ntsc; c64.fastLoad = true
        for _ in 0..<120 { c64.runFrame() }
        var c0 = cpuTime(); var t = Date()
        for _ in 0..<(ProcessInfo.processInfo.environment["LONG"] != nil ? 6000 : 600) { _ = c64.sid.takeSamples(); c64.runFrame() }
        print("BENCH flat-out cpu=\(cpuTime() - c0) wall=\(Date().timeIntervalSince(t)) for 10 s")
        for (frames, qos) in [(1, QualityOfService.userInteractive)] {
            var used = 0.0
            let th = Thread {
            c0 = self.cpuTime(); t = Date()
            let start = Date()
            var cycles = 0
            while Date().timeIntervalSince(start) < 10 {
                c64.run(cycles: c64.frameCycles * frames); cycles += c64.frameCycles * frames
                _ = c64.sid.takeSamples()
                let target = Double(cycles) / Double(c64.clockHz)
                let now = Date().timeIntervalSince(start)
                if target > now { Thread.sleep(forTimeInterval: target - now) }
            }
            used = self.cpuTime() - c0
            }
            th.qualityOfService = qos
            th.start()
            while !th.isFinished { Thread.sleep(forTimeInterval: 0.2) }
            print("BENCH paced qos=\(qos.rawValue) cpu=\(used) => \(Int(used * 10))%")
        }
    }
}
