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
    private var callbackPending = false
    private var completedFrames = 0
    /// Bumped each time `frontBuffer` is replaced, so the view uploads only new pictures.
    private var publishedFrames = 0
    /// Pictures the machine has completed (VIC-II, or VDC when showing 80 columns), for the FPS readout.
    var emulatedFrames: Int { lock.lock(); defer { lock.unlock() }; return completedFrames }
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
    /// Run at full speed while a disk drive motor is turning (opt-in: games often keep it running).
    var warpWhileDisk = false
    var paused = false

    init(c64: C64, audio: AudioOutput) {
        self.c64 = c64
        self.audio = audio
        c64.sid.sampleRate = audio.sampleRate
    }

    /// Schedules work to run on the emulation thread before the next short emulation slice.
    func perform(_ block: @escaping (C64) -> Void) {
        lock.lock(); pending.append(block); lock.unlock()
    }

    func withFrame<T>(_ body: ([UInt32], Int, Int, Bool) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(frontBuffer, frontSize.width, frontSize.height, frontIs80)
    }

    /// Hands the front buffer's bytes to `body` only when a picture was published after `serial`.
    func withFrame(newerThan serial: inout Int, _ body: (UnsafeRawBufferPointer, Int, Int, Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard publishedFrames != serial else { return }
        serial = publishedFrames
        frontBuffer.withUnsafeBytes { body($0, frontSize.width, frontSize.height, frontIs80) }
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

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// Copies the selected picture to the front buffer and schedules at most one main-thread refresh.
    private func publish(as80: Bool) {
        lock.lock()
        publishedFrames &+= 1
        frontIs80 = as80
        if as80 {
            c64.renderVDC(into: &vdcBuffer)
            frontBuffer = vdcBuffer
            frontSize = c64.vdcPictureSize
        } else {
            frontBuffer = c64.vic.frameBuffer
            frontSize = (VICII.screenWidth, VICII.screenHeight)
        }
        let schedule = !callbackPending && onFrame != nil
        if schedule { callbackPending = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.callbackPending = false; self.lock.unlock()
                self.onFrame?()
            }
        }
    }

    private var quietFrames = 0
    private var audioActive = true

    private func loop() {
        // Short slices let input reach the machine within a few milliseconds instead of a frame.
        let slices = 1
        var baseTime = EmulatorRunner.now()
        var baseCycles = c64.cycles
        var baseClock = c64.clockHz
        var lastPublish = 0.0
        var vicFrame = c64.vic.frameCount
        var vdcPicture = c64.vdcPictureCount
        while running {
            lock.lock()
            let work = pending
            pending.removeAll()
            lock.unlock()
            for w in work { w(c64) }

            if paused {
                Thread.sleep(forTimeInterval: 0.02)
                baseTime = EmulatorRunner.now(); baseCycles = c64.cycles
                continue
            }

            c64.run(cycles: max(1, c64.frameCycles / slices))
            let diskBusy = (c64.drive8?.motorOn ?? false) || (c64.drive9?.motorOn ?? false)
            let warp = self.warp || (warpWhileTape && c64.datasette.mode != .stopped && c64.cassetteMotor)
                || (warpWhileDisk && diskBusy)
            let samples = c64.sid.takeSamples()
            // About a second of silence (or mute) pauses the audio output; sound resumes it.
            let quiet = c64.sid.isSilent || audio.muted
            quietFrames = quiet ? quietFrames + 1 : 0
            let wantAudio = quietFrames < 60
            if wantAudio != audioActive {
                audioActive = wantAudio
                let audio = self.audio
                DispatchQueue.main.async { audio.setActive(wantAudio) }
            }
            if !warp {
                audio.ring.write(samples)
                audio.ring.trim(to: Int(audio.sampleRate) / 10)   // at most 100 ms queued
            }

            let as80: Bool
            switch display {
            case .automatic: as80 = c64.showing80Columns
            case .columns40: as80 = false
            case .columns80: as80 = c64.isC128
            }
            // Only draw the 80-column picture while it is on screen (it costs as much as the VIC-II).
            if c64.isC128 { c64.vdcDrawing = as80 }
            let newVIC = c64.vic.frameCount != vicFrame
            let newVDC = c64.vdcPictureCount != vdcPicture
            vicFrame = c64.vic.frameCount
            vdcPicture = c64.vdcPictureCount
            let fresh = as80 ? newVDC : newVIC
            if fresh { lock.lock(); completedFrames += 1; lock.unlock() }
            let t = EmulatorRunner.now()
            // Each display publishes on its own completed picture; warp limits copies to ~60 per second.
            if (fresh || as80 != frontIs80) && (!warp || t - lastPublish >= 1.0 / 60) {
                lastPublish = t
                publish(as80: as80)
            }

            if warp || c64.clockHz != baseClock {
                baseTime = t; baseCycles = c64.cycles; baseClock = c64.clockHz
                continue
            }
            // Pace emulated cycles to the monotonic clock; audio buffering never changes machine speed.
            let target = baseTime + Double(c64.cycles &- baseCycles) / Double(baseClock)
            if target > t {
                Thread.sleep(forTimeInterval: target - t)
            } else if t - target > 0.25 {
                baseTime = t; baseCycles = c64.cycles
            }
        }
    }
}
