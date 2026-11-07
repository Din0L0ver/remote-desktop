import UIKit

final class ViewController: UIViewController {
    private enum KeyboardMode {
        case letters
        case numbers
        case symbols
        case tools
    }

    private enum Language {
        case english
        case russian

        var title: String {
            switch self {
            case .english: return "EN"
            case .russian: return "RU"
            }
        }

        var rows: [[String]] {
            switch self {
            case .english:
                return [
                    Array("qwertyuiop").map(String.init),
                    Array("asdfghjkl").map(String.init),
                    Array("zxcvbnm").map(String.init)
                ]
            case .russian:
                return [
                    Array("йцукенгшщзхъ").map(String.init),
                    Array("фывапролджэ").map(String.init),
                    Array("ячсмитьбю").map(String.init)
                ]
            }
        }
    }

    private let streamView = RemoteVideoView()
    private let hostField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let cursorView = UIView()
    private let pinchModeControl = UISegmentedControl(items: ["Screen", "Mac app"])
    private let edgeKeysSwitch = UISwitch()
    private let closeSettingsButton = UIButton(type: .system)
    private let pinchGesture = UIPinchGestureRecognizer()
    private let scrollPan = UIPanGestureRecognizer()
    private var twoFingerState = TwoFingerGestureState()
    private var isScrollTracking = false
    private var isPinchTracking = false
    private var appliedPinchScale: CGFloat = 1
    private var landscapeRows: [(UIView, Bool, Int, Int)] = []
    private var isMouseHeld = false
    private var longPressOwnsDrag = false
    private var holdTimer: Timer?
    private var pinchAccumulator: CGFloat = 1
    private var lastAppZoomTime: TimeInterval = 0
    private let dragButtons = NSHashTable<UIButton>.weakObjects()

    // Used only in portrait. In landscape it is hidden so the center remains hit-testable.
    private let keyboardView = UIView()
    private let leftKeyboardPanel = UIView()
    private let rightKeyboardPanel = UIView()

    private var portraitKeyboardHeightConstraint: NSLayoutConstraint?
    private var fullScreenStreamConstraints: [NSLayoutConstraint] = []
    private var centeredStreamConstraints: [NSLayoutConstraint] = []

