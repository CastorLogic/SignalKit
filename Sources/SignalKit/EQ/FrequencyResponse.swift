// SignalKit - Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation // only for cosf/sinf/log10f/sqrtf via Darwin

/// Evaluates the frequency response of biquad IIR filters.
///
/// Given normalized coefficients [b0, b1, b2, a1, a2] (a0 = 1) and a sample rate,
/// computes magnitude (dB) and phase (radians) at arbitrary frequencies via the
/// z-transform: H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2),
/// evaluated at z = e^(j*2*pi*f/Fs).
///
/// Useful for verifying filter design, debugging EQ curves, and generating
/// data for frequency response plots.
public struct FrequencyResponse: Sendable {

    /// Magnitude in decibels at each frequency.
    public let magnitudeDB: [Float]

    /// Phase in radians at each frequency.
    public let phaseRadians: [Float]

    /// The frequencies (Hz) these values correspond to.
    public let frequencies: [Float]

    // MARK: - Single Stage

    /// Evaluate the frequency response of a single biquad stage.
    ///
    /// Coefficients use SignalKit's standard format: [b0, b1, b2, a1, a2],
    /// normalized so a0 = 1.
    ///
    /// - Parameters:
    ///   - b0: Numerator coefficient 0
    ///   - b1: Numerator coefficient 1
    ///   - b2: Numerator coefficient 2
    ///   - a1: Denominator coefficient 1 (sign convention: y[n] = b0*x[n] + ... - a1*y[n-1] - a2*y[n-2])
    ///   - a2: Denominator coefficient 2
    ///   - sampleRate: Sample rate in Hz
    ///   - frequencies: Array of frequencies (Hz) to evaluate
    /// - Returns: A `FrequencyResponse` with magnitude and phase at each frequency.
    public static func evaluate(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        sampleRate: Float,
        frequencies: [Float]
    ) -> FrequencyResponse {
        let count = frequencies.count
        var magDB = [Float](repeating: 0, count: count)
        var phase = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let w = 2.0 * Float.pi * frequencies[i] / sampleRate

            let cosW  = cosf(w)
            let sinW  = sinf(w)
            let cos2W = cosf(2.0 * w)
            let sin2W = sinf(2.0 * w)

            // Numerator: H_num = b0 + b1*e^(-jw) + b2*e^(-j2w)
            let numReal = b0 + b1 * cosW + b2 * cos2W
            let numImag = -(b1 * sinW + b2 * sin2W)

            // Denominator: H_den = 1 + a1*e^(-jw) + a2*e^(-j2w)
            // Note: our convention stores a1,a2 with the sign already for subtraction,
            // but the z-transform evaluates 1 + a1*z^-1 + a2*z^-2 directly.
            let denReal = 1.0 + a1 * cosW + a2 * cos2W
            let denImag = -(a1 * sinW + a2 * sin2W)

            // H(z) = num / den (complex division)
            let denMagSq = denReal * denReal + denImag * denImag
            let hReal = (numReal * denReal + numImag * denImag) / denMagSq
            let hImag = (numImag * denReal - numReal * denImag) / denMagSq

            let mag = sqrtf(hReal * hReal + hImag * hImag)
            magDB[i] = 20.0 * log10f(max(mag, 1e-20))
            phase[i] = atan2f(hImag, hReal)
        }

        return FrequencyResponse(magnitudeDB: magDB, phaseRadians: phase, frequencies: frequencies)
    }

    // MARK: - Cascade

    /// Evaluate the combined response of multiple cascaded biquad stages.
    ///
    /// The total magnitude in dB is the sum of individual stage magnitudes.
    /// The total phase is the sum of individual stage phases.
    ///
    /// - Parameters:
    ///   - stages: Array of coefficient tuples (b0, b1, b2, a1, a2).
    ///   - sampleRate: Sample rate in Hz.
    ///   - frequencies: Frequencies to evaluate.
    /// - Returns: Combined `FrequencyResponse`.
    public static func evaluateCascade(
        stages: [(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)],
        sampleRate: Float,
        frequencies: [Float]
    ) -> FrequencyResponse {
        let count = frequencies.count
        var totalMagDB = [Float](repeating: 0, count: count)
        var totalPhase = [Float](repeating: 0, count: count)

        for stage in stages {
            let response = evaluate(
                b0: stage.b0, b1: stage.b1, b2: stage.b2,
                a1: stage.a1, a2: stage.a2,
                sampleRate: sampleRate,
                frequencies: frequencies
            )
            for i in 0..<count {
                totalMagDB[i] += response.magnitudeDB[i]
                totalPhase[i] += response.phaseRadians[i]
            }
        }

        return FrequencyResponse(magnitudeDB: totalMagDB, phaseRadians: totalPhase, frequencies: frequencies)
    }

    // MARK: - Frequency Generation

    /// Generate logarithmically spaced frequencies between two bounds.
    ///
    /// Log spacing matches human pitch perception and is standard for
    /// audio frequency response plots.
    ///
    /// - Parameters:
    ///   - count: Number of frequency points (default: 256).
    ///   - from: Lower bound in Hz (default: 20).
    ///   - to: Upper bound in Hz (default: 20000).
    /// - Returns: Array of log-spaced frequencies.
    public static func logFrequencies(
        count: Int = 256,
        from: Float = 20,
        to: Float = 20000
    ) -> [Float] {
        guard count > 1 else { return [from] }
        let logFrom = log10f(from)
        let logTo = log10f(to)
        let step = (logTo - logFrom) / Float(count - 1)

        return (0..<count).map { i in
            powf(10.0, logFrom + Float(i) * step)
        }
    }
}
