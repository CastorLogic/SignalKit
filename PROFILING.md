# Profiling Audio DSP on Apple Silicon

A practical guide to profiling real-time audio code on M-series Macs. Written for SignalKit but applicable to any CoreAudio DSP workload.

## Prerequisites

- Xcode 15+ with Instruments
- A debug build of your target (`swift build` or Xcode's Debug scheme)
- Activity Monitor open to verify you're looking at the right process

## Quick Start

The fastest way to check if your audio code is real-time safe:

```bash
swift build
xcrun xctrace record --template "Time Profiler" --launch ./path-to-binary
```

Open the resulting `.trace` file in Instruments. Look for your `process()` function in the call tree. If you see `malloc`, `objc_msgSend`, or lock acquisition in the subtree, you have a problem.

## Instruments Templates That Matter

### Time Profiler

The go-to template. Shows where CPU time is spent, broken down by function.

**What to look for:**
- Your DSP code should be a thin, flat call tree. Deep stacks suggest unnecessary abstraction.
- `vDSP_*` calls should dominate the profile. If your own math code is hotter than vDSP, you're doing something the framework already handles.
- Any `swift_retain` / `swift_release` in the audio path means ARC is active. This is a real-time violation.

**Tip:** Filter by thread. Audio callbacks run on CoreAudio's real-time thread (usually named `com.apple.audio.IOThread.*`). Focus there, ignore the main thread.

### System Trace

Shows thread scheduling, context switches, and priority inversions. This is how you find why audio glitched even though your code is fast enough.

**What to look for:**
- **Priority inversions:** A real-time thread blocked on a lock held by a lower-priority thread. Instruments highlights these in red.
- **Thread preemption:** Your audio thread got descheduled. If this happens during a render callback, you get a dropout.
- **Excessive context switches:** More than 2-3 per audio callback is a sign of lock contention.

### os_signpost (Custom Intervals)

For measuring your own code paths with nanosecond precision:

```swift
import os

let log = OSLog(subsystem: "com.castorlogic.signalkit", category: .pointsOfInterest)

func ioProc(...) {
    os_signpost(.begin, log: log, name: "DSP")
    eq.process(left, count: frames, channel: 0)
    eq.process(right, count: frames, channel: 1)
    os_signpost(.end, log: log, name: "DSP")
}
```

Open the trace in Instruments with the "Points of Interest" instrument. You get a timeline with exact durations for each callback invocation.

## Apple Silicon Specifics

### Performance vs Efficiency Cores

M-series chips have two core types:
- **P-cores (Performance):** High clock speed, wide execution. This is where audio code should run.
- **E-cores (Efficiency):** Lower power, lower throughput. Audio on E-cores risks deadline misses.

CoreAudio's real-time thread typically runs on P-cores, but the scheduler can move it under thermal pressure. To encourage P-core scheduling:

```swift
// Set QoS on your audio processing thread
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
```

Real-time audio threads created by CoreAudio (`IOProc`) already have the correct priority. You only need to set this manually if you're spinning up your own threads.

### Cache Behavior

M4 Max: 192 KB L1 data cache per P-core, 16 MB shared L2 per cluster.

**For a typical 512-frame stereo buffer:**
- Buffer size: 512 frames x 2 channels x 4 bytes = 4 KB
- This fits comfortably in L1. Cache misses are unlikely for sequential processing.

**When caches matter:**
- Processing more than ~24K frames at once pushes past L1
- Random access patterns (e.g., delay lines with long delays) cause L1 misses
- Multiple processors sharing the same buffer stay hot if called sequentially

**Rule of thumb:** Process in-place and sequentially. The first processor loads the buffer into L1, subsequent processors find it already there. This is why SignalKit's pipeline pattern (EQ, compressor, limiter, widener on the same pointer) is cache-friendly by design.

### Thermal Throttling

Sustained benchmarks on laptops will throttle after 30-60 seconds. Your first measurements will be faster than steady-state.

**Mitigation:**
- Run benchmarks for at least 2 minutes, discard the first 10 seconds
- Use `powermetrics` to check current CPU frequency: `sudo powermetrics --samplers cpu_power -i 1000 -n 5`
- Benchmark on AC power, not battery
- Close other apps to avoid thermal competition

### Branch Prediction

M-series chips have excellent branch predictors, but audio code should minimize branches anyway:

```swift
// Avoid: branch per sample
for i in 0..<count {
    if samples[i] > threshold {  // branch every sample
        samples[i] = threshold
    }
}

// Prefer: branchless min
vDSP_vclip(samples, 1, &lowerBound, &threshold, samples, 1, vDSP_Length(count))
```

`vDSP_vclip` processes the entire buffer with SIMD, no branches.

## Measuring Real-Time Headroom

The key metric for audio DSP: **how much of the deadline does your code use?**

```
deadline = bufferSize / sampleRate
headroom = deadline / actualProcessingTime
```

At 512 frames / 48 kHz, the deadline is 10,667 microseconds. SignalKit's full pipeline takes ~38 microseconds, giving 282x headroom.

**How to measure accurately:**

```swift
import QuartzCore

var times = [Double]()

for _ in 0..<1000 {
    let start = CACurrentMediaTime()
    pipeline(left, right, frames)
    let end = CACurrentMediaTime()
    times.append((end - start) * 1_000_000)  // microseconds
}

times.sort()
let median = times[times.count / 2]
let p99 = times[Int(Double(times.count) * 0.99)]

print("Median: \(median) us")
print("P99:    \(p99) us")
print("Budget: \(deadline) us")
```

**Use median, not mean.** Outliers from thermal throttling or context switches skew the mean. Report P99 alongside median to show worst-case behavior.

## Common Mistakes

### 1. Profiling Release Builds

Always profile Debug builds for correctness checks (are you allocating?), but benchmark Release builds for performance numbers. The optimizer eliminates dead code, inlines functions, and vectorizes loops. Debug and Release performance can differ by 10x.

```bash
# Correctness profiling (Debug)
swift build
xcrun xctrace record --template "Time Profiler" --launch .build/debug/Benchmarks

# Performance benchmarking (Release)
swift build -c release
.build/release/Benchmarks
```

### 2. Forgetting Memory Alignment

`vDSP` functions assume 4-byte aligned Float pointers. `UnsafeMutablePointer<Float>.allocate(capacity:)` returns naturally aligned memory, so this is usually fine. Problems arise when you offset into a buffer of a different type.

### 3. Measuring Wall Clock Instead of CPU Time

`CACurrentMediaTime()` measures wall clock time, which includes time your thread was descheduled. For pure CPU cost, use `mach_absolute_time()`:

```swift
var info = mach_timebase_info_data_t()
mach_timebase_info(&info)

let start = mach_absolute_time()
process(buffer, count: frames)
let end = mach_absolute_time()

let nanoseconds = (end - start) * UInt64(info.numer) / UInt64(info.denom)
```

This gives you actual CPU cycles consumed, not wall clock time.

## Further Reading

- [WWDC 2019: What's New in Audio](https://developer.apple.com/videos/play/wwdc2019/510/) (thread priority, real-time guarantees)
- [WWDC 2022: Profile and Optimize Your Game's Memory](https://developer.apple.com/videos/play/wwdc2022/10106/) (cache hierarchy on Apple Silicon)
- Apple Technical Note TN2091: Device input using the HAL Output Audio Unit
- `man 3 os_signpost` for signpost API details
