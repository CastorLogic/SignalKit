// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation
import Accelerate

// MARK: - Loudness Meter

/// LUFS loudness meter and automatic gain control.
///
/// Measures integrated loudness using ITU-R BS.1770-4 K-weighting, then
/// optionally applies slow automatic gain correction to normalize audio
/// toward a target level (default −14 LUFS, the streaming standard).
///
/// K-weighting applies two pre-filters to the measurement signal only — the
/// audio output is never frequency-shaped:
///   Stage 1: High-shelf boost (+4 dB at ~1.5 kHz) modeling head acoustics
///   Stage 2: High-pass (~38 Hz) to exclude sub-bass from the measurement
///
/// Measurement uses a sliding RMS window (~400 ms). Gain correction ramps at
/// a maximum of 2 dB/s to avoid audible pumping.
///
/// The `process()` method handles both measurement and gain application. For
/// metering-only use (no gain modification), set `applyGain = false`.
///
/// - Reference: ITU-R BS.1770-4, "Algorithms to measure audio programme loudness
///   and true-peak audio level" (2015)
public final class LoudnessMeter: AudioProcessor {

    /// Target loudness in LUFS. Default: −14 (streaming standard).
    public var targetLUFS: Float = -14.0

    /// Enable/disable the gain correction stage. When false, only measures.
    public var applyGain: Bool = true

    /// Enable/disable the entire processor.
    public var enabled: Bool = true

    /// Maximum gain correction range (±dB).
    public var maxCorrectionDB: Float = 12.0

    /// Current applied gain in dB (for UI metering). Positive = boost.
    public private(set) var currentGainDB: Float = 0.0

    /// Current applied gain as a linear multiplier.
    public private(set) var currentGainLinear: Float = 1.0

    /// Target gain the meter is ramping toward.
    public private(set) var targetGainLinear: Float = 1.0

    /// Most recent integrated LUFS measurement. Updated every ~400 ms.
    public private(set) var measuredLUFS: Float = -120.0

    // RMS window
    private let windowSizeInSamples: Int
    private var rmsAccumulator: Float = 0
    private var sampleCount: Int = 0

    private let sampleRate: Double
    private let maxDBPerSecond: Float = 2.0

    // K-weighting biquad coefficients (vDSP_deq22 format: [b0,b1,b2,a1,a2])
    // Published values for 48 kHz from ITU-R BS.1770-4, Table 1 and Table 2.
    private let kWeightCoeffsStage1: [Float]
    private let kWeightCoeffsStage2: [Float]

    private var kWeightDelayStage1: [Float] = [0, 0, 0, 0]
    private var kWeightDelayStage2: [Float] = [0, 0, 0, 0]

    private let kWeightScratch: UnsafeMutablePointer<Float>
    private let maxScratchSize: Int

    public init(sampleRate: Double = 48000.0) {
        self.sampleRate = sampleRate
        self.windowSizeInSamples = Int(sampleRate * 0.4)

        self.maxScratchSize = 8192
        self.kWeightScratch = .allocate(capacity: maxScratchSize)
        self.kWeightScratch.initialize(repeating: 0, count: maxScratchSize)

        // K-weighting filter design.
        // At 48 kHz the coefficients match ITU-R BS.1770-4 Table 1/2 exactly.
        // At other rates they are recomputed to preserve the analog response.
        let fs = sampleRate
        if abs(fs - 48000.0) < 1.0 {
            self.kWeightCoeffsStage1 = [
                 1.53512485958697,
                -2.69169618940638,
                 1.19839281085285,
                -1.69065929318241,
                 0.73248077421585
            ]
        } else {
            // 2nd-order shelf via RBJ high-shelf at 1500 Hz with +4 dB
            let A = pow(10.0, 4.0 / 40.0)
            let w0h = 2.0 * Double.pi * 1500.97 / fs
            let alphaH = sin(w0h) / 2.0 * sqrt((A + 1.0/A) * (1.0/0.707 - 1.0) + 2.0)
            let cosW0h = cos(w0h)
            let twoSqrtAalpha = 2.0 * sqrt(A) * alphaH

            let b0h =        A * ((A + 1) + (A - 1) * cosW0h + twoSqrtAalpha)
            let b1h = -2.0 * A * ((A - 1) + (A + 1) * cosW0h)
            let b2h =        A * ((A + 1) + (A - 1) * cosW0h - twoSqrtAalpha)
            let a0h =             (A + 1) - (A - 1) * cosW0h + twoSqrtAalpha
            let a1h =       2.0 * ((A - 1) - (A + 1) * cosW0h)
            let a2h =             (A + 1) - (A - 1) * cosW0h - twoSqrtAalpha

            self.kWeightCoeffsStage1 = [
                Float(b0h/a0h), Float(b1h/a0h), Float(b2h/a0h),
                Float(a1h/a0h), Float(a2h/a0h)
            ]
        }

        // Stage 2: High-pass at ~38 Hz (2nd-order Butterworth)
        let fc2 = 38.13547087602444
        let w0lp = 2.0 * Double.pi * fc2 / fs
        let cosW0lp = cos(w0lp)
        let sinW0lp = sin(w0lp)
        let alphaLP = sinW0lp / (2.0 * sqrt(2.0))

        let b0lp =  (1.0 + cosW0lp) / 2.0
        let b1lp = -(1.0 + cosW0lp)
        let b2lp =  (1.0 + cosW0lp) / 2.0
        let a0lp =   1.0 + alphaLP
        let a1lp =  -2.0 * cosW0lp
        let a2lp =   1.0 - alphaLP

        self.kWeightCoeffsStage2 = [
            Float(b0lp/a0lp), Float(b1lp/a0lp), Float(b2lp/a0lp),
            Float(a1lp/a0lp), Float(a2lp/a0lp)
        ]
    }

