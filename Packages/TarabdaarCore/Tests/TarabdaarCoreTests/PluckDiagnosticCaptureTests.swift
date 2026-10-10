import AVFoundation
import XCTest
@testable import TarabdaarCore

final class PluckDiagnosticCaptureTests: XCTestCase {
    /// Capture preserves both channels exactly across blocks, bounds its length, and freezes at stop.
    func testBoundedLosslessCapture() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let capture = PluckDiagnosticCapture(format: format, seconds: 5.0 / 48000)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        input.frameLength = 3
        let left: [Float] = [0.000123, -0.000234, 0.000345]
        let right: [Float] = [-0.345, 0.456, -0.567]
        for i in 0..<3 {
            input.floatChannelData![0][i] = left[i]
            input.floatChannelData![1][i] = right[i]
        }
        let time = AVAudioTime(sampleTime: 128, atRate: 48000)
        capture.append(input, at: time)
        XCTAssertTrue(capture.start())
        XCTAssertFalse(capture.start())
        capture.append(input, at: time)
        capture.append(input, at: AVAudioTime(sampleTime: 132, atRate: 48000))
        let (pcm, info) = capture.finish()
        XCTAssertEqual(pcm.frameLength, 5)
        XCTAssertEqual(info["firstSampleTime"] as? Int64, 128)
        XCTAssertEqual(info["formatErrors"] as? Int, 0)
        XCTAssertEqual(info["tapDiscontinuities"] as? Int, 1)
        XCTAssertEqual(info["tapMissingFrames"] as? Int64, 1)
        XCTAssertEqual(info["tapRepeatedFrames"] as? Int64, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: pcm)
        }
        let file = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5)!
        try file.read(into: read)
        capture.append(input, at: time)
        for i in 0..<5 {
            XCTAssertEqual(read.floatChannelData![0][i], left[i % 3])
            XCTAssertEqual(read.floatChannelData![1][i], right[i % 3])
            XCTAssertEqual(pcm.floatChannelData![0][i], left[i % 3])
        }
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: info))
    }
}
