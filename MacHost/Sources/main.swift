import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Network

private let boundary = "split-keyboard-frame"
private let port: NWEndpoint.Port = 7777
private let frameInterval: TimeInterval = 1.0 / 18.0
private let maxStreamWidth: CGFloat = 1600
private let jpegCompression: CGFloat = 0.32

final class RemoteDesktopHost {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "remote.desktop.host")
    private let legacyCaptureQueue = DispatchQueue(label: "remote.desktop.jpeg")
    private var videoStreams: [ObjectIdentifier: VideoStream] = [:]
    private var inputSessions: [ObjectIdentifier: RemoteInputController] = [:]
    private var inputWatchdog: DispatchSourceTimer?

    init() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: port)
    }

    func start() {
        printPermissionStatus()

        print("""

        SplitKeyboard MacHost is running.
        Open the iPhone app and connect to this Mac on port 7777.
        Tailscale addresses: \(tailscaleAddresses().joined(separator: ", "))
        Other local addresses: \(localAddresses().joined(separator: ", "))

        Required macOS permissions:
        - System Settings > Privacy & Security > Screen Recording
        - System Settings > Privacy & Security > Accessibility

        Keep this terminal window open.
        """)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("Listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            self?.inputSessions.values.forEach { $0.releaseIfExpired() }
        }
        watchdog.resume()
        inputWatchdog = watchdog
        dispatchMain()
    }

    private func printPermissionStatus() {
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
        }

        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let hasAccessibility = AXIsProcessTrustedWithOptions(accessibilityOptions)

        print("""

        Permission check:
        - Screen Recording: \(hasScreenRecording ? "OK" : "missing")
        - Accessibility: \(hasAccessibility ? "OK" : "missing")
        """)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("Receive error: \(error)")
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest(data: nextBuffer) {
                self.route(request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/video"):
            startVideo(on: connection)
        case ("GET", "/stream"):
            startStream(on: connection)
        case ("POST", "/input"):
            handleInput(request.body)
            sendHTTP(status: "204 No Content", body: Data(), on: connection, close: true)
        case ("GET", "/"):
            let body = Data("SplitKeyboard MacHost is running.\n".utf8)
            sendHTTP(status: "200 OK", body: body, on: connection, close: true)
        default:
            sendHTTP(status: "404 Not Found", body: Data("Not found\n".utf8), on: connection, close: true)
        }
    }

    private func startVideo(on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let video = VideoStream(connection: connection)
        videoStreams[id] = video
        let input = RemoteInputController()
        inputSessions[id] = input
        video.onStop = { [weak self] in
            self?.queue.async { [weak self] in
                self?.inputSessions.removeValue(forKey: id)?.release()
                self?.videoStreams.removeValue(forKey: id)
            }
        }
        connection.stateUpdateHandler = { [weak video] state in
            switch state {
            case .failed, .cancelled: video?.stop()
            default: break
            }
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-splitkeyboard-h264\r\nX-SplitKeyboard-Version: 1\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error == nil { video.start() }
            else { video.stop() }
        })
        receiveControls(on: connection, video: video, buffer: Data())
    }

    private func receiveControls(on connection: NWConnection, video: VideoStream, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak video] data, _, complete, error in
            guard let self, let video else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(buffer.startIndex...end)
                guard line.count <= 64 * 1024,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    video.stop(reason: "Invalid control message")
                    return
                }
                if object["type"] as? String == "ack", let sequence = object["sequence"] as? NSNumber {
                    video.acknowledge(sequence.uint32Value)
                } else {
                    self.inputSessions[ObjectIdentifier(connection)]?.handle(object)
                }
            }
            if complete || error != nil || buffer.count > 64 * 1024 {
                video.stop()
            } else {
                self.receiveControls(on: connection, video: video, buffer: buffer)
            }
        }
    }

    private func startStream(on connection: NWConnection) {
        let header = [
            "HTTP/1.1 200 OK",
            "Connection: close",
            "Cache-Control: no-cache",
            "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)",
            "",
            ""
        ].joined(separator: "\r\n")
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if let error {
                print("Header send failed: \(error)")
                connection.cancel()
                return
            }
        })
        sendFrame(on: connection)
    }

    private func sendFrame(on connection: NWConnection) {
        legacyCaptureQueue.asyncAfter(deadline: .now() + frameInterval) { [weak self] in
            guard let self else { return }
            guard let jpeg = self.captureJPEG() else {
                self.sendFrame(on: connection)
                return
            }

            let frameHeader = [
                "--\(boundary)",
                "Content-Type: image/jpeg",
                "Content-Length: \(jpeg.count)",
                "",
                ""
            ].joined(separator: "\r\n")

            var payload = Data(frameHeader.utf8)
            payload.append(jpeg)
            payload.append(Data("\r\n".utf8))

            connection.send(content: payload, completion: .contentProcessed { error in
                if error == nil {
                    self.sendFrame(on: connection)
                } else {
                    connection.cancel()
                }
            })
        }
    }

    private func captureJPEG() -> Data? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        let outputImage = downscaledImageIfNeeded(image)
        let bitmap = NSBitmapImageRep(cgImage: outputImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegCompression])
    }

    private func downscaledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > maxStreamWidth else { return image }

        let scale = maxStreamWidth / width
        let targetWidth = Int(width * scale)
        let targetHeight = Int(height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func handleInput(_ body: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "text":
            if let value = object["value"] as? String {
                postText(value)
            }
        case "key":
            if let value = object["value"] as? String {
                postKey(value)
            }
        case "mouse":
            let action = object["action"] as? String ?? "move"
            let x = object["x"] as? Double ?? 0
            let y = object["y"] as? Double ?? 0
            postMouse(action: action, normalizedX: x, normalizedY: y)
        case "scroll":
            let dy = (object["dy"] as? NSNumber)?.doubleValue ?? object["dy"] as? Double ?? 0
            postScroll(deltaY: dy)
        default:
            break
        }
    }

    private func postText(_ text: String) {
        for character in text {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }

            let units = Array(String(character).utf16)
            units.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ key: String) {
        let keyCode: CGKeyCode?
        switch key {
        case "backspace": keyCode = 51
        case "return": keyCode = 36
        case "tab": keyCode = 48
        case "escape": keyCode = 53
        default: keyCode = nil
        }

        guard let keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMouse(action: String, normalizedX: Double, normalizedY: Double) {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let x = bounds.minX + max(0, min(1, normalizedX)) * max(0, bounds.width - 1)
        let y = bounds.minY + max(0, min(1, normalizedY)) * max(0, bounds.height - 1)
        let point = CGPoint(x: x, y: y)

        switch action {
        case "click":
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        default:
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    private func postScroll(deltaY: Double) {
        let lineDelta = max(-12, min(12, deltaY / 6))
        guard abs(lineDelta) >= 1 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(lineDelta),
            wheel2: 0,
            wheel3: 0
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    private func sendHTTP(status: String, body: Data, on connection: NWConnection, close: Bool) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Content-Type: text/plain; charset=utf-8",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            if close {
                connection.cancel()
            }
        })
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        method = String(parts[0])
        path = String(parts[1])

        let contentLength = lines.compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        body = data[bodyStart..<(bodyStart + contentLength)]
    }
}

private func localAddresses() -> [String] {
    allIPv4Addresses()
        .filter { !$0.hasPrefix("127.") && !$0.hasPrefix("100.") }
        .map { "\($0):7777" }
}

private func tailscaleAddresses() -> [String] {
    let addresses = allIPv4Addresses()
        .filter { $0.hasPrefix("100.") }
        .map { "\($0):7777" }

    return addresses.isEmpty ? ["not found - start Tailscale on this Mac"] : addresses
}

private func allIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        return ["127.0.0.1"]
    }
    defer { freeifaddrs(interfaces) }

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        let family = interface.ifa_addr.pointee.sa_family
        guard family == UInt8(AF_INET) else { continue }

        let flags = Int32(interface.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

        var address = interface.ifa_addr.pointee
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(&address, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        if result == 0 {
            addresses.append(String(cString: host))
        }
    }

    return addresses.isEmpty ? ["127.0.0.1"] : Array(Set(addresses)).sorted()
}

do {
    try RemoteDesktopHost().start()
} catch {
    print("Failed to start MacHost: \(error)")
    exit(1)
}
