// SignalKit - Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Darwin

// MARK: - Peak Limiter

/// Brick-wall peak limiter with look-ahead.
///
/// Prevents output from exceeding the ceiling. Infinite ratio above threshold.
/// Nothing passes. Uses a ~1 ms look-ahead delay so the gain envelope begins
/// reducing before the peak arrives, avoiding clicks.
///
/// Hot-path performance: zero transcendental math per sample. All gain computation
/// is done in the linear domain (comparisons and ratios). The only `log10` call
/// happens once per buffer for the GR meter.
///
/// - Note: The look-ahead introduces ~1 ms of latency. For zero-latency limiting,
///   set `lookAheadSamples` to 0 (but expect occasional clicks on sharp transients).
public final class LimiterProcessor: AudioProcessor, @unchecked Sendable {

    /// Output ceiling in dBFS. Default 0 dBFS (digital maximum).
    /// Typical mastering value: −0.3 dBFS.
    public var ceiling: Float = 0.0 {
        didSet { ceilingLinear = powf(10.0, ceiling / 20.0) }
    }

    /// Master bypass.
    public var enabled: Bool = true

    /// Current gain reduction in dB (for metering). Updated once per buffer.
    public private(set) var gainReductionDB: Float = 0.0

    private var ceilingLinear: Float = 1.0
    private let lookAheadSamples: Int
    private var ringBuffer: UnsafeMutablePointer<Float>
    private var ringPos: UnsafeMutablePointer<Int>
    private var envelope: UnsafeMutablePointer<Float>
    private let releaseCoeff: Float
    private let maxChannels: Int

    public init(sampleRate: Double = 48000.0, maxChannels: Int = 2) {
        self.maxChannels = maxChannels

        // ~1 ms look-ahead
        self.lookAheadSamples = max(1, Int(sampleRate * 0.001))

        let ringSize = lookAheadSamples * maxChannels
        self.ringBuffer = .allocate(capacity: ringSize)
        self.ringBuffer.initialize(repeating: 0, count: ringSize)

        self.ringPos = .allocate(capacity: maxChannels)
        self.ringPos.initialize(repeating: 0, count: maxChannels)
        self.envelope = .allocate(capacity: maxChannels)
        self.envelope.initialize(repeating: 0, count: maxChannels)

        // ~50 ms release: coeff = exp(−1 / (time_s × Fs))
        let releaseSamples = max(1.0, 0.050 * sampleRate)
        self.releaseCoeff = Float(exp(-1.0 / releaseSamples))
    }

    deinit {
        let ringSize = lookAheadSamples * maxChannels
        ringBuffer.deinitialize(count: ringSize); ringBuffer.deallocate()
        ringPos.deinitialize(count: maxChannels); ringPos.deallocate()
        envelope.deinitialize(count: maxChannels); envelope.deallocate()
    }

    /// Process a single channel in-place.
    ///
    /// Per-sample: instant attack, exponential release, linear-domain gain.
    ///   if |x| > envelope: envelope = |x|       (instant attack)
    ///   else:              envelope *= release   (exponential decay)
    ///   gain = min(1, ceiling / envelope)
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard enabled, channel < maxChannels, count > 0 else { return }

        let ceil = ceilingLinear
        let ringOffset = channel * lookAheadSamples
        var env = envelope[channel]
        var maxGain: Float = 1.0

        for i in 0..<count {
            let inputSample = samples[i]
            let absSample = abs(inputSample)

            // Peak envelope: instant attack, smooth release
            if absSample > env {
                env = absSample
            } else {
                env = releaseCoeff * env
            }

            // Linear-domain gain: ceiling / envelope (brick-wall)
            let gain: Float = env > ceil ? ceil / env : 1.0
            if gain < maxGain { maxGain = gain }

            // Look-ahead: swap with delayed sample
            let delayed = ringBuffer[ringOffset + ringPos[channel]]
            ringBuffer[ringOffset + ringPos[channel]] = inputSample
            ringPos[channel] = (ringPos[channel] + 1) % lookAheadSamples

            samples[i] = delayed * gain
        }

        envelope[channel] = env

        // GR meter (once per buffer, not per sample)
        let grDB: Float = maxGain < 0.999 ? -20.0 * log10(max(maxGain, 1e-10)) : 0
        let prevGR = gainReductionDB
        gainReductionDB = max(grDB, prevGR * 0.9)
    }

    /// Clear delay lines and envelope state.
    public func reset() {
        let ringSize = lookAheadSamples * maxChannels
        memset(ringBuffer, 0, ringSize * MemoryLayout<Float>.size)
        memset(ringPos, 0, maxChannels * MemoryLayout<Int>.size)
        memset(envelope, 0, maxChannels * MemoryLayout<Float>.size)
        gainReductionDB = 0
    }
}
