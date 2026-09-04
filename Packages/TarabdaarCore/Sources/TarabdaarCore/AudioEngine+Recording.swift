import AVFoundation
import Foundation

// Recording: the post-FX tap on the main mixer into a pre-allocated
// interleaved Int16 buffer, written as one complete WAV at stop.
extension AudioEngine {
    /// Frames written + first error of the last recording.
    public var lastRecordingStats: (frames: Int64, error: String?) {
        recordingLock.lock(); defer { recordingLock.unlock() }
        return (Int64(recCountFinal / 2), recOverflow ? "buffer overflow (recording exceeded capacity)" : nil)
    }

    /// Capture post-FX audio at the main mixer into a 16-bit stereo WAV at
    /// `url`, written in full at `stopRecording`. Stops any prior recording.
    public func startRecording(to url: URL) throws {
        stopRecording()
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let sr = outputFormat.sampleRate
        // Pre-allocate ~120 s of stereo so the tap never allocates.
        let cap = Int(sr) * 2 * 120
        recordingLock.lock()
        if recBuf.count < cap { recBuf = [Int16](repeating: 0, count: cap) }
        recCount = 0
        recURL = url
        recSampleRate = sr
        recActive = true
        recOverflow = false
        recordingLock.unlock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let nch = Int(buffer.format.channelCount)
            let l = ch[0]
            let r = nch > 1 ? ch[1] : ch[0]
            self.recordingLock.lock()
            if self.recActive {
                var idx = self.recCount
                let capCount = self.recBuf.count
                var f = 0
                while f < frames && idx + 1 < capCount {
                    self.recBuf[idx] = Int16(max(-1.0, min(1.0, l[f])) * 32767.0); idx += 1
                    self.recBuf[idx] = Int16(max(-1.0, min(1.0, r[f])) * 32767.0); idx += 1
                    f += 1
                }
                if f < frames { self.recOverflow = true }
                self.recCount = idx
            }
            self.recordingLock.unlock()
        }
        DispatchQueue.main.async {
            self.isRecording = true
            self.lastRecordingURL = url
        }
    }

    /// Stop recording and write the complete WAV synchronously (no-op if none).
    public func stopRecording() {
        recordingLock.lock()
        let active = recActive
        recActive = false
        recordingLock.unlock()
        // removeTap first so no further samples land while we snapshot.
        if active { engine.mainMixerNode.removeTap(onBus: 0) }
        recordingLock.lock()
        let url = recURL
        let n = recCount
        let sr = recSampleRate
        let samples = active ? Array(recBuf[0..<n]) : []
        recCountFinal = n
        recURL = nil
        recCount = 0
        recordingLock.unlock()
        if active, let url {
            Self.writeWavInt16(url: url, interleaved: samples, sampleRate: sr)
        }
        if active {
            DispatchQueue.main.async { self.isRecording = false }
        }
    }

    /// Write a complete 16-bit stereo PCM WAV (own header — no AVAudioFile).
    private static func writeWavInt16(url: URL, interleaved: [Int16], sampleRate: Double) {
        let dataBytes = interleaved.count * 2
        let byteRate = Int(sampleRate) * 2 * 2     // SR * channels * bytesPerSample
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)      // PCM, 2 ch
        u32(Int(sampleRate)); u32(byteRate); u16(4); u16(16)                   // blockAlign 4, 16-bit
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        interleaved.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: url)
    }
}
