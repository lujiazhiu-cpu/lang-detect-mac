//
// LangBarApp.swift — macOS 菜单栏常驻 · 截图识别语种 App
//
// 功能：
//   1) 常驻菜单栏（无 Dock 图标，LSUIElement），点击图标即可截图框选
//   2) 框选区域 OCR（Apple Vision，原始像素、关闭纠错、自动语种检测）
//   3) 逐块标注语种（不同语种不同颜色框 + 标签），左上角汇总各语种占比 + 是否混语
//   4) 文字太小/模糊/置信度低 → 标注「未识别」，绝不乱猜语种
//
// 覆盖语种：意 it / 葡 pt / 越 vi / 印尼 id / 日 ja / 韩 ko /
//          泰 th / 阿 ar / 德 de / 法 fr / 英 en（另可识别中文）
//
// 底层：Apple Vision（OCR，含逐块位置+置信度）+ Apple NaturalLanguage（语种判定）
//

import Foundation
import Vision
import NaturalLanguage
import AppKit
import ImageIO
import CoreGraphics   // CGPreflightScreenCaptureAccess 权限检查
import UserNotifications
import Carbon.HIToolbox   // 全局快捷键 RegisterEventHotKey

// ============================================================
// MARK: - 语种字典 / 配色
// ============================================================

let langCN: [String: String] = [
    "it": "意大利语", "pt": "葡萄牙语", "vi": "越南语", "id": "印尼语",
    "ja": "日语", "ko": "韩语", "th": "泰语", "ar": "阿拉伯语",
    "de": "德语", "fr": "法语", "en": "英语",
    "zh": "中文",
    "name": "英语（人名/地名）", "num": "数字", "und": "未识别"
]
func cnName(_ code: String) -> String { langCN[code] ?? code }

let langColor: [String: NSColor] = [
    "de": .systemBlue, "en": .systemGreen, "fr": .systemPurple,
    "it": .systemTeal, "pt": .systemOrange, "es": .systemBrown,
    "vi": .systemPink, "id": .systemIndigo, "ja": .systemRed,
    "ko": .magenta, "th": .brown, "ar": .darkGray,
    "zh": .orange,
    "name": .systemGreen, "num": .systemYellow, "und": .gray
]
func color(_ code: String) -> NSColor { langColor[code] ?? .gray }

let targetLangs: [NLLanguage] = [
    .italian, .portuguese, .vietnamese, .indonesian,
    .japanese, .korean, .thai, .arabic,
    .german, .french, .english,
    .simplifiedChinese, .traditionalChinese
]

// 置信度阈值：低于此值判为「未识别」，绝不乱猜
let OCR_CONFIDENCE_MIN: Float = 0.30       // Vision OCR 单块置信度下限
let NL_PROB_MIN: Double = 0.55             // NaturalLanguage 语种概率下限（拉丁语系）
let MIN_TEXT_HEIGHT_RATIO: CGFloat = 0.008 // 文字太小（相对整图高度）判为未识别

// ============================================================
// MARK: - 脚本归类 + 语种判定
// ============================================================

func scriptLang(for scalar: Unicode.Scalar) -> String? {
    let v = scalar.value
    switch v {
    case 0x0E00...0x0E7F: return "th"
    case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
         0xFB50...0xFDFF, 0xFE70...0xFEFF: return "ar"
    case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return "ko"
    case 0x3040...0x309F, 0x30A0...0x30FF: return "ja"
    case 0x4E00...0x9FFF, 0x3400...0x4DBF: return "han"
    default: return nil
    }
}

// 判断是否像"专有名词/缩写/编号"（人名、地名、品牌、ARS、20TH ISSUE 等）
// 规则：拉丁文本按空格分词，每个词满足以下之一即可：
//   - 首字母大写（Daniel、Sivan）
//   - 全大写（ARS、SGN、TROYE）
//   - 含数字的编号词（20TH、S2、V0）
// 全部词都满足，且至少含 1 个字母 → 判为专名
func isProperNounLike(_ text: String) -> Bool {
    let tokens = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }
        .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'()[]{}·—-")) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return false }
    var hasLetter = false
    for tok in tokens {
        let hasDigit = tok.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let letters = tok.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty { hasLetter = true }
        let firstIsUpper = tok.first.map { String($0) == String($0).uppercased() && String($0) != String($0).lowercased() } ?? false
        let allUpper = !letters.isEmpty && tok.uppercased() == tok
        // 允许：首字母大写 / 全大写 / 含数字编号（如 20TH、S2）
        if firstIsUpper || allUpper || hasDigit { continue }
        return false
    }
    return hasLetter
}

