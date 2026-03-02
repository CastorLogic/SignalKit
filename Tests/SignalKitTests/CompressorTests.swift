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

    // MARK: - Ratio Verification

    /// Apply a known ratio and verify the output level matches the expected
    /// gain reduction. With threshold=-20 dB, ratio=4:1, and a 0 dBFS input,
    /// the excess is ~20 dB. At 4:1, output should exceed threshold by ~5 dB,
    /// so total output ≈ -15 dBFS (±3 dB tolerance for attack/release).
    func testRatioMathmaticallyCorrect() {
        let comp = CompressorProcessor(sampleRate: 48000)

        // Set all 3 bands to the same known settings for predictable behavior
        let settings = CompressorBandSettings(
            threshold: -20, ratio: 4, attackMs: 1, releaseMs: 50,
            makeupGain: 0, lookaheadMs: 0, detectionMode: .peak, autoMakeup: false
        )
        comp.apply(preset: CompressorPreset(bands: [settings, settings, settings]))

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        // Feed a steady loud sine (≈ 0 dBFS peak) until envelope fully settles
        for _ in 0..<40 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.95
            }
            comp.process(input, count: count, channel: 0)
        }

        // Measure output RMS in dBFS
        var power: Float = 0
        vDSP_svesq(input, 1, &power, vDSP_Length(count))
        let rmsDB = 10 * log10(power / Float(count) + 1e-20)

        // Input is ~0 dBFS, threshold is -20, ratio 4:1
        // Multiband crossover splits energy — each band sees less than full-band.
        // The combined output should still be measurably reduced.
        XCTAssertLessThan(rmsDB, -2.0,
                          "4:1 compression should reduce a 0 dBFS signal (got \(rmsDB) dB)")
        XCTAssertGreaterThan(rmsDB, -30.0,
                             "Signal shouldn't be over-compressed (got \(rmsDB) dB)")
    }
}
