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
    /// True when `frontBuffer` holds the C128's 80-column (VDC) picture instead of the VIC-II's.
    private(set) var frontIs80 = false
    private(set) var frontSize = (width: VICII.screenWidth, height: VICII.screenHeight)
    private var vdcBuffer: [UInt32] = []
    /// Which of the C128's two video outputs the window shows, like the input switch on a monitor.
    enum Display: Int { case automatic, columns40, columns80 }
    var display = Display.automatic
    var warp = false
    /// Run at full speed while the Datasette motor is turning.
    var warpWhileTape = true
    /// Run at full speed while a disk drive motor is turning.
    var warpWhileDisk = true
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

    func withFrame<T>(_ body: ([UInt32], Int, Int, Bool) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(frontBuffer, frontSize.width, frontSize.height, frontIs80)
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
        var period: Double { Double(c64.frameCycles) / Double(c64.clockHz) }
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
            let diskBusy = (c64.drive8?.motorOn ?? false) || (c64.drive9?.motorOn ?? false)
            let warp = self.warp || (warpWhileTape && c64.datasette.mode != .stopped && c64.cassetteMotor)
                || (warpWhileDisk && diskBusy)
            let samples = c64.sid.takeSamples()
            frameCounter += 1
            if !warp { audio.ring.write(samples) }

            if !warp || frameCounter % 10 == 0 {
                lock.lock()
                switch display {
                case .automatic: frontIs80 = c64.showing80Columns
                case .columns40: frontIs80 = false
                case .columns80: frontIs80 = c64.isC128
                }
                if frontIs80 {
                    c64.renderVDC(into: &vdcBuffer)
                    frontBuffer = vdcBuffer
                    frontSize = c64.vdcPictureSize
                } else {
                    frontBuffer = c64.vic.frameBuffer
                    frontSize = (VICII.screenWidth, VICII.screenHeight)
                }
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