// 返回 (语种code, 是否可信)
// 分类桶：具体语种 / name(专名) / num(数字) / und(未识别)
func detectBlockLang(_ text: String) -> (String, Bool) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var scriptCount: [String: Int] = [:]
    var hasKana = false
    var latinLetters = 0
    var digitCount = 0
    for s in t.unicodeScalars {
        if let sc = scriptLang(for: s) {
            if sc == "ja" { hasKana = true }
            scriptCount[sc, default: 0] += 1
        } else if CharacterSet.letters.contains(s) {
            latinLetters += 1
        } else if CharacterSet.decimalDigits.contains(s) {
            digitCount += 1
        }
    }
    // 汉字归属
    if let han = scriptCount["han"] {
        scriptCount.removeValue(forKey: "han")
        if hasKana { scriptCount["ja", default: 0] += han }
        else { scriptCount["zh", default: 0] += han }
    }
    let nonLatinTotal = scriptCount.values.reduce(0, +)

    // ① 无字母（含非拉丁脚本）但有数字 → 数字
    if latinLetters == 0 && nonLatinTotal == 0 {
        if digitCount > 0 { return ("num", true) }
        return ("und", false)   // 纯符号
    }
    // ② 非拉丁脚本占主导 → 脚本判定高度可信
    if nonLatinTotal >= latinLetters, let top = scriptCount.max(by: { $0.value < $1.value }) {
        return (top.key, true)
    }
    // ③ 拉丁字母为主 → 先用 NaturalLanguage
    let letters = latinLetters
    if letters >= 3 {
        let r = NLLanguageRecognizer()
        r.languageConstraints = targetLangs
        r.processString(t)
        let hyp = r.languageHypotheses(withMaximum: 1)
        if let lang = r.dominantLanguage?.rawValue,
           let prob = hyp[NLLanguage(lang)], prob >= NL_PROB_MIN {
            return (lang.hasPrefix("zh") ? "zh" : lang, true)
        }
    }
    // ④ 语种判不准，但明显是专名/缩写/编号 → 标为专名（英语人名/地名），不算未识别
    if isProperNounLike(t) {
        return ("name", true)
    }
    // ⑤ 拉丁文本但太短或纯符号 → 未识别
    if letters < 2 { return ("und", false) }
    // ⑥ 仍拿不准的拉丁普通词 → 用 NL 的首选（即使概率偏低），给出"对应语种"而非未识别
    let r2 = NLLanguageRecognizer()
    r2.languageConstraints = targetLangs
    r2.processString(t)
    if let lang = r2.dominantLanguage?.rawValue {
        return (lang.hasPrefix("zh") ? "zh" : lang, true)
    }
    return ("und", false)
}

func letterCount(_ text: String) -> Int {
    return text.unicodeScalars.filter {
        CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || scriptLang(for: $0) != nil
    }.count
}

// ============================================================
// MARK: - 图像读取 / OCR / 标注
// ============================================================

func loadCGImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    if let src = CGImageSourceCreateWithURL(url, nil),
       let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { return cg }
    if let img = NSImage(contentsOfFile: path),
       let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
    return nil
}

struct Block { let text: String; let box: CGRect; let lang: String }

func ocrBlocks(_ cg: CGImage) -> [Block] {
    var blocks: [Block] = []
    let sem = DispatchSemaphore(value: 0)
    let req = VNRecognizeTextRequest { request, _ in
        if let obs = request.results as? [VNRecognizedTextObservation] {
            for o in obs {
                guard let cand = o.topCandidates(1).first else { continue }
                let s = cand.string
                if s.isEmpty { continue }
                // 判定语种可信度
                var lang: String
                let (guessed, ok) = detectBlockLang(s)
                // 三重不猜条件：OCR置信度低 / 文字太小 / 语种判定不可信
                if cand.confidence < OCR_CONFIDENCE_MIN ||
                   o.boundingBox.height < MIN_TEXT_HEIGHT_RATIO ||
                   !ok {
                    lang = "und"
                } else {
                    lang = guessed
                }
                blocks.append(Block(text: s, box: o.boundingBox, lang: lang))
            }
        }
        sem.signal()
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.minimumTextHeight = 0.0
    if #available(macOS 13.0, *) {
        req.revision = VNRecognizeTextRequestRevision3
        req.automaticallyDetectsLanguage = true
    } else {
        req.recognitionLanguages = ["en-US","fr-FR","de-DE","it-IT","pt-BR","vi-VN","id-ID","ja-JP","ko-KR","th-TH","ar-SA","zh-Hans","zh-Hant"]
    }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    sem.wait()
    return blocks
}

