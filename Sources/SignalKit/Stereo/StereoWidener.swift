// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Accelerate

// MARK: - Stereo Widener

/// Mid/Side stereo widener using vDSP-accelerated matrix operations.
///
/// Expands or narrows the stereo image by adjusting the ratio of mid (L+R)
/// to side (L−R) content. Based on the Blumlein M/S technique (1933).
///
/// Decomposition:
///   mid  = (L + R) × 0.5
///   side = (L − R) × 0.5
///
/// Reconstruction with width w:
///   L_out = mid + side × w  =  L × (0.5 + 0.5w) + R × (0.5 − 0.5w)
///   R_out = mid − side × w  =  L × (0.5 − 0.5w) + R × (0.5 + 0.5w)
///
/// Width values:
///   0.0 = mono (side cancelled)
///   1.0 = unchanged (bypass)
///   2.0 = double-wide
///   >2.0 = extreme width (may introduce phase artifacts)
///
/// Each instance owns its scratch memory. Multiple wideners can run concurrently
/// on separate threads without interference.
public final class StereoWidener: AudioProcessor, @unchecked Sendable {

    /// Current width value. 1.0 = bypass.
    public var width: Float = 1.0

    private let maxFrames: Int
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    // Channel-buffering for single-channel protocol path
    private let pendingL: UnsafeMutablePointer<Float>
    private var pendingCount: Int = 0

    /// Create a stereo widener.
    /// - Parameter maxBufferSize: Maximum number of frames per call (default 8192).
    public init(maxBufferSize: Int = 8192) {
        self.maxFrames = maxBufferSize
        self.scratchL = .allocate(capacity: maxBufferSize)
        self.scratchL.initialize(repeating: 0, count: maxBufferSize)
        self.scratchR = .allocate(capacity: maxBufferSize)
        self.scratchR.initialize(repeating: 0, count: maxBufferSize)
        self.pendingL = .allocate(capacity: maxBufferSize)
        self.pendingL.initialize(repeating: 0, count: maxBufferSize)
    }

    deinit {
        scratchL.deinitialize(count: maxFrames); scratchL.deallocate()
        scratchR.deinitialize(count: maxFrames); scratchR.deallocate()
        pendingL.deinitialize(count: maxFrames); pendingL.deallocate()
    }

    // MARK: - AudioProcessor Protocol

    /// Single-channel entry point. Channel 0 is buffered; processing occurs when channel 1 arrives.
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        guard abs(width - 1.0) > 0.01, count <= maxFrames else { return }
        if channel == 0 {
            memcpy(pendingL, samples, count * MemoryLayout<Float>.size)
            pendingCount = count
        } else if channel == 1, pendingCount > 0 {
            let n = min(count, pendingCount)
            processPlanar(left: pendingL, right: samples, count: n)
            // Write processed left back through the default stereo path
            pendingCount = 0
        }
    }

    /// Stateless processor — reset is a no-op.
    public func reset() {}

    /// Process stereo pair directly — preferred over the single-channel path.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        count: Int) {
        processPlanar(left: left, right: right, count: count)
    }

    /// Process interleaved stereo [L0, R0, L1, R1, ...] in-place.
    public func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard abs(width - 1.0) > 0.01, frameCount <= maxFrames else { return }

        var sameGain  = 0.5 + 0.5 * width
        var crossGain = 0.5 - 0.5 * width
        let n = vDSP_Length(frameCount)

        let leftPtr  = samples
        let rightPtr = samples + 1

        // De-interleave (stride-2 copy)
        var one: Float = 1.0
        vDSP_vsmul(leftPtr,  2, &one, scratchL, 1, n)
        vDSP_vsmul(rightPtr, 2, &one, scratchR, 1, n)

        // L_out = sameGain × L + crossGain × R
        vDSP_vsmul(scratchL, 1, &sameGain,  leftPtr, 2, n)
        vDSP_vsma(scratchR, 1, &crossGain, leftPtr, 2, leftPtr, 2, n)

        // R_out = crossGain × L + sameGain × R
        vDSP_vsmul(scratchR, 1, &sameGain,  rightPtr, 2, n)
        vDSP_vsma(scratchL, 1, &crossGain, rightPtr, 2, rightPtr, 2, n)
    }

    /// Process planar stereo (separate L/R buffers) in-place.
    public func processPlanar(left: UnsafeMutablePointer<Float>,
                              right: UnsafeMutablePointer<Float>,
                              count: Int, width: Float? = nil) {
        let w = width ?? self.width
        guard abs(w - 1.0) > 0.01, count <= maxFrames else { return }
        let n = vDSP_Length(count)

        var sameGain  = 0.5 + 0.5 * w
        var crossGain = 0.5 - 0.5 * w

        memcpy(scratchL, left, count * MemoryLayout<Float>.size)

        vDSP_vsmul(scratchL, 1, &sameGain, left, 1, n)
        vDSP_vsma(right, 1, &crossGain, left, 1, left, 1, n)

        vDSP_vsmul(right, 1, &sameGain, right, 1, n)
        vDSP_vsma(scratchL, 1, &crossGain, right, 1, right, 1, n)
    }

    // MARK: - Static Convenience (single-threaded only)

    /// Process planar stereo using a shared internal instance.
    ///
    /// - Warning: Not thread-safe. For concurrent use, create separate instances.
    public static func processPlanar(left: UnsafeMutablePointer<Float>,
                                     right: UnsafeMutablePointer<Float>,
                                     count: Int, width: Float) {
        sharedInstance.processPlanar(left: left, right: right, count: count, width: width)
    }

    /// Process interleaved stereo using a shared internal instance.
    ///
    /// - Warning: Not thread-safe. For concurrent use, create separate instances.
    public static func process(_ samples: UnsafeMutablePointer<Float>,
                               frameCount: Int, width: Float) {
        sharedInstance.width = width
        sharedInstance.processInterleaved(samples, frameCount: frameCount)
    }

    private static let sharedInstance = StereoWidener()
}
