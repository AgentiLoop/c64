import Foundation
import C64Core

/// Owns the machine and runs it on a dedicated thread at PAL speed (50.125 Hz frames),
/// feeding audio and publishing finished frames.
final class EmulatorRunner {
    let c64: C64
    let audio: AudioOutput
    private var thread: Thread?
    private let lock = NSLock()
    private var pending: [(C64) -> Void] = []
    private var running = false
    private(set) var frontBuffer = [UInt32](repeating: 0, count: VICII.screenWidth * VICII.screenHeight)
    var onFrame: (() -> Void)?
    var warp = false
    var paused = false

    init(c64: C64, audio: AudioOutput) {
        self.c64 = c64
        self.audio = audio
        c64.sid.sampleRate = audio.sampleRate
    }

    /// Schedules work to run on the emulation thread between frames.
    func perform(_ block: @escaping (C64) -> Void) {
        lock.lock(); pending.append(block); lock.unlock()
    }

    func withFrame<T>(_ body: ([UInt32]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(frontBuffer)
    }

    func start() {
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.name = "C64 emulation"
        thread = t
        t.start()
    }

    func stop() { running = false }

    private func loop() {
        let period = Double(C64.cyclesPerFrame) / Double(C64.palClock)
        var deadline = Date().timeIntervalSinceReferenceDate
        var frameCounter = 0
        while running {
            lock.lock()
            let work = pending
            pending.removeAll()
            lock.unlock()
            for w in work { w(c64) }

            if paused {
                Thread.sleep(forTimeInterval: 0.02)
                deadline = Date().timeIntervalSinceReferenceDate
                continue
            }

            c64.runFrame()
            let samples = c64.sid.takeSamples()
            frameCounter += 1
            if !warp { audio.ring.write(samples) }

            if !warp || frameCounter % 10 == 0 {
                lock.lock()
                frontBuffer = c64.vic.frameBuffer
                lock.unlock()
                if let cb = onFrame { DispatchQueue.main.async(execute: cb) }
            }

            if warp {
                deadline = Date().timeIntervalSinceReferenceDate
                continue
            }
            // Pace to real time, nudged by the audio fill level to avoid drift.
            deadline += period
            let fill = audio.ring.available
            if fill > 6000 { deadline += 0.002 } else if fill < 1500 { deadline -= 0.002 }
            let now = Date().timeIntervalSinceReferenceDate
            if deadline > now {
                Thread.sleep(forTimeInterval: deadline - now)
            } else if now - deadline > 0.25 {
                deadline = now
            }
        }
    }
}
