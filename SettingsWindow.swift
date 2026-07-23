//
// SettingsWindow.swift — 设置窗口（AppKit 原生）
//
// 提供：语种开关配置、OCR/NL 置信度阈值、文字最小高度、是否自动打开预览、恢复默认。
// 所有改动即时写入 Settings.shared（UserDefaults），下次识别立即生效。
//

import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var confSlider: NSSlider!
    private var confValue: NSTextField!
    private var probSlider: NSSlider!
    private var probValue: NSTextField!
    private var heightSlider: NSSlider!
    private var heightValue: NSTextField!
    private var autoOpenCheck: NSButton!
    private var langChecks: [(code: String, button: NSButton)] = []

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "语种识别 · 设置"
        self.init(window: win)
        win.delegate = self
        buildUI()
    }

    func show() {
        syncFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI 构建

    private func sectionTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 14)
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])

        // —— 语种配置 ——
        root.addArrangedSubview(sectionTitle("识别语种（勾选启用）"))
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 20
        var rowCells: [NSView] = []
        for code in allLangCodes {
            let cb = NSButton(checkboxWithTitle: cnName(code), target: self, action: #selector(langToggled))
            cb.identifier = NSUserInterfaceItemIdentifier(code)
            langChecks.append((code, cb))
            rowCells.append(cb)
            if rowCells.count == 3 {
                grid.addRow(with: rowCells)
                rowCells = []
            }
        }
        if !rowCells.isEmpty {
            while rowCells.count < 3 { rowCells.append(NSGridCell.emptyContentView) }
            grid.addRow(with: rowCells)
        }
        root.addArrangedSubview(grid)

        let langBtns = NSStackView()
        langBtns.orientation = .horizontal
        langBtns.spacing = 10
        let selAll = NSButton(title: "全选", target: self, action: #selector(selectAllLangs))
        let selNone = NSButton(title: "全不选", target: self, action: #selector(selectNoneLangs))
        langBtns.addArrangedSubview(selAll)
        langBtns.addArrangedSubview(selNone)
        root.addArrangedSubview(langBtns)

        root.addArrangedSubview(makeSeparator())

        // —— 阈值配置 ——
        root.addArrangedSubview(sectionTitle("识别阈值"))

        let (cRow, cSlider, cValue) = makeSliderRow(
            "OCR 置信度下限", min: 0.0, max: 1.0, action: #selector(confChanged))
        confSlider = cSlider; confValue = cValue
        root.addArrangedSubview(cRow)
        root.addArrangedSubview(hint("低于此置信度的文字块标为「未识别」，越高越严格"))

        let (pRow, pSlider, pValue) = makeSliderRow(
            "语种概率下限", min: 0.0, max: 1.0, action: #selector(probChanged))
        probSlider = pSlider; probValue = pValue
        root.addArrangedSubview(pRow)
        root.addArrangedSubview(hint("拉丁语系语种判定的最小概率，越高越保守"))

        let (hRow, hSlider, hValue) = makeSliderRow(
            "文字最小高度占比", min: 0.001, max: 0.05, action: #selector(heightChanged))
        heightSlider = hSlider; heightValue = hValue
        root.addArrangedSubview(hRow)
        root.addArrangedSubview(hint("文字高度低于整图此比例时标为「未识别」"))

        root.addArrangedSubview(makeSeparator())

        // —— 行为 ——
        root.addArrangedSubview(sectionTitle("行为"))
        autoOpenCheck = NSButton(checkboxWithTitle: "识别后自动用「预览」打开标注图",
                                 target: self, action: #selector(autoOpenToggled))
        root.addArrangedSubview(autoOpenCheck)

        root.addArrangedSubview(makeSeparator())

        // —— 底部按钮 ——
        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 12
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        let done = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        bottom.addArrangedSubview(reset)
        bottom.addArrangedSubview(done)
        root.addArrangedSubview(bottom)
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 432).isActive = true
        return box
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func makeSliderRow(_ title: String, min: Double, max: Double, action: Selector)
        -> (NSView, NSSlider, NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: action)
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = NSTextField(labelWithString: "—")
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 52).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return (row, slider, value)
    }

    // MARK: - 同步

    private func syncFromSettings() {
        let s = Settings.shared
        for (code, btn) in langChecks { btn.state = s.isEnabled(code) ? .on : .off }
        confSlider.doubleValue = Double(s.ocrConfidenceMin)
        probSlider.doubleValue = s.nlProbMin
        heightSlider.doubleValue = Double(s.minTextHeightRatio)
        autoOpenCheck.state = s.autoOpenPreview ? .on : .off
        refreshValueLabels()
    }

    private func refreshValueLabels() {
        confValue.stringValue = String(format: "%.2f", confSlider.doubleValue)
        probValue.stringValue = String(format: "%.2f", probSlider.doubleValue)
        heightValue.stringValue = String(format: "%.3f", heightSlider.doubleValue)
    }

    // MARK: - 动作

    @objc private func langToggled(_ sender: NSButton) {
        var enabled = langChecks.filter { $0.button.state == .on }.map { $0.code }
        if enabled.isEmpty { enabled = ["en"] } // 至少保留一种，避免无约束
        Settings.shared.enabledLangs = enabled
    }

    @objc private func selectAllLangs() {
        for (_, btn) in langChecks { btn.state = .on }
        Settings.shared.enabledLangs = allLangCodes
    }

    @objc private func selectNoneLangs() {
        for (_, btn) in langChecks { btn.state = .off }
        Settings.shared.enabledLangs = ["en"]
        // 保底把 en 勾上
        if let en = langChecks.first(where: { $0.code == "en" }) { en.button.state = .on }
    }

    @objc private func confChanged() {
        Settings.shared.ocrConfidenceMin = Float(confSlider.doubleValue)
        refreshValueLabels()
    }

    @objc private func probChanged() {
        Settings.shared.nlProbMin = probSlider.doubleValue
        refreshValueLabels()
    }

    @objc private func heightChanged() {
        Settings.shared.minTextHeightRatio = CGFloat(heightSlider.doubleValue)
        refreshValueLabels()
    }

    @objc private func autoOpenToggled() {
        Settings.shared.autoOpenPreview = (autoOpenCheck.state == .on)
    }

    @objc private func resetDefaults() {
        Settings.shared.resetToDefaults()
        syncFromSettings()
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
