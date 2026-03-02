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
}
