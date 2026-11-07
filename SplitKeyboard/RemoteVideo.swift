import UIKit
import AVFoundation
import Network

final class RemoteVideoView: UIView {
    private var videoLayer = AVSampleBufferDisplayLayer()
    private var pending: [(CMSampleBuffer, () -> Void)] = []
    private var requesting = false
    private(set) var imageSize: CGSize = .zero
    private(set) var zoomScale: CGFloat = 1
    private var zoomOffset = CGPoint.zero
    var renderedImageRect: CGRect {
        DesktopGeometry.imageRect(image: imageSize, viewport: bounds.size,
                                  aspectFit: contentMode == .scaleAspectFit, zoom: zoomScale, offset: zoomOffset)
    }
    var onFailure: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var contentMode: UIView.ContentMode {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.videoGravity = .resize
        videoLayer.frame = renderedImageRect
        CATransaction.commit()
    }

    func reset() {
        videoLayer.sampleBufferRenderer.stopRequestingMediaData()
        pending.removeAll()
        requesting = false
        imageSize = .zero
        zoomScale = 1
        zoomOffset = .zero
        videoLayer.removeFromSuperlayer()
        videoLayer = AVSampleBufferDisplayLayer()
        videoLayer.videoGravity = contentMode == .scaleAspectFit ? .resizeAspect : .resizeAspectFill
        layer.addSublayer(videoLayer)
        setNeedsLayout()
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard factor.isFinite, factor > 0, imageSize != .zero else { return }
        let old = renderedImageRect
        let normalized = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
        zoomScale = max(1, min(4, zoomScale * factor))
        let centered = DesktopGeometry.imageRect(image: imageSize, viewport: bounds.size,
                                                 aspectFit: contentMode == .scaleAspectFit, zoom: zoomScale, offset: .zero)
        zoomOffset = CGPoint(x: anchor.x - normalized.x * centered.width - centered.minX,
                             y: anchor.y - normalized.y * centered.height - centered.minY)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func panZoom(by delta: CGPoint) {
        let visible = renderedImageRect
        zoomOffset = CGPoint(x: visible.midX - bounds.midX + delta.x, y: visible.midY - bounds.midY + delta.y)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
        setNeedsLayout()
        layoutIfNeeded()
    }

    func display(_ sample: CMSampleBuffer, completion: @escaping () -> Void) {
        guard pending.count < 3 else {
            onFailure?("Video queue overflow. Reconnect.")
            return
        }
        pending.append((sample, completion))
        guard !requesting else { return }
        requesting = true
        let renderer = videoLayer.sampleBufferRenderer
        renderer.requestMediaDataWhenReady(on: .main) { [weak self, weak renderer] in
            guard let self, let renderer, renderer === self.videoLayer.sampleBufferRenderer else { return }
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.stopRequestingMediaData()
                self.requesting = false
                self.pending.removeAll()
                self.onFailure?(renderer.error?.localizedDescription ?? "Video decoder failed. Reconnect.")
                return
            }
            while renderer.isReadyForMoreMediaData, !self.pending.isEmpty {
                let (sample, completion) = self.pending.removeFirst()
                if let format = sample.formatDescription {
                    let size = CMVideoFormatDescriptionGetDimensions(format)
                    let newSize = CGSize(width: Int(size.width), height: Int(size.height))
                    if self.imageSize != newSize {
                        self.imageSize = newSize
                        self.setNeedsLayout()
                        self.layoutIfNeeded()
                    }
                }
                renderer.enqueue(sample)
                completion()
            }
            if self.pending.isEmpty {
                renderer.stopRequestingMediaData()
                self.requesting = false
            }
        }
    }
}

