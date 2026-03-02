import XCTest
import Accelerate
@testable import SignalKit

final class CompressorTests: XCTestCase {

    // MARK: - Bypass

    func testOffPresetIsPassthrough() {
        let comp = CompressorProcessor(sampleRate: 48000)
        comp.apply(preset: .off)

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate(); original.deallocate() }

        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.8
        }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        comp.process(input, count: count, channel: 0)

        for i in 0..<count {
            XCTAssertEqual(input[i], original[i], accuracy: 1e-6,
                           "1:1 ratio should be passthrough")
        }
    }

    func testIsOffProperty() {
        let comp = CompressorProcessor()
        comp.apply(preset: .off)
        XCTAssertTrue(comp.isOff)
        comp.apply(preset: .gentle)
        XCTAssertFalse(comp.isOff)
    }

    // MARK: - Gain Reduction

    func testLoudSignalGetsCompressed() {
        let comp = CompressorProcessor(sampleRate: 48000)
        comp.apply(preset: .moderate)

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        // Process several buffers so envelope settles
        for _ in 0..<10 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.9
            }
            comp.process(input, count: count, channel: 0)
        }

        // At least one band should report gain reduction
        let totalGR = comp.gainReduction.reduce(0, +)
        XCTAssertGreaterThan(totalGR, 0.1,
                             "Loud signal should trigger measurable gain reduction")
    }

    func testQuietSignalNotCompressed() {
        let comp = CompressorProcessor(sampleRate: 48000)
        comp.apply(preset: .gentle)

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        // Very quiet signal (well below threshold)
        for _ in 0..<5 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.001
            }
            comp.process(input, count: count, channel: 0)
        }

        let totalGR = comp.gainReduction.reduce(0, +)
        XCTAssertLessThan(totalGR, 0.5,
                          "Very quiet signal should have minimal gain reduction")
    }

    // MARK: - Preset

    func testPresetRoundTrip() {
        let comp = CompressorProcessor()
        comp.apply(preset: .gentle)
        let snapshot = comp.currentPreset()
        XCTAssertEqual(snapshot.bands.count, 3)
        XCTAssertEqual(snapshot.bands[0].threshold, -10)
    }

    // MARK: - Edge Cases

    func testSingleSampleBuffer() {
        let comp = CompressorProcessor(sampleRate: 48000)
        comp.apply(preset: .moderate)
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr[0] = 0.9
        comp.process(ptr, count: 1, channel: 0)
        // Should not crash
        XCTAssertFalse(ptr[0].isNaN, "Single sample should not produce NaN")
    }

    func testStereoProcessing() {
        let comp = CompressorProcessor(sampleRate: 48000, maxChannels: 2)
        comp.apply(preset: .moderate)
        let count = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        for i in 0..<count {
            left[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.8
            right[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.8
        }

        comp.process(left: left, right: right, count: count)
        // Should not crash, output should not be NaN
        XCTAssertFalse(left[count/2].isNaN)
        XCTAssertFalse(right[count/2].isNaN)
    }

    // MARK: - Reset

    func testResetClearsGainReduction() {
        let comp = CompressorProcessor(sampleRate: 48000)
        comp.apply(preset: .moderate)

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for _ in 0..<5 {
            for i in 0..<count { input[i] = 0.9 }
            comp.process(input, count: count, channel: 0)
        }

        comp.reset()
        XCTAssertEqual(comp.gainReduction, [0, 0, 0],
                       "Reset should zero gain reduction")
    }
}
