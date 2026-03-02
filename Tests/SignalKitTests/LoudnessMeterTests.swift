import XCTest
import Accelerate
@testable import SignalKit

final class LoudnessMeterTests: XCTestCase {

    // MARK: - Measurement

    func testSilenceMeasuresVeryLow() {
        let meter = LoudnessMeter(sampleRate: 48000)
        meter.applyGain = false

        let count = 512
        let silence = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { silence.deallocate() }

        // Feed enough silence to complete a measurement window (400ms ≈ 19200 samples)
        for _ in 0..<40 {
            for i in 0..<count { silence[i] = 0 }
            meter.process(silence, count: count, channel: 0)
        }

        XCTAssertLessThan(meter.measuredLUFS, -80,
                          "Silence should measure well below -80 LUFS")
    }

    func testLoudSignalMeasuresHigher() {
        let meter = LoudnessMeter(sampleRate: 48000)
        meter.applyGain = false

        let count = 512
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate() }

        // Feed loud sine to fill measurement window
        for _ in 0..<40 {
            for i in 0..<count {
                signal[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.5
            }
            meter.process(signal, count: count, channel: 0)
        }

        XCTAssertGreaterThan(meter.measuredLUFS, -30,
                             "0.5 amplitude sine should measure above -30 LUFS")
    }

    // MARK: - Gain Application

    func testGainApplied() {
        let meter = LoudnessMeter(sampleRate: 48000)
        meter.targetLUFS = -14.0
        meter.applyGain = true

        let count = 512
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate(); original.deallocate() }

        // Process many buffers to let gain settle
        for _ in 0..<80 {
            for i in 0..<count {
                signal[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.01
            }
            memcpy(original, signal, count * MemoryLayout<Float>.size)
            meter.process(signal, count: count, channel: 0)
        }

        // Quiet input should be boosted
        var outPower: Float = 0
        var inPower: Float = 0
        vDSP_svesq(signal, 1, &outPower, vDSP_Length(count))
        vDSP_svesq(original, 1, &inPower, vDSP_Length(count))

        XCTAssertGreaterThan(outPower, inPower,
                             "Quiet signal should be boosted toward target")
    }

    func testApplyGainFalseSkipsGain() {
        let meter = LoudnessMeter(sampleRate: 48000)
        meter.applyGain = false

        let count = 256
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate(); original.deallocate() }

        for i in 0..<count {
            signal[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.01
        }
        memcpy(original, signal, count * MemoryLayout<Float>.size)

        // Process many buffers
        for _ in 0..<80 {
            for i in 0..<count {
                signal[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.01
            }
            meter.process(signal, count: count, channel: 0)
        }

        // With applyGain=false, last buffer should be untouched
        for i in 0..<count {
            signal[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.01
        }
        memcpy(original, signal, count * MemoryLayout<Float>.size)
        meter.process(signal, count: count, channel: 0)

        for i in 0..<count {
            XCTAssertEqual(signal[i], original[i], accuracy: 1e-6,
                           "applyGain=false should not modify audio")
        }
    }

    // MARK: - Disabled

    func testDisabledIsPassthrough() {
        let meter = LoudnessMeter(sampleRate: 48000)
        meter.enabled = false

        let count = 64
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate() }
        for i in 0..<count { signal[i] = Float(i) * 0.1 }

        let saved = signal[32]
        meter.process(signal, count: count, channel: 0)
        XCTAssertEqual(signal[32], saved, accuracy: 1e-7)
    }

    // MARK: - Reset

    func testResetClearsAll() {
        let meter = LoudnessMeter(sampleRate: 48000)
        let count = 512
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate() }

        for _ in 0..<40 {
            for i in 0..<count { signal[i] = 0.5 }
            meter.process(signal, count: count, channel: 0)
        }

        meter.reset()
        XCTAssertEqual(meter.currentGainDB, 0)
        XCTAssertEqual(meter.currentGainLinear, 1.0)
        XCTAssertEqual(meter.measuredLUFS, -120.0)
    }

    // MARK: - Sample Rate Independence

    func testMeasurementAt44100Hz() {
        let meter = LoudnessMeter(sampleRate: 44100)
        meter.applyGain = false

        let count = 512
        let signal = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { signal.deallocate() }

        // Feed loud sine to fill measurement window (~400ms = 17640 samples at 44.1kHz)
        for _ in 0..<40 {
            for i in 0..<count {
                signal[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 44100.0) * 0.5
            }
            meter.process(signal, count: count, channel: 0)
        }

        // Should still produce a reasonable LUFS reading
        XCTAssertGreaterThan(meter.measuredLUFS, -30,
                             "1kHz sine at 44.1kHz should measure above -30 LUFS")
        XCTAssertLessThan(meter.measuredLUFS, 0,
                          "Should not exceed 0 LUFS")
    }

    // MARK: - AudioProcessor Protocol

    func testConformsToAudioProcessor() {
        let meter = LoudnessMeter(sampleRate: 48000)
        let processor: AudioProcessor = meter
        processor.reset()
    }
}
