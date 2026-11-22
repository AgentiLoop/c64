import AVFoundation

/// Lock-protected mono sample FIFO between the emulation thread and the audio render thread.
final class SampleRing {
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) { buffer = [Float](repeating: 0, count: capacity) }

    var available: Int { lock.lock(); defer { lock.unlock() }; return count }

    func write(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            if count == buffer.count { readIndex = (readIndex + 1) % buffer.count; count -= 1 }
            buffer[writeIndex] = s
            writeIndex = (writeIndex + 1) % buffer.count
            count += 1
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        var last: Float = count > 0 ? buffer[readIndex] : 0
        for i in 0..<frames {
            if count > 0 {
                last = buffer[readIndex]
                readIndex = (readIndex + 1) % buffer.count
                count -= 1
            }
            out[i] = last
        }
    }
}

final class AudioOutput {
    let engine = AVAudioEngine()
    let ring = SampleRing(capacity: 44_100)
    private(set) var sampleRate: Double = 44_100
    var muted = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(into: ptr, frames: Int(frameCount))
            if self?.muted == true { for i in 0..<Int(frameCount) { ptr[i] = 0 } }
            for b in buffers.dropFirst() {
                if let p = b.mData { memcpy(p, ptr, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.8
    }

    func start() {
        do { try engine.start() } catch { NSLog("Audio engine failed: \(error)") }
    }
}
