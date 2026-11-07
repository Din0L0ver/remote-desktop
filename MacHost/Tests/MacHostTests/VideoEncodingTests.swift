import XCTest
import VideoToolbox
import RemoteProtocol
@testable import MacHost

final class VideoEncodingTests: XCTestCase {
    func testSettingsAreBounded() {
        let defaults = VideoSettings(environment: [:])
        XCTAssertEqual(defaults.width, 1920)
        XCTAssertEqual(defaults.fps, 30)
        XCTAssertEqual(defaults.bitrate, 8_000_000)
        let invalid = VideoSettings(environment: ["SK_MAX_WIDTH": "-100", "SK_FPS": "10000", "SK_BITRATE_MBPS": "oops"])
        XCTAssertEqual(invalid.width, 960)
        XCTAssertEqual(invalid.fps, 60)
        XCTAssertEqual(invalid.bitrate, 8_000_000)
    }

    func testHardwareEncodeWireDecodeIncludingReferenceFrames() throws {
        let encoder = try VideoStream.makeEncoder(width: 320, height: 180, settings: VideoSettings(environment: [:]))
        defer { VTCompressionSessionInvalidate(encoder) }
        // makeEncoder requires hardware acceleration; creation fails without it.
        var decoder: VTDecompressionSession?
        defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
        var referenceFrameCount = 0

        for index in 0..<8 {
            let image = try makeImage(index: index)
            let encoded = expectation(description: "Encoded \(index)")
            var encodedSample: CMSampleBuffer?
            let result = VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: image, presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                XCTAssertEqual(status, noErr)
                encodedSample = sample
                encoded.fulfill()
            }
            XCTAssertEqual(result, noErr)
            wait(for: [encoded], timeout: 5)
            let original = try VideoPacket(sequence: UInt32(index), sample: XCTUnwrap(encodedSample))
            if !original.isKeyFrame { referenceFrameCount += 1 }
            var parser = VideoPacketParser()
            let wire = original.framed()
            var packets: [VideoPacket] = []
            for offset in stride(from: 0, to: wire.count, by: 37) {
                packets += try parser.append(Data(wire[offset..<min(offset + 37, wire.count)]))
            }
            let packet = try XCTUnwrap(packets.first)
            let format = try packet.formatDescription()
            if decoder == nil {
                let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
                XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                            decoderSpecification: nil, imageBufferAttributes: attributes,
                                                            outputCallback: nil, decompressionSessionOut: &decoder), noErr)
            }
            let sample = try packet.sampleBuffer(format: format)
            let decoded = expectation(description: "Decoded \(index)")
            let decodeStatus = VTDecompressionSessionDecodeFrame(try XCTUnwrap(decoder), sampleBuffer: sample,
                                                                  flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                XCTAssertEqual(status, noErr)
                XCTAssertNotNil(image)
                if let image {
                    XCTAssertEqual(CVPixelBufferGetWidth(image), 320)
                    XCTAssertEqual(CVPixelBufferGetHeight(image), 180)
                    CVPixelBufferLockBaseAddress(image, .readOnly)
                    let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                    XCTAssertEqual(Int(pixels[0]), 35 + index * 15, accuracy: 12)
                    CVPixelBufferUnlockBaseAddress(image, .readOnly)
                }
                decoded.fulfill()
            }
            XCTAssertEqual(decodeStatus, noErr)
            wait(for: [decoded], timeout: 5)
        }
        XCTAssertGreaterThan(referenceFrameCount, 0, "Must exercise dependent H.264 frames, not just key frames")
    }

    private func makeImage(index: Int) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, attributes, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<180 {
            for x in 0..<320 {
                let offset = y * stride + x * 4
                base[offset] = UInt8(35 + index * 15)
                base[offset + 1] = 100
                base[offset + 2] = 180
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