func annotate(_ cg: CGImage, blocks: [Block], breakdown: [(String, Int)], mixed: Bool, outPath: String) {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)

    // ---- 预先计算顶部信息条（浅色，独立于原图，不遮挡内容）----
    let total = breakdown.reduce(0) { $0 + $1.1 }
    let hFont = NSFont.boldSystemFont(ofSize: max(20, H * 0.020))
    let hAttrs: [NSAttributedString.Key: Any] = [.font: hFont, .foregroundColor: NSColor.black]
    let dotR = hFont.pointSize * 0.62
    let sidePad = max(16, W * 0.012)
    let itemGap = hFont.pointSize * 1.1
    let lineH = hFont.pointSize * 1.7

    // 组装条目：标题 + 各语种占比
    struct HItem { let text: String; let color: NSColor?; let width: CGFloat }
    var items: [HItem] = []
    let title = "语种占比" + (mixed ? "（混语）" : "")
    items.append(HItem(text: title, color: nil,
                       width: (title as NSString).size(withAttributes: hAttrs).width))
    if total > 0 {
        for (code, cnt) in breakdown {
            let pct = Int((Double(cnt) / Double(total) * 100).rounded())
            let t = "\(cnName(code)) \(pct)%"
            let tw = (t as NSString).size(withAttributes: hAttrs).width
            items.append(HItem(text: t, color: color(code), width: dotR + 6 + tw))
        }
    }
    // 计算需要几行（按图宽自动换行）
    var rows = 1
    var cursor = sidePad
    var placements: [(item: HItem, row: Int, x: CGFloat)] = []
    for it in items {
        let w = it.width
        if cursor + w > W - sidePad, cursor > sidePad {
            rows += 1; cursor = sidePad
        }
        placements.append((it, rows - 1, cursor))
        cursor += w + itemGap
    }
    let vPad: CGFloat = 12
    let headerH = CGFloat(rows) * lineH + vPad * 2
    let totalH = H + headerH

    // ---- 画布：底部放原图，顶部放信息条 ----
    let img = NSImage(size: NSSize(width: W, height: totalH))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return }
    // 原图（底部）
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    // 信息条背景（顶部，浅色，不透明但独立于原图区域）
    ctx.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1.0).cgColor)
    ctx.fill(CGRect(x: 0, y: H, width: W, height: headerH))
    // 分隔细线
    ctx.setFillColor(NSColor(calibratedWhite: 0.80, alpha: 1.0).cgColor)
    ctx.fill(CGRect(x: 0, y: H, width: W, height: max(1, H * 0.0015)))

    // 逐条目绘制（row 0 在最上面）
    for p in placements {
        let rowTopY = totalH - vPad - CGFloat(p.row) * lineH
        let textY = rowTopY - lineH + (lineH - hFont.pointSize) * 0.5
        var x = p.x
        if let c = p.item.color {
            let cy = textY + hFont.pointSize * 0.15
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: cy, width: dotR, height: dotR))
            x += dotR + 6
        }
        (p.item.text as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: hAttrs)
    }

    // ---- 逐块标注框 + 标签（画在原图区域内）----
    let fontSize = max(16, H * 0.014)
    let font = NSFont.boldSystemFont(ofSize: fontSize)
    for b in blocks {
        let rect = CGRect(x: b.box.minX * W, y: b.box.minY * H,
                          width: b.box.width * W, height: b.box.height * H)
        let c = color(b.lang)
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(max(2, H * 0.002))
        if b.lang == "und" { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
        else { ctx.setLineDash(phase: 0, lengths: []) }
        ctx.stroke(rect)
        ctx.setLineDash(phase: 0, lengths: [])

        let label = cnName(b.lang)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 4
        var lx = rect.minX
        var ly = rect.maxY + 2
        if ly + size.height + pad*2 > H { ly = rect.minY - size.height - pad*2 - 2 }
        if lx + size.width + pad*2 > W { lx = W - size.width - pad*2 }
        if lx < 0 { lx = 0 }; if ly < 0 { ly = 0 }
        let bg = CGRect(x: lx, y: ly, width: size.width + pad*2, height: size.height + pad*2)
        ctx.setFillColor(c.cgColor)
        ctx.fill(bg)
        (label as NSString).draw(at: NSPoint(x: lx + pad, y: ly + pad), withAttributes: attrs)
    }

    img.unlockFocus()
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
    }
}

