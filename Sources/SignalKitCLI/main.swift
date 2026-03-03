import Foundation
import SignalKit

// ═══════════════════════════════════════════════════════
// SignalKit CLI. WAV Processor Example
//
// Demonstrates the full SignalKit processing chain on a
// WAV file. Reads 16/24/32-bit PCM, processes through
// configurable processors, writes the result.
//
// Usage:
//   signalkit-cli input.wav output.wav [options]
//
// Options:
//   --eq            Apply 10-band EQ (bass boost preset)
//   --compress      Apply 3-band compressor (moderate)
//   --limit CEIL    Apply brick-wall limiter at CEIL dBFS
//   --widen WIDTH   Apply stereo widener (0.0–3.0)
//   --crossfeed AMT Apply headphone crossfeed (0.0–1.0)
//   --normalize     Apply LUFS normalization to -14 LUFS
//   --meter         Print LUFS measurement (no processing)
//   --all           Apply full chain: EQ→Comp→Limit→Widen
// ═══════════════════════════════════════════════════════

// MARK: - WAV File I/O

struct WAVHeader {
    var channels: Int
    var sampleRate: Int
    var bitsPerSample: Int
    var dataSize: Int
    var dataOffset: Int
}

enum WAVError: Error, CustomStringConvertible {
    case notWAV
    case unsupportedFormat(String)
    case readError(String)

    var description: String {
        switch self {
        case .notWAV: return "Not a valid WAV file"
        case .unsupportedFormat(let s): return "Unsupported format: \(s)"
        case .readError(let s): return "Read error: \(s)"
        }
    }
}

func readWAV(path: String) throws -> (header: WAVHeader, samples: [[Float]]) {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw WAVError.readError("Cannot open \(path)")
    }
    guard data.count >= 44 else { throw WAVError.notWAV }

    // Verify RIFF header
    let riff = String(data: data[0..<4], encoding: .ascii)
    let wave = String(data: data[8..<12], encoding: .ascii)
    guard riff == "RIFF", wave == "WAVE" else { throw WAVError.notWAV }

    // Parse format chunk
    var offset = 12
    var formatFound = false
    var header = WAVHeader(channels: 0, sampleRate: 0, bitsPerSample: 0, dataSize: 0, dataOffset: 0)

    while offset + 8 <= data.count {
        let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
        let chunkSize = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) })

        if chunkID == "fmt " {
            let audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt16.self) }
            guard audioFormat == 1 || audioFormat == 3 else {
                throw WAVError.unsupportedFormat("Only PCM (1) and IEEE float (3) supported, got \(audioFormat)")
            }

            header.channels = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self) })
            header.sampleRate = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self) })
            header.bitsPerSample = Int(data.withUnsafeBytes { $0.load(fromByteOffset: offset + 22, as: UInt16.self) })
            formatFound = true
        } else if chunkID == "data" {
            header.dataSize = chunkSize
            header.dataOffset = offset + 8
            break
        }

        offset += 8 + chunkSize
        if chunkSize % 2 != 0 { offset += 1 } // padding byte
    }

    guard formatFound, header.dataOffset > 0 else { throw WAVError.notWAV }

    // Decode samples to Float
    let bytesPerSample = header.bitsPerSample / 8
    let totalSamples = header.dataSize / bytesPerSample
    let framesCount = totalSamples / header.channels

    var channels = [[Float]](repeating: [Float](repeating: 0, count: framesCount), count: header.channels)

    data.withUnsafeBytes { rawBuf in
        let base = rawBuf.baseAddress! + header.dataOffset

        for frame in 0..<framesCount {
            for ch in 0..<header.channels {
                let sampleOffset = (frame * header.channels + ch) * bytesPerSample
                let ptr = base + sampleOffset

                let value: Float
                switch header.bitsPerSample {
                case 16:
                    let raw = ptr.assumingMemoryBound(to: Int16.self).pointee
                    value = Float(raw) / 32768.0
                case 24:
                    let b0 = ptr.load(fromByteOffset: 0, as: UInt8.self)
                    let b1 = ptr.load(fromByteOffset: 1, as: UInt8.self)
                    let b2 = ptr.load(fromByteOffset: 2, as: UInt8.self)
                    var raw = Int32(b0) | (Int32(b1) << 8) | (Int32(b2) << 16)
                    if raw & 0x800000 != 0 { raw |= Int32(bitPattern: 0xFF000000) }
                    value = Float(raw) / 8388608.0
                case 32:
                    value = ptr.assumingMemoryBound(to: Float.self).pointee
                default:
                    value = 0
                }
                channels[ch][frame] = value
            }
        }
    }

    return (header, channels)
}

