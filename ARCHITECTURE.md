# Architecture

SignalKit is a collection of audio DSP processors designed for real-time use. This document covers the design principles, real-time safety rules, and integration patterns.

## Core Protocol

Every processor conforms to `AudioProcessor`:

```swift
public protocol AudioProcessor: AnyObject {
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int)
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>, count: Int)
    func reset()
}
```

The single-channel `process(_:count:channel:)` is the primary entry point. A default extension provides a stereo `process(left:right:count:)` that calls the single-channel method for channels 0 and 1. Processors only need to implement the single-channel method.

## Real-Time Safety

CoreAudio's render thread is real-time priority. Blocking or allocating on it drops audio. All processors are safe to call directly from:

- `IOProc` callbacks (HAL-level)
- Audio Unit render callbacks (`AURenderCallback`)
- `AVAudioEngine` tap blocks

### Rules Enforced in `process()`

| Rule | Rationale |
|------|-----------|
| No heap allocations | `malloc` can block on a global lock |
| No Objective-C messaging | `objc_msgSend` can trigger the ObjC runtime lock |
| No Swift `Array` mutations | Copy-on-write triggers `malloc` when refcount > 1 |
| No `print` or `NSLog` | I/O can block indefinitely |
| No locks or semaphores | Priority inversion with non-RT threads |
| No ARC retain/release | `swift_retain` uses atomic operations that can stall |

### How Processors Achieve This

1. **Pre-allocated buffers** — all workspace memory is allocated in `init()` using `UnsafeMutablePointer<Float>.allocate`. The `process()` path only reads/writes existing memory.

2. **`UnsafeMutablePointer` over `Array`** — avoids Swift's copy-on-write semantics and bounds checking. Manual `deinit` handles cleanup.

3. **`public final class`** — the `final` keyword prevents dynamic dispatch. Combined with `public`, the compiler can devirtualize and inline `process()` calls.

4. **`@inline(__always)`** on hot inner loops — forces inlining of tiny helper functions (e.g., biquad application in the loudness meter).

5. **Linear-domain math in limiters** — `exp2f` and `log2f` are used instead of `powf` where possible. The limiter avoids all transcendental functions in its per-sample loop.

## Signal Flow

A typical processing chain:

```
Input → EQ → Compressor → Limiter → Stereo Widener → Loudness Meter → Output
          ↑                                               ↑
     10 biquads                                    K-weighting + AGC
     (vDSP_deq22)                                      (optional)
```

Each stage processes audio in-place. No intermediate buffer copies between stages — the same pointer is passed through the chain.

## Processor Design Patterns

### Stateful Processors (class-based)

`EQProcessor`, `CompressorProcessor`, `LimiterProcessor`, `CrossfeedProcessor`, `LoudnessMeter`, `StereoWidener` — these are `public final class` instances conforming to `AudioProcessor`. Stateful processors maintain internal filter delays, envelope followers, or delay lines, and expose a `reset()` method to clear state.

`StereoWidener` is technically stateless (M/S is a pure matrix operation), but is implemented as a class with instance-owned scratch buffers for thread safety. Multiple wideners can run concurrently without interference.

### Lock-Free Data Structures

`SPSCRingBuffer` — uses `OSMemoryBarrier()` for cross-thread visibility. The producer and consumer each own their respective pointer (write/read), so no locking is needed. Only valid for single-producer, single-consumer patterns.

## Threading Model

```
┌─────────────────┐     ┌──────────────────┐
│  Audio Thread    │     │  Main Thread     │
│  (RT priority)  │     │  (UI)            │
│                 │     │                  │
│  process()      │     │  setGain()       │
│  (no alloc)      │     │  apply(preset:)  │
│                 │     │  reset()         │
└────────┬────────┘     └────────┬─────────┘
         │                       │
         │   Naturally-aligned   │
         │   Float writes are    │
         │   atomic on ARM64     │
         └───────────────────────┘
```

Parameter changes (gain, threshold, width) use naturally-aligned `Float` stores, which are atomic on ARM64. No explicit synchronization is needed for single-value parameter updates. Preset changes that modify multiple parameters should be applied outside the render callback or accepted as briefly inconsistent (individual parameters will never tear).

All value types (`EQPreset`, `EQBand`, `CompressorPreset`, `CompressorBandSettings`) conform to `Sendable`, `Hashable`, and `Codable`. Enums use `@frozen` for ABI stability and switch optimization. Processor classes are intentionally non-`Sendable` — they are designed for single-owner use on one thread.

## Buffer Formats

All processors work with raw `Float` (32-bit) buffers:

- **Planar**: separate `left` and `right` pointers, each containing `count` samples
- **Interleaved**: single pointer with `[L0, R0, L1, R1, ...]` layout, `frameCount * 2` samples total

Most processors accept planar format. `StereoWidener` and `CrossfeedProcessor` support both planar and interleaved.

## Integration Examples

### CoreAudio IOProc

```swift
let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)

func ioProc(device: AudioDeviceID, ..., data: UnsafeMutablePointer<AudioBufferList>) {
    let bufList = UnsafeMutableAudioBufferListPointer(data)
    let left  = bufList[0].mData!.assumingMemoryBound(to: Float.self)
    let right = bufList[1].mData!.assumingMemoryBound(to: Float.self)
    let frames = Int(bufList[0].mDataByteSize) / MemoryLayout<Float>.size

    eq.process(left, count: frames, channel: 0)
    eq.process(right, count: frames, channel: 1)
}
```

### AVAudioEngine Tap

```swift
let compressor = CompressorProcessor(sampleRate: 48000)

playerNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
    let left  = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    let frames = Int(buffer.frameLength)

    compressor.process(left, count: frames, channel: 0)
    compressor.process(right, count: frames, channel: 1)
}
```
