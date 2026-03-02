// SignalKit — Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Foundation
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
/// Thread safety: `width` is a single naturally-aligned Float — atomic on ARM64.
/// RT safety: uses static pre-allocated scratch buffers, zero heap work in process().
public struct StereoWidener {

    private static let maxScratchFrames = 8192
    private static var scratchL = UnsafeMutablePointer<Float>.allocate(capacity: maxScratchFrames)
    private static var scratchR = UnsafeMutablePointer<Float>.allocate(capacity: maxScratchFrames)

    /// Process interleaved stereo [L0, R0, L1, R1, ...] in-place.
    public static func process(_ samples: UnsafeMutablePointer<Float>,
                               frameCount: Int, width: Float) {
        guard abs(width - 1.0) > 0.01 else { return }
        guard frameCount <= maxScratchFrames else { return }

        var sameGain  = 0.5 + 0.5 * width
        var crossGain = 0.5 - 0.5 * width
        let n = vDSP_Length(frameCount)

        let leftPtr  = samples
        let rightPtr = samples + 1
        let tempL = scratchL
        let tempR = scratchR

        // De-interleave (stride-2 copy)
        var one: Float = 1.0
        vDSP_vsmul(leftPtr,  2, &one, tempL, 1, n)
        vDSP_vsmul(rightPtr, 2, &one, tempR, 1, n)

        // L_out = sameGain × L + crossGain × R
        vDSP_vsmul(tempL, 1, &sameGain,  leftPtr, 2, n)
        vDSP_vsma(tempR, 1, &crossGain, leftPtr, 2, leftPtr, 2, n)

        // R_out = crossGain × L + sameGain × R
        vDSP_vsmul(tempR, 1, &sameGain,  rightPtr, 2, n)
        vDSP_vsma(tempL, 1, &crossGain, rightPtr, 2, rightPtr, 2, n)
    }

    /// Process planar stereo (separate L/R buffers) in-place.
    public static func processPlanar(left: UnsafeMutablePointer<Float>,
                                     right: UnsafeMutablePointer<Float>,
                                     count: Int, width: Float) {
        guard abs(width - 1.0) > 0.01 else { return }
        guard count <= maxScratchFrames else { return }
        let n = vDSP_Length(count)

        var sameGain  = 0.5 + 0.5 * width
        var crossGain = 0.5 - 0.5 * width

        let tempL = scratchL
        memcpy(tempL, left, count * MemoryLayout<Float>.size)

        vDSP_vsmul(tempL, 1, &sameGain, left, 1, n)
        vDSP_vsma(right, 1, &crossGain, left, 1, left, 1, n)

        vDSP_vsmul(right, 1, &sameGain, right, 1, n)
        vDSP_vsma(tempL, 1, &crossGain, right, 1, right, 1, n)
    }
}
