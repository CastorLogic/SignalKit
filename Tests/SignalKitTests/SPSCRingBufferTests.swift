import XCTest
@testable import SignalKit

final class SPSCRingBufferTests: XCTestCase {

    // MARK: - Basic Read/Write

    func testWriteAndReadBack() {
        let ring = SPSCRingBuffer(capacity: 1024, channels: 2)
        let frameCount = 128
        let sampleCount = frameCount * 2

        let writeData = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        let readData = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { writeData.deallocate(); readData.deallocate() }

        for i in 0..<sampleCount { writeData[i] = Float(i) }

        ring.write(writeData, frameCount: frameCount)
        XCTAssertEqual(ring.available, frameCount)

        ring.read(readData, frameCount: frameCount)
        XCTAssertEqual(ring.available, 0)

        for i in 0..<sampleCount {
            XCTAssertEqual(readData[i], Float(i), accuracy: 1e-7,
                           "Sample \(i) should match written value")
        }
    }

    func testMultipleWritesThenRead() {
        let ring = SPSCRingBuffer(capacity: 256, channels: 1)

        let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        defer { chunk.deallocate() }

        // Write 4 chunks of 32
        for batch in 0..<4 {
            for i in 0..<32 { chunk[i] = Float(batch * 32 + i) }
            ring.write(chunk, frameCount: 32)
        }

        XCTAssertEqual(ring.available, 128)

        // Read all 128
        let readBuf = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { readBuf.deallocate() }
        ring.read(readBuf, frameCount: 128)

        for i in 0..<128 {
            XCTAssertEqual(readBuf[i], Float(i), accuracy: 1e-7)
        }
    }

    // MARK: - Underrun

    func testUnderrunFillsSilence() {
        let ring = SPSCRingBuffer(capacity: 256, channels: 1)

        // Write only 10 frames
        let writeData = UnsafeMutablePointer<Float>.allocate(capacity: 10)
        defer { writeData.deallocate() }
        for i in 0..<10 { writeData[i] = Float(i + 1) }
        ring.write(writeData, frameCount: 10)

        // Read 20 frames (10 more than available)
        let readData = UnsafeMutablePointer<Float>.allocate(capacity: 20)
        defer { readData.deallocate() }
        for i in 0..<20 { readData[i] = -999 } // sentinel
        ring.read(readData, frameCount: 20)

        // First 10 should have data
        for i in 0..<10 {
            XCTAssertEqual(readData[i], Float(i + 1), accuracy: 1e-7)
        }
        // Remaining 10 should be zero (silence)
        for i in 10..<20 {
            XCTAssertEqual(readData[i], 0, accuracy: 1e-7,
                           "Underrun should produce silence at sample \(i)")
        }
    }

    // MARK: - Wrap-around

    func testWrapAround() {
        let ring = SPSCRingBuffer(capacity: 16, channels: 1)

        let write8 = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let read8 = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { write8.deallocate(); read8.deallocate() }

        // Fill 12 frames (write wraps at capacity 16, reserving 1)
        for i in 0..<8 { write8[i] = Float(i) }
        ring.write(write8, frameCount: 8)

        // Read 6 frames (frees space)
        ring.read(read8, frameCount: 6)

        // Write 10 more (this will wrap around)
        let write10 = UnsafeMutablePointer<Float>.allocate(capacity: 10)
        defer { write10.deallocate() }
        for i in 0..<10 { write10[i] = Float(100 + i) }
        ring.write(write10, frameCount: 10)

        // Read everything
        let remaining = ring.available
        let readAll = UnsafeMutablePointer<Float>.allocate(capacity: remaining)
        defer { readAll.deallocate() }
        ring.read(readAll, frameCount: remaining)

        // Verify no NaN or garbage
        for i in 0..<remaining {
            XCTAssertFalse(readAll[i].isNaN, "Sample \(i) should not be NaN")
        }
    }

    // MARK: - Multi-channel

    func testStereoRoundTrip() {
        let ring = SPSCRingBuffer(capacity: 64, channels: 2)
        let frames = 16
        let samples = frames * 2

        let writeData = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        let readData = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        defer { writeData.deallocate(); readData.deallocate() }

        // Interleaved stereo: [L0, R0, L1, R1, ...]
        for i in 0..<frames {
            writeData[i * 2]     = Float(i) // left
            writeData[i * 2 + 1] = Float(-i) // right
        }

        ring.write(writeData, frameCount: frames)
        ring.read(readData, frameCount: frames)

        for i in 0..<frames {
            XCTAssertEqual(readData[i * 2], Float(i), accuracy: 1e-7)
            XCTAssertEqual(readData[i * 2 + 1], Float(-i), accuracy: 1e-7)
        }
    }

    // MARK: - Empty Read

    func testEmptyReadYieldsSilence() {
        let ring = SPSCRingBuffer(capacity: 64, channels: 1)

        let readData = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { readData.deallocate() }
        for i in 0..<8 { readData[i] = 999 }

        ring.read(readData, frameCount: 8)

        for i in 0..<8 {
            XCTAssertEqual(readData[i], 0, accuracy: 1e-7,
                           "Empty ring should read silence")
        }
    }

    // MARK: - Diagnostics

    func testDiagnosticCounters() {
        let ring = SPSCRingBuffer(capacity: 128, channels: 1)

        let data = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        defer { data.deallocate() }

        ring.write(data, frameCount: 32)
        XCTAssertEqual(ring.written, 32)

        ring.read(data, frameCount: 16)
        XCTAssertEqual(ring.readCount, 16)

        ring.write(data, frameCount: 10)
        XCTAssertEqual(ring.written, 42)
        XCTAssertEqual(ring.available, 26) // 32 - 16 + 10
    }
}
