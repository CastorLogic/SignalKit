// SignalKit - Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Accelerate
import RealtimeSanitizer

// MARK: - Band Settings

/// Envelope detection mode for compressor bands.
@frozen public enum DetectionMode: String, Codable, Sendable {
    /// Track instantaneous peaks. Fast response, catches transients.
    case peak
    /// Track perceived loudness (RMS power). Smoother, more musical.
    case rms
}

/// Per-band compressor configuration.
public struct CompressorBandSettings: Codable, Hashable, Sendable {
    public var threshold: Float     // dBFS, -60 to 0
    public var ratio: Float         // 1:1 (off) to 20:1 (brick-wall)
    public var attackMs: Float      // 0.1 to 100 ms
    public var releaseMs: Float     // 10 to 1000 ms
    public var makeupGain: Float    // 0 to 24 dB
    public var lookaheadMs: Float   // 0 (off) to 10 ms, adds latency
    public var detectionMode: DetectionMode
    public var autoMakeup: Bool     // derive makeup gain from threshold/ratio

    public init(threshold: Float = -20, ratio: Float = 4, attackMs: Float = 10,
                releaseMs: Float = 100, makeupGain: Float = 0, lookaheadMs: Float = 0,
                detectionMode: DetectionMode = .peak, autoMakeup: Bool = false) {
        self.threshold = threshold
        self.ratio = ratio
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.makeupGain = makeupGain
        self.lookaheadMs = lookaheadMs
        self.detectionMode = detectionMode
        self.autoMakeup = autoMakeup
    }
}

// MARK: - Preset

/// Serializable multiband compressor preset.
public struct CompressorPreset: Codable, Hashable, Sendable {
    /// Settings for each frequency band (low, mid, high).
    public var bands: [CompressorBandSettings]

    public init(bands: [CompressorBandSettings]) {
        self.bands = bands
    }

    /// All ratios at 1:1 (passthrough).
    public static let off = CompressorPreset(bands: [
        .init(threshold: 0, ratio: 1, attackMs: 10, releaseMs: 100, makeupGain: 0),
        .init(threshold: 0, ratio: 1, attackMs: 10, releaseMs: 100, makeupGain: 0),
        .init(threshold: 0, ratio: 1, attackMs: 10, releaseMs: 100, makeupGain: 0),
    ])

    /// Conservative compression. Only catches extreme peaks, preserves dynamics.
    public static let gentle = CompressorPreset(bands: [
        .init(threshold: -10, ratio: 1.5, attackMs: 50, releaseMs: 300, makeupGain: 0),
        .init(threshold: -8,  ratio: 1.5, attackMs: 40, releaseMs: 250, makeupGain: 0),
        .init(threshold: -10, ratio: 1.5, attackMs: 30, releaseMs: 200, makeupGain: 0),
    ])

    /// Noticeable but clean leveling. Good general-purpose starting point.
    public static let moderate = CompressorPreset(bands: [
        .init(threshold: -18, ratio: 2.5, attackMs: 15, releaseMs: 200, makeupGain: 2),
        .init(threshold: -14, ratio: 3,   attackMs: 10, releaseMs: 150, makeupGain: 2),
        .init(threshold: -16, ratio: 2,   attackMs: 8,  releaseMs: 120, makeupGain: 1),
    ])

    /// True when all bands are effectively at 1:1 ratio.
    public var isOff: Bool {
        bands.allSatisfy { $0.ratio < 1.05 }
    }
}

// MARK: - Compressor Processor

/// 3-band multiband compressor with Linkwitz-Riley crossover.
///
/// Signal flow:
///   input → LR4 crossover (250 Hz / 4 kHz) → 3 independent compressors → sum
///
/// Crossover is 4th-order Linkwitz-Riley (two cascaded 2nd-order Butterworth).
/// Each band has an independent envelope follower (peak or RMS), a soft-knee
/// gain computer, and optional lookahead delay.
///
/// Two-pass architecture per band:
///   1. Compute gain curve into a scratch buffer (per-sample envelope + gain computer)
///   2. Apply gain curve to audio via `vDSP_vmul` (SIMD-accelerated)
///
/// Timing coefficients follow the standard 1-pole IIR model:
///   coeff = exp(−1 / (time_seconds × Fs))
///
/// Gain computer uses the soft-knee model from Giannoulis et al.,
/// "Digital Dynamic Range Compressor Design. A Tutorial and Analysis" (AES, 2012).
///
/// Real-time safe: all buffers pre-allocated, no heap work in `process()`.
///
/// - Reference: Giannoulis, Massberg & Reiss (2012), https://doi.org/10.1121/1.4822479
/// - Reference: Linkwitz & Riley (1976), "Active Crossover Networks for Noncoincident Drivers"
public final class CompressorProcessor: AudioProcessor, @unchecked Sendable {