// All transport, framing and input state is confined to queue. UI callbacks run on main.
final class RemoteVideoClient {
    var onFrame: ((CMSampleBuffer, @escaping () -> Void) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private let queue = DispatchQueue(label: "splitkeyboard.video", qos: .userInteractive)
    private var connection: NWConnection?
    private var header = Data()
    private var receivedHeader = false
    private var receivedFrame = false
    private var parser = VideoPacketParser()
    private var lastSPS = Data()
    private var lastPPS = Data()
    private var format: CMVideoFormatDescription?
    private var outgoing: [(data: Data, isMove: Bool)] = []
    private var sending = false
    private var stopped = false
    private var statsTime = ProcessInfo.processInfo.systemUptime
    private var frameCount = 0
    private var byteCount = 0
    private var statsTimer: DispatchSourceTimer?

    deinit { connection?.cancel() }

    func connect(host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                          using: NWParameters(tls: nil, tcp: tcp))
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, !self.stopped else { return }
                switch state {
                case .ready:
                    let request = "GET /video HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                        if let error { self?.finish(error.localizedDescription) }
                    })
                    self.receive()
                case .failed(let error): self.finish(error.localizedDescription)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.stopped, !self.receivedFrame else { return }
                self.finish("No video. Restart the updated MacHost and check Screen Recording permission.")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.finish(nil) }
    }

    private func status(_ message: String, connected: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message, connected) }
    }

    private func finish(_ message: String?) {
        guard !stopped else { return }
        stopped = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        outgoing.removeAll()
        statsTimer?.cancel()
        statsTimer = nil
        if let message { status(message, connected: false) }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            do {
                if let data, !data.isEmpty { try self.consume(data) }
            } catch {
                self.finish("Invalid video stream. Update MacHost and reconnect.")
                return
            }
            if complete || error != nil {
                self.finish(error?.localizedDescription ?? "Video disconnected. Check MacHost.")
            } else if !self.stopped {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) throws {
        var payload = data
        byteCount += data.count
        if !receivedHeader {
            header.append(data)
            guard let separator = header.range(of: Data("\r\n\r\n".utf8)) else {
                guard header.count <= 16 * 1024 else { throw VideoProtocolError.invalidPacket }
                return
            }
            guard separator.lowerBound - header.startIndex <= 16 * 1024 else {
                throw VideoProtocolError.invalidPacket
            }
            let text = String(decoding: header[..<separator.lowerBound], as: UTF8.self).lowercased()
            guard text.hasPrefix("http/1.1 200 "), text.contains("application/x-splitkeyboard-h264"),
                  text.contains("x-splitkeyboard-version: 1") else {
                finish("Update and restart MacHost: this client requires the H.264 host.")
                return
            }
            payload = Data(header[separator.upperBound...])
            header.removeAll()
            receivedHeader = true
        }
        for packet in try parser.append(payload) {
            if packet.sps != lastSPS || packet.pps != lastPPS {
                format = try packet.formatDescription()
                lastSPS = packet.sps
                lastPPS = packet.pps
            }
            guard let format else { throw VideoProtocolError.invalidPacket }
            let sample = try packet.sampleBuffer(format: format)
            receivedFrame = true
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(sample, { [weak self] in
                    self?.acknowledge(packet.sequence)
                })
            }
        }
    }

    private func acknowledge(_ sequence: UInt32) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.enqueue(["type": "ack", "sequence": sequence])
            if self.statsTimer == nil {
                self.statsTime = ProcessInfo.processInfo.systemUptime
                self.byteCount = 0
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.reportStatistics() }
                timer.resume()
                self.statsTimer = timer
            }
            self.frameCount += 1
        }
    }

    private func reportStatistics() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - statsTime)
        status(String(format: "%.0f FPS / %.1f Mbps", Double(frameCount) / elapsed,
                      Double(byteCount) * 8 / elapsed / 1_000_000), connected: true)
        frameCount = 0
        byteCount = 0
        statsTime = now
    }

    func send(_ object: [String: Any]) {
        queue.async { [weak self] in self?.enqueue(object) }
    }

    private func enqueue(_ object: [String: Any]) {
        guard !stopped, receivedHeader,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        let isMove = object["type"] as? String == "mouse" && object["action"] as? String == "move"
        // Coalesce only consecutive moves, preserving click, text and scroll ordering.
        if isMove, outgoing.last?.isMove == true { outgoing.removeLast() }
        guard outgoing.count < 256 else {
            finish("Connection too slow for input. Reconnect.")
            return
        }
        outgoing.append((data, isMove))
        drainInput()
    }

    private func drainInput() {
        guard !sending, !outgoing.isEmpty, let connection, !stopped else { return }
        sending = true
        let message = outgoing.removeFirst()
        connection.send(content: message.data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            self.sending = false
            if let error { self.finish(error.localizedDescription) }
            else { self.drainInput() }
        })
    }
}
