import XCTest
import Accelerate
@testable import SignalKit

final class EQProcessorTests: XCTestCase {

    // MARK: - Passthrough

    func testFlatEQIsPassthrough() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate(); original.deallocate() }

        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0)
        }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        eq.process(input, count: count, channel: 0)

        for i in 0..<count {
            XCTAssertEqual(input[i], original[i], accuracy: 1e-6,
                           "Flat EQ should be passthrough at sample \(i)")
        }
    }

    func testIsFlatProperty() {
        let eq = EQProcessor()
        XCTAssertTrue(eq.isFlat)
        eq.setGain(3.0, forBand: 5)
        XCTAssertFalse(eq.isFlat)
        eq.setGain(0.0, forBand: 5)
        XCTAssertTrue(eq.isFlat)
    }

    // MARK: - Gain

    func testBoostIncreasesSignalPower() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        eq.setGain(12.0, forBand: 5) // +12 dB at 1 kHz

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate(); original.deallocate() }

        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.1
        }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        eq.process(input, count: count, channel: 0)

        var outputPower: Float = 0
        var inputPower: Float = 0
        vDSP_svesq(input, 1, &outputPower, vDSP_Length(count))
        vDSP_svesq(original, 1, &inputPower, vDSP_Length(count))

        XCTAssertGreaterThan(outputPower, inputPower * 2.0,
                             "12 dB boost should significantly increase power")
    }

    func testCutDecreasesPower() {
        let eq = EQProcessor(sampleRate: 48000)
        eq.setGain(-12.0, forBand: 5) // -12 dB at 1 kHz

        let count = 1024
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate(); original.deallocate() }

        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.5
        }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        // Process several times for filter to settle
        for _ in 0..<4 {
            for i in 0..<count {
                input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.5
            }
            eq.process(input, count: count, channel: 0)
        }

        var outputPower: Float = 0
        var inputPower: Float = 0
        vDSP_svesq(input, 1, &outputPower, vDSP_Length(count))
        vDSP_svesq(original, 1, &inputPower, vDSP_Length(count))

        XCTAssertLessThan(outputPower, inputPower * 0.5,
                          "12 dB cut should significantly decrease power")
    }

    func testGainClamping() {
        let eq = EQProcessor()
        eq.setGain(99.0, forBand: 0)
        XCTAssertEqual(eq.bands[0].gain, 12.0, "Gain should be clamped to +12")
        eq.setGain(-99.0, forBand: 0)
        XCTAssertEqual(eq.bands[0].gain, -12.0, "Gain should be clamped to -12")
    }

    // MARK: - Channel Independence

    func testChannelIndependence() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        eq.setGain(12.0, forBand: 5)

        let count = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }

        for i in 0..<count {
            left[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.5
            right[i] = 0 // silence on right
        }

        eq.process(left: left, right: right, count: count)

        // Right channel should remain silent
        for i in 0..<count {
            XCTAssertEqual(right[i], 0.0, accuracy: 1e-10,
                           "Silent right channel should stay silent")
        }
    }

    // MARK: - Edge Cases

    func testZeroLengthBufferNoOp() {
        let eq = EQProcessor()
        eq.setGain(6.0, forBand: 5)
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr[0] = 0.5
        eq.process(ptr, count: 0, channel: 0)
        XCTAssertEqual(ptr[0], 0.5, "Zero-length should be no-op")
    }

    func testInvalidChannelNoOp() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        eq.setGain(6.0, forBand: 5)
        let count = 64
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { ptr.deallocate() }
        for i in 0..<count { ptr[i] = Float(i) }
        eq.process(ptr, count: count, channel: 5) // invalid channel
        XCTAssertEqual(ptr[0], 0.0, "Invalid channel should be no-op")
    }

    func testInvalidBandIgnored() {
        let eq = EQProcessor()
        eq.setGain(6.0, forBand: -1)
        eq.setGain(6.0, forBand: 99)
        XCTAssertTrue(eq.isFlat, "Invalid band indices should be ignored")
    }

    // MARK: - Reset

    func testResetClearsState() {
        let eq = EQProcessor()
        eq.setGain(12.0, forBand: 5)
        XCTAssertFalse(eq.isFlat)
        eq.reset()
        XCTAssertTrue(eq.isFlat)
    }

    // MARK: - Preset

    func testPresetRoundTrip() {
        let eq = EQProcessor()
        eq.apply(preset: .bassBoost)
        let snapshot = eq.currentPreset()
        XCTAssertEqual(snapshot.gains, EQPreset.bassBoost.gains)
    }

    func testFlatPresetIsFlat() {
        XCTAssertTrue(EQPreset.flat.isFlat)
        XCTAssertFalse(EQPreset.bassBoost.isFlat)
    }

    // MARK: - Sample Rate

    func testSampleRateUpdateRecalculates() {
        let eq = EQProcessor(sampleRate: 44100)
        eq.setGain(6.0, forBand: 5)
        eq.updateSampleRate(48000)
        // Should not crash, and isFlat should still be false
        XCTAssertFalse(eq.isFlat)
    }
}