    private let bandCount = 3
    private let crossoverFreqs: [Double] = [250.0, 4000.0]

    /// Current per-band settings. Written from control thread, read lock-free by audio thread.
    public private(set) var settings: [CompressorBandSettings]

    // LR4 crossover coefficients: [crossover][stage][b0,b1,b2,a1,a2]
    private var lpCoeffs: [[[Double]]]
    private var hpCoeffs: [[[Double]]]

    // Crossover delay state: [crossover][stage][channel] = [x1,x2,y1,y2]
    private var lpDelays: [[[[Double]]]]
    private var hpDelays: [[[[Double]]]]

    // Envelope followers: [band][channel]
    private var envelopes: [[Float]]

    /// Per-band gain reduction in dB. Written by audio thread for metering.
    public var gainReduction: [Float]

    // Pre-allocated scratch buffers (raw pointers for RT safety)
    private let scratchLow:  UnsafeMutablePointer<Float>
    private let scratchMid:  UnsafeMutablePointer<Float>
    private let scratchHigh: UnsafeMutablePointer<Float>
    private let scratchTemp: UnsafeMutablePointer<Float>
    private let scratchGain: UnsafeMutablePointer<Float>
    private let maxBufferSize: Int

    private var sampleRate: Double
    private let maxChannels: Int

    // Per-sample timing coefficients derived from attack/release ms
    private var attackCoeffs:  [Float]
    private var releaseCoeffs: [Float]
    private var makeupLinear:  [Float]

    // Lookahead ring buffers: [band][channel]
    // Max 10 ms @ 48 kHz = 480 samples
    private let maxLookaheadSamples = 480
    private var lookaheadBuffers:  [[UnsafeMutablePointer<Float>]]
    private var lookaheadWriteIdx: [[Int]]
    private var lookaheadSamples:  [Int]

    public init(sampleRate: Double = 48000.0, maxChannels: Int = 2, maxBufferSize: Int = 4096) {
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels
        self.maxBufferSize = maxBufferSize

        self.settings = CompressorPreset.off.bands

        self.scratchLow  = .allocate(capacity: maxBufferSize)
        self.scratchLow.initialize(repeating: 0, count: maxBufferSize)
        self.scratchMid  = .allocate(capacity: maxBufferSize)
        self.scratchMid.initialize(repeating: 0, count: maxBufferSize)
        self.scratchHigh = .allocate(capacity: maxBufferSize)
        self.scratchHigh.initialize(repeating: 0, count: maxBufferSize)
        self.scratchTemp = .allocate(capacity: maxBufferSize)
        self.scratchTemp.initialize(repeating: 0, count: maxBufferSize)
        self.scratchGain = .allocate(capacity: maxBufferSize)
        self.scratchGain.initialize(repeating: 1, count: maxBufferSize)

        self.lpCoeffs = Array(repeating: Array(repeating: [1, 0, 0, 0, 0], count: 2), count: 2)
        self.hpCoeffs = Array(repeating: Array(repeating: [1, 0, 0, 0, 0], count: 2), count: 2)
        self.lpDelays = Array(repeating: Array(repeating: Array(repeating: [0, 0, 0, 0], count: maxChannels), count: 2), count: 2)
        self.hpDelays = Array(repeating: Array(repeating: Array(repeating: [0, 0, 0, 0], count: maxChannels), count: 2), count: 2)

        self.envelopes     = Array(repeating: [Float](repeating: 0, count: maxChannels), count: 3)
        self.gainReduction = [Float](repeating: 0, count: 3)
        self.attackCoeffs  = [Float](repeating: 0, count: 3)
        self.releaseCoeffs = [Float](repeating: 0, count: 3)
        self.makeupLinear  = [Float](repeating: 1, count: 3)

        self.lookaheadSamples  = [Int](repeating: 0, count: 3)
        self.lookaheadWriteIdx = Array(repeating: [Int](repeating: 0, count: maxChannels), count: 3)
        let laCapacity = maxLookaheadSamples
        self.lookaheadBuffers = (0..<3).map { _ in
            (0..<maxChannels).map { _ in
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: laCapacity)
                ptr.initialize(repeating: 0, count: laCapacity)
                return ptr
            }
        }

