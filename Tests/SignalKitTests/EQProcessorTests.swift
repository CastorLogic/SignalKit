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

    // MARK: - Frequency Accuracy (DFT)

    /// Verify that a +12 dB boost at band 5 (1 kHz) actually increases energy
    /// in the 800-1200 Hz region relative to the 4-8 kHz region.
    /// Uses vDSP DFT for spectral analysis, the way audio engineers validate EQ.
    func testFrequencyResponseViaDFT() {
        let sampleRate: Double = 48000
        let eq = EQProcessor(sampleRate: sampleRate, maxChannels: 1)
        eq.setGain(12.0, forBand: 5) // +12 dB at 1 kHz

        // Generate white noise (deterministic seed via linear congruential)
        let N = 4096
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: N)
        defer { buf.deallocate() }
        var seed: UInt32 = 42
        for i in 0..<N {
            seed = seed &* 1664525 &+ 1013904223
            buf[i] = Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }

        // Settle the filter, then process the analysis buffer
        for _ in 0..<4 { eq.process(buf, count: N, channel: 0) }
        // Regenerate and process once more for clean analysis
        seed = 42
        for i in 0..<N {
            seed = seed &* 1664525 &+ 1013904223
            buf[i] = Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        eq.process(buf, count: N, channel: 0)

        // DFT via Accelerate. use raw pointers for safe scoping
        let halfN = N / 2
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer { realp.deallocate(); imagp.deallocate() }
        realp.initialize(repeating: 0, count: halfN)
        imagp.initialize(repeating: 0, count: halfN)

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        buf.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
        }

        let log2n = vDSP_Length(log2(Float(N)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            XCTFail("Failed to create FFT setup"); return
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // Compute magnitude squared per bin
        var magnitudes = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))

        // Bin resolution = sampleRate / N = 48000/4096 ≈ 11.72 Hz
        let binRes = Float(sampleRate) / Float(N)
        let boostLo = Int(800 / binRes)   // ~68
        let boostHi = Int(1200 / binRes)  // ~102
        let refLo   = Int(4000 / binRes)  // ~341
        let refHi   = Int(8000 / binRes)  // ~682

        var boostPower: Float = 0
        for i in boostLo...boostHi { boostPower += magnitudes[i] }
        boostPower /= Float(boostHi - boostLo + 1)

        var refPower: Float = 0
        for i in refLo...refHi { refPower += magnitudes[i] }
        refPower /= Float(refHi - refLo + 1)

        let boostDB = 10 * log10(boostPower / max(refPower, 1e-20))
        XCTAssertGreaterThan(boostDB, 8.0,
                             "1 kHz region should be >8 dB louder than 4-8 kHz (got \(boostDB) dB)")
    }

    // MARK: - Cross-Sample-Rate Consistency

    /// Verify EQ produces similar boost at 1 kHz regardless of sample rate.
    /// Proves the bilinear transform pre-warps correctly.
    func testCrossSampleRateConsistency() {
        let rates: [Double] = [44100, 96000]
        var outputPowers = [Float]()

        for rate in rates {
            let eq = EQProcessor(sampleRate: rate, maxChannels: 1)
            eq.setGain(6.0, forBand: 5) // +6 dB at 1 kHz

            let count = 2048
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { buf.deallocate() }

            // Settle + measure
            for _ in 0..<8 {
                for i in 0..<count {
                    buf[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / Float(rate)) * 0.3
                }
                eq.process(buf, count: count, channel: 0)
            }

            var power: Float = 0
            vDSP_svesq(buf, 1, &power, vDSP_Length(count))
            outputPowers.append(power / Float(count))
        }

        // Both should produce similar RMS. within 1.5 dB
        let diffDB = abs(10 * log10(outputPowers[0] / max(outputPowers[1], 1e-20)))
        XCTAssertLessThan(diffDB, 1.5,
                          "EQ at 44.1k and 96k should agree within 1.5 dB (got \(diffDB) dB)")
    }

    // MARK: - NaN / Denormal Robustness

    /// Processors must survive corrupt input (NaN, Inf, denormals) without
    /// crashing, and must recover after reset().
    func testNaNAndInfRobustness() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 1)
        eq.setGain(6.0, forBand: 5)

        let count = 64
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buf.deallocate() }

        // Feed corrupt data
        for i in 0..<count {
            switch i % 4 {
            case 0: buf[i] = .nan
            case 1: buf[i] = .infinity
            case 2: buf[i] = -.infinity
            case 3: buf[i] = 1.0e-40 // denormal
            default: buf[i] = 0
            }
        }
        eq.process(buf, count: count, channel: 0) // must not crash

        // Reset and verify recovery with normal input
        eq.reset()
        for i in 0..<count {
            buf[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.5
        }
        eq.process(buf, count: count, channel: 0)

        var hasFinite = false
        for i in 0..<count {
            if buf[i].isFinite { hasFinite = true; break }
        }
        XCTAssertTrue(hasFinite, "EQ should recover finite output after reset()")
    }
}
