import AVFoundation
import Foundation

/// Polyphonic synthesizer with per-channel frequency glide support.
/// Voices are keyed by channel index (0 or 1), not touch ID.
class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private var voices: [Int: Voice] = [:]
    private let lock = NSLock()

    @Published var isRunning = false

    private struct Voice {
        var frequency: Double
        var targetFrequency: Double
        var amplitude: Double
        var phase: Double = 0
        var envelope: Double = 0
        var releasing = false
    }

    private var sourceNode: AVAudioSourceNode!

    init() {
        setupAudio()
    }

    private func setupAudio() {
        let sampleRate = Config.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0]
            let frames = Int(frameCount)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            for i in 0..<frames {
                data[i] = 0
            }

            self.lock.lock()
            for (id, var voice) in self.voices {
                for i in 0..<frames {
                    voice.frequency += (voice.targetFrequency - voice.frequency) * Config.frequencySmoothing

                    if voice.releasing {
                        voice.envelope *= Config.releaseCoefficient
                    } else {
                        voice.envelope += (voice.amplitude - voice.envelope) * Config.attackCoefficient
                    }

                    let phaseIncrement = voice.frequency / sampleRate
                    let sample = sin(voice.phase * 2.0 * .pi) * voice.envelope
                    data[i] += Float(sample)
                    voice.phase += phaseIncrement
                    if voice.phase >= 1.0 { voice.phase -= 1.0 }
                }
                self.voices[id] = voice

                if voice.releasing && voice.envelope < 0.001 {
                    self.voices.removeValue(forKey: id)
                }
            }
            // Equal-power gain normalization to prevent clipping with multiple voices
            let voiceCount = max(1, self.voices.count)
            if voiceCount > 1 {
                let gain = Float(1.0 / sqrt(Double(voiceCount)))
                for i in 0..<frames { data[i] *= gain }
            }

            self.lock.unlock()

            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine failed to start: \(error)")
        }
    }

    static func frequency(for midiNote: Int) -> Double {
        440.0 * pow(2.0, Double(midiNote - 69) / 12.0)
    }

    static func frequency(for midiNote: Double) -> Double {
        440.0 * pow(2.0, (midiNote - 69.0) / 12.0)
    }

    func noteOn(channel: Int, midiNote: Int, velocity: Int) {
        let freq = Self.frequency(for: midiNote)
        let amp = Double(velocity) / 127.0 * Config.maxAmplitude

        lock.lock()
        voices[channel] = Voice(frequency: freq, targetFrequency: freq, amplitude: amp)
        lock.unlock()
    }

    func noteOff(channel: Int) {
        lock.lock()
        voices[channel]?.releasing = true
        lock.unlock()
    }

    func setFrequency(channel: Int, frequency: Double) {
        lock.lock()
        voices[channel]?.targetFrequency = frequency
        lock.unlock()
    }

    func setAmplitude(channel: Int, amplitude: Double) {
        lock.lock()
        voices[channel]?.amplitude = amplitude
        lock.unlock()
    }

    func stopAll() {
        lock.lock()
        for id in voices.keys {
            voices[id]?.releasing = true
        }
        lock.unlock()
    }

    deinit {
        engine.stop()
    }
}
