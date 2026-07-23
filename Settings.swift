//
// Settings.swift — 全局设置存储（语种开关 / 置信度阈值 / 行为选项）
//
// 说明：把原本硬编码在 LangBarApp.swift 里的阈值与目标语种，抽成可在「设置窗口」
//      里配置、并持久化到 UserDefaults 的运行期设置。
//

import Foundation
import NaturalLanguage
import CoreGraphics

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
    }

    private init() {
        d.register(defaults: [
            K.ocrConf: 0.30,
            K.nlProb: 0.55,
            K.minHeight: 0.008,
            K.enabledLangs: allLangCodes,
            K.autoOpenPreview: true
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
    }
}
