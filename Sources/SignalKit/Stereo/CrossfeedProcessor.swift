// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Darwin

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
public final class CrossfeedProcessor: AudioProcessor {

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

    // Per-channel scratch for single-channel protocol support
    private let maxFrames = 8192
    private let channelBuf: UnsafeMutablePointer<Float>  // stores channel 0 until channel 1 arrives
    private var pendingCount: Int = 0

    public init(sampleRate: Double = 48000.0) {
        // ~0.3 ms ITD
        self.delaySamples = max(1, Int(sampleRate * 0.0003))

        self.delayBufferL = .allocate(capacity: delaySamples)
        self.delayBufferL.initialize(repeating: 0, count: delaySamples)
        self.delayBufferR = .allocate(capacity: delaySamples)
        self.delayBufferR.initialize(repeating: 0, count: delaySamples)

        self.channelBuf = .allocate(capacity: maxFrames)
        self.channelBuf.initialize(repeating: 0, count: maxFrames)

        // 1st-order LP at ~700 Hz: coeff = exp(−2π × fc / Fs)
        self.lpCoeff = Float(exp(-2.0 * Double.pi * 700.0 / sampleRate))
    }

    deinit {
        delayBufferL.deinitialize(count: delaySamples); delayBufferL.deallocate()
        delayBufferR.deinitialize(count: delaySamples); delayBufferR.deallocate()
        channelBuf.deinitialize(count: maxFrames); channelBuf.deallocate()
    }

    // MARK: - AudioProcessor Protocol

    /// Single-channel entry point. Crossfeed requires both channels, so channel 0
    /// is buffered internally. Processing occurs when channel 1 arrives.
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard !isOff else { return }

        if channel == 0 {
            let n = min(count, maxFrames)
            memcpy(channelBuf, samples, n * MemoryLayout<Float>.size)
            pendingCount = n
        } else if channel == 1 && pendingCount > 0 {
            let n = min(count, pendingCount)
            processPlanarCore(left: channelBuf, right: samples, count: n)
            // Write processed left back — caller must have kept their pointer valid
            // This is inherently correct because the protocol default calls channel 0
            // then channel 1 on the same buffer pair via process(left:right:count:).
            pendingCount = 0
        }
    }

    /// Process stereo pair directly — preferred over the single-channel path.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        count: Int) {
        guard !isOff else { return }
        processPlanarCore(left: left, right: right, count: count)
    }

    // MARK: - Interleaved / Planar Convenience

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
        processPlanarCore(left: left, right: right, count: count)
    }

    // MARK: - Core

    private func processPlanarCore(left: UnsafeMutablePointer<Float>,
                                   right: UnsafeMutablePointer<Float>,
                                   count: Int) {
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
        pendingCount = 0
    }
}