        recalculateCrossover()
        recalculateTimingCoeffs()
    }

    deinit {
        scratchLow.deinitialize(count: maxBufferSize);  scratchLow.deallocate()
        scratchMid.deinitialize(count: maxBufferSize);  scratchMid.deallocate()
        scratchHigh.deinitialize(count: maxBufferSize); scratchHigh.deallocate()
        scratchTemp.deinitialize(count: maxBufferSize); scratchTemp.deallocate()
        scratchGain.deinitialize(count: maxBufferSize); scratchGain.deallocate()
        for band in 0..<3 {
            for ch in 0..<maxChannels {
                lookaheadBuffers[band][ch].deinitialize(count: maxLookaheadSamples)
                lookaheadBuffers[band][ch].deallocate()
            }
        }
    }

    // MARK: - Public API

    /// Apply a preset. Call from the control thread.
    public func apply(preset: CompressorPreset) {
        guard preset.bands.count == bandCount else { return }
        settings = preset.bands
        recalculateTimingCoeffs()
    }

    /// Update a single band. Call from the control thread.
    public func setBand(_ index: Int, settings: CompressorBandSettings) {
        guard index >= 0 && index < bandCount else { return }
        self.settings[index] = settings
        recalculateTimingCoeffs()
    }

    /// Snapshot current settings as a preset.
    public func currentPreset() -> CompressorPreset {
        CompressorPreset(bands: settings)
    }

    /// Update sample rate and recalculate crossover + timing coefficients.
    public func updateSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        sampleRate = rate
        recalculateCrossover()
        recalculateTimingCoeffs()
        clearDelays()
    }

    /// True when all bands are at 1:1 ratio (no compression).
    public var isOff: Bool {
        settings.allSatisfy { $0.ratio < 1.05 }
    }

    /// Reset all state (envelopes, delay lines, gain reduction).
    public func reset() {
        clearDelays()
    }

    // MARK: - Real-Time Processing

    /// Process a single channel in-place.
    ///
    /// Signal flow: split → compress per band → recombine.
    @NonBlocking(in: "RELEASE")
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard channel < maxChannels, count > 0, count <= maxBufferSize else { return }
        guard !isOff else { return }

        // Band-split: input → low + (mid + high)
        applyCrossover(input: samples, lowOut: scratchLow, highOut: scratchTemp,
                       crossoverIndex: 0, channel: channel, count: count)
        // Split remainder → mid + high
        applyCrossover(input: scratchTemp, lowOut: scratchMid, highOut: scratchHigh,
                       crossoverIndex: 1, channel: channel, count: count)

        compressBand(0, buffer: scratchLow,  count: count, channel: channel)
        compressBand(1, buffer: scratchMid,  count: count, channel: channel)
        compressBand(2, buffer: scratchHigh, count: count, channel: channel)

        // Recombine: output = low + mid + high
        vDSP_vadd(scratchLow, 1, scratchMid, 1, samples, 1, vDSP_Length(count))
        vDSP_vadd(samples, 1, scratchHigh, 1, samples, 1, vDSP_Length(count))
    }

    // MARK: - Crossover

    /// 4th-order Linkwitz-Riley split (two cascaded Butterworth biquads per path).
    private func applyCrossover(input: UnsafePointer<Float>,
                                lowOut: UnsafeMutablePointer<Float>,
                                highOut: UnsafeMutablePointer<Float>,
                                crossoverIndex ci: Int, channel ch: Int, count: Int) {
        // Low-pass: two stages
        applyBiquad(input: input, output: lowOut,
                    coeffs: lpCoeffs[ci][0], delays: &lpDelays[ci][0][ch], count: count)
        applyBiquad(input: UnsafePointer(lowOut), output: scratchTemp,
                    coeffs: lpCoeffs[ci][1], delays: &lpDelays[ci][1][ch], count: count)
        memcpy(lowOut, scratchTemp, count * MemoryLayout<Float>.size)

        // High-pass: two stages
        applyBiquad(input: input, output: highOut,
                    coeffs: hpCoeffs[ci][0], delays: &hpDelays[ci][0][ch], count: count)
        applyBiquad(input: UnsafePointer(highOut), output: scratchTemp,
                    coeffs: hpCoeffs[ci][1], delays: &hpDelays[ci][1][ch], count: count)
        memcpy(highOut, scratchTemp, count * MemoryLayout<Float>.size)
    }

    /// Single biquad stage: y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
    private func applyBiquad(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>,
                             coeffs: [Double], delays: inout [Double], count: Int) {
        let b0 = coeffs[0], b1 = coeffs[1], b2 = coeffs[2], a1 = coeffs[3], a2 = coeffs[4]
        var x1 = delays[0], x2 = delays[1], y1 = delays[2], y2 = delays[3]

        for i in 0..<count {
            let x = Double(input[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            output[i] = Float(y)
        }

        delays[0] = x1; delays[1] = x2; delays[2] = y1; delays[3] = y2
    }

    // MARK: - Per-Band Compression

    /// Compress a single band. Two-pass: envelope → gain curve, then vDSP_vmul.
    ///
    /// Envelope follower:
    ///   Peak:  env = coeff·env + (1-coeff)·|x|;   dB = 20·log10(env) ≈ 6.0206·log2(env)
    ///   RMS:   env = coeff·env + (1-coeff)·x²;    dB = 10·log10(env) ≈ 3.0103·log2(env)
    ///
    /// Gain computer (soft knee, 3 dB width):
    ///   below knee:   gain = 0 dB
    ///   above knee:   gain = threshold + (input − threshold)/ratio − input
    ///   within knee:  quadratic interpolation per Giannoulis et al. (2012)
    ///
    /// dB-to-linear conversion uses exp2f for speed:
    ///   10^(dB/20) = 2^(dB × log2(10)/20) = 2^(dB × 0.05017)
    private func compressBand(_ band: Int, buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        let s = settings[band]
        guard s.ratio > 1.05 else { return }

        let threshold = s.threshold
        let ratio     = s.ratio
        let atkCoeff  = attackCoeffs[band]
        let relCoeff  = releaseCoeffs[band]
        let makeup    = makeupLinear[band]
        let kneeWidth: Float = 3.0
        let laDelay   = lookaheadSamples[band]
        let isRMS     = s.detectionMode == .rms

        var env   = envelopes[band][channel]
        var maxGR: Float = 0

        let ringBuf  = lookaheadBuffers[band][channel]
        var writeIdx = lookaheadWriteIdx[band][channel]

        // Pass 1: envelope + gain curve
        for i in 0..<count {
            let currentSample = buffer[i]
            let absSample = abs(currentSample)

            let envDB: Float
            if isRMS {
                let squared = absSample * absSample
                if squared > env {
                    env = atkCoeff * env + (1.0 - atkCoeff) * squared
                } else {
                    env = relCoeff * env + (1.0 - relCoeff) * squared
                }
                envDB = env > 1e-20 ? 3.0103 * log2f(env) : -120.0
            } else {
                if absSample > env {
                    env = atkCoeff * env + (1.0 - atkCoeff) * absSample
                } else {
                    env = relCoeff * env + (1.0 - relCoeff) * absSample
                }
                envDB = env > 1e-10 ? 6.0206 * log2f(env) : -120.0
            }

            // Soft-knee gain computer
            let gainDB: Float
            if envDB < (threshold - kneeWidth / 2.0) {
                gainDB = 0
            } else if envDB > (threshold + kneeWidth / 2.0) {
                gainDB = (threshold + (envDB - threshold) / ratio) - envDB
            } else {
                let x = envDB - threshold + kneeWidth / 2.0
                gainDB = ((1.0 / ratio - 1.0) * x * x) / (2.0 * kneeWidth)
            }

            if -gainDB > maxGR { maxGR = -gainDB }

            // exp2f(dB × 0.05017) = 10^(dB/20), see ARCHITECTURE.md for derivation
            scratchGain[i] = exp2f(gainDB * 0.05017088738) * makeup

            // Lookahead: swap current sample with delayed
            if laDelay > 0 {
                let readIdx = (writeIdx + maxLookaheadSamples - laDelay) % maxLookaheadSamples
                let delayed = ringBuf[readIdx]
                ringBuf[writeIdx] = currentSample
                writeIdx = (writeIdx + 1) % maxLookaheadSamples
                buffer[i] = delayed
            }
        }

        envelopes[band][channel] = env
        lookaheadWriteIdx[band][channel] = writeIdx

        // Pass 2: apply gain curve (SIMD)
        vDSP_vmul(buffer, 1, scratchGain, 1, buffer, 1, vDSP_Length(count))

        // Update GR meter (fast attack, slow decay)
        let prevGR = gainReduction[band]
        gainReduction[band] = max(maxGR, prevGR * 0.9)
    }

    // MARK: - Coefficient Calculation

    /// Compute LR4 crossover coefficients.
    ///
    /// A 4th-order Linkwitz-Riley crossover is two cascaded 2nd-order Butterworth
    /// filters. The Butterworth Q is 1/√2. Both LP and HP paths share the same
    /// denominator coefficients (a0, a1, a2).
    ///
    /// - Reference: Linkwitz & Riley (1976), JAES
    private func recalculateCrossover() {
        for (i, freq) in crossoverFreqs.enumerated() {
            let w0    = 2.0 * Double.pi * freq / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * sqrt(2.0))  // Q = 1/√2

            // Low-pass Butterworth
            let lpB0 = (1.0 - cosW0) / 2.0
            let lpB1 =  1.0 - cosW0
            let lpB2 = (1.0 - cosW0) / 2.0
            let a0   =  1.0 + alpha
            let a1   = -2.0 * cosW0
            let a2   =  1.0 - alpha

            let lpNorm = [lpB0/a0, lpB1/a0, lpB2/a0, a1/a0, a2/a0]
            lpCoeffs[i][0] = lpNorm
            lpCoeffs[i][1] = lpNorm

            // High-pass Butterworth
            let hpB0 =  (1.0 + cosW0) / 2.0
            let hpB1 = -(1.0 + cosW0)
            let hpB2 =  (1.0 + cosW0) / 2.0

            let hpNorm = [hpB0/a0, hpB1/a0, hpB2/a0, a1/a0, a2/a0]
            hpCoeffs[i][0] = hpNorm
            hpCoeffs[i][1] = hpNorm
        }
    }

    /// Derive per-sample attack/release coefficients, makeup gain, and lookahead from settings.
    ///
    /// Time constant: coeff = exp(−1 / (time_s × Fs))
    /// Auto-makeup: compensates for expected gain reduction at threshold.
    ///   Formula: −threshold × (1 − 1/ratio) / 2
    private func recalculateTimingCoeffs() {
        for i in 0..<bandCount {
            let s = settings[i]
            let atkSamples = max(1.0, Double(s.attackMs) / 1000.0 * sampleRate)
            let relSamples = max(1.0, Double(s.releaseMs) / 1000.0 * sampleRate)
            attackCoeffs[i]  = Float(exp(-1.0 / atkSamples))
            releaseCoeffs[i] = Float(exp(-1.0 / relSamples))

            if s.autoMakeup && s.ratio > 1.05 {
                let autoGainDB = -s.threshold * (1.0 - 1.0 / s.ratio) / 2.0
                makeupLinear[i] = exp2f(autoGainDB * 0.05017088738)
            } else {
                makeupLinear[i] = exp2f(s.makeupGain * 0.05017088738)
            }

            let laSamples = Int(max(0, s.lookaheadMs) / 1000.0 * Float(sampleRate))
            lookaheadSamples[i] = min(laSamples, maxLookaheadSamples - 1)
        }
    }

    private func clearDelays() {
        for ci in 0..<2 {
            for stage in 0..<2 {
                for ch in 0..<maxChannels {
                    lpDelays[ci][stage][ch][0] = 0
                    lpDelays[ci][stage][ch][1] = 0
                    lpDelays[ci][stage][ch][2] = 0
                    lpDelays[ci][stage][ch][3] = 0
                    hpDelays[ci][stage][ch][0] = 0
                    hpDelays[ci][stage][ch][1] = 0
                    hpDelays[ci][stage][ch][2] = 0
                    hpDelays[ci][stage][ch][3] = 0
                }
            }
        }
        for band in 0..<bandCount {
            for ch in 0..<maxChannels {
                envelopes[band][ch] = 0
                memset(lookaheadBuffers[band][ch], 0, maxLookaheadSamples * MemoryLayout<Float>.size)
                lookaheadWriteIdx[band][ch] = 0
            }
        }
        for i in 0..<bandCount { gainReduction[i] = 0 }
    }
}
