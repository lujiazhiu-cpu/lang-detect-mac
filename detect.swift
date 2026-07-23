#!/usr/bin/env swift
//
// detect.swift — 截图/图片 语种识别 + 可视化标注（离线）
// 底层：Apple Vision（OCR，含逐块位置）+ Apple NaturalLanguage（语种判定）
// 用法：swift detect.swift <输入图> <标注输出图>
// 输出：
//   - 在 <标注输出图> 上，为每块文字画框并标注语种
//   - stdout 打印一行 JSON：{ main, mixed, breakdown, blocks, text }
//
// 覆盖语种：意 it / 葡 pt / 越 vi / 印尼 id / 日 ja / 韩 ko /
//          泰 th / 阿 ar / 德 de / 法 fr / 英 en（另可识别中文）
//

import Foundation
import Vision
import NaturalLanguage
import AppKit
import ImageIO

// ---- 语种中文名 ----
let langCN: [String: String] = [
    "it": "意大利语", "pt": "葡萄牙语", "vi": "越南语", "id": "印尼语",
    "ja": "日语", "ko": "韩语", "th": "泰语", "ar": "阿拉伯语",
    "de": "德语", "fr": "法语", "en": "英语",
    "zh": "中文", "und": "未知"
]
func cnName(_ code: String) -> String { langCN[code] ?? code }

// ---- 语种配色（标注框/标签用）----
let langColor: [String: NSColor] = [
    "de": .systemBlue, "en": .systemGreen, "fr": .systemPurple,
    "it": .systemTeal, "pt": .systemOrange, "es": .systemBrown,
    "vi": .systemPink, "id": .systemIndigo, "ja": .systemRed,
    "ko": .magenta, "th": .brown, "ar": .darkGray,
    "zh": .orange, "und": .gray
]
func color(_ code: String) -> NSColor { langColor[code] ?? .gray }

let targetLangs: [NLLanguage] = [
    .italian, .portuguese, .vietnamese, .indonesian,
    .japanese, .korean, .thai, .arabic,
    .german, .french, .english,
    .simplifiedChinese, .traditionalChinese
]

// ---- 按 Unicode 脚本给单个字符归类（硬语种）----
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

// ---- 判定一“块”文字的语种（优先脚本，其次 NL）----
func detectBlockLang(_ text: String) -> String {
    var scriptCount: [String: Int] = [:]
    var hasKana = false
    var latinLetters = 0
    for s in text.unicodeScalars {
        if let sc = scriptLang(for: s) {
            if sc == "ja" { hasKana = true }
            scriptCount[sc, default: 0] += 1
        } else if CharacterSet.letters.contains(s) {
            latinLetters += 1
        }
    }
    // 汉字归属
    if let han = scriptCount["han"] {
        scriptCount.removeValue(forKey: "han")
        if hasKana { scriptCount["ja", default: 0] += han }
        else { scriptCount["zh", default: 0] += han }
    }
    let nonLatinTotal = scriptCount.values.reduce(0, +)
    // 若非拉丁脚本占主导，直接返回其中最多者
    if nonLatinTotal >= latinLetters, let top = scriptCount.max(by: { $0.value < $1.value }) {
        return top.key
    }
    // 拉丁字母为主 → 用 NL
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return "und" }
    let r = NLLanguageRecognizer()
    r.languageConstraints = targetLangs
    r.processString(t)
    if let lang = r.dominantLanguage?.rawValue {
        return lang.hasPrefix("zh") ? "zh" : lang
    }
    return "und"
}

func letterCount(_ text: String) -> Int {
    return text.unicodeScalars.filter { CharacterSet.letters.contains($0) || scriptLang(for: $0) != nil }.count
}

// ---- 读原始像素图 ----
func loadCGImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    if let src = CGImageSourceCreateWithURL(url, nil),
       let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { return cg }
    if let img = NSImage(contentsOfFile: path),
       let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
    return nil
}

// ---- OCR，返回每块文字 + 归一化 boundingBox ----
struct Block { let text: String; let box: CGRect; let lang: String }

