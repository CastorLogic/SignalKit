// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation

/// Shared interface for real-time audio processors.
///
/// All conforming types guarantee real-time safety in their `process` methods:
/// no heap allocations, no locks, no Objective-C messaging. Safe to call from
/// CoreAudio IOProc and Audio Unit render callbacks.
public protocol AudioProcessor: AnyObject {
    /// Process audio samples in-place.
    ///
    /// - Parameters:
    ///   - left: Interleaved or left-channel sample buffer.
    ///   - right: Right-channel sample buffer (ignored for mono processors).
    ///   - count: Number of frames to process.
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 count: Int)

    /// Reset internal state (delay lines, envelopes, filter memory).
    /// Call when starting a new stream or after a discontinuity.
    func reset()
}
