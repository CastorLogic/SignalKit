// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation
import Accelerate

// MARK: - Band Configuration

/// Filter shape for an EQ band.
public enum EQBandType: Int, Codable, CaseIterable {
    case lowShelf = 0
    case peaking = 1
    case highShelf = 2
}

/// A single parametric EQ band.
public struct EQBand: Codable, Equatable {
    public var gain: Float       // dB, clamped to ±12
    public var frequency: Float  // Hz
    public var q: Float          // quality factor
    public var type: EQBandType

    public init(gain: Float = 0.0, frequency: Float, q: Float, type: EQBandType) {
        self.gain = gain
        self.frequency = frequency
        self.q = q
        self.type = type
    }

    /// True when gain is large enough to audibly affect the signal.
    public var isActive: Bool { abs(gain) > 0.05 }
}

/// Number of bands in the default ISO configuration.
public let kEQBandCount = 10

/// ISO 31 center frequencies spanning the audible range.
public let kEQFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

/// Human-readable labels for each band.
public let kEQLabels: [String] = ["31", "62", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]



// MARK: - Preset

/// Serializable 10-band EQ preset.
public struct EQPreset: Codable, Equatable {
    /// Per-band gain in dB. Indices 0–9 correspond to `kEQFrequencies`.
    public var gains: [Float]

    public init(gains: [Float]? = nil) {
        self.gains = gains ?? Array(repeating: 0, count: kEQBandCount)
        while self.gains.count < kEQBandCount { self.gains.append(0) }
        if self.gains.count > kEQBandCount { self.gains = Array(self.gains.prefix(kEQBandCount)) }
    }

    /// True when all bands are at or near 0 dB.
    public var isFlat: Bool {
        gains.allSatisfy { abs($0) < 0.05 }
    }

    // MARK: Named Presets

    /// All bands at 0 dB — passthrough.
    public static let flat = EQPreset()

    /// Gentle low-end boost.
    //                                        31   62  125  250  500   1K   2K   4K   8K  16K
    public static let bassBoost   = EQPreset(gains: [ 6,  5,   4,   2,   0,   0,  0,   0,   0,   0])

    /// Mid-frequency presence lift for speech intelligibility.
    public static let voiceClarity = EQPreset(gains: [-2, -1,   0,   0,   1,   3,  4,   3,   1,   0])

    /// Rock/pop: scooped mids, boosted lows and highs.
    public static let rock = EQPreset(gains: [ 5,  4,   2,  -1,  -2,  -1,  2,   4,   5,   4])

    /// Acoustic instruments: warm low-mids, gentle treble lift.
    public static let acoustic = EQPreset(gains: [ 2,  3,   3,   2,   1,   0,  1,   2,   2,   1])

    /// Fletcher-Munson loudness contour for low-volume listening.
    public static let loudness = EQPreset(gains: [ 6,  5,   3,   0,  -1,   0,  0,   1,   3,   5])
}



// MARK: - EQ Processor

/// 10-band parametric equalizer using cascaded biquad IIR filters.
///
/// Filter topology: low shelf → 8× peaking → high shelf, applied serially per channel.
/// Each biquad stage is computed via `vDSP_deq22` for SIMD-accelerated processing
/// on Apple Silicon. Coefficients follow the RBJ Audio EQ Cookbook
/// (Bristow-Johnson, 1998).
///
/// Real-time safe: `process()` performs zero heap allocations. All scratch buffers
/// are pre-allocated at init. Coefficients are updated from the control thread via
/// `setGain(band:gain:)` and read lock-free by the audio thread — the worst case
/// is processing one callback with stale coefficients, which is inaudible.
public final class EQProcessor: AudioProcessor {

    public private(set) var bands: [EQBand]

    // Biquad coefficients [b0, b1, b2, a1, a2] per band, normalized (a0 = 1).
    private var coefficients: [[Double]]
    private var vdspCoeffs: [[Float]]

    // Delay state: delays[band][channel] = [x(n-2), x(n-1), y(n-1), y(n-2)]
    private var delays: [[[Float]]]