    private var videoClient: RemoteVideoClient?
    private var resumeAfterBackground = false
    private var remoteHost: String?
    private var remotePort: UInt16 = 7777
    private var language: Language = .english
    private var keyboardMode: KeyboardMode = .letters
    private var isShifted = false
    private var lastLayoutSize: CGSize = .zero
    private var lastVideoSize: CGSize = .zero
    private var isConnected = false
    private var cursorPoint = CGPoint(x: 0.5, y: 0.5)
    private var lastScrollTranslationY: CGFloat = 0
    private var accumulatedScrollDeltaY: CGFloat = 0

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        [.bottom, .left, .right]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureRemoteView()
        configureTopBar()
        configureKeyboards()
        rebuildKeyboard()
        NotificationCenter.default.addObserver(self, selector: #selector(pauseVideo),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeVideo),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        streamView.onFailure = { [weak self] message in
            self?.videoClient?.stop()
            self?.videoClient = nil
            self?.streamView.reset()
            self?.statusLabel.text = message
            self?.setConnectedUI(false)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = view.bounds.size
        if abs(size.width - lastLayoutSize.width) > 1 || abs(size.height - lastLayoutSize.height) > 1 {
            lastLayoutSize = size
            updateKeyboardHeights()
            rebuildKeyboard()
        }
        layoutLandscapeRows()
        // Constraints can settle in a second pass after rotation, even with the same root size.
        updateCursorView()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        endMouseHold()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.layoutLandscapeRows()
            self?.updateCursorView()
        }
    }

    private var isLandscape: Bool {
        view.bounds.width > view.bounds.height
    }

    private func configureRemoteView() {
        streamView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        streamView.contentMode = .scaleAspectFill
        streamView.clipsToBounds = true
        streamView.isUserInteractionEnabled = true
        streamView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(streamView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        scrollPan.addTarget(self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.delegate = self
        scrollPan.name = "scroll"

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 6
        pan.require(toFail: hold)
        tap.require(toFail: hold)
        doubleTap.require(toFail: hold)
        let contextTap = UITapGestureRecognizer(target: self, action: #selector(handleContextTap(_:)))
        contextTap.numberOfTouchesRequired = 2
        contextTap.require(toFail: scrollPan)
        contextTap.require(toFail: pinchGesture)
        pinchGesture.addTarget(self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        pinchGesture.name = "pinch"

        let viewportPan = UIPanGestureRecognizer(target: self, action: #selector(handleViewportPan(_:)))
        viewportPan.minimumNumberOfTouches = 3
        viewportPan.maximumNumberOfTouches = 3

        streamView.addGestureRecognizer(tap)
        streamView.addGestureRecognizer(doubleTap)
        streamView.addGestureRecognizer(pan)
        streamView.addGestureRecognizer(scrollPan)
        streamView.addGestureRecognizer(hold)
        streamView.addGestureRecognizer(contextTap)
        streamView.addGestureRecognizer(pinchGesture)
        streamView.addGestureRecognizer(viewportPan)

        cursorView.isUserInteractionEnabled = false
        cursorView.backgroundColor = .white
        cursorView.layer.cornerRadius = 8
        cursorView.layer.borderWidth = 2
        cursorView.layer.borderColor = UIColor.black.cgColor
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.45
        cursorView.layer.shadowRadius = 4
        cursorView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cursorView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(cursorView)

        fullScreenStreamConstraints = [
            streamView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            streamView.topAnchor.constraint(equalTo: view.topAnchor),
            streamView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(fullScreenStreamConstraints)
    }

    private func configureTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        hostField.placeholder = "Tailscale IP: 100.x.y.z"
        hostField.text = UserDefaults.standard.string(forKey: "lastHost") ?? ""
        hostField.keyboardType = .numbersAndPunctuation
        hostField.autocorrectionType = .no
        hostField.autocapitalizationType = .none
        hostField.borderStyle = .roundedRect
        hostField.clearButtonMode = .whileEditing

        connectButton.setTitle("Connect", for: .normal)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

        statusLabel.text = "Not connected"
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0

        closeSettingsButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeSettingsButton.tintColor = .white
        closeSettingsButton.accessibilityLabel = "Close settings"
        closeSettingsButton.toolTip = "Close settings"
        closeSettingsButton.isHidden = true
        closeSettingsButton.addTarget(self, action: #selector(closeSettings), for: .touchUpInside)

        let pinchTitle = UILabel()
        pinchTitle.text = "Pinch zoom"
        pinchTitle.textColor = .white
        pinchTitle.font = .systemFont(ofSize: 13)
        pinchModeControl.selectedSegmentIndex = 0
        pinchModeControl.accessibilityLabel = "Pinch zoom target"
        pinchModeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        pinchModeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        pinchModeControl.selectedSegmentTintColor = .white
        let pinchRow = UIStackView(arrangedSubviews: [pinchTitle, pinchModeControl])
        pinchRow.spacing = 10
        pinchRow.alignment = .center
        let edgeTitle = UILabel()
        edgeTitle.text = "Edge keys"
        edgeTitle.textColor = .white
        edgeTitle.font = .systemFont(ofSize: 13)
        edgeKeysSwitch.isOn = UserDefaults.standard.object(forKey: "edgeKeys") as? Bool ?? true
        edgeKeysSwitch.accessibilityLabel = "Keys around display cutout"
        edgeKeysSwitch.addTarget(self, action: #selector(edgeKeysChanged), for: .valueChanged)
        let edgeRow = UIStackView(arrangedSubviews: [edgeTitle, edgeKeysSwitch])
        edgeRow.spacing = 10
        edgeRow.alignment = .center

        let connectionRow = UIStackView(arrangedSubviews: [hostField, connectButton, closeSettingsButton])
        connectionRow.axis = .horizontal
        connectionRow.spacing = 8
        connectionRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [connectionRow, pinchRow, edgeRow, statusLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: streamView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: streamView.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: topBar.contentView.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: topBar.contentView.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topBar.contentView.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -8),
            connectButton.widthAnchor.constraint(equalToConstant: 78)
        ])
        let closeWidth = closeSettingsButton.widthAnchor.constraint(equalToConstant: 44)
        closeWidth.priority = .defaultHigh
        closeWidth.isActive = true
        closeSettingsButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func configureKeyboards() {
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.backgroundColor = keyboardBackground
        view.addSubview(keyboardView)

        [leftKeyboardPanel, rightKeyboardPanel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.backgroundColor = keyboardBackground
            $0.layer.cornerRadius = 0
            $0.clipsToBounds = true
            $0.isHidden = true
            view.addSubview($0)
        }

        portraitKeyboardHeightConstraint = keyboardView.heightAnchor.constraint(equalToConstant: 256)
        portraitKeyboardHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            leftKeyboardPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftKeyboardPanel.topAnchor.constraint(equalTo: view.topAnchor),
            leftKeyboardPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftKeyboardPanel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.16),

            rightKeyboardPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightKeyboardPanel.topAnchor.constraint(equalTo: view.topAnchor),
            rightKeyboardPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rightKeyboardPanel.widthAnchor.constraint(equalTo: leftKeyboardPanel.widthAnchor)
        ])

        centeredStreamConstraints = [
            streamView.leadingAnchor.constraint(equalTo: leftKeyboardPanel.trailingAnchor),
            streamView.trailingAnchor.constraint(equalTo: rightKeyboardPanel.leadingAnchor),
            streamView.topAnchor.constraint(equalTo: view.topAnchor),
            streamView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
    }

    private var keyboardBackground: UIColor {
        UIColor(red: 207 / 255, green: 211 / 255, blue: 217 / 255, alpha: 0.96)
    }

    private func updateKeyboardHeights() {
        portraitKeyboardHeightConstraint?.constant = 256
    }

    private func rebuildKeyboard() {
        if isLandscape {
            rebuildLandscapeKeyboard()
        } else {
            rebuildPortraitKeyboard()
        }
    }

    private func rebuildPortraitKeyboard() {
        updateRemoteLayoutForCurrentOrientation()
        keyboardView.isHidden = false
        leftKeyboardPanel.isHidden = true
        rightKeyboardPanel.isHidden = true

        keyboardView.subviews.forEach { $0.removeFromSuperview() }
        keyboardView.backgroundColor = keyboardBackground
        landscapeRows.removeAll()

        let outer = verticalStack(spacing: 8)
        keyboardView.addSubview(outer)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 4),
            outer.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -4),
            outer.topAnchor.constraint(equalTo: keyboardView.topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: keyboardView.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])

        if keyboardMode == .tools {
            [["copy", "paste", "cut"], ["selectAll", "drag", "rightClick"],
             ["undo", "redo", "zoomReset"], ["tools", "addr", "escape"]].forEach {
                outer.addArrangedSubview(landscapeGridRow($0))
            }
            bringOverlaysToFront()
            return
        }
        for (index, row) in rowsForCurrentMode().enumerated() {
            outer.addArrangedSubview(portraitLetterRow(row, rowIndex: index))
        }

        outer.addArrangedSubview(portraitControlRow())
        bringOverlaysToFront()
    }

    private func rebuildLandscapeKeyboard() {
        updateRemoteLayoutForCurrentOrientation()
        keyboardView.isHidden = true
        leftKeyboardPanel.isHidden = false
        rightKeyboardPanel.isHidden = false

        leftKeyboardPanel.subviews.forEach { $0.removeFromSuperview() }
        rightKeyboardPanel.subviews.forEach { $0.removeFromSuperview() }

        leftKeyboardPanel.backgroundColor = keyboardBackground
        rightKeyboardPanel.backgroundColor = keyboardBackground

        landscapeRows.removeAll()
        for (panel, left, rows) in [(leftKeyboardPanel, true, landscapeLeftRows()), (rightKeyboardPanel, false, landscapeRightRows())] {
            for (index, keys) in rows.enumerated() {
                let row = landscapeGridRow(keys)
                row.translatesAutoresizingMaskIntoConstraints = true
                panel.addSubview(row)
                landscapeRows.append((row, left, index, rows.count))
            }
        }
        layoutLandscapeRows()
        bringOverlaysToFront()
    }

    private func layoutLandscapeRows() {
        guard isLandscape, let screen = view.window?.windowScene?.screen else { return }
        let fixed = screen.fixedCoordinateSpace
        let topEdge = view.convert(CGPoint(x: fixed.bounds.midX, y: fixed.bounds.minY), from: fixed)
        let cutout: DisplayCutoutSide = abs(topEdge.y - view.bounds.midY) < 30 ? (topEdge.x < view.bounds.midX ? .left : .right) : .unknown
        let native = screen.nativeBounds.size
        let isIPhone15Size = abs(min(native.width, native.height) - 1179) < 2 && abs(max(native.width, native.height) - 2556) < 2
        for (row, left, index, count) in landscapeRows {
            row.frame = DesktopGeometry.rowFrame(screen: view.bounds.size, panelOnLeft: left, row: index, count: count,
                                                  cutout: cutout, edgeSafeInset: left ? view.safeAreaInsets.left : view.safeAreaInsets.right,
                                                  bottomSafeInset: view.safeAreaInsets.bottom,
                                                  useIslandTemplate: edgeKeysSwitch.isOn && isIPhone15Size)
        }
    }

    private func updateRemoteLayoutForCurrentOrientation() {
        if isLandscape {
            NSLayoutConstraint.deactivate(fullScreenStreamConstraints)
            NSLayoutConstraint.activate(centeredStreamConstraints)
            streamView.contentMode = .scaleAspectFit
            streamView.backgroundColor = .black
        } else {
            NSLayoutConstraint.deactivate(centeredStreamConstraints)
            NSLayoutConstraint.activate(fullScreenStreamConstraints)
            streamView.contentMode = .scaleAspectFill
        }
    }

    private func portraitLetterRow(_ letters: [String], rowIndex: Int) -> UIView {
        let container = UIView()
        let row = keyRow(spacing: 5)
        container.addSubview(row)

        let inset: CGFloat
        switch rowIndex {
        case 1: inset = 18
        case 2: inset = 46
        default: inset = 0
        }

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if rowIndex == 2 && keyboardMode == .letters {
            row.addArrangedSubview(keyButton("shift", action: #selector(toggleShift)))
        }

        letters.forEach { row.addArrangedSubview(inputButton($0)) }

        if rowIndex == 2 {
            row.addArrangedSubview(keyButton("delete", action: #selector(deleteBackward)))
        }

        return container
    }

    private func portraitControlRow() -> UIView {
        let row = keyRow(spacing: 5)
        row.addArrangedSubview(keyButton(modeSwitchTitle(), action: #selector(toggleKeyboardMode)))
        row.addArrangedSubview(keyButton(language.title, action: #selector(toggleLanguage)))
        row.addArrangedSubview(keyButton("space", action: #selector(insertSpace)))
        row.addArrangedSubview(keyButton("click", action: #selector(clickCursor)))
        row.addArrangedSubview(keyButton("tools", action: #selector(toggleTools)))
        row.addArrangedSubview(keyButton("return", action: #selector(insertReturn)))
        return row
    }

    private func landscapeGridRow(_ keys: [String]) -> UIView {
        let row = keyRow(spacing: 4)
        keys.forEach { key in
            switch key {
            case "tools": row.addArrangedSubview(keyButton("tools", action: #selector(toggleTools)))
            case "drag": row.addArrangedSubview(keyButton("drag", action: #selector(toggleMouseHold)))
            case "rightClick": row.addArrangedSubview(keyButton("rightClick", action: #selector(rightClickCursor)))
            case "zoomReset": row.addArrangedSubview(keyButton("zoomReset", action: #selector(resetZoom)))
            case "escape": row.addArrangedSubview(keyButton("escape", action: #selector(insertEscape)))
            case "copy", "paste", "cut", "selectAll", "undo", "redo", "zoomIn", "zoomOut":
                let button = keyButton(key, action: nil)
                button.addAction(UIAction { [weak self] _ in self?.sendShortcut(key) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            case "shift":
                row.addArrangedSubview(keyButton("shift", action: #selector(toggleShift)))
            case "delete":
                row.addArrangedSubview(keyButton("delete", action: #selector(deleteBackward)))
            case "mode":
                row.addArrangedSubview(keyButton(modeSwitchTitle(), action: #selector(toggleKeyboardMode)))
            case "lang":
                row.addArrangedSubview(keyButton(language.title, action: #selector(toggleLanguage)))
            case "space":
                row.addArrangedSubview(keyButton("space", action: #selector(insertSpace)))
            case "addr":
                row.addArrangedSubview(keyButton("addr", action: #selector(showAddressBar)))
            case "symbols":
                row.addArrangedSubview(keyButton(symbolSwitchTitle(), action: #selector(toggleSymbolMode)))
            case "click":
                row.addArrangedSubview(keyButton("click", action: #selector(clickCursor)))
            case "tab":
                row.addArrangedSubview(keyButton("tab", action: #selector(insertTab)))
            case "return":
                row.addArrangedSubview(keyButton("return", action: #selector(insertReturn)))
            default:
                row.addArrangedSubview(inputButton(key))
            }
        }
        return row
    }

    private func landscapeLeftRows() -> [[String]] {
        if keyboardMode == .tools {
            return [["copy", "paste"], ["cut", "selectAll"], ["undo", "redo"], ["addr"], ["tools"]]
        }
        let rows = rowsForCurrentMode()
        let keys = rows.enumerated().flatMap { index, row -> [String] in
            let splitIndex = Int(ceil(Double(row.count) / 2.0))
            var keys = Array(row.prefix(splitIndex))
            if index == 2 && keyboardMode == .letters {
                keys.insert("shift", at: 0)
            }
            return keys
        }

        return chunk(keys, size: 3) + [
            ["mode", "lang"],
            ["space"],
            ["tools"]
        ]
    }

    private func landscapeRightRows() -> [[String]] {
        if keyboardMode == .tools {
            return [["click", "rightClick"], ["drag"], ["zoomIn", "zoomOut"], ["zoomReset"], ["escape"]]
        }
        let rows = rowsForCurrentMode()
        let keys = rows.enumerated().flatMap { index, row -> [String] in
            let splitIndex = Int(ceil(Double(row.count) / 2.0))
            var keys = Array(row.suffix(row.count - splitIndex))
            if index == 2 {
                keys.append("delete")
            }
            return keys
        }

        return chunk(keys, size: 3) + [
            ["symbols", "click"],
            ["tab"],
            ["return"]
        ]
    }

    private func chunk(_ keys: [String], size: Int) -> [[String]] {
        stride(from: 0, to: keys.count, by: size).map {
            Array(keys[$0..<min($0 + size, keys.count)])
        }
    }

    private func verticalStack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func keyRow(spacing: CGFloat? = nil) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = spacing ?? (isLandscape ? 4 : 5)
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func rowsForCurrentMode() -> [[String]] {
        switch keyboardMode {
        case .tools: return []
        case .letters:
            return language.rows
        case .numbers:
            return [
                Array("1234567890").map(String.init),
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                [".", ",", "?", "!", "'", "_", "=", "+"]
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                [".", ",", "?", "!", "'", "`", "…", "—"]
            ]
        }
    }

    private func inputButton(_ value: String) -> UIButton {
        let title = keyboardMode == .letters && isShifted ? value.uppercased() : value
        let button = styledButton(title)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.sendInput(type: "text", value: title)
            if self.isShifted {
                self.isShifted = false
                self.rebuildKeyboard()
            }
        }, for: .touchUpInside)
        return button
    }

    private func keyButton(_ title: String, action: Selector?) -> UIButton {
        let button = styledButton(displayTitle(title), background: UIColor(red: 172 / 255, green: 179 / 255, blue: 189 / 255, alpha: 1))
        let symbols = ["space": "space", "return": "return", "tab": "arrow.right.to.line", "click": "cursorarrow.click",
                       "tools": keyboardMode == .tools ? "keyboard" : "slider.horizontal.3", "copy": "doc.on.doc", "paste": "doc.on.clipboard",
                       "cut": "scissors", "selectAll": "selection.pin.in.out", "undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward",
                       "drag": "hand.draw", "rightClick": "computermouse", "zoomIn": "plus.magnifyingglass", "zoomOut": "minus.magnifyingglass",
                       "zoomReset": "arrow.counterclockwise", "escape": "escape"]
        if let symbol = symbols[title],
           let image = UIImage(systemName: symbol) {
            var config = button.configuration
            config?.title = nil
            config?.image = image
            config?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
            button.configuration = config
            button.accessibilityLabel = title
            button.toolTip = title
        }
        if title == "drag" {
            dragButtons.add(button)
            updateDragButton(button)
        }
        if let action {
            button.addTarget(self, action: action, for: title == "click" ? .touchDown : .touchUpInside)
        }
        return button
    }

    private func updateDragButton(_ button: UIButton) {
        button.configuration?.baseBackgroundColor = isMouseHeld ? .systemYellow : UIColor(red: 172 / 255, green: 179 / 255, blue: 189 / 255, alpha: 1)
        button.configuration?.baseForegroundColor = isMouseHeld ? .black : .label
        button.accessibilityValue = isMouseHeld ? "Held" : "Released"
    }

    private func updateHoldAppearance() {
        cursorView.backgroundColor = isMouseHeld ? .systemYellow : .white
        // Keep controls alive: replacing them cancels a second thumb's in-flight touch.
        dragButtons.allObjects.forEach(updateDragButton)
    }

    private func styledButton(_ title: String, background: UIColor = .white) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = background
        config.baseForegroundColor = .label
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
        config.titleLineBreakMode = .byClipping
        let font = UIFont.systemFont(ofSize: isLandscape ? (title.count > 1 ? 16 : 18) : 22)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = font
            return attributes
        }

        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: isLandscape ? 18 : 22)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.5
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.22
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        return button
    }

    private func displayTitle(_ title: String) -> String {
        switch title {
        case "shift": return "⇧"
        case "delete": return "⌫"
        case "space": return "space"
        case "return": return "return"
        case "tab": return "tab"
        case "click": return "click"
        case "addr": return "addr"
        case "numbers": return "123"
        case "letters": return "ABC"
        case "symbols": return "#+="
        default: return title
        }
    }

    private func modeSwitchTitle() -> String {
        keyboardMode == .letters ? "numbers" : "letters"
    }

    private func symbolSwitchTitle() -> String {
        keyboardMode == .symbols ? "numbers" : "symbols"
    }

    @objc private func connectTapped() {
        let rawHost = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawHost.isEmpty else {
            statusLabel.text = "Enter Mac IP"
            return
        }

        UserDefaults.standard.set(rawHost, forKey: "lastHost")
        guard let endpoint = parseEndpoint(rawHost) else {
            statusLabel.text = "Bad address"
            return
        }

        view.endEditing(true)
        remoteHost = endpoint.host
        remotePort = endpoint.port
        statusLabel.text = "Connecting..."
        startStream(host: endpoint.host, port: endpoint.port)
    }

    private func parseEndpoint(_ rawValue: String) -> (host: String, port: UInt16)? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "http://", with: "")
        value = value.replacingOccurrences(of: "https://", with: "")
        value = value.components(separatedBy: "/").first ?? value

        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts.first ?? ""
        guard !host.isEmpty else { return nil }

        let port: UInt16
        if parts.count == 2, let parsedPort = UInt16(parts[1]) {
            port = parsedPort
        } else {
            port = 7777
        }

        return (host, port)
    }

    private func startStream(host: String, port: UInt16) {
        endMouseHold()
        videoClient?.stop()
        streamView.reset()
        lastVideoSize = .zero
        setConnectedUI(false)
        let client = RemoteVideoClient()
        videoClient = client
        client.onStatus = { [weak self, weak client] message, connected in
            guard let self, let client, self.videoClient === client else { return }
            self.statusLabel.text = message
            if !connected {
                self.videoClient = nil
                self.streamView.reset()
                self.setConnectedUI(false)
            }
        }
        client.onFrame = { [weak self, weak client] sample, acknowledge in
            guard let self, let client, self.videoClient === client else { return }
            self.streamView.display(sample) { [weak self, weak client] in
                guard let self, let client, self.videoClient === client else { return }
                if !self.isConnected {
                    self.statusLabel.text = "Live"
                    self.setConnectedUI(true)
                }
                if self.lastVideoSize != self.streamView.imageSize {
                    self.lastVideoSize = self.streamView.imageSize
                    self.updateCursorView()
                }
                acknowledge()
            }
        }
        client.connect(host: host, port: port)
    }

    @objc private func pauseVideo() {
        endMouseHold()
        resumeAfterBackground = videoClient != nil
        videoClient?.stop()
        videoClient = nil
        streamView.reset()
        setConnectedUI(false)
    }

    @objc private func resumeVideo() {
        guard resumeAfterBackground, let remoteHost else { return }
        resumeAfterBackground = false
        statusLabel.text = "Connecting..."
        startStream(host: remoteHost, port: remotePort)
    }

    private func setConnectedUI(_ connected: Bool) {
        if !connected { endMouseHold() }
        isConnected = connected
        closeSettingsButton.isHidden = !connected
        if !connected { topBar.isHidden = false }
        UIView.animate(withDuration: 0.22) {
            self.topBar.alpha = connected ? 0 : 1
        } completion: { _ in
            self.topBar.isHidden = self.isConnected && self.topBar.alpha == 0
            self.bringOverlaysToFront()
        }
    }

    private func sendInput(type: String, value: String) {
        endMouseHold()
        sendJSON(["type": type, "value": value])
    }

    private func sendMouse(action: String, point: CGPoint) {
        guard let normalizedPoint = normalizedScreenPoint(from: point) else { return }
        cursorPoint = normalizedPoint
        updateCursorView()
        sendMouse(action: action, normalizedPoint: normalizedPoint)
    }

    private func sendMouse(action: String, normalizedPoint: CGPoint) {
        let normalizedX = max(0, min(1, normalizedPoint.x))
        let normalizedY = max(0, min(1, normalizedPoint.y))
        sendJSON(["type": "mouse", "action": action, "x": normalizedX, "y": normalizedY])
    }

    private func sendScroll(deltaY: CGFloat) {
        sendJSON(["type": "scroll", "dy": Double(deltaY)])
    }

    private func normalizedScreenPoint(from point: CGPoint) -> CGPoint? {
        guard streamView.bounds.contains(point) else { return nil }
        guard streamView.imageSize != .zero else {
            return CGPoint(
                x: max(0, min(1, point.x / max(streamView.bounds.width, 1))),
                y: max(0, min(1, point.y / max(streamView.bounds.height, 1)))
            )
        }

        let geometry = renderedImageGeometry()
        let renderedSize = geometry.size
        let origin = geometry.origin
        guard CGRect(origin: origin, size: renderedSize).contains(point) else { return nil }
        let imagePoint = CGPoint(x: (point.x - origin.x) / renderedSize.width, y: (point.y - origin.y) / renderedSize.height)

        return CGPoint(x: max(0, min(1, imagePoint.x)), y: max(0, min(1, imagePoint.y)))
    }

    private func screenPoint(from normalizedPoint: CGPoint) -> CGPoint {
        guard streamView.imageSize != .zero else {
            let localPoint = CGPoint(x: normalizedPoint.x * streamView.bounds.width, y: normalizedPoint.y * streamView.bounds.height)
            return streamView.convert(localPoint, to: view)
        }

        let geometry = renderedImageGeometry()
        let renderedSize = geometry.size
        let origin = geometry.origin
        let localPoint = CGPoint(x: origin.x + normalizedPoint.x * renderedSize.width, y: origin.y + normalizedPoint.y * renderedSize.height)
        return streamView.convert(localPoint, to: view)
    }

    private func renderedImageGeometry() -> (origin: CGPoint, size: CGSize) {
        let rect = streamView.renderedImageRect
        return (rect.origin, rect.size)
    }

    private func updateCursorView() {
        var point = screenPoint(from: cursorPoint)
        cursorView.isHidden = !isConnected || !streamView.convert(streamView.bounds, to: view).contains(point)
        let desktopBounds = streamView.convert(streamView.bounds, to: view).insetBy(dx: 8, dy: 8)
        point.x = max(desktopBounds.minX, min(desktopBounds.maxX, point.x))
        point.y = max(desktopBounds.minY, min(desktopBounds.maxY, point.y))
        cursorView.frame = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
    }

    private func bringOverlaysToFront() {
        view.bringSubviewToFront(cursorView)
        if !keyboardView.isHidden {
            view.bringSubviewToFront(keyboardView)
        }
        if !leftKeyboardPanel.isHidden {
            view.bringSubviewToFront(leftKeyboardPanel)
        }
        if !rightKeyboardPanel.isHidden {
            view.bringSubviewToFront(rightKeyboardPanel)
        }
        if !topBar.isHidden {
            view.bringSubviewToFront(topBar)
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard isConnected, let videoClient else {
            statusLabel.text = "Not connected"
            return
        }
        videoClient.send(object)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        endMouseHold()
        sendMouse(action: "click", point: gesture.location(in: streamView))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        endMouseHold()
        sendMouse(action: "doubleClick", point: gesture.location(in: streamView))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            sendMouse(action: isMouseHeld ? "drag" : "move", point: gesture.location(in: streamView))
        }
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginTwoFingerGesture()
            isScrollTracking = true
            sendMouse(action: "move", point: gesture.location(in: streamView))
            fallthrough
        case .changed, .ended:
            defer {
                if gesture.state == .ended { isScrollTracking = false; finishTwoFingerGesture() }
            }
            guard twoFingerState.update(translation: gesture.translation(in: streamView),
                                        scale: isPinchTracking ? pinchGesture.scale : 1) == .scroll else { return }
            let translationY = gesture.translation(in: streamView).y
            let deltaY = translationY - lastScrollTranslationY
            lastScrollTranslationY = translationY

            accumulatedScrollDeltaY += deltaY
            if abs(accumulatedScrollDeltaY) >= 6 {
                sendScroll(deltaY: accumulatedScrollDeltaY)
                accumulatedScrollDeltaY = 0
            }
        default:
            isScrollTracking = false
            finishTwoFingerGesture()
        }
    }

    private func beginTwoFingerGesture() {
        if !isScrollTracking && !isPinchTracking {
            twoFingerState = TwoFingerGestureState()
            lastScrollTranslationY = 0
            accumulatedScrollDeltaY = 0
            appliedPinchScale = 1
            pinchAccumulator = 1
        }
        endMouseHold()
    }

    private func finishTwoFingerGesture() {
        if !isScrollTracking && !isPinchTracking {
            twoFingerState = TwoFingerGestureState()
            lastScrollTranslationY = 0
            accumulatedScrollDeltaY = 0
        }
    }

    @objc private func handleViewportPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { endMouseHold() }
        if gesture.state == .began || gesture.state == .changed {
            streamView.panZoom(by: gesture.translation(in: streamView))
            gesture.setTranslation(.zero, in: streamView)
            updateCursorView()
        }
    }

    @objc private func toggleShift() {
        isShifted.toggle()
        rebuildKeyboard()
    }

    @objc private func toggleTools() {
        keyboardMode = keyboardMode == .tools ? .letters : .tools
        isShifted = false
        rebuildKeyboard()
    }

    private func beginMouseHold() {
        guard isConnected, !isMouseHeld else { return }
        isMouseHeld = true
        sendMouse(action: "down", normalizedPoint: cursorPoint)
        updateHoldAppearance()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.sendJSON(["type": "hold"])
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func endMouseHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        longPressOwnsDrag = false
        guard isMouseHeld else { return }
        videoClient?.send(["type": "release"])
        isMouseHeld = false
        updateHoldAppearance()
    }

    @objc private func toggleMouseHold() {
        if isMouseHeld { endMouseHold() } else { beginMouseHold() }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !isMouseHeld, isConnected,
                  let point = normalizedScreenPoint(from: gesture.location(in: streamView)) else { return }
            cursorPoint = point
            beginMouseHold()
            longPressOwnsDrag = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updateCursorView()
        case .changed:
            if isMouseHeld { sendMouse(action: "drag", point: gesture.location(in: streamView)) }
        case .ended, .cancelled, .failed:
            if longPressOwnsDrag { endMouseHold() }
        default: break
        }
    }

    @objc private func handleContextTap(_ gesture: UITapGestureRecognizer) {
        endMouseHold()
        sendMouse(action: "rightClick", point: gesture.location(in: streamView))
    }

    @objc private func rightClickCursor() {
        endMouseHold()
        sendMouse(action: "rightClick", normalizedPoint: cursorPoint)
    }

    private func sendShortcut(_ command: String) {
        endMouseHold()
        sendInput(type: "shortcut", value: command)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else {
            isPinchTracking = false
            finishTwoFingerGesture()
            return
        }
        if gesture.state == .began {
            beginTwoFingerGesture()
            isPinchTracking = true
        }
        guard twoFingerState.update(translation: isScrollTracking ? scrollPan.translation(in: streamView) : .zero,
                                    scale: gesture.scale) == .zoom else { return }
        let factor = gesture.scale / appliedPinchScale
        appliedPinchScale = gesture.scale
        if pinchModeControl.selectedSegmentIndex == 0 {
            streamView.zoom(by: factor, around: gesture.location(in: streamView))
            updateCursorView()
        } else {
            pinchAccumulator *= factor
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAppZoomTime > 0.12 {
                if pinchAccumulator > 1.15 {
                    sendShortcut("zoomIn")
                    pinchAccumulator = 1
                    lastAppZoomTime = now
                } else if pinchAccumulator < 0.87 {
                    sendShortcut("zoomOut")
                    pinchAccumulator = 1
                    lastAppZoomTime = now
                }
            }
        }
    }

    @objc private func resetZoom() {
        streamView.resetZoom()
        if pinchModeControl.selectedSegmentIndex == 1 { sendShortcut("actualSize") }
        updateCursorView()
    }

    @objc private func insertEscape() {
        endMouseHold()
        sendInput(type: "key", value: "escape")
    }

    @objc private func toggleKeyboardMode() {
        keyboardMode = keyboardMode == .letters ? .numbers : .letters
        isShifted = false
        rebuildKeyboard()
    }

    @objc private func toggleSymbolMode() {
        keyboardMode = keyboardMode == .symbols ? .numbers : .symbols
        isShifted = false
        rebuildKeyboard()
    }

    @objc private func toggleLanguage() {
        language = language == .english ? .russian : .english
        keyboardMode = .letters
        isShifted = false
        rebuildKeyboard()
    }

    @objc private func showAddressBar() {
        endMouseHold()
        topBar.isHidden = false
        UIView.animate(withDuration: 0.22) {
            self.topBar.alpha = 1
        } completion: { _ in
            self.bringOverlaysToFront()
        }
    }

    @objc private func edgeKeysChanged() {
        UserDefaults.standard.set(edgeKeysSwitch.isOn, forKey: "edgeKeys")
        layoutLandscapeRows()
    }

    @objc private func closeSettings() {
        guard isConnected else { return }
        view.endEditing(true)
        setConnectedUI(true)
    }

    @objc private func clickCursor() {
        guard isConnected else {
            showAddressBar()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        endMouseHold()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sendMouse(action: "click", normalizedPoint: cursorPoint)
    }

    @objc private func deleteBackward() {
        sendInput(type: "key", value: "backspace")
    }

    @objc private func insertSpace() {
        sendInput(type: "text", value: " ")
    }

    @objc private func insertReturn() {
        sendInput(type: "key", value: "return")
    }

    @objc private func insertTab() {
        sendInput(type: "key", value: "tab")
    }
}

extension ViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        Set([gestureRecognizer.name ?? "", otherGestureRecognizer.name ?? ""]) == Set(["pinch", "scroll"])
    }
}
