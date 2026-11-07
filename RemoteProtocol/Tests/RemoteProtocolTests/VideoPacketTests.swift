import XCTest
@testable import RemoteProtocol

final class VideoPacketTests: XCTestCase {
    private func packet(_ sequence: UInt32 = 1) -> VideoPacket {
        VideoPacket(sequence: sequence, sps: Data([0x67, 1]), pps: Data([0x68, 2]),
                    avcc: Data([0, 0, 0, 2, 0x65, 3]))
    }

    func testEveryPossibleTCPBoundary() throws {
        let wire = packet().framed()
        for split in 0...wire.count {
            var parser = VideoPacketParser()
            let frames = try parser.append(Data(wire.prefix(split))) + parser.append(Data(wire.dropFirst(split)))
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(frames.first?.avcc, packet().avcc)
            XCTAssertTrue(frames[0].isKeyFrame)
        }
    }

    func testByteAtATimeAndCoalescedFrames() throws {
        let wire = packet(1).framed() + packet(2).framed() + packet(3).framed()
        var fragmented = VideoPacketParser()
        var frames: [VideoPacket] = []
        for byte in wire { frames += try fragmented.append(Data([byte])) }
        XCTAssertEqual(frames.map(\.sequence), [1, 2, 3])
        var combined = VideoPacketParser()
        XCTAssertEqual(try combined.append(wire).map(\.sequence), [1, 2, 3])
    }

    func testPartialNextFrameDoesNotLoseBytes() throws {
        var parser = VideoPacketParser()
        let next = packet(2).framed()
        XCTAssertEqual(try parser.append(packet(1).framed() + next.prefix(7)).map(\.sequence), [1])
        XCTAssertEqual(try parser.append(Data(next.dropFirst(7))).map(\.sequence), [2])
    }

    func testRejectsInvalidLengthsBeforeAllocatingPayload() {
        for bytes: [UInt8] in [[0, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF], [0, 0, 0, 12]] {
            var parser = VideoPacketParser()
            XCTAssertThrowsError(try parser.append(Data(bytes)))
        }
    }

    func testRejectsTruncatedParametersAndNALUnits() {
        for avcc in [Data([0, 0, 0]), Data([0, 0, 0, 5, 0x65]), Data([0, 0, 0, 0])] {
            let invalid = VideoPacket(sequence: 1, sps: Data([0x67]), pps: Data([0x68]), avcc: avcc)
            var parser = VideoPacketParser()
            XCTAssertThrowsError(try parser.append(invalid.framed()))
        }
        var invalidParameters = packet().framed()
        invalidParameters.replaceSubrange(8..<12, with: [0, 0, 1, 0])
        var parser = VideoPacketParser()
        XCTAssertThrowsError(try parser.append(invalidParameters))
    }
}
