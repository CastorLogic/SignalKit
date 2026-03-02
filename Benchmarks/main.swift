import Foundation
import Accelerate
import SignalKit

// MARK: - Timing Infrastructure

/// High-resolution timer using mach_absolute_time (nanosecond precision).
struct BenchTimer {
    private static let info: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(info.numer) / UInt64(info.denom)
    }

    static func measure(_ iterations: Int, _ body: () -> Void) -> BenchResult {
        // Warmup — fill caches and JIT
        for _ in 0..<10 { body() }

        var samples = [Double]()
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = mach_absolute_time()
            body()
            let end = mach_absolute_time()
            samples.append(Double(nanoseconds(end - start)))
        }

        samples.sort()
        let median = samples[samples.count / 2]
        let p5  = samples[Int(Double(samples.count) * 0.05)]
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        let mean = samples.reduce(0, +) / Double(samples.count)

        return BenchResult(
            medianNs: median, meanNs: mean,
            minNs: samples.first!, maxNs: samples.last!,
            p5Ns: p5, p95Ns: p95, iterations: iterations
        )
    }
}

struct BenchResult: Codable {
    let medianNs: Double
    let meanNs: Double
    let minNs: Double
    let maxNs: Double
    let p5Ns: Double
    let p95Ns: Double
    let iterations: Int

    var medianUs: Double { medianNs / 1000.0 }
    var p5Us: Double { p5Ns / 1000.0 }
    var p95Us: Double { p95Ns / 1000.0 }
}

struct BenchmarkReport: Codable {
    let version: String
    let timestamp: String
    let machine: String
    let sampleRate: Double
    let bufferSize: Int
    let iterations: Int
    let results: [String: BenchResult]
    let totalPipelineMedianUs: Double
}

// MARK: - Test Signal

/// Stereo test signal: 1 kHz fundamental + 3 kHz harmonic at −6 dBFS.
func generateTestSignal(frameCount: Int, sampleRate: Double) -> (left: [Float], right: [Float]) {
    var left  = [Float](repeating: 0, count: frameCount)
    var right = [Float](repeating: 0, count: frameCount)
    let amp: Float = 0.5

    for i in 0..<frameCount {
        let t = Float(i) / Float(sampleRate)
        left[i]  = amp * (sinf(2.0 * .pi * 1000.0 * t) + 0.3 * sinf(2.0 * .pi * 3000.0 * t))
        right[i] = amp * (sinf(2.0 * .pi * 1000.0 * t + 0.5) + 0.3 * sinf(2.0 * .pi * 3000.0 * t + 0.3))
    }
    return (left, right)
}

func interleave(_ left: [Float], _ right: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: left.count * 2)
    for i in 0..<left.count {
        out[i * 2]     = left[i]
        out[i * 2 + 1] = right[i]
    }
    return out
}

// MARK: - Runner

let sampleRate = 48000.0
let bufferSize = 512
let iterations = 5000

let deadline = Double(bufferSize) / sampleRate * 1_000_000

print("═══════════════════════════════════════════════════════")
print(" SignalKit DSP Benchmark")
print("═══════════════════════════════════════════════════════")
print(" Sample Rate:  \(Int(sampleRate)) Hz")
print(" Buffer Size:  \(bufferSize) frames")
print(" Iterations:   \(iterations)")
print(String(format: " RT Deadline:  %.1f μs", deadline))
print("═══════════════════════════════════════════════════════\n")

let (testL, testR) = generateTestSignal(frameCount: bufferSize, sampleRate: sampleRate)
let testInterleaved = interleave(testL, testR)

var results = [String: BenchResult]()

func printResult(_ label: String, _ r: BenchResult) {
    let pct = r.medianUs / deadline * 100
    print(String(format: "   Median: %8.2f μs  (%4.1f%% of deadline)  [P5: %.1f, P95: %.1f]",
                 r.medianUs, pct, r.p5Us, r.p95Us))
}

// --- 1. EQ (10-band biquad cascade) ---
print("▶ EQ Processor (10-band biquad)...")
do {
    let eq = EQProcessor(sampleRate: sampleRate, maxChannels: 2)
    eq.setAllGains([-3.0, -1.5, 0.0, 2.0, 4.0, 3.0, 1.0, -1.0, -2.5, -4.0])

    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)
        eq.process(bufL, count: bufferSize, channel: 0)
        eq.process(bufR, count: bufferSize, channel: 1)
    }
    results["eq_10band"] = r
    printResult("EQ", r)
}

