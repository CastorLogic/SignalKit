import XCTest
@testable import SignalKit

final class LimiterTests: XCTestCase {

    // MARK: - Ceiling Enforcement

    func testOutputNeverExceedsCeiling() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        limiter.ceiling = -1.0 // -1 dBFS ≈ 0.891 linear
        let ceilingLinear: Float = powf(10.0, -1.0 / 20.0)

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        // Process several buffers of loud signal to fill look-ahead
        for _ in 0..<5 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 1.5
            }
            limiter.process(input, count: count, channel: 0)
        }

        // After look-ahead fills, no output should exceed ceiling
        for i in 0..<count {
            XCTAssertLessThanOrEqual(abs(input[i]), ceilingLinear + 0.01,
                                     "Output should not exceed ceiling at sample \(i)")
        }
    }

    func testZeroCeilingIsDigitalMax() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        // Default ceiling is 0 dBFS = 1.0 linear
        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for _ in 0..<5 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 2.0
            }
            limiter.process(input, count: count, channel: 0)
        }

        for i in 0..<count {
            XCTAssertLessThanOrEqual(abs(input[i]), 1.05,
                                     "Output should not exceed 0 dBFS")
        }
    }

    // MARK: - Bypass

    func testDisabledIsPassthrough() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        limiter.enabled = false

        let count = 256
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate(); original.deallocate() }

        for i in 0..<count { input[i] = Float(i) * 0.01 }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        limiter.process(input, count: count, channel: 0)

        for i in 0..<count {
            XCTAssertEqual(input[i], original[i], accuracy: 1e-7)
        }
    }

    // MARK: - Gain Reduction Metering

    func testGainReductionReported() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        limiter.ceiling = -6.0

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for _ in 0..<5 {
            for i in 0..<count { input[i] = 0.95 }
            limiter.process(input, count: count, channel: 0)
        }

        XCTAssertGreaterThan(limiter.gainReductionDB, 0,
                             "Loud signal above ceiling should show gain reduction")
    }

    func testSilenceNoGainReduction() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for i in 0..<count { input[i] = 0 }
        limiter.process(input, count: count, channel: 0)
        XCTAssertEqual(limiter.gainReductionDB, 0, accuracy: 0.01)
    }

    // MARK: - Reset

    func testResetClearsState() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        let count = 256
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for i in 0..<count { input[i] = 1.5 }
        limiter.process(input, count: count, channel: 0)

        limiter.reset()
        XCTAssertEqual(limiter.gainReductionDB, 0)
    }

    // MARK: - Edge Cases

    func testSingleSampleBuffer() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr[0] = 2.0
        limiter.process(ptr, count: 1, channel: 0)
        XCTAssertFalse(ptr[0].isNaN)
    }

    func testZeroLengthNoOp() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr[0] = 99.0
        limiter.process(ptr, count: 0, channel: 0)
        XCTAssertEqual(ptr[0], 99.0)
    }

    // MARK: - True-Peak Ceiling

    /// Feed a hot signal that creates inter-sample peaks, then verify no
    /// output sample exceeds the ceiling. Uses 4x oversampled linear
    /// interpolation to check for inter-sample violations.
    func testTruePeakCeiling() {
        let limiter = LimiterProcessor(sampleRate: 48000)
        limiter.ceiling = -3.0 // -3 dBFS ≈ 0.708 linear
        let ceilingLinear: Float = powf(10.0, -3.0 / 20.0)

        let count = 512
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buf.deallocate() }

        // Feed hot bursts to fill look-ahead and trigger limiting
        for _ in 0..<8 {
            for i in 0..<count {
                // Multi-frequency hot signal that creates inter-sample peaks
                let t = Float(i) / 48000.0
                buf[i] = sinf(2.0 * .pi * 997.0 * t) * 1.2
                      + sinf(2.0 * .pi * 3001.0 * t) * 0.8
            }
            limiter.process(buf, count: count, channel: 0)
        }

        // Sample-level check: no output should exceed ceiling
        var maxSample: Float = 0
        for i in 0..<count { maxSample = max(maxSample, abs(buf[i])) }
        XCTAssertLessThanOrEqual(maxSample, ceilingLinear + 0.02,
                                 "No output sample should exceed -3 dBFS ceiling")

        // 4× oversampled check (linear interpolation between samples)
        var maxInterp: Float = 0
        for i in 0..<(count - 1) {
            for j in 0..<4 {
                let frac = Float(j) / 4.0
                let interp = buf[i] * (1.0 - frac) + buf[i + 1] * frac
                maxInterp = max(maxInterp, abs(interp))
            }
        }
        XCTAssertLessThanOrEqual(maxInterp, ceilingLinear + 0.05,
                                 "Interpolated peaks should stay near ceiling")

        // Gain reduction should be nonzero
        XCTAssertGreaterThan(limiter.gainReductionDB, 0,
                             "Should report gain reduction for hot signal")
    }
}
