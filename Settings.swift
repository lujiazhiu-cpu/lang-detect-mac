//
// Settings.swift — 全局设置存储（语种开关 / 置信度阈值 / 行为选项）
//
// 说明：把原本硬编码在 LangBarApp.swift 里的阈值与目标语种，抽成可在「设置窗口」
//      里配置、并持久化到 UserDefaults 的运行期设置。
//

import Foundation
import NaturalLanguage
import CoreGraphics
import AppKit
import Carbon.HIToolbox   // 快捷键虚拟键码 / Carbon 修饰键掩码

// 快捷键变更通知：设置窗口改完快捷键后 post，AppDelegate 收到即重新注册全局热键
extension Notification.Name {
    static let hotKeyChanged = Notification.Name("langbar.hotKeyChanged")
}

// 默认快捷键：⌃⌥L（Control+Option+L）
let defaultHotKeyCode: UInt32 = UInt32(kVK_ANSI_L)                     // 37
let defaultHotKeyModifiers: UInt32 = UInt32(controlKey | optionKey)

// Cocoa 修饰键 → Carbon 修饰键掩码
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var c: UInt32 = 0
    if flags.contains(.control) { c |= UInt32(controlKey) }
    if flags.contains(.option)  { c |= UInt32(optionKey) }
    if flags.contains(.shift)   { c |= UInt32(shiftKey) }
    if flags.contains(.command) { c |= UInt32(cmdKey) }
    return c
}

// Carbon 修饰键掩码 → Cocoa 修饰键（用于菜单项 keyEquivalentModifierMask）
func cocoaModifiers(fromCarbon c: UInt32) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if c & UInt32(controlKey) != 0 { f.insert(.control) }
    if c & UInt32(optionKey)  != 0 { f.insert(.option) }
    if c & UInt32(shiftKey)   != 0 { f.insert(.shift) }
    if c & UInt32(cmdKey)     != 0 { f.insert(.command) }
    return f
}

// Carbon 修饰键掩码 → 符号串（按 ⌃⌥⇧⌘ 习惯顺序）
func modifierSymbols(carbon c: UInt32) -> String {
    var s = ""
    if c & UInt32(controlKey) != 0 { s += "⌃" }
    if c & UInt32(optionKey)  != 0 { s += "⌥" }
    if c & UInt32(shiftKey)   != 0 { s += "⇧" }
    if c & UInt32(cmdKey)     != 0 { s += "⌘" }
    return s
}

// 虚拟键码 → 展示名（覆盖常用字母/数字/符号/功能键）
let keyCodeNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
    27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
    36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
    100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
]

// 虚拟键码 → 供菜单 keyEquivalent 使用的字符（找不到返回空串）
func menuKeyEquivalent(for code: UInt32) -> String {
    guard let name = keyCodeNames[code], name.count == 1 else { return "" }
    // 仅对普通可打印单字符生效，符号如 ↩/⇥ 不作为菜单快捷键
    let disallowed: Set<String> = ["↩", "⇥", "⌫", "⎋", "←", "→", "↓", "↑"]
    if disallowed.contains(name) { return "" }
    return name.lowercased()
}

// 全部可配置语种（与 langCN / langColor 对应；zh 单独包含简繁）
let allLangCodes = ["it", "pt", "vi", "id", "ja", "ko", "th", "ar", "de", "fr", "en", "zh"]

// 语种 code -> NaturalLanguage 约束
let codeToNLLanguage: [String: NLLanguage] = [
    "it": .italian, "pt": .portuguese, "vi": .vietnamese, "id": .indonesian,
    "ja": .japanese, "ko": .korean, "th": .thai, "ar": .arabic,
    "de": .german, "fr": .french, "en": .english,
    "zh": .simplifiedChinese
]

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum K {
        static let ocrConf = "ocrConfidenceMin"
        static let nlProb = "nlProbMin"
        static let minHeight = "minTextHeightRatio"
        static let enabledLangs = "enabledLangs"
        static let autoOpenPreview = "autoOpenPreview"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
    }

    private init() {
        d.register(defaults: [
            K.ocrConf: 0.30,
            K.nlProb: 0.55,
            K.minHeight: 0.008,
            K.enabledLangs: allLangCodes,
            K.autoOpenPreview: true,
            K.hotKeyCode: Int(defaultHotKeyCode),
            K.hotKeyModifiers: Int(defaultHotKeyModifiers)
        ])
    }

    // OCR 单块置信度下限（低于判为未识别）
    var ocrConfidenceMin: Float {
        get { Float(d.double(forKey: K.ocrConf)) }
        set { d.set(Double(newValue), forKey: K.ocrConf) }
    }

    // NaturalLanguage 语种概率下限（拉丁语系）
    var nlProbMin: Double {
        get { d.double(forKey: K.nlProb) }
        set { d.set(newValue, forKey: K.nlProb) }
    }

    // 文字最小高度占比（低于判为未识别）
    var minTextHeightRatio: CGFloat {
        get { CGFloat(d.double(forKey: K.minHeight)) }
        set { d.set(Double(newValue), forKey: K.minHeight) }
    }

    // 识别完成后是否自动用「预览」打开标注图
    var autoOpenPreview: Bool {
        get { d.bool(forKey: K.autoOpenPreview) }
        set { d.set(newValue, forKey: K.autoOpenPreview) }
    }

    // 已启用语种（用户可在设置里勾选）
    var enabledLangs: [String] {
        get { (d.array(forKey: K.enabledLangs) as? [String]) ?? allLangCodes }
        set { d.set(newValue, forKey: K.enabledLangs) }
    }

    func isEnabled(_ code: String) -> Bool { enabledLangs.contains(code) }

    // 触发截图识别的全局快捷键（虚拟键码 + Carbon 修饰键掩码）
    var hotKeyCode: UInt32 {
        get { UInt32(d.integer(forKey: K.hotKeyCode)) }
        set { d.set(Int(newValue), forKey: K.hotKeyCode) }
    }
    var hotKeyModifiers: UInt32 {
        get { UInt32(d.integer(forKey: K.hotKeyModifiers)) }
        set { d.set(Int(newValue), forKey: K.hotKeyModifiers) }
    }
    // 快捷键展示串，如「⌃⌥L」
    var hotKeyDisplayString: String {
        let mods = modifierSymbols(carbon: hotKeyModifiers)
        let key = keyCodeNames[hotKeyCode] ?? "Key\(hotKeyCode)"
        return mods + key
    }

    // 供 NaturalLanguage 使用的目标语种约束（跟随用户勾选）
    var targetNLLanguages: [NLLanguage] {
        var arr = enabledLangs.compactMap { codeToNLLanguage[$0] }
        if enabledLangs.contains("zh") { arr.append(.traditionalChinese) }
        return arr.isEmpty ? [.english] : arr
    }

    func resetToDefaults() {
        ocrConfidenceMin = 0.30
        nlProbMin = 0.55
        minTextHeightRatio = 0.008
        enabledLangs = allLangCodes
        autoOpenPreview = true
        hotKeyCode = defaultHotKeyCode
        hotKeyModifiers = defaultHotKeyModifiers
    }
}
