# Getting Started with SignalKit

Add SignalKit to your project and process your first audio buffer.

## Installation

Add SignalKit as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CastorLogic/SignalKit.git", from: "1.0.0")
]
```

Then add `"SignalKit"` to your target's dependencies.

## Processing a Single Buffer

Every processor works with `UnsafeMutablePointer<Float>` buffers, the same format
you get from Core Audio's render callback.

```swift
import SignalKit

// Create processors once (e.g., in your audio engine setup)
let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
let compressor = CompressorProcessor(sampleRate: 48000, maxChannels: 2)
let limiter = LimiterProcessor(sampleRate: 48000)

// Configure
eq.apply(preset: .bassBoost)
compressor.apply(preset: .moderate)
limiter.ceiling = -1.0  // -1 dBFS ceiling

// In your audio render callback:
func processAudio(left: UnsafeMutablePointer<Float>,
                  right: UnsafeMutablePointer<Float>,
                  frameCount: Int) {
    eq.process(left: left, right: right, count: frameCount)
    compressor.process(left: left, right: right, count: frameCount)
    limiter.process(left: left, right: right, count: frameCount)
}
```

All three calls are safe to make directly on the real-time audio thread.

## Building a Metered Chain

Add loudness metering and stereo processing to the chain:

```swift
let meter = LoudnessMeter(sampleRate: 48000)
meter.targetLUFS = -14.0
meter.applyGain = true

let widener = StereoWidener()
widener.width = 1.3  // slight widening

func processAudio(left: UnsafeMutablePointer<Float>,
                  right: UnsafeMutablePointer<Float>,
                  frameCount: Int) {
    eq.process(left: left, right: right, count: frameCount)
    compressor.process(left: left, right: right, count: frameCount)
    limiter.process(left: left, right: right, count: frameCount)
    widener.process(left: left, right: right, count: frameCount)
    
    // Meter measures on channel 0, applies gain to both
    meter.process(left: left, right: right, count: frameCount)
    
    // Read metering on the main thread
    // let lufs = meter.measuredLUFS
}
```

## Presets

Both ``EQProcessor`` and ``CompressorProcessor`` support serializable presets:

```swift
// Apply a built-in preset
eq.apply(preset: .vocal)

// Capture the current state as a preset
let snapshot = eq.currentPreset()

// Presets are Codable. save to disk
let data = try JSONEncoder().encode(snapshot)
```

## Thread Safety

Processors are designed for single-writer access from the audio thread.
Read properties like ``LoudnessMeter/measuredLUFS`` from any thread.
Preset structs (``EQPreset``, ``CompressorPreset``) are `Sendable` and safe to
pass across concurrency boundaries.
