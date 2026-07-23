//
// HistoryWindow.swift — 历史记录窗口（AppKit 原生）
//
// 左侧 NSTableView 列出历次识别记录（时间/主体语种/是否混语/块数），
// 右侧展示选中记录的标注图与各语种占比；支持「打开标注图」「清空历史」。
//

import AppKit

final class HistoryWindowController: NSWindowController, NSWindowDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {
    static let shared = HistoryWindowController()

    private var table: NSTableView!
    private var imageView: NSImageView!
    private var detailLabel: NSTextField!
    private var emptyLabel: NSTextField!

    private var entries: [HistoryEntry] = []

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "语种识别 · 历史记录"
        self.init(window: win)
        win.delegate = self
        win.minSize = NSSize(width: 360, height: 240)
        buildUI()
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // 左侧表格
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelectedImage)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.title = "识别记录"
        col.width = 260
        table.addTableColumn(col)
        table.headerView = nil
        scroll.documentView = table
        content.addSubview(scroll)

        // 右侧详情：文字说明 + 标注图预览
        // 直接把控件加到 content 并用约束框定四边，避免图片以原始像素尺寸撑破窗口
        detailLabel = NSTextField(labelWithString: "从左侧选择一条记录查看详情")
        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        // 允许在窗口变窄时被压缩换行，而不是把窗口撑宽
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(detailLabel)

        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // 关键：让图片视图不以原图尺寸驱动布局，而是被窗口/约束框定后自适应缩放
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        content.addSubview(imageView)

        // 底部工具条
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let openBtn = NSButton(title: "打开标注图", target: self, action: #selector(openSelectedImage))
        let clearBtn = NSButton(title: "清空历史", target: self, action: #selector(clearHistory))
        toolbar.addArrangedSubview(openBtn)
        toolbar.addArrangedSubview(clearBtn)
        content.addSubview(toolbar)

        // 空状态提示
        emptyLabel = NSTextField(labelWithString: "暂无识别记录，先截图识别一次吧～")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.widthAnchor.constraint(equalToConstant: 280),
            scroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -10),

            detailLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            imageView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -10),

            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    private func reload() {
        entries = HistoryStore.shared.entries
        table.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        if !entries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            detailLabel.stringValue = "从左侧选择一条记录查看详情"
            imageView.image = nil
        }
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = id
                tf.lineBreakMode = .byTruncatingTail
                tf.maximumNumberOfLines = 2
                return tf
            }()
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        let mixed = e.mixed ? " · 混语" : ""
        cell.stringValue = "\(df.string(from: e.date))\n主体：\(cnName(e.mainLang))\(mixed) · \(e.blockCount) 块"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        let e = entries[row]

        let total = e.breakdown.values.reduce(0, +)
        let sorted = e.breakdown.sorted { $0.value > $1.value }
        var lines: [String] = []
        for (code, cnt) in sorted {
            let pct = total > 0 ? Int((Double(cnt) / Double(total) * 100).rounded()) : 0
            lines.append("\(cnName(code)) \(pct)%")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        detailLabel.stringValue = """
        时间：\(df.string(from: e.date))
        主体语种：\(cnName(e.mainLang))　是否混语：\(e.mixed ? "是" : "否")　文本块数：\(e.blockCount)
        各语种占比：\(lines.isEmpty ? "（无）" : lines.joined(separator: "  "))
        """
        imageView.image = NSImage(contentsOfFile: e.imagePath)
    }

    // MARK: - 动作

    @objc private func openSelectedImage() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        let path = entries[row].imagePath
        guard FileManager.default.fileExists(atPath: path) else {
            NSSound.beep(); return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空历史记录？"
        alert.informativeText = "将删除全部识别记录及其标注图快照，此操作不可撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clear()
            reload()
        }
    }
}