func ocrBlocks(_ cg: CGImage) -> [Block] {
    var blocks: [Block] = []
    let sem = DispatchSemaphore(value: 0)
    let req = VNRecognizeTextRequest { request, err in
        if let e = err { FileHandle.standardError.write("[debug] OCR错误: \(e)\n".data(using: .utf8)!) }
        if let obs = request.results as? [VNRecognizedTextObservation] {
            for o in obs {
                guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { continue }
                blocks.append(Block(text: s, box: o.boundingBox, lang: detectBlockLang(s)))
            }
            FileHandle.standardError.write("[debug] 识别到 \(obs.count) 块文本\n".data(using: .utf8)!)
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

// ---- 在图上绘制标注 ----
func annotate(_ cg: CGImage, blocks: [Block], breakdown: [(String, Int)], mixed: Bool, outPath: String) {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

    let fontSize = max(16, H * 0.014)
    let font = NSFont.boldSystemFont(ofSize: fontSize)

    for b in blocks {
        let rect = CGRect(x: b.box.minX * W, y: b.box.minY * H,
                          width: b.box.width * W, height: b.box.height * H)
        let c = color(b.lang)
        // 画框
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(max(2, H * 0.002))
        ctx.stroke(rect)
        // 画标签背景 + 文字（放在框上方）
        let label = cnName(b.lang)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white
        ]
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

    // ---- 顶部汇总面板 ----
    let total = breakdown.reduce(0) { $0 + $1.1 }
    if total > 0 {
        var lines: [String] = ["语种占比" + (mixed ? "（混语）" : "")]
        for (code, cnt) in breakdown {
            let pct = Int((Double(cnt) / Double(total) * 100).rounded())
            lines.append("\(cnName(code))  \(pct)%")
        }
        let panelFont = NSFont.boldSystemFont(ofSize: max(18, H * 0.016))
        let attrs: [NSAttributedString.Key: Any] = [.font: panelFont, .foregroundColor: NSColor.white]
        var maxW: CGFloat = 0; var totalH: CGFloat = 0
        let sizes = lines.map { (l: String) -> NSSize in
            let s = (l as NSString).size(withAttributes: attrs)
            maxW = max(maxW, s.width); totalH += s.height + 4
            return s
        }
        let pad: CGFloat = 10
        let panel = CGRect(x: 10, y: H - totalH - pad*2 - 10,
                           width: maxW + pad*2, height: totalH + pad*2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fill(panel)
        var y = panel.maxY - pad
        for (i, l) in lines.enumerated() {
            y -= sizes[i].height + 4
            (l as NSString).draw(at: NSPoint(x: panel.minX + pad, y: y), withAttributes: attrs)
        }
    }

    img.unlockFocus()
    // 存 PNG
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
    }
}

// ---- main ----
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: swift detect.swift <输入图> <标注输出图>\n".data(using: .utf8)!)
    exit(2)
}
let inPath = args[1], outPath = args[2]
guard let cg = loadCGImage(inPath) else {
    print("{\"main\":\"未知\",\"mixed\":false,\"breakdown\":[],\"blocks\":0,\"text\":\"\"}")
    exit(0)
}
FileHandle.standardError.write("[debug] 图片像素: \(cg.width)x\(cg.height)\n".data(using: .utf8)!)

let blocks = ocrBlocks(cg)

// 汇总各语种字符占比
var counts: [String: Int] = [:]
for b in blocks where b.lang != "und" {
    counts[b.lang, default: 0] += letterCount(b.text)
}
let sorted = counts.sorted { $0.value > $1.value }
let mainLang = sorted.first?.key ?? "und"
var mixed = false
let total = sorted.reduce(0) { $0 + $1.1 }
if sorted.count >= 2, total > 0 {
    let share = Double(sorted[1].value) / Double(total)
    if share >= 0.15 && sorted[1].value >= 3 { mixed = true }
}

// 画标注图
annotate(cg, blocks: blocks, breakdown: sorted, mixed: mixed, outPath: outPath)

// 输出 JSON
func jsonEscape(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""; case "\\": out += "\\\\"
        case "\n": out += "\\n"; case "\r": out += "\\r"; case "\t": out += "\\t"
        default: out.unicodeScalars.append(c)
        }
    }
    return out
}
let breakdownJSON = sorted.map { "{\"lang\":\"\(cnName($0.0))\",\"count\":\($0.1)}" }.joined(separator: ",")
let allText = blocks.map { $0.text }.joined(separator: " | ")
print("{\"main\":\"\(cnName(mainLang))\",\"mixed\":\(mixed),\"breakdown\":[\(breakdownJSON)],\"blocks\":\(blocks.count),\"text\":\"\(jsonEscape(allText))\"}")
