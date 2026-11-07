import Foundation
import CoreGraphics

final class RemoteInputController {
    private let emit: (CGEvent) -> Void
    private let displayBounds: () -> CGRect
    private let eventSource = CGEventSource(stateID: .privateState)
    private(set) var isDragging = false
    private var point = CGPoint.zero
    private var lastHoldActivity: TimeInterval = 0

    init(emit: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         displayBounds: @escaping () -> CGRect = { CGDisplayBounds(CGMainDisplayID()) }) {
        self.emit = emit
        self.displayBounds = displayBounds
    }

    func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "mouse":
            guard let x = object["x"] as? Double, let y = object["y"] as? Double, x.isFinite, y.isFinite else { return }
            let action = object["action"] as? String
            if ["move", "click", "doubleClick", "rightClick"].contains(action ?? "") { release() }
            let bounds = displayBounds()
            point = CGPoint(x: bounds.minX + max(0, min(1, x)) * max(0, bounds.width - 1),
                            y: bounds.minY + max(0, min(1, y)) * max(0, bounds.height - 1))
            switch action {
            case "down":
                if !isDragging { mouse(.leftMouseDown); isDragging = true }
                refreshHold()
            case "up": release()
            case "drag":
                mouse(isDragging ? .leftMouseDragged : .mouseMoved)
                if isDragging { refreshHold() }
            case "move":
                release()
                mouse(.mouseMoved)
            case "click":
                release(); mouse(.leftMouseDown); mouse(.leftMouseUp)
            case "doubleClick":
                release()
                for count: Int64 in 1...2 { mouse(.leftMouseDown, count: count); mouse(.leftMouseUp, count: count) }
            case "rightClick":
                release(); mouse(.rightMouseDown, button: .right); mouse(.rightMouseUp, button: .right)
            default: break
            }
        case "hold": if isDragging { refreshHold() }
        case "release": release()
        case "shortcut":
            guard let value = object["value"] as? String else { return }
            release()
            let keys: [String: CGKeyCode] = ["copy": 8, "paste": 9, "cut": 7, "selectAll": 0,
                                           "undo": 6, "redo": 6, "zoomIn": 24, "zoomOut": 27, "actualSize": 29]
            if let key = keys[value] {
                var flags: CGEventFlags = .maskCommand
                if value == "redo" || value == "zoomIn" { flags.insert(.maskShift) }
                keyEvents(key, flags: flags)
            }
        case "key":
            release()
            let keys: [String: CGKeyCode] = ["backspace": 51, "return": 36, "tab": 48, "escape": 53]
            if let value = object["value"] as? String, let code = keys[value] { keyEvents(code) }
        case "text":
            guard let text = object["value"] as? String else { return }
            release()
            for character in text {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: down) else { continue }
                    event.flags = []
                    units.withUnsafeBufferPointer {
                        if let base = $0.baseAddress { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base) }
                    }
                    emit(event)
                }
            }
        case "scroll":
            guard let dy = object["dy"] as? Double, dy.isFinite else { return }
            release()
            let amount = max(-12, min(12, dy / 6))
            guard abs(amount) >= 1, let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line,
                                                       wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0) else { return }
            event.flags = []
            emit(event)
        default: break
        }
    }

    func refreshHold() { lastHoldActivity = ProcessInfo.processInfo.systemUptime }

    func releaseIfExpired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if isDragging && now - lastHoldActivity > 8 { release() }
    }

    func release() {
        guard isDragging else { return }
        mouse(.leftMouseUp)
        isDragging = false
    }

    private func mouse(_ type: CGEventType, button: CGMouseButton = .left, count: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: count)
        emit(event)
    }

    private func keyEvents(_ key: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: down) else { continue }
            // End the shortcut without leaving Command/Shift in the synthetic event state.
            event.flags = down ? flags : []
            emit(event)
        }
    }
}
