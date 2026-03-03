// SignalKit - Audio DSP Toolkit
// Copyright © 2026 Castor Logic Studio. MIT License.

import Darwin

// MARK: - SPSC Ring Buffer

/// Lock-free single-producer/single-consumer ring buffer for real-time audio.
///
/// Designed to decouple two clock domains. e.g., a capture callback writing
/// at one sample rate and a render callback reading at another. Both
/// threads can operate simultaneously without locks.
///
/// Overflow policy: writer advances the read pointer (drops oldest frames).
/// Underrun policy: reader outputs silence (zero-fills).
///
/// Thread safety is achieved via `OSMemoryBarrier()`, a lightweight store
/// fence that guarantees cross-thread visibility of buffer contents before
/// the head/tail pointers are updated. No locks, no Objective-C messaging.
///
/// Both write() and read() have a fast path (contiguous memcpy when data
/// doesn't wrap around the ring) and a slow path (per-frame copy with
/// wrap-around handling).
///
/// - Note: This is a SPSC structure. Using multiple writers or multiple
///   readers concurrently is undefined behavior.
public final class SPSCRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let channels: Int
    private let buffer: UnsafeMutablePointer<Float>

    // Head/tail stored as pointers for volatile-like cross-thread semantics.
    private let _writePos: UnsafeMutablePointer<Int>
    private let _readPos:  UnsafeMutablePointer<Int>
    private var totalWritten: UInt64 = 0
    private var totalRead:    UInt64 = 0

    /// Create a ring buffer.
    /// - Parameters:
    ///   - capacity: Maximum number of frames (not samples) the buffer can hold.
    ///   - channels: Number of interleaved channels per frame.
    public init(capacity: Int, channels: Int) {
        self.capacity = capacity
        self.channels = channels
        let totalSamples = capacity * channels
        self.buffer = .allocate(capacity: totalSamples)
        buffer.initialize(repeating: 0, count: totalSamples)
        self._writePos = .allocate(capacity: 1)
        _writePos.initialize(to: 0)
        self._readPos = .allocate(capacity: 1)
        _readPos.initialize(to: 0)
    }

    deinit {
        buffer.deinitialize(count: capacity * channels); buffer.deallocate()
        _writePos.deinitialize(count: 1); _writePos.deallocate()
        _readPos.deinitialize(count: 1);  _readPos.deallocate()
    }

    /// Write interleaved frames from the producer thread.
    ///
    /// `data` must contain at least `frameCount × channels` samples.
    /// On overflow, the oldest unread frames are discarded.
    public func write(_ data: UnsafePointer<Float>, frameCount: Int) {
        var wp = _writePos.pointee
        OSMemoryBarrier()
        let currentRP = _readPos.pointee

        let spaceToEnd = capacity - wp
        let availableFrames: Int
        if wp >= currentRP {
            availableFrames = capacity - (wp - currentRP) - 1
        } else {
            availableFrames = currentRP - wp - 1
        }

        // Fast path: contiguous write, no overflow
        if frameCount <= availableFrames && frameCount <= spaceToEnd {
            memcpy(buffer.advanced(by: wp * channels), data,
                   frameCount * channels * MemoryLayout<Float>.size)
            wp = (wp + frameCount) % capacity
            OSMemoryBarrier()
            _writePos.pointee = wp
            totalWritten += UInt64(frameCount)
            return
        }

        // Slow path: per-frame with wrap and overflow
        var rp = currentRP
        for f in 0..<frameCount {
            let dstOffset = wp * channels
            let srcOffset = f * channels
            for ch in 0..<channels {
                buffer[dstOffset + ch] = data[srcOffset + ch]
            }
            wp = (wp + 1) % capacity

            if wp == rp {
                rp = (rp + 1) % capacity
                OSMemoryBarrier()
                _readPos.pointee = rp
            }
        }
        OSMemoryBarrier()
        _writePos.pointee = wp
        totalWritten += UInt64(frameCount)
    }

    /// Read interleaved frames for the consumer thread.
    ///
    /// `data` must have space for `frameCount × channels` samples.
    /// Underrun frames are zero-filled (silence).
    public func read(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        var rp = _readPos.pointee
        OSMemoryBarrier()
        let wp = _writePos.pointee

        let avail: Int
        if wp >= rp {
            avail = wp - rp
        } else {
            avail = capacity - rp + wp
        }

        let framesToRead = min(frameCount, avail)
        let spaceToEnd = capacity - rp

        // Fast path: contiguous read
        if framesToRead > 0 && framesToRead <= spaceToEnd {
            memcpy(data, buffer.advanced(by: rp * channels),
                   framesToRead * channels * MemoryLayout<Float>.size)
            rp = (rp + framesToRead) % capacity

            if framesToRead < frameCount {
                let remaining = (frameCount - framesToRead) * channels
                memset(data.advanced(by: framesToRead * channels), 0,
                       remaining * MemoryLayout<Float>.size)
            }

            OSMemoryBarrier()
            _readPos.pointee = rp
            totalRead += UInt64(frameCount)
            return
        }

        // Slow path: per-frame with wrap and underrun
        for f in 0..<frameCount {
            let dstOffset = f * channels
            if rp != wp {
                let srcOffset = rp * channels
                for ch in 0..<channels {
                    data[dstOffset + ch] = buffer[srcOffset + ch]
                }
                rp = (rp + 1) % capacity
            } else {
                for ch in 0..<channels {
                    data[dstOffset + ch] = 0
                }
            }
        }
        OSMemoryBarrier()
        _readPos.pointee = rp
        totalRead += UInt64(frameCount)
    }

    /// Approximate fill level in frames. Safe to call from any thread.
    public var available: Int {
        OSMemoryBarrier()
        let wp = _writePos.pointee
        let rp = _readPos.pointee
        return wp >= rp ? wp - rp : capacity - rp + wp
    }

    /// Total frames written since creation (diagnostic).
    public var written: UInt64 { totalWritten }

    /// Total frames read since creation (diagnostic).
    public var readCount: UInt64 { totalRead }
}