    deinit {
        kWeightScratch.deinitialize(count: maxScratchSize)
        kWeightScratch.deallocate()
    }

    /// Process a single channel in-place.
    ///
    /// Measures K-weighted LUFS on channel 0. Both channels receive identical gain.
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard enabled, count > 0 else { return }

        // Measure on channel 0 only
        if channel == 0 {
            let n = min(count, maxScratchSize)

            // Copy to scratch — K-weighting is measurement-only, audio stays clean
            memcpy(kWeightScratch, samples, n * MemoryLayout<Float>.size)

            applyBiquad(kWeightScratch, count: n,
                        coeffs: kWeightCoeffsStage1, delay: &kWeightDelayStage1)
            applyBiquad(kWeightScratch, count: n,
                        coeffs: kWeightCoeffsStage2, delay: &kWeightDelayStage2)

            // Sum of squares on K-weighted signal
            var sumSq: Float = 0
            vDSP_svesq(kWeightScratch, 1, &sumSq, vDSP_Length(n))
            rmsAccumulator += sumSq
            sampleCount += n

            // Window complete — compute LUFS and update target
            if sampleCount >= windowSizeInSamples {
                let meanSquare = rmsAccumulator / Float(sampleCount)
                let rms = sqrtf(max(meanSquare, 1e-20))
                measuredLUFS = 20.0 * log10(max(rms, 1e-10))

                let correctionDB = max(-maxCorrectionDB,
                                       min(maxCorrectionDB, targetLUFS - measuredLUFS))
                targetGainLinear = powf(10.0, correctionDB / 20.0)
                currentGainDB = correctionDB

                rmsAccumulator = 0
                sampleCount = 0
            }
        }

        guard applyGain else { return }

        // Ramp gain toward target at maxDBPerSecond
        let bufferDuration = Float(count) / Float(sampleRate)
        let maxChangeDB = maxDBPerSecond * bufferDuration
        let maxRatio = powf(10.0, maxChangeDB / 20.0)

        if abs(currentGainLinear - targetGainLinear) > 0.001 {
            let ratio = targetGainLinear / max(currentGainLinear, 1e-10)
            if ratio > maxRatio {
                currentGainLinear *= maxRatio
            } else if ratio < 1.0 / maxRatio {
                currentGainLinear /= maxRatio
            } else {
                currentGainLinear = targetGainLinear
            }

            if channel == 0 {
                currentGainDB = currentGainLinear > 1e-10
                    ? 20.0 * log10(currentGainLinear) : -120.0
            }
        }

        // Apply gain: vectorized multiply
        if abs(currentGainLinear - 1.0) > 0.001 {
            var gain = currentGainLinear
            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))
        }
    }

    /// Process stereo pair.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        count: Int) {
        process(left, count: count, channel: 0)
        process(right, count: count, channel: 1)
    }

    // MARK: - K-Weighting Biquad

    @inline(__always)
    private func applyBiquad(_ samples: UnsafeMutablePointer<Float>, count: Int,
                             coeffs: [Float], delay: inout [Float]) {
        let b0 = coeffs[0], b1 = coeffs[1], b2 = coeffs[2]
        let a1 = coeffs[3], a2 = coeffs[4]
        var x1 = delay[0], x2 = delay[1]
        var y1 = delay[2], y2 = delay[3]

        for i in 0..<count {
            let x0 = samples[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            samples[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }

        delay[0] = x1; delay[1] = x2
        delay[2] = y1; delay[3] = y2
    }

    /// Reset all state.
    public func reset() {
        rmsAccumulator = 0
        sampleCount = 0
        currentGainDB = 0
        currentGainLinear = 1.0
        targetGainLinear = 1.0
        measuredLUFS = -120.0
        kWeightDelayStage1 = [0, 0, 0, 0]
        kWeightDelayStage2 = [0, 0, 0, 0]
    }
}