    private let maxChannels: Int
    private var sampleRate: Double

    // Pre-allocated scratch for vDSP_deq22. Size = maxBufferSize + 2 because
    // vDSP_deq22 reads two prepended delay samples before the input vector.
    private let scratchInput: UnsafeMutablePointer<Float>
    private let scratchOutput: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int
    private static let maxBufferSize = 4096

    public init(sampleRate: Double = 48000.0, maxChannels: Int = 2) {
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels

        self.scratchCapacity = EQProcessor.maxBufferSize + 2
        self.scratchInput = .allocate(capacity: scratchCapacity)
        self.scratchInput.initialize(repeating: 0, count: scratchCapacity)
        self.scratchOutput = .allocate(capacity: scratchCapacity)
        self.scratchOutput.initialize(repeating: 0, count: scratchCapacity)

        // 10-band ISO layout: shelf–peak–peak–...–peak–shelf
        self.bands = kEQFrequencies.enumerated().map { i, freq in
            let type: EQBandType = i == 0 ? .lowShelf : (i == kEQBandCount - 1 ? .highShelf : .peaking)
            let q: Float = type == .peaking ? 1.4 : 0.707
            return EQBand(gain: 0, frequency: freq, q: q, type: type)
        }

        self.coefficients = Array(repeating: [1, 0, 0, 0, 0], count: kEQBandCount)
        self.vdspCoeffs   = Array(repeating: [1, 0, 0, 0, 0], count: kEQBandCount)
        self.delays = Array(repeating: Array(repeating: [0, 0, 0, 0], count: maxChannels),
                            count: kEQBandCount)
    }

    deinit {
        scratchInput.deinitialize(count: scratchCapacity)
        scratchInput.deallocate()
        scratchOutput.deinitialize(count: scratchCapacity)
        scratchOutput.deallocate()
    }

    // MARK: - Public API

    /// Set gain for a single band and recalculate its coefficients.
    /// Call from the control thread.
    public func setGain(band: Int, gain: Float) {
        guard band >= 0 && band < bands.count else { return }
        bands[band].gain = max(-12, min(12, gain))
        recalculateCoefficient(for: band)
    }

    /// Set all 10 bands at once.
    public func setAllGains(_ gains: [Float]) {
        for i in 0..<min(gains.count, bands.count) {
            bands[i].gain = max(-12, min(12, gains[i]))
        }
        recalculateAllCoefficients()
    }

    /// Apply a preset.
    public func apply(preset: EQPreset) {
        setAllGains(preset.gains)
    }

    /// Snapshot the current gain values as a preset.
    public func currentPreset() -> EQPreset {
        EQPreset(gains: bands.map { $0.gain })
    }

    /// Reset all bands to 0 dB and clear filter memory.
    public func reset() {
        for i in 0..<bands.count { bands[i].gain = 0 }
        recalculateAllCoefficients()
        clearDelays()
    }

