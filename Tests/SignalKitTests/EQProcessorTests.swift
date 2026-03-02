import XCTest
import Accelerate
@testable import SignalKit

final class EQProcessorTests: XCTestCase {
    func testFlatEQIsPassthrough() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        // Fill with 1 kHz sine
        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0)
        }

        // Copy for comparison
        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { original.deallocate() }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        // Process with flat EQ (all gains = 0)
        eq.process(input, count: count, channel: 0)

        // Output should match input (flat EQ = passthrough)
        for i in 0..<count {
            XCTAssertEqual(input[i], original[i], accuracy: 1e-6,
                           "Flat EQ should be passthrough at sample \(i)")
        }
    }

    func testBandGainModifiesSignal() {
        let eq = EQProcessor(sampleRate: 48000, maxChannels: 2)
        eq.setGain(band: 5, gain: 12.0) // +12 dB at 1 kHz

        let count = 512
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { input.deallocate() }

        for i in 0..<count {
            input[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / 48000.0) * 0.1
        }

        let original = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { original.deallocate() }
        memcpy(original, input, count * MemoryLayout<Float>.size)

        eq.process(input, count: count, channel: 0)

        // Signal should be amplified
        var outputPower: Float = 0
        var inputPower: Float = 0
        vDSP_svesq(input, 1, &outputPower, vDSP_Length(count))
        vDSP_svesq(original, 1, &inputPower, vDSP_Length(count))

        XCTAssertGreaterThan(outputPower, inputPower * 2.0,
                             "12 dB boost should significantly increase power")
    }
}
