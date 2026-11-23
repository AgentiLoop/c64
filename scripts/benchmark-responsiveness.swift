// Compile alongside EmulatorRunner.swift and AudioOutput.swift against a release C64Core module.
import Foundation
@testable import C64Core

@main
struct ResponsivenessBenchmark {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    static func emit(_ row: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func machine(_ roms: ROMSet, _ model: String, _ standard: VideoStandard) -> C64 {
        let c = C64(roms: roms)
        c.standard = standard
        if model != "C64" {
            c.setC128(roms.c128!)
            c.key4080Down = model == "C128-80"
        }
        for _ in 0..<180 { c.runFrame(); _ = c.sid.takeSamples() }
        return c
    }
    static func main() throws {
        guard let roms = ROMSet.load(), roms.c128 != nil else { fatalError("C64 and C128 ROMs required") }
        for standard in [VideoStandard.pal, .ntsc] {
            for model in ["C64", "C128-40", "C128-80"] {
                let c = machine(roms, model, standard)
                var times: [Double] = []
                for _ in 0..<300 {
                    let t = now()
                    c.runFrame()
                    _ = c.sid.takeSamples()
                    times.append(now() - t)
                }
                let seconds = times.reduce(0, +)
                emit(["test": "core", "model": model, "standard": standard.rawValue,
                      "fps": 300 / seconds, "mean_ms": seconds / 300 * 1000,
                      "p95_ms": times.sorted()[284] * 1000])
                c.setKey(.a, pressed: true)
                c.setKey(.b, pressed: true)
                let (row, col) = C64Key.b.matrix
                var frames = 0
                while c.keyMatrix[row] & (1 << col) == 0 && frames < 10 {
                    c.runFrame(); frames += 1
                }
                emit(["test": "second_key_delay", "model": model, "standard": standard.rawValue, "frames": frames])
            }
        }
        for model in ["C64", "C128-40", "C128-80"] {
            for fullAudio in [false, true] {
                let c = machine(roms, model, .pal)
                let audio = AudioOutput()
                let runner = EmulatorRunner(c64: c, audio: audio)
                runner.warpWhileDisk = false; runner.warpWhileTape = false
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "benchmark.audio"))
                if !fullAudio {
                    timer.schedule(deadline: .now(), repeating: .milliseconds(10))
                    timer.setEventHandler {
                        var samples = [Float](repeating: 0, count: 441)
                        samples.withUnsafeMutableBufferPointer { audio.ring.read(into: $0.baseAddress!, frames: 441) }
                    }
                }
                timer.resume()
                var callbacks = 0
                runner.onFrame = { callbacks += 1 }
                runner.start()
                var latency: [Double] = []
                for i in 0..<80 {
                    Thread.sleep(forTimeInterval: Double(i % 7 + 1) / 1000)
                    let done = DispatchSemaphore(value: 0), t = now()
                    runner.perform { _ in done.signal() }
                    precondition(done.wait(timeout: .now() + 5) == .success)
                    latency.append((now() - t) * 1000)
                }
                let start = DispatchSemaphore(value: 0)
                var cycles: UInt64 = 0
                var begin = 0.0
                runner.perform { c in cycles = c.cycles; begin = now(); start.signal() }
                start.wait()
                Thread.sleep(forTimeInterval: 2)
                let end = DispatchSemaphore(value: 0)
                var speed = 0.0
                runner.perform { c in speed = Double(c.cycles - cycles) / Double(c.clockHz) / (now() - begin); end.signal() }
                end.wait()
                runner.stop(); timer.cancel()
                Thread.sleep(forTimeInterval: 0.05)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                emit(["test": "runner", "model": model, "audio": fullAudio ? "not-drained" : "44100Hz-consumer",
                      "speed_percent": speed * 100, "input_mean_ms": latency.reduce(0,+) / Double(latency.count),
                      "input_p95_ms": latency.sorted()[75], "queued_callbacks": callbacks])
            }
        }
    }
}
