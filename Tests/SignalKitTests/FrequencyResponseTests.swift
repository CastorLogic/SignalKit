// SignalKit - Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import XCTest
@testable import SignalKit

final class FrequencyResponseTests: XCTestCase {

    let sampleRate: Float = 48000

    // MARK: - Unity (Passthrough)

    func testUnityCoefficientsProduceFlatResponse() {
        // b0=1, b1=0, b2=0, a1=0, a2=0 is a wire (output = input).
        let freqs = FrequencyResponse.logFrequencies(count: 64)
        let response = FrequencyResponse.evaluate(
            b0: 1, b1: 0, b2: 0, a1: 0, a2: 0,
            sampleRate: sampleRate,
            frequencies: freqs
        )

        for i in 0..<freqs.count {
            XCTAssertEqual(response.magnitudeDB[i], 0.0, accuracy: 0.001,
                           "Unity filter should be 0 dB at \(freqs[i]) Hz")
            XCTAssertEqual(response.phaseRadians[i], 0.0, accuracy: 0.001,
                           "Unity filter should have 0 phase at \(freqs[i]) Hz")
        }
    }

    // MARK: - Known Peaking Filter

    func testPeakingFilterBoostAtCenter() {
        // Compute a +6 dB peaking filter at 1 kHz, Q=1.0 using RBJ Cookbook formulas.
        let f0: Float = 1000
        let gainDB: Float = 6.0
        let Q: Float = 1.0
        let A = powf(10, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * f0 / sampleRate
        let alpha = sinf(w0) / (2.0 * Q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosf(w0)
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosf(w0)
        let a2 = 1.0 - alpha / A

        // Normalize by a0
        let response = FrequencyResponse.evaluate(
            b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0,
            sampleRate: sampleRate,
            frequencies: [f0]
        )

        XCTAssertEqual(response.magnitudeDB[0], gainDB, accuracy: 0.1,
                       "Peaking filter should read \(gainDB) dB at center frequency")
    }

    // MARK: - Cascade Equals Sum

    func testCascadeMagnitudeIsSumOfStages() {
        // Two identical stages in cascade should produce 2x the magnitude in dB.
        let coeffs: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) = (
            b0: 1.05, b1: -1.9, b2: 0.92, a1: -1.9, a2: 0.9
        )
        let freqs = FrequencyResponse.logFrequencies(count: 32)

        let single = FrequencyResponse.evaluate(
            b0: coeffs.b0, b1: coeffs.b1, b2: coeffs.b2,
            a1: coeffs.a1, a2: coeffs.a2,
            sampleRate: sampleRate, frequencies: freqs
        )
        let cascade = FrequencyResponse.evaluateCascade(
            stages: [coeffs, coeffs],
            sampleRate: sampleRate, frequencies: freqs
        )

        for i in 0..<freqs.count {
            XCTAssertEqual(cascade.magnitudeDB[i], 2.0 * single.magnitudeDB[i], accuracy: 0.01,
                           "Cascade of 2 identical stages should double the dB magnitude")
        }
    }

    // MARK: - DC and Nyquist

    func testDCResponse() {
        // At DC (0 Hz), z = 1, so H(1) = (b0+b1+b2) / (1+a1+a2).
        let b0: Float = 1.0, b1: Float = 0.5, b2: Float = 0.25
        let a1: Float = -0.3, a2: Float = 0.1

        let response = FrequencyResponse.evaluate(
            b0: b0, b1: b1, b2: b2, a1: a1, a2: a2,
            sampleRate: sampleRate, frequencies: [0.001] // near DC
        )

        let expectedMag = (b0 + b1 + b2) / (1.0 + a1 + a2)
        let expectedDB = 20.0 * log10f(expectedMag)

        XCTAssertEqual(response.magnitudeDB[0], expectedDB, accuracy: 0.05,
                       "DC magnitude should match analytical (b0+b1+b2)/(1+a1+a2)")
    }

    func testNyquistResponse() {
        // At Nyquist (fs/2), z = -1, so H(-1) = (b0-b1+b2) / (1-a1+a2).
        let b0: Float = 1.0, b1: Float = 0.5, b2: Float = 0.25
        let a1: Float = -0.3, a2: Float = 0.1
        let nyquist = sampleRate / 2.0

        let response = FrequencyResponse.evaluate(
            b0: b0, b1: b1, b2: b2, a1: a1, a2: a2,
            sampleRate: sampleRate, frequencies: [nyquist - 1] // just below Nyquist
        )

        let expectedMag = (b0 - b1 + b2) / (1.0 - a1 + a2)
        let expectedDB = 20.0 * log10f(expectedMag)

        XCTAssertEqual(response.magnitudeDB[0], expectedDB, accuracy: 0.2,
                       "Near-Nyquist magnitude should approximate (b0-b1+b2)/(1-a1+a2)")
    }

    // MARK: - Log Frequencies

    func testLogFrequenciesRange() {
        let freqs = FrequencyResponse.logFrequencies(count: 128, from: 20, to: 20000)

        XCTAssertEqual(freqs.count, 128)
        XCTAssertEqual(freqs.first!, 20.0, accuracy: 0.01)
        XCTAssertEqual(freqs.last!, 20000.0, accuracy: 1.0)

        // Verify monotonically increasing
        for i in 1..<freqs.count {
            XCTAssertGreaterThan(freqs[i], freqs[i-1],
                                "Log frequencies must be monotonically increasing")
        }
    }

    func testLogFrequenciesSinglePoint() {
        let freqs = FrequencyResponse.logFrequencies(count: 1, from: 1000, to: 10000)
        XCTAssertEqual(freqs.count, 1)
        XCTAssertEqual(freqs[0], 1000.0, accuracy: 0.01)
    }

    // MARK: - Phase

    func testSymmetricFilterHasZeroPhaseAtDC() {
        // A symmetric denominator/numerator pair should have ~0 phase near DC.
        let response = FrequencyResponse.evaluate(
            b0: 1, b1: 0, b2: 0, a1: 0, a2: 0,
            sampleRate: sampleRate,
            frequencies: [1.0]  // near DC
        )

        XCTAssertEqual(response.phaseRadians[0], 0.0, accuracy: 0.001,
                       "Unity filter should have zero phase near DC")
    }
}
