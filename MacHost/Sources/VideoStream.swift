import Foundation
import ScreenCaptureKit
import VideoToolbox
import Network
import RemoteProtocol

struct VideoSettings {
    let width: Int
    let fps: Int
    let bitrate: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        width = min(2560, max(960, Int(environment["SK_MAX_WIDTH"] ?? "") ?? 1920))
        fps = min(60, max(15, Int(environment["SK_FPS"] ?? "") ?? 30))
        bitrate = min(16, max(2, Int(environment["SK_BITRATE_MBPS"] ?? "") ?? 8)) * 1_000_000
    }
}

final class VideoStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "remote.desktop.video", qos: .userInteractive)
    private let settings = VideoSettings()
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var stopped = false
    private var encoding = false
    private var latestFrame: (CVPixelBuffer, CMTime)?
    private var sequence: UInt32 = 0
    private var pending: [UInt32: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?
    private var currentBitrate = 0
    private var averageLatency: Double = 0
    private var lastRateChange = ProcessInfo.processInfo.systemUptime
    private var statsStart = ProcessInfo.processInfo.systemUptime
    private var sentBytes = 0
    private var acknowledgedFrames = 0
    var onStop: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    self.finish("Screen capture unavailable: \(error?.localizedDescription ?? "main display not found")")
                    return
                }
                do {
                    try self.configure(display: display)
                } catch {
                    self.finish("Video setup failed: \(error)")
                }
            }
        }
    }

    private func configure(display: SCDisplay) throws {
        let nativeWidth = CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? display.width
        let width = min(settings.width, nativeWidth) / 2 * 2
        let height = max(2, Int(Double(width) * Double(display.height) / Double(display.width)) / 2 * 2)
        encoder = try Self.makeEncoder(width: width, height: height, settings: settings)
        currentBitrate = settings.bitrate

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                               configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        capture.startCapture { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error { self.finish("Screen capture failed: \(error.localizedDescription)") }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        self.timer = timer
        print("H.264 hardware stream: \(width)x\(height), up to \(settings.fps) FPS, \(settings.bitrate / 1_000_000) Mbps target")
    }

    static func makeEncoder(width: Int, height: Int, settings: VideoSettings) throws -> VTCompressionSession {
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw VideoProtocolError.invalidVideo(status) }
        var prepared = false
        defer { if !prepared { VTCompressionSessionInvalidate(session) } }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: settings.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: settings.fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard result == noErr else { throw VideoProtocolError.invalidVideo(result) }
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else { throw VideoProtocolError.invalidVideo(prepareStatus) }

        prepared = true
        return session
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              rawStatus == SCFrameStatus.complete.rawValue,
              let image = sampleBuffer.imageBuffer else { return }
        // Retain only the newest unsent surface, including the final update after a burst.
        latestFrame = (image, sampleBuffer.presentationTimeStamp)
        encodeLatestIfPossible()
    }

    private func encodeLatestIfPossible() {
        // Never drop an encoded reference frame. Apply backpressure before encoding.
        guard !stopped, !encoding, pending.count < 3,
              let encoder, let (image, time) = latestFrame else { return }
        latestFrame = nil
        encoding = true
        let result = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                guard !self.stopped else { return }
                guard status == noErr else {
                    self.finish("Encoder failed: \(status)")
                    return
                }
                if !flags.contains(.frameDropped), let sample {
                    do { try self.send(sample) }
                    catch { self.finish("Invalid encoded frame: \(error)") }
                }
                self.encodeLatestIfPossible()
            }
        }
        if result != noErr { finish("Encode submission failed: \(result)") }
    }

    private func send(_ sample: CMSampleBuffer) throws {
        sequence &+= 1
        let packet = try VideoPacket(sequence: sequence, sample: sample).framed()
        pending[sequence] = ProcessInfo.processInfo.systemUptime
        sentBytes += packet.count
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.stop(reason: "Video send failed: \(error.localizedDescription)") }
        })
    }

    func acknowledge(_ sequence: UInt32) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let sent = self.pending.removeValue(forKey: sequence) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let latency = now - sent
            self.averageLatency = self.averageLatency == 0 ? latency : self.averageLatency * 0.8 + latency * 0.2
            self.acknowledgedFrames += 1
            if now - self.lastRateChange > 2, let encoder = self.encoder {
                var bitrate = self.currentBitrate
                if self.averageLatency > 0.25 { bitrate = max(2_000_000, bitrate * 3 / 4) }
                else if self.averageLatency < 0.12 { bitrate = min(self.settings.bitrate, bitrate + 500_000) }
                if bitrate != self.currentBitrate {
                    let status = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate,
                                                      value: bitrate as CFNumber)
                    if status == noErr { self.currentBitrate = bitrate }
                }
                self.lastRateChange = now
            }
            self.encodeLatestIfPossible()
        }
    }

    private func checkHealth() {
        let now = ProcessInfo.processInfo.systemUptime
        if let oldest = pending.values.min(), now - oldest > 10 {
            finish("Client stopped acknowledging video")
            return
        }
        let elapsed = now - statsStart
        if elapsed >= 5 {
            print(String(format: "Video: %.1f delivered FPS, %.2f Mbps, %.0f ms delivery/ACK, target %.1f Mbps",
                         Double(acknowledgedFrames) / elapsed, Double(sentBytes) * 8 / elapsed / 1_000_000,
                         averageLatency * 1000, Double(currentBitrate) / 1_000_000))
            statsStart = now
            sentBytes = 0
            acknowledgedFrames = 0
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop(reason: "Screen capture stopped: \(error.localizedDescription)")
    }

    func stop(reason: String = "Video disconnected") {
        queue.async { [weak self] in self?.finish(reason) }
    }

    private func finish(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        print(reason)
        timer?.cancel()
        timer = nil
        stream?.stopCapture { _ in }
        stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        latestFrame = nil
        pending.removeAll()
        connection.cancel()
        onStop?()
        onStop = nil
    }
}
