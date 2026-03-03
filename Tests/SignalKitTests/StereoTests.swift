import XCTest
import Accelerate
@testable import SignalKit

final class StereoTests: XCTestCase {

    // MARK: - StereoWidener

    func testUnityWidthIsPassthrough() {
        let count = 256
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        defer { interleaved.deallocate(); original.deallocate() }

        for i in 0..<count {
            interleaved[i * 2]     = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
            interleaved[i * 2 + 1] = sinf(2.0 * .pi * 880.0 * Float(i) / 48000.0)
        }
        memcpy(original, interleaved, count * 2 * MemoryLayout<Float>.size)

        StereoWidener.process(interleaved, frameCount: count, width: 1.0)

        for i in 0..<(count * 2) {
            XCTAssertEqual(interleaved[i], original[i], accuracy: 1e-6,
                           "Width 1.0 should be passthrough")
        }
    }

    func testZeroWidthProducesMono() {
        let count = 256
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        defer { interleaved.deallocate() }

        // Hard-panned: left only
        for i in 0..<count {
            interleaved[i * 2]     = 1.0
            interleaved[i * 2 + 1] = 0.0
        }

        StereoWidener.process(interleaved, frameCount: count, width: 0.0)

        // Width 0 → mono: L_out = R_out = 0.5*L + 0.5*R = 0.5
        for i in 0..<count {
            XCTAssertEqual(interleaved[i * 2], 0.5, accuracy: 1e-5, "Left should be 0.5")
            XCTAssertEqual(interleaved[i * 2 + 1], 0.5, accuracy: 1e-5, "Right should be 0.5")
        }
    }

    func testPlanarWidening() {
        let count = 128
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        for i in 0..<count {
            left[i]  = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
            right[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
        }

        // Width 0 on identical signals → identical output (mid-only content stays same)
        StereoWidener.processPlanar(left: left, right: right, count: count, width: 0.0)

        for i in 0..<count {
            XCTAssertEqual(left[i], right[i], accuracy: 1e-5,
                           "Mono content should remain equal after widening")
        }
    }

    func testWidthDoublingIncreasesSpread() {
        let count = 256
        let stereo = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        defer { stereo.deallocate() }

        // Different signals on L and R
        for i in 0..<count {
            stereo[i * 2]     = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
            stereo[i * 2 + 1] = sinf(2.0 * .pi * 880.0 * Float(i) / 48000.0)
        }

        // Copy before widening
        let before = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        defer { before.deallocate() }
        memcpy(before, stereo, count * 2 * MemoryLayout<Float>.size)

        StereoWidener.process(stereo, frameCount: count, width: 2.0)

        // With width=2, the side component is doubled. L and R should differ more
        var diffBefore: Float = 0
        var diffAfter: Float = 0
        for i in 0..<count {
            diffBefore += abs(before[i * 2] - before[i * 2 + 1])
            diffAfter += abs(stereo[i * 2] - stereo[i * 2 + 1])
        }
        XCTAssertGreaterThan(diffAfter, diffBefore,
                             "Width 2.0 should increase L/R difference")
    }

    // MARK: - CrossfeedProcessor

    func testCrossfeedOffIsPassthrough() {
        let crossfeed = CrossfeedProcessor(sampleRate: 48000)
        crossfeed.amount = 0.0
        XCTAssertTrue(crossfeed.isOff)

        let count = 256
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
        defer { interleaved.deallocate(); original.deallocate() }

        for i in 0..<(count * 2) { interleaved[i] = Float(i) * 0.001 }
        memcpy(original, interleaved, count * 2 * MemoryLayout<Float>.size)

        crossfeed.processInterleaved(interleaved, frameCount: count)

        for i in 0..<(count * 2) {
            XCTAssertEqual(interleaved[i], original[i], accuracy: 1e-7)
        }
    }

    func testCrossfeedBleedsOppositeChannel() {
        let crossfeed = CrossfeedProcessor(sampleRate: 48000)
        crossfeed.amount = 0.5

        let count = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        // Process multiple buffers so delay fills
        for _ in 0..<10 {
            for i in 0..<count {
                left[i]  = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
                right[i] = 0 // silence on right
            }
            crossfeed.processPlanar(left: left, right: right, count: count)
        }

        // Right channel should now have some signal bled from left
        var rightPower: Float = 0
        vDSP_svesq(right, 1, &rightPower, vDSP_Length(count))
        XCTAssertGreaterThan(rightPower, 0.01,
                             "Crossfeed should bleed left signal into right")
    }

    func testCrossfeedReset() {
        let crossfeed = CrossfeedProcessor(sampleRate: 48000)
        crossfeed.amount = 0.3

        let count = 128
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        for i in 0..<count { left[i] = 1.0; right[i] = -1.0 }
        crossfeed.processPlanar(left: left, right: right, count: count)

        crossfeed.reset()

        // After reset, processing silence should yield silence
        for i in 0..<count { left[i] = 0; right[i] = 0 }
        crossfeed.processPlanar(left: left, right: right, count: count)

        for i in 0..<count {
            XCTAssertEqual(left[i], 0, accuracy: 1e-5)
            XCTAssertEqual(right[i], 0, accuracy: 1e-5)
        }
    }

    // MARK: - StereoWidener Mono Collapse

    /// Width=0 must produce identical L and R (mono collapse).
    /// This is the M/S identity: Side=0 → L = R = (L+R)/2.
    /// Also serves as a regression test for the left-channel bug
    /// (left data not written back through the protocol path).
    func testMonoCollapseViaProtocolPath() {
        let widener = StereoWidener()
        widener.width = 0.0

        let count = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        // Different signals on L and R
        for i in 0..<count {
            left[i]  = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
            right[i] = sinf(2.0 * .pi * 880.0 * Float(i) / 48000.0)
        }

        // Use the AudioProcessor protocol path (the one that had the bug)
        widener.process(left: left, right: right, count: count)

        // After mono collapse, L and R should be identical
        for i in 0..<count {
            XCTAssertEqual(left[i], right[i], accuracy: 1e-5,
                           "Width=0 should produce identical L/R at sample \(i)")
        }

        // Verify the mono value is (original_L + original_R) / 2
        // Recompute expected mono for spot check at sample 100
        let expectedMono = (sinf(2.0 * .pi * 440.0 * 100.0 / 48000.0)
                          + sinf(2.0 * .pi * 880.0 * 100.0 / 48000.0)) / 2.0
        XCTAssertEqual(left[100], expectedMono, accuracy: 1e-4,
                       "Mono value should be (L+R)/2")
    }
}