// --- 2. Compressor (3-band multiband) ---
print("▶ Compressor (3-band multiband)...")
do {
    let comp = CompressorProcessor(sampleRate: sampleRate)
    comp.apply(preset: .moderate)

    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)
        comp.process(bufL, count: bufferSize, channel: 0)
        comp.process(bufR, count: bufferSize, channel: 1)
    }
    results["compressor_3band"] = r
    printResult("Compressor", r)
}

// --- 3. Limiter (brick-wall) ---
print("▶ Limiter (brick-wall)...")
do {
    let lim = LimiterProcessor(sampleRate: sampleRate, maxChannels: 2)
    lim.ceiling = -0.3

    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)
        lim.process(bufL, count: bufferSize, channel: 0)
        lim.process(bufR, count: bufferSize, channel: 1)
    }
    results["limiter"] = r
    printResult("Limiter", r)
}

// --- 4. Stereo Widener (planar) ---
print("▶ Stereo Widener (planar)...")
do {
    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)
        StereoWidener.processPlanar(left: bufL, right: bufR, count: bufferSize, width: 1.8)
    }
    results["stereo_widener"] = r
    printResult("Widener", r)
}

// --- 5. Crossfeed ---
print("▶ Crossfeed...")
do {
    let xfeed = CrossfeedProcessor(sampleRate: sampleRate)
    xfeed.amount = 0.6

    let buf = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize * 2)
    defer { buf.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(buf, testInterleaved, bufferSize * 2 * MemoryLayout<Float>.size)
        xfeed.processInterleaved(buf, frameCount: bufferSize)
    }
    results["crossfeed"] = r
    printResult("Crossfeed", r)
}

// --- 6. Loudness Meter ---
print("▶ Loudness Meter (LUFS + AGC)...")
do {
    let meter = LoudnessMeter(sampleRate: sampleRate)

    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)
        meter.process(bufL, count: bufferSize, channel: 0)
        meter.process(bufR, count: bufferSize, channel: 1)
    }
    results["loudness_meter"] = r
    printResult("LUFS Meter", r)
}

// --- 7. SPSC Ring Buffer ---
print("▶ SPSC Ring Buffer (write+read)...")
do {
    let ring = SPSCRingBuffer(capacity: 4096, channels: 2)

    let writeBuf = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize * 2)
    let readBuf = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize * 2)
    defer { writeBuf.deallocate(); readBuf.deallocate() }
    memcpy(writeBuf, testInterleaved, bufferSize * 2 * MemoryLayout<Float>.size)

    let r = BenchTimer.measure(iterations) {
        ring.write(writeBuf, frameCount: bufferSize)
        ring.read(readBuf, frameCount: bufferSize)
    }
    results["spsc_ring_buffer"] = r
    printResult("Ring Buffer", r)
}

// --- 8. Full Pipeline ---
print("\n▶ Full Pipeline (EQ → Compressor → Limiter → Widener → LUFS)...")
do {
    let eq = EQProcessor(sampleRate: sampleRate, maxChannels: 2)
    eq.setAllGains([-3.0, -1.5, 0.0, 2.0, 4.0, 3.0, 1.0, -1.0, -2.5, -4.0])

    let comp = CompressorProcessor(sampleRate: sampleRate)
    comp.apply(preset: .moderate)

    let lim = LimiterProcessor(sampleRate: sampleRate, maxChannels: 2)
    lim.ceiling = -0.3

    let meter = LoudnessMeter(sampleRate: sampleRate)

    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { bufL.deallocate(); bufR.deallocate() }

    let r = BenchTimer.measure(iterations) {
        memcpy(bufL, testL, bufferSize * MemoryLayout<Float>.size)
        memcpy(bufR, testR, bufferSize * MemoryLayout<Float>.size)

        eq.process(bufL, count: bufferSize, channel: 0)
        eq.process(bufR, count: bufferSize, channel: 1)

        comp.process(bufL, count: bufferSize, channel: 0)
        comp.process(bufR, count: bufferSize, channel: 1)

        lim.process(bufL, count: bufferSize, channel: 0)
        lim.process(bufR, count: bufferSize, channel: 1)

        StereoWidener.processPlanar(left: bufL, right: bufR, count: bufferSize, width: 1.8)

        meter.process(bufL, count: bufferSize, channel: 0)
        meter.process(bufR, count: bufferSize, channel: 1)
    }
    results["full_pipeline"] = r
    printResult("Pipeline", r)
}

// MARK: - Summary

let pipelineUs = results["full_pipeline"]!.medianUs

