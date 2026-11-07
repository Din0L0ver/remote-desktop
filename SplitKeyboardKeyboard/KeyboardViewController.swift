import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum Language: CaseIterable {
        case english
        case russian

        var switchTitle: String {
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

    private let keyboardView = UIView()
    private var heightConstraint: NSLayoutConstraint?
    private var currentLanguage: Language = .english
    private var isShifted = false
    private var lastLayoutSize: CGSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(red: 207 / 255, green: 211 / 255, blue: 217 / 255, alpha: 1)
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)

        heightConstraint = view.heightAnchor.constraint(equalToConstant: preferredHeight(for: view.bounds.size))
        heightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        rebuildKeyboard()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = view.bounds.size
        if abs(size.width - lastLayoutSize.width) > 1 || abs(size.height - lastLayoutSize.height) > 1 {
            lastLayoutSize = size
            heightConstraint?.constant = preferredHeight(for: size)
            rebuildKeyboard()
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        updateKeyAppearance()
    }

    private var isLandscape: Bool {
        view.bounds.width > view.bounds.height && view.bounds.width > 520
    }

    private func preferredHeight(for size: CGSize) -> CGFloat {
        size.width > size.height && size.width > 520 ? 194 : 258
    }

    private func rebuildKeyboard() {
        keyboardView.subviews.forEach { $0.removeFromSuperview() }

        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 8
        outer.distribution = .fillEqually
        outer.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(outer)

        let sideInset: CGFloat = isLandscape ? 8 : 4
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: sideInset),
            outer.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -sideInset),
            outer.topAnchor.constraint(equalTo: keyboardView.topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: keyboardView.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])

        for (index, row) in currentLanguage.rows.enumerated() {
            outer.addArrangedSubview(isLandscape ? splitLetterRow(row, rowIndex: index) : normalLetterRow(row, rowIndex: index))
        }

        outer.addArrangedSubview(controlRow())
        updateKeyAppearance()
    }

    private func normalLetterRow(_ letters: [String], rowIndex: Int) -> UIView {
        let container = UIView()
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let horizontalInset: CGFloat
        switch rowIndex {
        case 1: horizontalInset = 18
        case 2: horizontalInset = 46
        default: horizontalInset = 0
        }

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalInset),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if rowIndex == 2 {
            row.addArrangedSubview(specialKey(title: "shift", action: #selector(toggleShift), widthWeight: 1.35))
        }

        letters.forEach { row.addArrangedSubview(letterKey($0)) }

        if rowIndex == 2 {
            row.addArrangedSubview(specialKey(title: "delete", action: #selector(deleteBackward), widthWeight: 1.35))
        }

        return container
    }

    private func splitLetterRow(_ letters: [String], rowIndex: Int) -> UIView {
        let container = UIView()
        let left = UIStackView()
        let right = UIStackView()
        [left, right].forEach {
            $0.axis = .horizontal
            $0.spacing = 5
            $0.distribution = .fillEqually
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        let splitIndex = Int(ceil(Double(letters.count) / 2.0))
        let leftLetters = Array(letters.prefix(splitIndex))
        let rightLetters = Array(letters.suffix(letters.count - splitIndex))

        if rowIndex == 2 {
            left.addArrangedSubview(specialKey(title: "shift", action: #selector(toggleShift), widthWeight: 1.25))
        }

        leftLetters.forEach { left.addArrangedSubview(letterKey($0)) }
        rightLetters.forEach { right.addArrangedSubview(letterKey($0)) }

        if rowIndex == 2 {
            right.addArrangedSubview(specialKey(title: "delete", action: #selector(deleteBackward), widthWeight: 1.25))
        }

        let gap = max(view.bounds.width * 0.18, 118)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: container.centerXAnchor, constant: -(gap / 2)),

            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: container.topAnchor),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: container.centerXAnchor, constant: gap / 2),
            left.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])

        return container
    }

    private func controlRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fill

        let language = specialKey(title: currentLanguage.switchTitle, action: #selector(toggleLanguage), widthWeight: 1)
        let globe = specialKey(title: "🌐", action: #selector(advanceToNextInputMode), widthWeight: 1)
        let space = specialKey(title: "space", action: #selector(insertSpace), widthWeight: isLandscape ? 3.5 : 5)
        let returnKey = specialKey(title: "return", action: #selector(insertReturn), widthWeight: 1.6)

        [language, globe, space, returnKey].forEach { row.addArrangedSubview($0) }

        if isLandscape {
            let leftSpacer = UIView()
            let rightSpacer = UIView()
            row.insertArrangedSubview(leftSpacer, at: 2)
            row.insertArrangedSubview(rightSpacer, at: 4)
            leftSpacer.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.11).isActive = true
            rightSpacer.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.11).isActive = true
        }

        return row
    }

    private func letterKey(_ value: String) -> UIButton {
        let title = isShifted ? value.uppercased() : value
        let button = keyButton(title: title, background: .white)
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(title)
            self?.isShifted = false
            self?.rebuildKeyboard()
        }, for: .touchUpInside)
        return button
    }

    private func specialKey(title: String, action: Selector, widthWeight: CGFloat) -> UIButton {
        let button = keyButton(title: title, background: UIColor(red: 172 / 255, green: 179 / 255, blue: 189 / 255, alpha: 1))
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38 * widthWeight).isActive = true
        return button
    }

    private func keyButton(title: String, background: UIColor) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = displayTitle(title)
        config.baseBackgroundColor = background
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)

        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.22
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.clipsToBounds = false
        return button
    }

    private func displayTitle(_ title: String) -> String {
        switch title {
        case "shift": return isShifted ? "⇧" : "⇧"
        case "delete": return "⌫"
        case "space": return "space"
        case "return": return "return"
        default: return title
        }
    }

    private func updateKeyAppearance() {
        keyboardView.subviews.forEach { $0.setNeedsLayout() }
    }

    @objc private func toggleShift() {
        isShifted.toggle()
        rebuildKeyboard()
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertReturn() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func toggleLanguage() {
        currentLanguage = currentLanguage == .english ? .russian : .english
        isShifted = false
        rebuildKeyboard()
    }
}
