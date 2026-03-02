# ``SignalKit``

Real-time audio DSP processors for Apple platforms, written in pure Swift.

## Overview

SignalKit provides a focused set of audio processors built on Apple's Accelerate framework. Every processor conforms to the ``AudioProcessor`` protocol and is safe to call from a real-time audio thread — no heap allocations in our code path, no locks, no Objective-C runtime traffic.

The library has zero external dependencies and ships as a single Swift package.

### Processors

- ``EQProcessor`` — 10-band parametric equalizer (ISO 31 center frequencies)
- ``CompressorProcessor`` — 3-band multiband compressor with Linkwitz-Riley crossover
- ``LimiterProcessor`` — Look-ahead brickwall limiter with true-peak ceiling enforcement
- ``LoudnessMeter`` — ITU-R BS.1770-4 loudness meter with optional auto-gain correction
- ``StereoWidener`` — Mid/side stereo width control
- ``CrossfeedProcessor`` — Headphone crossfeed for natural stereo imaging
- ``SPSCRingBuffer`` — Lock-free single-producer/single-consumer ring buffer

### Real-Time Safety

All ``AudioProcessor`` implementations guarantee:

- No heap allocations in our code path during `process()` calls
- No Foundation imports (Darwin and Accelerate only)
- No locks or dispatch queues
- No ARC retain/release on the audio thread

## Topics

### Essentials

- ``AudioProcessor``
- <doc:GettingStarted>

### Equalization

- ``EQProcessor``
- ``EQBand``
- ``EQBandType``
- ``EQPreset``

### Dynamics

- ``CompressorProcessor``
- ``CompressorBandSettings``
- ``CompressorPreset``
- ``DetectionMode``
- ``LimiterProcessor``

### Metering

- ``LoudnessMeter``

### Stereo

- ``StereoWidener``
- ``CrossfeedProcessor``

### Buffers

- ``SPSCRingBuffer``