// 汇总结果
struct DetectResult {
    let mainLang: String
    let mixed: Bool
    let breakdown: [(String, Int)]
    let blockCount: Int
    let textLen: Int
    let annotatedPath: String
}

func runDetect(shotPath: String, annoPath: String) -> DetectResult? {
    guard let cg = loadCGImage(shotPath) else { return nil }
    let blocks = ocrBlocks(cg)
    // 占比汇总：包含 专名/数字，排除 未识别
    var counts: [String: Int] = [:]
    for b in blocks where b.lang != "und" {
        counts[b.lang, default: 0] += letterCount(b.text)
    }
    let sorted = counts.sorted { $0.value > $1.value }
    // 主体语种 / 混语：仅按"真实语种"判断（排除 name/num/und）
    let realLangs = sorted.filter { $0.key != "name" && $0.key != "num" }
    let mainLang = realLangs.first?.key ?? (sorted.first?.key ?? "und")
    var mixed = false
    let total = realLangs.reduce(0) { $0 + $1.1 }
    if realLangs.count >= 2, total > 0 {
        let share = Double(realLangs[1].value) / Double(total)
        if share >= 0.15 && realLangs[1].value >= 3 { mixed = true }
    }
    annotate(cg, blocks: blocks, breakdown: sorted, mixed: mixed, outPath: annoPath)
    let textLen = blocks.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines).count
    return DetectResult(mainLang: mainLang, mixed: mixed, breakdown: sorted,
                        blockCount: blocks.count, textLen: textLen, annotatedPath: annoPath)
}

