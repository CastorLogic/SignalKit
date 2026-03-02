// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

/// Shared interface for real-time audio processors.
///
/// All conforming types guarantee real-time safety in their `process` methods:
/// no heap allocations in our code path, no locks, no Objective-C messaging. Safe to call from
/// CoreAudio IOProc and Audio Unit render callbacks.
public protocol AudioProcessor: AnyObject {
    /// Process a single channel of audio samples in-place.
    ///
    /// - Parameters:
    ///   - samples: Audio buffer, modified in-place.
    ///   - count: Number of frames to process.
    ///   - channel: Channel index (0 = left, 1 = right).
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int)

    /// Process a stereo pair in-place. Default implementation calls
    /// `process(_:count:channel:)` for channels 0 and 1.
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 count: Int)

    /// Reset internal state (delay lines, envelopes, filter memory).
    /// Call when starting a new stream or after a discontinuity.
    func reset()
}

/// Default stereo implementation — processors only need to implement single-channel.
public extension AudioProcessor {
    @inlinable
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 count: Int) {
        process(left, count: count, channel: 0)
        process(right, count: count, channel: 1)
    }
}