    /// Update sample rate. Recalculates all coefficients and clears delay lines.
    public func updateSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        sampleRate = rate
        recalculateAllCoefficients()
        clearDelays()
    }

    /// True when every band is effectively flat.
    public var isFlat: Bool {
        bands.allSatisfy { !$0.isActive }
    }

    // MARK: - Real-Time Processing

    /// Process samples in-place through the 10-band biquad cascade.
    ///
    /// `vDSP_deq22` implements the difference equation:
    ///   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]
    ///
    /// The input vector must be prepended with two delay samples [x(n-2), x(n-1)],
    /// and the output vector with [y(n-2), y(n-1)]. Results appear at output[2...].
    ///
    /// - Parameters:
    ///   - samples: Audio buffer, modified in-place.
    ///   - count: Frame count.
    ///   - channel: Channel index (0 = L, 1 = R).
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard channel < maxChannels, count > 0 else { return }
        let n = min(count, EQProcessor.maxBufferSize)

        for band in 0..<bands.count {
            guard bands[band].isActive else { continue }

            // Prepend input delay samples
            scratchInput[0] = delays[band][channel][0]
            scratchInput[1] = delays[band][channel][1]
            memcpy(scratchInput.advanced(by: 2), samples, n * MemoryLayout<Float>.size)

            // Prepend output delay samples
            scratchOutput[0] = delays[band][channel][3]
            scratchOutput[1] = delays[band][channel][2]

            vDSP_deq22(scratchInput, 1, vdspCoeffs[band], scratchOutput, 1, vDSP_Length(n))

            memcpy(samples, scratchOutput.advanced(by: 2), n * MemoryLayout<Float>.size)

            // Persist delay state for next callback
            delays[band][channel][0] = scratchInput[n]
            delays[band][channel][1] = scratchInput[n + 1]
            delays[band][channel][2] = scratchOutput[n + 1]
            delays[band][channel][3] = scratchOutput[n]
        }
    }

    /// Process stereo pair. Convenience wrapper for the common L/R case.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        count: Int) {
        process(left, count: count, channel: 0)
        process(right, count: count, channel: 1)
    }

    // MARK: - Coefficient Calculation

    /// Recalculate all band coefficients. Call after bulk gain changes.
    public func recalculateAllCoefficients() {
        for i in 0..<bands.count { recalculateCoefficient(for: i) }
    }

    /// Compute biquad coefficients for one band.
    ///
    /// Formulas from R. Bristow-Johnson, "Audio EQ Cookbook" (1998):
    ///   A     = 10^(dBgain / 40)
    ///   w0    = 2π × f0 / Fs
    ///   alpha = sin(w0) / (2Q)
    ///
    /// - Reference: https://www.w3.org/2011/audio/audio-eq-cookbook.html
    private func recalculateCoefficient(for index: Int) {
        let band = bands[index]

        guard band.isActive else {
            coefficients[index] = [1, 0, 0, 0, 0]
            vdspCoeffs[index]   = [1, 0, 0, 0, 0]
            return
        }

        let A     = pow(10.0, Double(band.gain) / 40.0)
        let w0    = 2.0 * Double.pi * Double(band.frequency) / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * Double(band.q))

        var b0: Double, b1: Double, b2: Double
        var a0: Double, a1: Double, a2: Double

        switch band.type {
        case .lowShelf:
            let twoSqrtAalpha = 2.0 * sqrt(A) * alpha
            b0 =       A * ((A + 1) - (A - 1) * cosw0 + twoSqrtAalpha)
            b1 = 2.0 * A * ((A - 1) - (A + 1) * cosw0)
            b2 =       A * ((A + 1) - (A - 1) * cosw0 - twoSqrtAalpha)
            a0 =            (A + 1) + (A - 1) * cosw0 + twoSqrtAalpha
            a1 =     -2.0 * ((A - 1) + (A + 1) * cosw0)
            a2 =            (A + 1) + (A - 1) * cosw0 - twoSqrtAalpha

        case .peaking:
            b0 =  1.0 + alpha * A
            b1 = -2.0 * cosw0
            b2 =  1.0 - alpha * A
            a0 =  1.0 + alpha / A
            a1 = -2.0 * cosw0
            a2 =  1.0 - alpha / A

        case .highShelf:
            let twoSqrtAalpha = 2.0 * sqrt(A) * alpha
            b0 =       A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAalpha)
            b1 = -2.0 * A * ((A - 1) + (A + 1) * cosw0)
            b2 =       A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAalpha)
            a0 =            (A + 1) - (A - 1) * cosw0 + twoSqrtAalpha
            a1 =      2.0 * ((A - 1) - (A + 1) * cosw0)
            a2 =            (A + 1) - (A - 1) * cosw0 - twoSqrtAalpha
        }

        let norm = [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        coefficients[index] = norm
        vdspCoeffs[index]   = norm.map { Float($0) }
    }

    private func clearDelays() {
        for band in 0..<delays.count {
            for ch in 0..<delays[band].count {
                delays[band][ch][0] = 0
                delays[band][ch][1] = 0
                delays[band][ch][2] = 0
                delays[band][ch][3] = 0
            }
        }
    }
}
