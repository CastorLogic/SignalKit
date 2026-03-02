// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation

// MARK: - Crossfeed Processor

/// Headphone crossfeed for natural stereo imaging.
///
/// Blends a delayed, low-passed fraction of each channel into the opposite ear,
/// simulating the acoustic crosstalk that loudspeakers provide naturally. Reduces
/// the "inside your head" effect of hard-panned headphone mixes.
///
/// Signal path per channel:
///   opposite_channel → delay (~0.3 ms ITD) → 1st-order LP (~700 Hz) → blend
///
/// The interaural time delay (ITD) approximates the ~0.3 ms path difference
/// between ears for a sound arriving from 30° off-center. The low-pass simulates
/// head-shadow frequency rolloff.
///
/// - Reference: Bauer, "Stereophonic Earphone Reproduction" (JAES, 1961)
public final class CrossfeedProcessor {

    /// Blend amount. 0 = off, 0.3 = natural crossfeed, 1.0 = mono.
    public var amount: Float = 0.0

    /// True when amount is negligible.
    public var isOff: Bool { amount < 0.01 }

    private let delaySamples: Int
    private var delayBufferL: UnsafeMutablePointer<Float>
    private var delayBufferR: UnsafeMutablePointer<Float>
    private var delayPos: Int = 0

    // 1st-order IIR low-pass state
    private var lpStateL: Float = 0
    private var lpStateR: Float = 0
    private var lpCoeff: Float

    public init(sampleRate: Double = 48000.0) {
        // ~0.3 ms ITD
        self.delaySamples = max(1, Int(sampleRate * 0.0003))

        self.delayBufferL = .allocate(capacity: delaySamples)
        self.delayBufferL.initialize(repeating: 0, count: delaySamples)
        self.delayBufferR = .allocate(capacity: delaySamples)
        self.delayBufferR.initialize(repeating: 0, count: delaySamples)

        // 1st-order LP at ~700 Hz: coeff = exp(−2π × fc / Fs)
        self.lpCoeff = Float(exp(-2.0 * Double.pi * 700.0 / sampleRate))
    }

    deinit {
        delayBufferL.deinitialize(count: delaySamples); delayBufferL.deallocate()
        delayBufferR.deinitialize(count: delaySamples); delayBufferR.deallocate()
    }

    /// Process interleaved stereo [L0, R0, L1, R1, ...] in-place.
    public func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !isOff else { return }

        let blend = amount
        let normFactor = 1.0 / (1.0 + blend * 0.5)

        for i in 0..<frameCount {
            let li = i * 2
            let ri = i * 2 + 1
            let left  = samples[li]
            let right = samples[ri]

            let delayedR = delayBufferR[delayPos]
            let delayedL = delayBufferL[delayPos]

            delayBufferL[delayPos] = left
            delayBufferR[delayPos] = right
            delayPos = (delayPos + 1) % delaySamples

            // LP filter the crossfed signal (attenuate highs, simulate head shadow)
            lpStateL = lpCoeff * lpStateL + (1.0 - lpCoeff) * delayedR
            lpStateR = lpCoeff * lpStateR + (1.0 - lpCoeff) * delayedL

            samples[li] = (left  + blend * lpStateL) * normFactor
            samples[ri] = (right + blend * lpStateR) * normFactor
        }
    }

    /// Process planar stereo (separate L/R buffers) in-place.
    public func processPlanar(left: UnsafeMutablePointer<Float>,
                              right: UnsafeMutablePointer<Float>,
                              count: Int) {
        guard !isOff else { return }

        let blend = amount
        let normFactor = 1.0 / (1.0 + blend * 0.5)

        for i in 0..<count {
            let l = left[i]
            let r = right[i]

            let delayedR = delayBufferR[delayPos]
            let delayedL = delayBufferL[delayPos]

            delayBufferL[delayPos] = l
            delayBufferR[delayPos] = r
            delayPos = (delayPos + 1) % delaySamples

            lpStateL = lpCoeff * lpStateL + (1.0 - lpCoeff) * delayedR
            lpStateR = lpCoeff * lpStateR + (1.0 - lpCoeff) * delayedL

            left[i]  = (l + blend * lpStateL) * normFactor
            right[i] = (r + blend * lpStateR) * normFactor
        }
    }

    /// Clear delay lines and filter state.
    public func reset() {
        for i in 0..<delaySamples {
            delayBufferL[i] = 0
            delayBufferR[i] = 0
        }
        delayPos = 0
        lpStateL = 0
        lpStateR = 0
    }
}
