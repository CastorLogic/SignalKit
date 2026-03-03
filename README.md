# SignalKit

Pure Swift audio DSP toolkit for real-time signal processing on Apple platforms.

[![CI](https://github.com/CastorLogic/SignalKit/actions/workflows/ci.yml/badge.svg)](https://github.com/CastorLogic/SignalKit/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20visionOS-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

SignalKit is a collection of audio processors for real-time use in CoreAudio IOProc callbacks, Audio Unit render threads, and `AVAudioEngine` tap blocks. No heap allocations in our code path: no locks, no Objective-C messaging, no hidden `malloc`.

## Processors

| Module | Description | Acceleration |
|--------|-------------|--------------|
| **EQProcessor** | 10-band parametric EQ (biquad cascade) | `vDSP_deq22` |
| **CompressorProcessor** | 3-band multiband compressor with Linkwitz-Riley crossovers | `vDSP` |
| **LimiterProcessor** | Brick-wall look-ahead peak limiter | Linear-domain math |
| **StereoWidener** | Mid/Side stereo image control | `vDSP` matrix ops |
| **CrossfeedProcessor** | Headphone crossfeed with ITD simulation | IIR + delay line |
| **LoudnessMeter** | ITU-R BS.1770-4 LUFS meter with optional AGC | K-weighting biquads |
| **SPSCRingBuffer** | Lock-free single-producer/single-consumer ring buffer | `OSMemoryBarrier` |

## Quick Start

### Installation

Add SignalKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CastorLogic/SignalKit.git", from: "1.0.0")
]
```

### Usage

```swift
import SignalKit

// Create a 10-band EQ at 48 kHz
let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
eq.apply(preset: .bassBoost)

// Process audio in your render callback
func renderCallback(buffer: UnsafeMutablePointer<Float>, frames: Int) {
    eq.process(buffer, count: frames, channel: 0)
}
```

### Multiband Compression

```swift
let compressor = CompressorProcessor(sampleRate: 48000)
compressor.apply(preset: .moderate)

// In your audio callback
compressor.process(left, count: frameCount, channel: 0)
compressor.process(right, count: frameCount, channel: 1)
```

### Stereo Processing

```swift
// Widen stereo image (1.0 = unchanged, 0.0 = mono, 2.0 = double-wide)
let widener = StereoWidener()
widener.width = 1.5
widener.processPlanar(left: leftBuf, right: rightBuf, count: frames)

// Headphone crossfeed
let crossfeed = CrossfeedProcessor(sampleRate: 48000)
crossfeed.amount = 0.3  // natural crossfeed
crossfeed.processInterleaved(interleavedBuf, frameCount: frames)
```

### LUFS Metering

```swift
let meter = LoudnessMeter(sampleRate: 48000)
meter.applyGain = false  // measurement only, no AGC

meter.process(left: leftBuf, right: rightBuf, count: frames)
print("Loudness: \(meter.measuredLUFS) LUFS")
```

### Lock-Free Ring Buffer

```swift
// Bridge two clock domains (e.g., capture at 48 kHz, playback at 44.1 kHz)
let ring = SPSCRingBuffer(capacity: 4096, channels: 2)

// Producer thread (audio capture callback)
ring.write(capturedSamples, frameCount: 512)

// Consumer thread (playback callback)
ring.read(playbackBuffer, frameCount: 480)
```

## Performance

Measured on Apple Silicon (M-series), 512 frames at 48 kHz, release build, 5000 iterations.

| Processor | Median | % of RT Budget |
|-----------|--------|---------------|
| EQ (10-band biquad) | 7.96 μs | 0.07% |
| Compressor (3-band) | 29.21 μs | 0.27% |
| Limiter (brick-wall) | 2.88 μs | 0.03% |
| Stereo Widener | 0.12 μs | < 0.01% |
| Crossfeed | 1.42 μs | 0.01% |
| LUFS Meter + AGC | 1.92 μs | 0.02% |
| SPSC Ring Buffer | 0.08 μs | < 0.01% |
| **Full Pipeline** | **37.79 μs** | **0.35%** |

The full pipeline. EQ, compressor, limiter, stereo widener, and LUFS metering. uses **0.35% of one core's real-time budget** at 48 kHz / 512 frames (10,667 μs deadline).

> Benchmarks measure isolated DSP processing time per stereo buffer. System overhead (CoreAudio callbacks, thread scheduling, IPC) depends on your application architecture and is not included. Reproduce locally with `swift run -c release Benchmarks`.

### Design Choices That Affect Performance

- **`vDSP_deq22`** for biquad filters. Apple's SIMD-optimized IIR implementation, processing up to 4 samples per cycle via NEON on Apple Silicon.
- **Pre-allocated buffers**: every processor allocates its workspace at `init()`. The `process()` path touches only stack variables and pre-existing heap memory.
- **Linear-domain math** in the limiter: avoids `log`/`exp` in the hot loop. Only the metering output uses `log10`.
- **`public final class`**. enables devirtualization, letting the compiler inline method dispatch.

## Real-Time Safety

All processors follow these rules in their `process()` methods:

- **No heap allocations**: no `malloc`, no `Array.append`, no string formatting
- **No locks**: no `os_unfair_lock`, no `DispatchSemaphore`, no `@synchronized`
- **No Objective-C messaging**: no `objc_msgSend`, which can trigger the ObjC runtime lock
- **No Swift runtime calls**: no ARC retain/release on the audio thread

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full real-time safety guide.

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 16+ / tvOS 16+ / visionOS 1+
- Apple Accelerate framework (included with all Apple platforms)
- Zero external dependencies

## Project Structure

```
Sources/SignalKit/
├── Core/           AudioProcessor protocol
├── EQ/             EQProcessor (10-band parametric)
├── Dynamics/       CompressorProcessor, LimiterProcessor
├── Stereo/         StereoWidener, CrossfeedProcessor
├── Metering/       LoudnessMeter (ITU-R BS.1770-4)
└── Buffers/        SPSCRingBuffer (lock-free SPSC)

Tests/SignalKitTests/   60 tests across all processors
Benchmarks/             Performance measurement suite
```

## Running Tests & Benchmarks

```bash
# Run the test suite (60 tests)
swift test

# Run benchmarks (release build required for accurate timing)
swift run -c release Benchmarks
```

## References

The DSP implementations reference the following:

- R. Bristow-Johnson, "Audio EQ Cookbook". biquad filter coefficient formulas
- D. Giannoulis et al., "Digital Dynamic Range Compressor Design" (JAES, 2012)
- S. Linkwitz, "Active Crossover Networks for Non-coincident Drivers" (JAES, 1976)
- A. Blumlein, British Patent 394,325 (1933). M/S stereo technique
- B. Bauer, "Stereophonic Earphone Reproduction" (JAES, 1961). crossfeed
- ITU-R BS.1770-4, "Algorithms to measure audio programme loudness" (2015)

## License

MIT License. See [LICENSE](LICENSE) for details.

Copyright © 2026 Castor Logic Studio