func writeWAV(path: String, samples: [[Float]], sampleRate: Int, bitsPerSample: Int = 16) throws {
    let channels = samples.count
    let frameCount = samples[0].count
    let bytesPerSample = bitsPerSample / 8
    let dataSize = frameCount * channels * bytesPerSample
    let fileSize = 44 + dataSize

    var data = Data(count: fileSize)

    // RIFF header
    data[0..<4] = "RIFF".data(using: .ascii)!
    withUnsafeBytes(of: UInt32(fileSize - 8)) { data[4..<8] = Data($0) }
    data[8..<12] = "WAVE".data(using: .ascii)!

    // fmt chunk
    data[12..<16] = "fmt ".data(using: .ascii)!
    withUnsafeBytes(of: UInt32(16)) { data[16..<20] = Data($0) }
    withUnsafeBytes(of: UInt16(1)) { data[20..<22] = Data($0) } // PCM
    withUnsafeBytes(of: UInt16(channels)) { data[22..<24] = Data($0) }
    withUnsafeBytes(of: UInt32(sampleRate)) { data[24..<28] = Data($0) }
    let byteRate = UInt32(sampleRate * channels * bytesPerSample)
    withUnsafeBytes(of: byteRate) { data[28..<32] = Data($0) }
    withUnsafeBytes(of: UInt16(channels * bytesPerSample)) { data[32..<34] = Data($0) }
    withUnsafeBytes(of: UInt16(bitsPerSample)) { data[34..<36] = Data($0) }

    // data chunk
    data[36..<40] = "data".data(using: .ascii)!
    withUnsafeBytes(of: UInt32(dataSize)) { data[40..<44] = Data($0) }

    // Interleave and encode
    var offset = 44
    for frame in 0..<frameCount {
        for ch in 0..<channels {
            let sample = max(-1.0, min(1.0, samples[ch][frame]))
            switch bitsPerSample {
            case 16:
                let raw = Int16(sample * 32767.0)
                withUnsafeBytes(of: raw) { data[offset..<offset+2] = Data($0) }
            case 24:
                let raw = Int32(sample * 8388607.0)
                data[offset]   = UInt8(raw & 0xFF)
                data[offset+1] = UInt8((raw >> 8) & 0xFF)
                data[offset+2] = UInt8((raw >> 16) & 0xFF)
            default:
                break
            }
            offset += bytesPerSample
        }
    }

    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - CLI

func printUsage() {
    print("""
    SignalKit CLI. WAV Processor

    Usage: signalkit-cli <input.wav> <output.wav> [options]

    Options:
      --eq              Apply 10-band EQ (bass boost preset)
      --compress        Apply 3-band compressor (moderate preset)
      --limit <dBFS>    Apply brick-wall limiter (e.g., --limit -0.3)
      --widen <width>   Stereo widener (0.0 = mono, 1.0 = off, 2.0 = wide)
      --crossfeed <amt> Headphone crossfeed (0.0–1.0)
      --normalize       LUFS normalization to -14 LUFS
      --meter           Print LUFS measurement only (no output file needed)
      --all             Full chain: EQ → Compressor → Limiter → Widener
    """)
}

let args = CommandLine.arguments

guard args.count >= 3 else {
    printUsage()
    exit(1)
}

let inputPath = args[1]
let outputPath = args[2]
let options = Set(args.dropFirst(3))

func argValue(_ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let meterOnly = options.contains("--meter")
let useAll = options.contains("--all")
let useEQ = useAll || options.contains("--eq")
let useComp = useAll || options.contains("--compress")
let useLimiter = useAll || args.contains("--limit")
let useWidener = useAll || args.contains("--widen")
let useCrossfeed = args.contains("--crossfeed")
let useNormalize = options.contains("--normalize")

// Read input
print("Reading \(inputPath)...")
let (header, rawChannels) = try readWAV(path: inputPath)
let sr = Double(header.sampleRate)
let frameCount = rawChannels[0].count
let isStereo = rawChannels.count >= 2

print("  Format: \(header.channels)ch, \(header.sampleRate) Hz, \(header.bitsPerSample)-bit")
print("  Frames: \(frameCount) (\(String(format: "%.2f", Double(frameCount) / sr)) seconds)")

// Copy to mutable buffers
var left = rawChannels[0]
var right = isStereo ? rawChannels[1] : rawChannels[0]

// Process in chunks
let chunkSize = 512

left.withUnsafeMutableBufferPointer { leftBuf in
    right.withUnsafeMutableBufferPointer { rightBuf in
        let leftPtr = leftBuf.baseAddress!
        let rightPtr = rightBuf.baseAddress!

        // Init processors
        let eq = EQProcessor(sampleRate: sr, maxChannels: 2)
        if useEQ { eq.apply(preset: .bassBoost) }

        let comp = CompressorProcessor(sampleRate: sr, maxChannels: 2)
        if useComp { comp.apply(preset: .moderate) }

        let limiter = LimiterProcessor(sampleRate: sr, maxChannels: 2)
        let ceilingDB = Float(argValue("--limit") ?? "-0.3") ?? -0.3
        limiter.ceiling = ceilingDB

        let widthVal = Float(argValue("--widen") ?? "1.5") ?? 1.5

        let crossfeed = CrossfeedProcessor(sampleRate: sr)
        crossfeed.amount = Float(argValue("--crossfeed") ?? "0.3") ?? 0.3

        let meter = LoudnessMeter(sampleRate: sr)
        meter.applyGain = useNormalize
        meter.targetLUFS = -14.0

        var processed = 0
        while processed < frameCount {
            let remaining = frameCount - processed
            let n = min(chunkSize, remaining)
            let lp = leftPtr + processed
            let rp = rightPtr + processed

            if useEQ {
                eq.process(lp, count: n, channel: 0)
                eq.process(rp, count: n, channel: 1)
            }

            if useComp {
                comp.process(lp, count: n, channel: 0)
                comp.process(rp, count: n, channel: 1)
            }

            if useLimiter {
                limiter.process(lp, count: n, channel: 0)
                limiter.process(rp, count: n, channel: 1)
            }

            if useWidener && isStereo {
                StereoWidener.processPlanar(left: lp, right: rp, count: n, width: widthVal)
            }

            if useCrossfeed && isStereo {
                crossfeed.processPlanar(left: lp, right: rp, count: n)
            }

            if useNormalize || meterOnly {
                meter.process(lp, count: n, channel: 0)
                meter.process(rp, count: n, channel: 1)
            }

            processed += n
        }

        // Report
        var chain = [String]()
        if useEQ { chain.append("EQ (bass boost)") }
        if useComp { chain.append("Compressor (moderate)") }
        if useLimiter { chain.append("Limiter (\(ceilingDB) dBFS)") }
        if useWidener { chain.append("Widener (\(widthVal))") }
        if useCrossfeed { chain.append("Crossfeed (\(crossfeed.amount))") }
        if useNormalize { chain.append("Normalize (-14 LUFS)") }

        if meterOnly || useNormalize {
            print("  LUFS: \(String(format: "%.1f", meter.measuredLUFS))")
        }

        if !chain.isEmpty {
            print("  Chain: \(chain.joined(separator: " → "))")
        }
    }
}

// Write output (unless meter-only)
if !meterOnly {
    print("Writing \(outputPath)...")
    let output = isStereo ? [left, right] : [left]
    try writeWAV(path: outputPath, samples: output, sampleRate: header.sampleRate,
                 bitsPerSample: min(header.bitsPerSample, 24))
    print("Done.")
} else {
    print("Measurement complete (no output written).")
}
