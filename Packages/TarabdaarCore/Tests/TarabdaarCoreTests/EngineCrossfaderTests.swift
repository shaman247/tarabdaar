import XCTest
@testable import TarabdaarCore

final class EngineCrossfaderTests: XCTestCase {
    private final class ConstantEngine: StereoRenderEngine {
        let value: Double
        var beforeRender: (() -> Void)?

        init(_ value: Double) { self.value = value }

        func render(frames: Int, outL: UnsafeMutablePointer<Double>,
                    outR: UnsafeMutablePointer<Double>) {
            let action = beforeRender
            beforeRender = nil
            action?()
            for i in 0..<frames { outL[i] = value; outR[i] = value }
        }
    }

    private static func render(_ fader: EngineCrossfader<ConstantEngine>,
                               frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = fader.render(frames: frames, outL: l.baseAddress!, outR: r.baseAddress!)
            }
        }
        XCTAssertEqual(left, right)
        return left
    }

    /// Publishing during a buffer cannot advance or finish the replacement fade.
    func testPublicationDuringRenderPreservesNewFade() {
        for oldDuration in [4.0, 16.0] {
            let fader = EngineCrossfader<ConstantEngine>(sr: 1000, maxFrames: 4)
            let a = ConstantEngine(1), b = ConstantEngine(2), c = ConstantEngine(3)
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            b.beforeRender = {
                entered.signal()
                XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
            }
            fader.publish(a, crossfadeMs: 0)
            fader.publish(b, crossfadeMs: oldDuration)
            DispatchQueue.global().async {
                _ = Self.render(fader, frames: 4)
                finished.signal()
            }
            let ready = entered.wait(timeout: .now() + 5)
            XCTAssertEqual(ready, .success)
            fader.publish(c, crossfadeMs: 8)
            resume.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

            let first = Self.render(fader, frames: 4)
            XCTAssertEqual(first[0], 2)
            let second = Self.render(fader, frames: 4)
            XCTAssertEqual(second[0], Float(5 / sqrt(2.0)), accuracy: 1e-6)
            XCTAssertEqual(Self.render(fader, frames: 1), [3])
        }
    }
}