// ============================================================
// MARK: - 菜单栏 App
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    let shotPath = NSTemporaryDirectory() + "langbar_shot.png"
    let annoPath = NSTemporaryDirectory() + "langbar_annotated.png"

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 无 Dock 图标

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            var iconSet = false
            // 自定义菜单栏图标（取景框+A）：同时加载 1x(22) 与 @2x(44) 两个位图表示，
            // 让 AppKit 在 Retina 屏自动用 44px 高清位图，避免发糊
            if let resDir = Bundle.main.resourcePath {
                let img = NSImage(size: NSSize(width: 22, height: 22))
                var added = false
                for name in ["menubar_icon.png", "menubar_icon@2x.png"] {
                    if let d = try? Data(contentsOf: URL(fileURLWithPath: resDir + "/" + name)),
                       let rep = NSBitmapImageRep(data: d) {
                        rep.size = NSSize(width: 22, height: 22)  // 两个位图都声明为 22pt，像素差(22/44)=密度
                        img.addRepresentation(rep)
                        added = true
                    }
                }
                if added {
                    img.isTemplate = true   // 模板模式：随菜单栏明暗自动上色（形状来自 alpha）
                    btn.image = img
                    iconSet = true
                }
            }
            if !iconSet {
                if let img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "语种识别") {
                    img.isTemplate = true
                    btn.image = img
                } else {
                    btn.title = "文A"
                }
            }
            btn.toolTip = "截图识别语种（⌃⌥L）"
        }

        let menu = NSMenu()
        // 菜单里展示全局快捷键提示（⌃⌥L），实际由下面的 RegisterEventHotKey 全局注册
        let capItem = NSMenuItem(title: "📸 截图识别语种", action: #selector(capture), keyEquivalent: "l")
        capItem.keyEquivalentModifierMask = [.control, .option]
        capItem.target = self
        menu.addItem(capItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "打开上次标注图", action: #selector(openLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关于 / 使用说明", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        registerGlobalHotKey()
    }

    // 注册全局快捷键 ⌃⌥L（Control+Option+L），不与浏览器 ⌘D 冲突，且全系统任意 App 前台都能触发
    func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4c414e47) /* 'LANG' */, id: 1)
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.capture() }
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
        // kVK_ANSI_L = 37；controlKey | optionKey 为 Carbon 修饰键掩码
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func capture() {
        // 先检查屏幕录制权限：未授权则用我们自己的弹窗，直接跳「屏幕录制」设置页
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()   // 触发系统登记本 App 到列表
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "截图识别需要屏幕录制权限。\n请在弹出的设置页勾选「语种识别」，然后重新点击识别即可。"
            alert.addButton(withTitle: "打开屏幕录制设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                openScreenRecordingSettings()
            }
            return
        }
        // 关掉菜单，交互式框选截图
        try? FileManager.default.removeItem(atPath: shotPath)
        try? FileManager.default.removeItem(atPath: annoPath)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-i", shotPath]   // -x 静音；-i 交互框选（系统原生，无自绘覆盖层）
        do { try task.run(); task.waitUntilExit() }
        catch { showDialog(title: "语种识别", msg: "无法启动截图：\(error.localizedDescription)"); return }

        guard FileManager.default.fileExists(atPath: shotPath) else { return }  // 用户取消

        // 异步做 OCR，避免卡 UI
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runDetect(shotPath: self.shotPath, annoPath: self.annoPath)
            DispatchQueue.main.async {
                guard let r = result else {
                    self.showDialog(title: "语种识别", msg: "读取截图失败，请重试。")
                    return
                }
                if r.textLen < 2 {
                    self.showDialog(title: "语种识别 · 需要重试",
                                    msg: "⚠️ 几乎没识别到文字。\n请框住清晰的文字区域，或把图放大后再框。")
                    return
                }
                // 打开标注图
                if FileManager.default.fileExists(atPath: r.annotatedPath) {
                    self.openInPreview(r.annotatedPath)
                }
                // 汇总弹窗
                let total = r.breakdown.reduce(0) { $0 + $1.1 }
                var lines: [String] = []
                for (code, cnt) in r.breakdown {
                    let pct = total > 0 ? Int((Double(cnt) / Double(total) * 100).rounded()) : 0
                    lines.append("\(cnName(code))  \(pct)%")
                }
                let breakStr = lines.isEmpty ? "（无可信语种）" : lines.joined(separator: "\n")
                let msg = """
                主体语种：\(cnName(r.mainLang))
                是否混语：\(r.mixed ? "是" : "否")
                文本块数：\(r.blockCount)

                各语种占比：
                \(breakStr)

                （标注图已用「预览」打开，每块文字旁标了语种；专名=人名/地名，数字=纯数字，虚线灰框=未识别）
                """
                self.showDialog(title: "语种识别结果", msg: msg)
            }
        }
    }

    @objc func openLast() {
        if FileManager.default.fileExists(atPath: annoPath) {
            openInPreview(annoPath)
        } else {
            showDialog(title: "语种识别", msg: "还没有识别记录，先点「截图识别语种」吧。")
        }
    }

    @objc func about() {
        showDialog(title: "语种识别 · 使用说明", msg: """
        触发方式：点菜单栏图标 →「截图识别语种」，或按全局快捷键 ⌃⌥L（Control+Option+L）。
        框选屏幕上带文字的区域即可。

        • 覆盖语种：意/葡/越/印尼/日/韩/泰/阿/德/法/英（另可识别中文）
        • 每块文字旁标注语种，不同语种不同颜色
        • 人名/地名/品牌/缩写（如 TROYE SIVAN、ARS）→ 标「英语（人名/地名）」
        • 纯数字（如 2024）→ 标「数字」
        • 左上角显示各语种占比 + 是否混语
        • 仅当文字太小/模糊/OCR 不确定时才标「未识别」（虚线灰框），不会乱猜

        首次使用需在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选本 App。
        """)
    }

    @objc func quit() { NSApp.terminate(nil) }

    // 直接跳转到「系统设置 → 隐私与安全性 → 屏幕录制」页（而不是通用页）
    func openScreenRecordingSettings() {
        let urlStr = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    // 用「预览」独立窗口打开标注图（每次新开一份，不叠加到屏幕/网页上）
    func openInPreview(_ path: String) {
        // 每次复制成带时间戳的新文件，保证「预览」弹出的是一张独立静态图片窗口
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = NSTemporaryDirectory() + "语种标注_\(stamp).png"
        try? FileManager.default.removeItem(atPath: dst)
        try? FileManager.default.copyItem(atPath: path, toPath: dst)
        let target = FileManager.default.fileExists(atPath: dst) ? dst : path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Preview", target]   // 强制用「预览」打开为独立窗口
        do { try task.run() }
        catch { NSWorkspace.shared.open(URL(fileURLWithPath: target)) }
    }

    func showDialog(title: String, msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
