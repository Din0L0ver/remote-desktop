import Foundation
import CoreMedia

public enum VideoProtocolError: Error {
    case invalidPacket
    case invalidVideo(OSStatus)
}

// Wire v1: big-endian payload length, sequence, SPS length, PPS length,
// followed by SPS, PPS and the AVCC access unit (four-byte NAL lengths).
public struct VideoPacket {
    public let sequence: UInt32
    public let sps: Data
    public let pps: Data
    public let avcc: Data
    public static let maximumSize = 8 * 1024 * 1024

    public init(sequence: UInt32, sps: Data, pps: Data, avcc: Data) {
        self.sequence = sequence
        self.sps = sps
        self.pps = pps
        self.avcc = avcc
    }

    public init(sequence: UInt32, sample: CMSampleBuffer) throws {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else {
            throw VideoProtocolError.invalidPacket
        }
        var parameters: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var nalLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLength)
            guard status == noErr, let pointer, nalLength == 4 else {
                throw VideoProtocolError.invalidVideo(status)
            }
            parameters.append(Data(bytes: pointer, count: size))
        }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let status = avcc.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr, avcc.count + 12 + parameters[0].count + parameters[1].count <= Self.maximumSize else {
            throw VideoProtocolError.invalidVideo(status)
        }
        self.init(sequence: sequence, sps: parameters[0], pps: parameters[1], avcc: avcc)
    }

    public init(payload: Data) throws {
        var reader = PacketReader(data: payload)
        sequence = try reader.uint32()
        let spsLength = Int(try reader.uint32())
        let ppsLength = Int(try reader.uint32())
        guard (1...65536).contains(spsLength), (1...65536).contains(ppsLength) else {
            throw VideoProtocolError.invalidPacket
        }
        sps = try reader.bytes(spsLength)
        pps = try reader.bytes(ppsLength)
        avcc = try reader.bytes(reader.remaining)
        guard !avcc.isEmpty, payload.count <= Self.maximumSize else {
            throw VideoProtocolError.invalidPacket
        }
        var nals = PacketReader(data: avcc)
        while nals.remaining > 0 {
            let length = Int(try nals.uint32())
            guard length > 0 else { throw VideoProtocolError.invalidPacket }
            _ = try nals.bytes(length)
        }
    }

    public func framed() -> Data {
        var result = Data()
        for value in [UInt32(12 + sps.count + pps.count + avcc.count), sequence,
                      UInt32(sps.count), UInt32(pps.count)] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { result.append(contentsOf: $0) }
        }
        result.append(sps)
        result.append(pps)
        result.append(avcc)
        return result
    }

    public var isKeyFrame: Bool {
        var reader = PacketReader(data: avcc)
        while reader.remaining > 0 {
            guard let length = try? reader.uint32(), let nal = try? reader.bytes(Int(length)) else { return false }
            if let first = nal.first, first & 0x1F == 5 { return true }
        }
        return false
    }

    public func formatDescription() throws -> CMVideoFormatDescription {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                let pointers = [spsBuffer.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBuffer.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw VideoProtocolError.invalidVideo(status) }
        return format
    }

    public func sampleBuffer(format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoProtocolError.invalidVideo(status) }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { throw VideoProtocolError.invalidVideo(status) }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoProtocolError.invalidVideo(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

public struct VideoPacketParser {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [VideoPacket] {
        buffer.append(data)
        var packets: [VideoPacket] = []
        var consumed = buffer.startIndex
        while buffer.endIndex - consumed >= 4 {
            let length = buffer[consumed..<(consumed + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard (13...VideoPacket.maximumSize).contains(length) else {
                throw VideoProtocolError.invalidPacket
            }
            guard buffer.endIndex - consumed - 4 >= length else { break }
            packets.append(try VideoPacket(payload: Data(buffer[(consumed + 4)..<(consumed + 4 + length)])))
            consumed += 4 + length
        }
        buffer.removeSubrange(buffer.startIndex..<consumed)
        guard buffer.count <= VideoPacket.maximumSize + 4 else { throw VideoProtocolError.invalidPacket }
        return packets
    }
}

private struct PacketReader {
    let data: Data
    private var offset = 0
    init(data: Data) { self.data = data }
    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw VideoProtocolError.invalidPacket }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<(start + count)])
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