print("\n═══════════════════════════════════════════════════════")
print(" Summary")
print("═══════════════════════════════════════════════════════")
print(String(format: " Full Pipeline:     %8.2f μs (median)", pipelineUs))
print(String(format: " RT Deadline:       %8.0f μs", deadline))
print(String(format: " Headroom:          %8.0f× (%.1f%% of budget)", deadline / pipelineUs, pipelineUs / deadline * 100))
print("═══════════════════════════════════════════════════════")

// MARK: - JSON Export

let dateFormatter = ISO8601DateFormatter()
let timestamp = dateFormatter.string(from: Date())

#if arch(arm64)
let arch = "arm64"
#elseif arch(x86_64)
let arch = "x86_64"
#else
let arch = "unknown"
#endif

var sysname = utsname()
uname(&sysname)
let machineName = withUnsafePointer(to: &sysname.machine) {
    $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
        String(cString: $0)
    }
}

let report = BenchmarkReport(
    version: "1.0",
    timestamp: timestamp,
    machine: "\(machineName) (\(arch))",
    sampleRate: sampleRate,
    bufferSize: bufferSize,
    iterations: iterations,
    results: results,
    totalPipelineMedianUs: pipelineUs
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let jsonData = try! encoder.encode(report)

let benchDir = FileManager.default.currentDirectoryPath + "/benchmarks"
try? FileManager.default.createDirectory(atPath: benchDir, withIntermediateDirectories: true)

let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
let filename = "benchmark_\(safeTimestamp).json"
try! jsonData.write(to: URL(fileURLWithPath: benchDir + "/" + filename))
try! jsonData.write(to: URL(fileURLWithPath: benchDir + "/latest.json"))

print("\n📁 Report: benchmarks/\(filename)")
print("📁 Latest: benchmarks/latest.json")

// MARK: - Baseline Comparison

let baselinePath = benchDir + "/baseline.json"
if FileManager.default.fileExists(atPath: baselinePath) {
    print("\n═══════════════════════════════════════════════════════")
    print(" Comparison vs Baseline")
    print("═══════════════════════════════════════════════════════")

    do {
        let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
        let baseline = try JSONDecoder().decode(BenchmarkReport.self, from: baselineData)

        let header = " " + "Test".padding(toLength: 24, withPad: " ", startingAt: 0)
            + "Baseline".padding(toLength: 14, withPad: " ", startingAt: 0)
            + "Current".padding(toLength: 14, withPad: " ", startingAt: 0)
            + "Δ"
        print(header)
        print(String(repeating: "─", count: 64))

        let allKeys = Set(baseline.results.keys).union(results.keys).sorted()
        for key in allKeys {
            let baseUs = baseline.results[key]?.medianUs
            let currUs = results[key]?.medianUs
            let label = " " + key.padding(toLength: 24, withPad: " ", startingAt: 0)

            if let b = baseUs, let c = currUs {
                let delta = (c - b) / b * 100.0
                let arrow = delta < -2 ? "⬇️" : (delta > 2 ? "⬆️" : "  ")
                print("\(label)\(String(format: "%8.2f", b)) μs  \(String(format: "%8.2f", c)) μs  \(String(format: "%+6.1f", delta))% \(arrow)")
            } else if let b = baseUs {
                print("\(label)\(String(format: "%8.2f", b)) μs  (removed)")
            } else if let c = currUs {
                print("\(label)   (new)   \(String(format: "%8.2f", c)) μs")
            }
        }

        print(String(repeating: "─", count: 64))
        let totalDelta = (pipelineUs - baseline.totalPipelineMedianUs) / baseline.totalPipelineMedianUs * 100.0
        let totalLabel = " " + "TOTAL PIPELINE".padding(toLength: 24, withPad: " ", startingAt: 0)
        print("\(totalLabel)\(String(format: "%8.2f", baseline.totalPipelineMedianUs)) μs  \(String(format: "%8.2f", pipelineUs)) μs  \(String(format: "%+6.1f", totalDelta))%")

        if totalDelta > 5 {
            print("\n⚠️  REGRESSION: Pipeline is \(String(format: "%.1f", totalDelta))% slower than baseline!")
        } else if totalDelta < -5 {
            print("\n✅  IMPROVEMENT: Pipeline is \(String(format: "%.1f", abs(totalDelta)))% faster than baseline!")
        } else {
            print("\n   Within ±5% of baseline (within noise)")
        }
    } catch {
        print("  ⚠️ Could not read baseline: \(error)")
    }
} else {
    print("\n💡 To set baseline:  cp benchmarks/latest.json benchmarks/baseline.json")
}

print("")
