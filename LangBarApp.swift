//
// LangBarApp.swift — macOS 菜单栏常驻 · 截图识别语种 App
//
// 功能：
//   1) 常驻菜单栏（无 Dock 图标，LSUIElement），点击图标即可截图框选
//   2) 框选区域 OCR（Apple Vision，原始像素、关闭纠错、自动语种检测）
//   3) 逐块标注语种（不同语种不同颜色框 + 标签），左上角汇总各语种占比 + 是否混语
//   4) 文字太小/模糊/置信度低 → 标注「未识别」，绝不乱猜语种
//   5) 中文文字自动跳过：不识别、不标注、不计入占比统计
//
// 覆盖语种：意 it / 葡 pt / 越 vi / 印尼 id / 日 ja / 韩 ko /
//          泰 th / 阿 ar / 德 de / 法 fr / 英 en（中文自动跳过）
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
    "de": "德语", "fr": "法语", "en": "英语", "pl": "波兰语", "es": "西班牙语",
    "ru": "俄语",
    "zh": "中文",
    "name": "英语（人名/地名）", "num": "数字", "und": "未识别"
]
func cnName(_ code: String) -> String { langCN[code] ?? code }

let langColor: [String: NSColor] = [
    "de": .systemBlue, "en": .systemGreen, "fr": .systemPurple, "pl": .systemYellow,
    "it": .systemTeal, "pt": .systemOrange,
    // 西班牙语：橙红色，与葡萄牙语(橙)/法语(紫)明显区分
    "es": NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.10, alpha: 1.0),
    "vi": .systemPink, "id": .systemIndigo, "ja": .systemRed,
    "ko": .magenta, "th": .brown, "ar": .darkGray,
    // 俄语：暗红棕色，与 ja(红)/th(棕)/ar(深灰) 区分
    "ru": NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.07, alpha: 1.0),
    "zh": .orange,
    "name": .systemGreen, "num": .systemYellow, "und": .gray
]
func color(_ code: String) -> NSColor { langColor[code] ?? .gray }

let targetLangs: [NLLanguage] = [
    .italian, .portuguese, .vietnamese, .indonesian,
    .japanese, .korean, .thai, .arabic,
    .german, .french, .english, .polish, .spanish,
    .simplifiedChinese, .traditionalChinese
]

// 允许输出的语种白名单：NaturalLanguage 偶尔会返回目标集外的杂语
// （如荷兰语 nl / 斯洛伐克语 sk），凡不在此集合内的结果一律不采信，避免误判。
let allowedLangCodes: Set<String> = [
    "it", "pt", "vi", "id", "ja", "ko", "th", "ar",
    "de", "fr", "en", "pl", "es", "ru", "zh"
]

// 语种黑名单：明确不需要识别的语种（挪威语：书面挪威 nb / 新挪威 nn / 通用 no）。
//   命中即判「未识别」und，阻断回退到次优白名单语种（如被误判成德语/英语）造成的错判。
let blacklistLangCodes: Set<String> = ["no", "nb", "nn"]
// 黑名单拦截阈值：fastText/NL 首选为挪威语且概率 ≥ 此值、且文本足够长时才拦，避免短词误伤。
let BLACKLIST_MIN_PROB: Double = 0.60
let BLACKLIST_MIN_LETTERS: Int = 8

// 置信度阈值：低于此值判为「未识别」，绝不乱猜
let OCR_CONFIDENCE_MIN: Float = 0.30       // Vision OCR 单块置信度下限
let NL_PROB_MIN: Double = 0.55             // NaturalLanguage 语种概率下限（拉丁语系）
let MIN_TEXT_HEIGHT_RATIO: CGFloat = 0.008 // 文字太小（相对整图高度）判为未识别
// 第8批·最高：未识别兜底阈值 —— fastText 与 Apple NL 置信度均低于此值 → 判 und（不强归任何语种）
let UND_MIN_CONF: Double = 0.2

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

// 强制判「英语人名/地名(name)」：著名人名/地名，即使被其它语种短词规则命中也归专名。
// 单 token（小写匹配）
let properNounForceList: Set<String> = [
    "corbusier", "ahmedabad", "bauhaus", "mies", "gropius", "niemeyer"
]
func isProperNounForced(_ token: String) -> Bool { properNounForceList.contains(token.lowercased()) }
// 整块短语（归一化后小写匹配）：如 "le corbusier"（LE 会被误判意语，故整块保护）
let properNounForcePhrases: Set<String> = [
    "le corbusier", "le corbusier's", "le corbusiers"
]

// 短词英语兜底的「保护名单」：这些 ≤4 ASCII 短词不被"断词碎片→英语"规则覆盖
// （德语冠词保持德语；意语高频代词/冠词保持意语——见任务2）
let shortWordEnglishKeepList: Set<String> = [
    // 德语冠词/限定词
    "die","das","der","den","dem","des","ein","von",
    // 意大利语高频代词/冠词（用户明确要求保留为意语）
    "lei","lui","lo","la","le","li","gli","una","uno","cosa","il","non","che","chi"
]

// 拉丁文本按空白分词并去除首尾标点，返回有效 token 列表
func latinTokens(_ text: String) -> [String] {
    return text.split { $0 == " " || $0 == "\n" || $0 == "\t" }
        .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'()[]{}·—-")) }
        .filter { !$0.isEmpty }
}

// 纯数字/日期/时间/价格/尺寸 token：去掉数字、标点和单位后为空 → 视为数字 token，完全跳过。
// 注意：Uhr/cm/px/h 只有在与数字同现时才作为单位剥离；单独的 "Uhr" 不是数字 token（保留为德语词）。
func isNumericToken(_ token: String) -> Bool {
    let lower = token.lowercased()
    // 必须含至少一个数字，才可能是数字 token（避免把纯 "uhr"/"cm" 当数字）
    guard lower.contains(where: { $0.isNumber }) else { return false }
    var s = lower
    for unit in ["uhr", "cm", "mm", "px", "kg", "km"] { s = s.replacingOccurrences(of: unit, with: "") }
    // 剥离数字与常见分隔/货币/单位符号
    let strip: Set<Character> = ["0","1","2","3","4","5","6","7","8","9",
                                 ".", ",", "-", ":", "/", "%", "€", "$", "£", "×", "x", "h", " ", "'", "’"]
    s.removeAll { strip.contains($0) }
    return s.isEmpty
}

// ============================================================
// MARK: - 第13批·改动I：月份名 + 时间格式 跳过（不计入语种统计、不画框）
// ============================================================
// 五语（意/葡/西/法/德）月份名，全小写存储；匹配时用 tok.lowercased()。
//   含变音符形态（março/février/août/märz）与其 ASCII 变体（marco/fevrier/aout/maerz）。
//   全大写变体（GENNAIO/AOÛT）由 lowercased() 归一自动命中，无需单列。
//   语义同数字跳过：命中 → 从统计中剔除（不计 total、不计 und、不画框）。
let monthNames: Set<String> = [
    // 意大利语
    "gennaio","febbraio","marzo","aprile","maggio","giugno","luglio","agosto",
    "settembre","ottobre","novembre","dicembre",
    // 葡萄牙语
    "janeiro","fevereiro","março","marco","abril","maio","junho","julho",
    "setembro","outubro","dezembro",
    // 西班牙语
    "enero","febrero","mayo","junio","julio","septiembre","setiembre",
    "octubre","noviembre","diciembre",
    // 法语
    "janvier","février","fevrier","mars","avril","juin","juillet","août","aout",
    "septembre","décembre","decembre",
    // 德语
    "januar","februar","märz","maerz","juli","oktober",
    // 英德共用（april/mai/juni/august/september/november 与其它语重叠，统一收入以确保跳过）
    "august","september","november","october","december","june","july"
]

// 时间格式 token（H 17,30 / H17:30 / 17h30 / 17:30 / 17.30 等）→ 跳过不计语种。
//   注意：多数时间样例（17:30 / 17h30 / 17.30 / 17,30）在 isNumericToken 中因分隔符/单位
//   剥离后已为空 → 已判数字 token；此处新增正则作为显式补充，覆盖含前缀 H/h 的形态，
//   与 Python 镜像同步。
func isTimeToken(_ token: String) -> Bool {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    // ^[Hh]?\s?\d{1,2}[:hH.,]\d{2}$  形如 17:30 / 17h30 / 17.30 / 17,30 / H17:30 / H 17,30(单侧)
    let pattern = "^[Hh]?\\s?\\d{1,2}[:hH.,]\\d{2}$"
    if let re = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        if re.firstMatch(in: t, range: range) != nil { return true }
    }
    return false
}

// ============================================================
// MARK: - 第14批·改动M：价格 / 期刊编号 / 条形码 格式扩展跳过
// ============================================================
// 语义同数字跳过：命中即不计语种、不画框、不进 total。与 run_lang_tests.py 镜像同步。

// 价格：token 含货币符号 € $ £，或以 Fr./CHF 开头/结尾，且去掉货币标记与数字分隔符后主体为空（纯数字价格）。
//   例：4,50€ / Fr. 8.– / CHF 12 / £9.99 / $100
func isPriceToken(_ token: String) -> Bool {
    let lower = token.lowercased()
    guard lower.contains(where: { $0.isNumber }) else { return false }
    let hasCurrencySymbol = lower.contains("€") || lower.contains("$") || lower.contains("£")
    let hasCHF = lower.hasPrefix("chf") || lower.hasSuffix("chf")
    let hasFr = lower.hasPrefix("fr.") || lower.hasSuffix("fr.") || lower.hasPrefix("fr ") || lower.hasSuffix(" fr")
    guard hasCurrencySymbol || hasCHF || hasFr else { return false }
    var s = lower
    for mark in ["chf", "fr.", "fr"] { s = s.replacingOccurrences(of: mark, with: "") }
    // 剥离数字、货币符号与常见分隔符（含瑞士法郎尾巴 .– / –）
    let strip: Set<Character> = ["0","1","2","3","4","5","6","7","8","9",
                                 ".", ",", "-", "–", "—", "/", "€", "$", "£", " ", "'", "’"]
    s.removeAll { strip.contains($0) }
    return s.isEmpty
}

// 期刊/刊号编号：以 N° / N.º / Nr. / n° 开头（其后一般为数字）。例：N° 27 / Nr. 4 / n°12
func isJournalNumberToken(_ token: String) -> Bool {
    let lower = token.lowercased()
    for p in ["n°", "n.º", "nr.", "nº"] {
        if lower.hasPrefix(p) { return true }
    }
    return false
}

// 条形码：纯数字串且长度 ≥ 8（如 9772297641006）。
func isBarcodeToken(_ token: String) -> Bool {
    let digits = token.filter { $0.isNumber }
    return digits.count >= 8 && digits.count == token.count
}

// ============================================================
// MARK: - 第14批·改动N：品牌名 / 网址 / App 名跳过
// ============================================================
// 语义同数字跳过：命中即不计语种、不画框、不进 total。与 run_lang_tests.py 镜像同步。

// 1) 品牌 / App 名（全小写）：token.lowercased() 精确命中即跳过。
let brandSkipList: Set<String> = [
    "instagram", "facebook", "twitter", "youtube", "whatsapp", "tiktok", "snapchat",
    "pinterest", "linkedin", "spotify", "netflix", "amazon", "google", "apple"
]

// 2) 网址：token 无空格、含 '.' 且以/含常见 TLD（.com/.ch/.fr/.de/.it/.pt/.es/.net/.org）→ 整体跳过。
//    例：www.easybiken.ch / magicmaman.com。要求含 '.' 避免误伤正常缩写。
let urlTLDs: [String] = [".com", ".ch", ".fr", ".de", ".it", ".pt", ".es", ".net", ".org"]
func looksLikeURL(_ token: String) -> Bool {
    let lower = token.lowercased()
    guard !lower.contains(" "), lower.contains(".") else { return false }
    for tld in urlTLDs {
        // 作为结尾 TLD，或后接 '/'（如 www.easybiken.ch/page）
        if lower.hasSuffix(tld) || lower.contains(tld + "/") { return true }
    }
    return false
}

// 品牌 + 网址统一判据（不依赖运行时 fastText）。连字符低置信品牌规则在运行时置信度处理（见镜像 stub 说明）。
func isBrandOrUrlToken(_ token: String) -> Bool {
    if brandSkipList.contains(token.lowercased()) { return true }
    if looksLikeURL(token) { return true }
    return false
}

// 3) 连字符品牌（运行时规则）：token 全小写、含 '-'（连字符）且 fastText 置信度 < 0.4 → 跳过。
//    仅在拥有 fastText 置信度的调用点生效；此处提供纯静态判据（是否全小写含连字符），
//    置信度判断由调用点补充。run_lang_tests.py 镜像因无 fastText 运行时，做 stub（恒为 false）。
func isLowercaseHyphenToken(_ token: String) -> Bool {
    guard token.contains("-") else { return false }
    return token == token.lowercased() && token.contains(where: { $0.isLetter })
}

// 统一「跳过 token」判据：数字 / 月份名 / 时间格式 / 价格 / 期刊编号 / 条形码 任一命中 → 从语种统计中剔除。
func isSkipToken(_ token: String) -> Bool {
    if isNumericToken(token) { return true }
    if monthNames.contains(token.lowercased()) { return true }
    if isTimeToken(token) { return true }
    if isPriceToken(token) { return true }
    if isJournalNumberToken(token) { return true }
    if isBarcodeToken(token) { return true }
    if isBrandOrUrlToken(token) { return true }
    return false
}

// ============================================================
// MARK: - 语言形态学线索（德语 / 英语），用于消解双语误判与词缀误判
// ============================================================

// 德语特有字符：命中即强烈提示德语
let germanChars: Set<Character> = ["ä", "ö", "ü", "ß", "Ä", "Ö", "Ü"]

// 德语高频功能词/冠词/介词/连词/代词（小写比较）——刻意只保留“区分度高”的词，
// 避免选入 in/or/as 这类跨语言（意/葡/法）通用词造成误判。
let germanStopwords: Set<String> = [
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
    "und", "oder", "aber", "denn", "sondern", "doch",
    "für", "mit", "von", "zum", "zur", "vom", "im", "am", "ins", "beim",
    "auf", "aus", "bei", "nach", "über", "unter", "zwischen", "durch", "gegen", "ohne", "um", "vor", "hinter", "neben",
    "ist", "sind", "war", "waren", "wird", "werden", "wurde", "wurden", "hat", "haben", "hatte",
    "sein", "seine", "ihre", "nicht", "auch", "schon", "noch", "sehr", "mehr", "als", "wie", "wenn",
    "weil", "dass", "damit", "sowie", "ich", "wir", "ihr", "kein", "keine", "keinen", "nur",
    "mich", "dich", "sich", "diese", "dieser", "dieses", "roman"
]

// 英语高频功能词——同样只保留“区分度高”的词（去掉 a/an/in/on/at/or/as/so/if 等跨语言词）。
let englishStopwords: Set<String> = [
    "the", "and", "is", "are", "was", "were", "of", "to", "for", "with", "that", "this", "these", "those",
    "from", "by", "it", "not", "which", "who", "whom", "whose", "been", "being", "have", "has", "had",
    "will", "would", "should", "could", "you", "your", "they", "their", "our", "there", "when", "what",
    "because", "about", "into", "than", "then", "only", "also", "more", "most", "such"
]

// 德语常见构词后缀 → 最小整词长度（避免误伤英文短词，如 young/sung/shaft/tennis）。
// 覆盖用户明确要求的 -bau / -schaft / -ung / -keit 等。
let germanSuffixMinLen: [(suf: String, minLen: Int)] = [
    ("schaft", 7), ("ismus", 6), ("ität", 5), ("keit", 6), ("heit", 6),
    ("ung", 6), ("nis", 7), ("tum", 5), ("bau", 5),
    ("lich", 5), ("isch", 5), ("haft", 6), ("tät", 4)
]

// 德语高频词根/关键词（子串匹配，全小写；全大写/首字母大写时同样命中）。
// 用于识别「全大写德语词」（WERK/STATT/BASTO）与「德语复合词」（Kunstverlag = Kunst+Verlag）。
// 均为 ≥4 字母、与英文碰撞低的强信号词根；命中即判德语，避免走「英语专名」路径。
let germanRoots: Set<String> = [
    // 用户点名要求的高频词根
    "werk", "statt", "verlag", "kunst", "bast", "tier",
    // 地名/建筑/机构类复合词常见词根
    "stadt", "haus", "dorf", "wald", "garten", "kirch", "markt", "platz",
    "strasse", "straße", "schloss", "bahnhof", "brücke", "brucke",
    // 组织/学科/抽象名词词根
    "gesellschaft", "wissenschaft", "arbeit", "wirtschaft", "freiheit",
    "buch", "schule", "spiel", "herz", "geist", "meister",
    "könig", "konig", "kaiser", "zeitung",
    "grafie", "grafien", "geber", "reiter", "kosmos", "blauer"
]

// 德语常见名字（人名，全小写比较）——仅当 token 呈人名形态（首字母大写/全大写）时采信，
// 避免误伤英文小写功能词（如 "else" 作「否则」义）。用于识别德语人名（如 Else Stadler-Jacobs）。
let germanGivenNames: Set<String> = [
    "else", "otto", "hans", "fritz", "greta", "ilse", "ursula", "jürgen", "jurgen",
    "heinz", "kurt", "dieter", "wolfgang", "günther", "gunther", "helga", "gerda",
    "inge", "klaus", "horst", "ernst", "wilhelm", "friedrich", "heinrich", "ludwig",
    "gottfried", "hannelore", "gisela", "gudrun", "bernd", "uwe", "jens", "jörg", "jorg",
    "anneliese", "hedwig", "waltraud", "hertha", "kathe", "käthe", "gustav", "reinhard"
]

// token 是否呈「人名/大写形态」（首字母大写，含全大写）
func isCapitalizedToken(_ token: String) -> Bool {
    guard let f = token.first else { return false }
    let fs = String(f)
    return fs == fs.uppercased() && fs != fs.lowercased()
}

// token 是否为德语常见名字（仅在大写形态时采信）
func isGermanGivenName(_ token: String) -> Bool {
    guard isCapitalizedToken(token) else { return false }
    return germanGivenNames.contains(token.lowercased())
}

// 判断单个 token 是否带明显德语形态（特殊字符 / 构词后缀 / 德语词根子串）
func tokenLooksGerman(_ token: String) -> Bool {
    if token.contains(where: { germanChars.contains($0) }) { return true }
    let lower = token.lowercased()
    for (suf, minLen) in germanSuffixMinLen {
        if lower.count >= minLen && lower.hasSuffix(suf) { return true }
    }
    // 德语词根子串匹配：全大写(WERK/STATT)、复合词(Kunstverlag)、变体(BASTO 含 bast) 均可命中
    for root in germanRoots {
        if lower.contains(root) { return true }
    }
    return false
}

// 文本 tokens 中是否含任何德语特征（词根/词缀/特殊字符/德语人名）
func hasGermanFeature(_ tokens: [String]) -> Bool {
    return tokens.contains { tokenLooksGerman($0) || isGermanGivenName($0) }
}

// ============================================================
// MARK: - NSSpellChecker 词典辅助（德语 / 英语拼写词典）
// ============================================================

// 词典判定结果：.german=德语词典命中 / .english=仅英语词典命中 / .none=两者都未命中或无词典
enum SpellLangHit { case german, english, none }

// 解析系统中实际可用的德/英拼写词典语言标识（如 de_DE / en_US）。
// 若系统未安装对应词典则为 nil，届时词典辅助自动降级（不影响词根/词缀/人名规则）。
func resolveSpellLanguage(_ prefixes: [String]) -> String? {
    let avail = NSSpellChecker.shared.availableLanguages
    for p in prefixes where avail.contains(p) { return p }
    for p in prefixes {
        if let hit = avail.first(where: { $0 == p || $0.hasPrefix(p + "_") || $0.hasPrefix(p + "-") }) {
            return hit
        }
    }
    return nil
}

let germanSpellLang: String? = resolveSpellLanguage(["de", "de_DE"])
let englishSpellLang: String? = resolveSpellLanguage(["en", "en_US", "en_GB"])

// NSSpellChecker 非线程安全，OCR 在后台队列执行，故对其访问统一加锁串行化。
let spellLock = NSLock()
let spellCacheLock = NSLock()
var spellHitCache: [String: SpellLangHit] = [:]

// 用指定语言的拼写词典检查单词是否拼写正确（即词典命中）。language 为 nil → 降级返回 false。
func spellValid(_ word: String, language: String?) -> Bool {
    guard let lang = language, !word.isEmpty else { return false }
    spellLock.lock()
    defer { spellLock.unlock() }
    let r = NSSpellChecker.shared.checkSpelling(
        of: word, startingAt: 0, language: lang,
        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    return r.location == NSNotFound
}

// 生成查词典的候选形态：原词 +（全大写时）Title Case 形态（WERK→Werk、BASTO→Basto）。
func spellCandidates(_ token: String) -> [String] {
    var cands = [token]
    let hasLetter = token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    let isAllUpper = hasLetter && token == token.uppercased() && token != token.lowercased()
    if isAllUpper {
        let lower = token.lowercased()
        let titled = lower.prefix(1).uppercased() + lower.dropFirst()
        cands.append(titled)
    }
    return cands
}

// 对单个 token 做德/英拼写词典判定：
//   德语命中           → .german（优先，即便英语也命中）
//   仅英语命中         → .english
//   两者都未命中(专名/全大写缩写) → .none（不采信词典，交回词根/词缀规则）
func spellCheckToken(_ token: String) -> SpellLangHit {
    if germanSpellLang == nil && englishSpellLang == nil { return .none }
    spellCacheLock.lock()
    if let cached = spellHitCache[token] { spellCacheLock.unlock(); return cached }
    spellCacheLock.unlock()

    let cands = spellCandidates(token)
    var deHit = false, enHit = false
    for c in cands {
        if !deHit && spellValid(c, language: germanSpellLang) { deHit = true }
        if !enHit && spellValid(c, language: englishSpellLang) { enHit = true }
    }
    let hit: SpellLangHit = deHit ? .german : (enHit ? .english : .none)

    spellCacheLock.lock(); spellHitCache[token] = hit; spellCacheLock.unlock()
    return hit
}

// ============================================================
// MARK: - 英语强制白名单 / 法语 / 波兰语 / 拼音 识别
// ============================================================

// 英语强制白名单：命中即判英语（最高优先），修复全大写英语词被误判德语。
let englishForceList: Set<String> = [
    "exposure","space","champion","blend","coffee","origin","natural","washed",
    "anaerobic","organization","few","espresso","roast","arabica","robusta","aroma",
    "flavor","flavour","notes","process","honey","single","medium","dark","light",
    "brand","shop","store","sale","quality","premium","fresh","official","studio","design",
    "pride",
    // 英语短句/杂志栏目词（修复被误判德语）
    "consulting","stories","beauty","living","lifestyle","advertising","businesses",
    "business","next","level","fashion","travel","food","health","home","people",
    "news","culture","interview","review","guide","special","edition","magazine",
    // 英语月份（英德共用月份强制判英语，修复被判印尼/波兰/泰语）
    "january","february","march","april","may","june","july","august",
    "september","october","november","december",
    // 英语杂志/时尚品牌名（ELLE 法语也有，但作杂志品牌标英语）
    "esquire","harper","bazaar","instyle","elle","vogue","wear","sleek","tweed",
    // 英语常用短词（防止全大写被误判为「人名/地名」）
    "love","joy","pure","back","big","splash","summer","vibe","party","easy",
    "cool","wild","soft","style",
    // 简单英语词（修复被误判印尼语/波兰语/法语）
    "enjoy","tasty","pieces","journal","splice","using","analog","analogue",
    // 英语音乐/出版词汇（修复被误判印尼语/意大利语/德语）
    "violin","thing","arts","music","makers","maker","advertorials","advertorial",
    // 普通英语词/建筑词汇（修复被误判「英语人名/地名」或其他语种）
    "form","follows","vernacular","architecture","building","buildings",
    "why","do","black","casting","housing","association","millowners",
    "hybrid","urbanity",
    "chemsex"
]
func isEnglishForced(_ token: String) -> Bool { englishForceList.contains(token.lowercased()) }

// 德语强制白名单：命中即判德语（不区分大小写），修复全大写德语词被误判英语。
let germanForceListRaw = """
blauer
reiter
kosmos
fotografie
fotografien
herausgeber
verlag
kunst
werk
statt
bau
kunstverlag
blaue
blau
roman
berlin
hamburg
münchen
muenchen
köln
koeln
frankfurt
stuttgart
düsseldorf
duesseldorf
leipzig
straße
strasse
str
deutsch
englisch
französisch
franzosisch
italienisch
spanisch
japanisch
koreanisch
russisch
polnisch
arabisch
türkisch
turkisch
chinesisch
griechisch
lateinisch
schwedisch
niederländisch
niederlandisch
dänisch
danisch
norwegisch
finnisch
ungarisch
tschechisch
slowakisch
perfekt
deutschperfekt
leserbriefe
abitur
grammatik
schreiben
lesen
sprechen
hörverstehen
horverstehen
vokabeln
übungen
ubungen
österreich
osterreich
schweiz
österreichisch
osterreichisch
lernen
lernhilfe
lernkarte
zeitschrift
magazin
ausgabe
heft
seite
freizeit
steuersparakademie
wissen
größtes
groesstes
eisfeld
jahre
jahr
werbung
medien
daten
fahren
sonntag
zahnbehandlung
winterparadies
programm
größte
groesste
größer
groesser
freiheit
gesundheit
sicherheit
zukunft
erfolg
angebot
angebote
januar
februar
märz
maerz
mai
juni
juli
oktober
dezember
die
das
der
den
dem
des
ein
eine
einen
einem
einer
eines
operetten
musicals
spielliteratur
musikpädagogik
musikpadagogik
musikbuch
neuerscheinungen
frühjahr
fruehjahr
herbst
printausgaben
sonderwerbeformen
noten
notenausgabe
klavier
gesang
herausgegeben
von
metropole
auflage
band
berge
feiern
tirol
seminare
sind
ist
nicht
aber
acht
achte
achten
achter
achtes
allein
allem
allen
aller
allerdings
alles
allgemeinen
also
ander
andere
anderem
anderen
anderer
anderes
anderm
andern
anderr
anders
auch
ausser
ausserdem
außer
außerdem
bald
beide
beiden
beim
beispiel
bekannt
bereits
besonders
besser
besten
bisher
bist
dabei
dadurch
dafür
dagegen
daher
dahin
dahinter
damals
damit
danach
daneben
dank
dann
daran
darauf
daraus
darf
darfst
darin
darum
darunter
darüber
dasein
daselbst
dass
dasselbe
davon
davor
dazu
dazwischen
daß
dein
deine
deinem
deinen
deiner
deines
dementsprechend
demgegenüber
demgemäss
demgemäß
demselben
demzufolge
denen
denn
denselben
deren
derer
derjenige
derjenigen
dermassen
dermaßen
derselbe
derselben
deshalb
desselben
dessen
deswegen
dich
diejenige
diejenigen
dies
diese
dieselbe
dieselben
diesem
diesen
dieser
dieses
doch
dort
drei
drin
dritte
dritten
dritter
drittes
durch
durchaus
durfte
durften
dürfen
dürft
eben
ebenso
ehrlich
eigen
eigene
eigenen
eigener
eigenes
einander
einig
einige
einigem
einigen
einiger
einiges
einmal
eins
ende
endlich
entweder
ernst
erst
erste
ersten
erster
erstes
etwa
etwas
euch
euer
eure
eurem
euren
eurer
eures
folgende
früher
fünf
fünfte
fünften
fünfter
fünftes
für
ganz
ganze
ganzen
ganzer
ganzes
gedurft
gegen
gegenüber
gehabt
gehen
geht
gekannt
gekonnt
gemacht
gemocht
gemusst
genug
gerade
gern
gesagt
geschweige
gewesen
gewollt
geworden
gibt
ging
gleich
gott
gross
grosse
grossen
grosser
grosses
groß
große
großen
großer
großes
gute
guter
gutes
habe
haben
habt
hast
hatte
hatten
hattest
hattet
heisst
heute
hier
hinter
hoch
hätte
hätten
ihnen
ihre
ihrem
ihren
ihrer
ihres
immer
indem
infolgedessen
irgend
jahren
jede
jedem
jeden
jeder
jedermann
jedermanns
jedes
jedoch
jemand
jemandem
jemanden
jene
jenem
jenen
jener
jenes
jetzt
kann
kannst
kaum
kein
keine
keinem
keinen
keiner
keines
kleine
kleinen
kleiner
kleines
kommen
kommt
konnte
konnten
kurz
können
könnt
könnte
lang
lange
leicht
leide
lieber
machen
macht
machte
magst
mahn
manche
manchem
manchen
mancher
manches
mann
mehr
mein
meine
meinem
meinen
meiner
meines
mensch
menschen
mich
mittel
mochte
mochten
morgen
muss
musst
musste
mussten
muß
mußt
möchte
mögen
möglich
mögt
müssen
müsst
müßt
nach
nachdem
nahm
natürlich
neben
nein
neue
neuen
neun
neunte
neunten
neunter
neuntes
nichts
niemand
niemandem
niemanden
noch
oben
oder
offen
ohne
ordnung
recht
rechte
rechten
rechter
rechtes
richtig
rund
sache
sagt
sagte
satt
schlecht
schluss
schon
sechs
sechste
sechsten
sechster
sechstes
sehr
seid
seien
seine
seinem
seinen
seiner
seines
seit
seitdem
selbst
sich
sieben
siebente
siebenten
siebenter
siebentes
solang
solche
solchem
solchen
solcher
solches
soll
sollen
sollst
sollt
sollte
sollten
sondern
sonst
soweit
sowie
später
startseite
steht
suche
tage
tagen
teil
tritt
trotzdem
unse
unsem
unsen
unser
unsere
unserer
unses
unter
vergangenen
viel
viele
vielem
vielen
vielleicht
vier
vierte
vierten
vierter
viertes
wahr
wann
waren
warst
wart
warum
wegen
weil
weit
weiter
weitere
weiteren
weiteres
welche
welchem
welchen
welcher
welches
wenig
wenige
weniger
weniges
wenigstens
wenn
werde
werden
werdet
weshalb
wessen
wieder
wieso
will
willst
wird
wirklich
wirst
woher
wohin
wohl
wollen
wollt
wollte
wollten
worden
wurde
wurden
während
währenddem
währenddessen
wäre
würde
würden
zehn
zehnte
zehnten
zehnter
zehntes
zeit
zuerst
zugleich
zunächst
zurück
zusammen
zwanzig
zwar
zwei
zweite
zweiten
zweiter
zweites
zwischen
zwölf
über
überhaupt
übrigens
weiß
sagen
sehen
komm
einfach
leben
weißt
sicher
leid
lassen
genau
klar
leute
vater
schön
glaube
gesehen
reden
liebe
geld
mutter
raus
paar
passiert
dachte
gehört
hör
helfen
nacht
finden
geben
hören
sieht
hause
mädchen
abend
haus
denke
warte
machst
essen
angst
bleiben
welt
schnell
getan
stimmt
nehmen
kinder
glauben
bringen
scheiße
brauchen
junge
musik
arbeit
fragen
heißt
familie
warten
sofort
bevor
sohn
brauche
fertig
gefunden
hilfe
verdammt
halten
siehst
verstehe
wusste
bruder
denken
könnten
sehe
egal
kennen
vergessen
frage
mache
komme
sieh
echt
eigentlich
stadt
männer
namen
bekommen
kopf
gehe
glück
letzte
freunde
töten
dinge
meinst
toll
minuten
bereit
ahnung
bisschen
tür
jungs
augen
polizei
stehen
sterben
draußen
kenne
runter
vorbei
treffen
gerne
dran
arbeiten
verrückt
sorgen
einzige
tochter
braucht
schwester
ruhig
spät
ziemlich
solltest
sogar
kerl
frauen
liegt
suchen
hört
verstehen
spielen
teufel
verstanden
verloren
grund
kommst
ruhe
stunden
hoffe
denkst
gestern
versuchen
letzten
schatz
nimm
erzählt
läuft
schwer
wasser
lässt
versucht
gekommen
geschichte
holen
bedeutet
nett
wahrheit
woche
bringt
bestimmt
sagst
schau
wagen
gefallen
spaß
niemals
schuld
getötet
verlassen
zeigen
beste
bleibt
würdest
manchmal
glaubst
lasst
spiel
nehme
freundin
gefällt
erzählen
entschuldigen
wichtig
gehst
bett
sachen
schule
entschuldigung
wort
hättest
wären
schlafen
gesicht
bloß
unten
stellen
gedacht
tust
trinken
unseren
kriegen
blut
eltern
scheint
herz
glücklich
bleib
drauf
irgendwie
reicht
fest
waffe
irgendwas
klingt
platz
brauchst
falsch
alten
nummer
jungen
früh
setzen
wahrscheinlich
arsch
telefon
kennst
willkommen
retten
hierher
wär
fehler
nächste
stunde
hände
gegeben
menge
langsam
wartet
lieben
büro
nächsten
gebe
wochen
schaffen
leider
scheiß
hölle
doktor
voll
überall
hund
direkt
wolltest
denkt
schiff
neues
könig
funktioniert
nennen
feuer
laufen
alleine
erinnern
völlig
kumpel
verlieren
spricht
kaffee
luft
fand
entschuldige
ziehen
verschwinden
könntest
seht
aufhören
richtige
unserem
buch
krank
fühle
verstehst
wert
arzt
froh
versuche
rufen
heiraten
lebt
onkel
gebracht
erklären
spielt
wahl
vertrauen
gegangen
gefühl
kaufen
geschafft
typen
interessiert
möchten
hält
glaub
irgendwo
stück
genauso
kennt
genommen
licht
getroffen
himmel
nachricht
drüben
passt
sagten
kümmern
laut
vergiss
angerufen
sitzen
erde
schlüssel
passieren
eher
gefragt
gefängnis
opfer
körper
findet
böse
gesprochen
versuch
vorstellen
wovon
sobald
nochmal
herren
waffen
wohnung
heißen
krankenhaus
bringe
höre
millionen
klasse
sinn
verletzt
ändern
erfahren
tragen
vorsichtig
stolz
fällt
möchtest
leuten
schöne
schicken
schätze
länger
großartig
lacht
anrufen
redest
fühlen
erwartet
stimme
glaubt
setz
mund
kämpfen
wisst
lachen
hörst
zeug
lustig
umbringen
hasse
schlimm
unglaublich
wärst
führen
gestorben
schauen
meinung
mörder
ähm
geschehen
geschäft
verzeihung
fliegen
zeig
aufs
vorher
schneller
liebt
verdient
meisten
denk
umgebracht
versprochen
hinten
monate
erinnere
arbeitet
rufe
nötig
heraus
tages
unmöglich
liebling
tatsächlich
folgen
bitten
behalten
nähe
arbeite
verdammte
plötzlich
lebens
tisch
hörte
jemals
liegen
verkaufen
gefährlich
anfangen
bekommt
hilft
meister
kampf
antwort
geschickt
obwohl
komisch
gewinnen
bezahlt
voller
unterwegs
dumm
ärger
bild
bezahlen
starb
monaten
leiche
arschloch
verheiratet
zieh
nimmt
gerettet
traum
entscheidung
schlimmer
regeln
fenster
fangen
ständig
findest
gefahr
absolut
augenblick
bescheid
gedanken
werd
ziel
benutzt
bewegung
wünschte
worte
zahlen
anfang
legen
erinnerst
anwalt
fahr
sitzt
hilf
schönen
müsste
bier
fürs
klappe
süß
herum
ließ
gleiche
monat
hochzeit
führt
wach
wozu
geschrieben
benutzen
informationen
erledigt
hoffentlich
fühlt
tanzen
ansehen
zuhause
wunderbar
hältst
reise
gewonnen
irgendwann
steckt
jedenfalls
schreit
tolle
rüber
tschüss
nennt
raum
heiß
kalt
irgendetwas
weile
unbedingt
sekunden
wofür
erzähl
beweise
freut
seele
schießen
müde
dauert
brief
gelernt
sucht
unfall
kontrolle
herzen
schlagen
wütend
weise
damen
gottes
fehlt
vorsicht
heiße
beweisen
zumindest
vermisst
hübsch
kriegt
verbindung
tief
richtung
lage
sowieso
lauf
ehre
stell
geschenk
gelesen
gekauft
wussten
gestohlen
lügen
beziehung
verschwunden
steh
nächstes
gearbeitet
preis
witz
meinte
gesucht
süße
rücken
schrecklich
letzter
verliebt
öffnen
redet
seltsam
versteckt
fürchte
verschwinde
erwischt
verkauft
erwarten
pferd
wunder
sauer
vermutlich
näher
majestät
aussehen
beschützen
geboren
erreichen
punkt
kindern
kirche
verraten
selber
befehl
fährt
zieht
geburtstag
wette
sekunde
fahre
schwöre
geredet
zeiten
traurig
anruf
nachrichten
frieden
karte
güte
diesmal
schade
persönlich
kriege
stirbt
bleibe
verändert
lieb
nämlich
letztes
bekam
ruft
gericht
ewig
singen
beschäftigt
toten
weihnachten
offensichtlich
naja
gefühle
fuß
überraschung
geheimnis
kontakt
drogen
regierung
wein
kriegst
ermordet
entfernt
geschlafen
erledigen
schlaf
lust
wunderschön
witzig
zerstört
willen
richtigen
namens
zeigt
geliebt
gehören
brachte
herrn
blick
besuch
schlechte
bewegen
haare
antworten
präsident
sagtest
hoffnung
stecken
lebe
rechts
entscheiden
miteinander
meint
liebst
bleibst
kümmere
wohnen
weder
möglichkeit
kaputt
bekomme
flugzeug
vergangenheit
aufhalten
stellt
verspreche
überrascht
sauber
schlag
untertitel
setzt
frag
vaters
nervös
gesellschaft
verstecken
schuldig
hals
schützen
besuchen
passen
überleben
erhalten
teilen
gebäude
schicksal
zeichen
besorgt
küche
lief
vergnügen
wüsste
volk
herausfinden
königin
soldaten
gelassen
gefahren
verstand
schönes
angefangen
fühlst
worauf
gebeten
kamera
achtung
schuhe
glückwunsch
gibst
übernehmen
gegend
wald
nimmst
erkennen
falsche
verantwortlich
stöhnt
herein
kleid
zerstören
jawohl
gegessen
abendessen
gesetz
gemeinsam
geholfen
wohnt
schritt
guck
nahe
aussieht
beginnen
dachten
ungefähr
aufgabe
furchtbar
drinnen
zuvor
freue
amerika
übrig
spur
falschen
melden
helfe
werfen
haltet
erinnert
hängt
freude
ehemann
erschossen
verzeihen
schwein
entschieden
verdammten
brauch
gewusst
vorne
stopp
übel
schlampe
schöner
unsinn
gesund
respekt
leisten
bedeuten
mitnehmen
gespielt
schwierigkeiten
hälfte
kannte
stehe
planeten
schwanger
gruppe
verhaftet
irgendwelche
händen
versteht
drehen
danken
zufrieden
schließen
besorgen
wochenende
worüber
stimmen
nehmt
witze
beine
verbrechen
bericht
nachts
prinzessin
schmerz
klingelt
echte
gleichen
fernsehen
wünsche
schließlich
gefangen
schätzchen
schwierig
gewartet
kümmert
rennen
lied
eier
fantastisch
schaut
hielt
insel
dauern
zufällig
bewegt
mitten
bullen
feind
einverstanden
neuer
bauen
trägt
hängen
freunden
halb
verpasst
sprach
leise
wusstest
fanden
unternehmen
träume
schläft
kostet
spiele
unseres
entlang
versprechen
tiere
verdienen
unterhalten
eingeladen
schaden
genannt
beenden
geändert
lächerlich
geschlagen
schätzen
männern
beginnt
ehren
fleisch
besonderes
besteht
reichen
zeitung
worum
nachgedacht
betrunken
sowas
patienten
gespräch
leiden
tötet
unterschied
singt
schreien
sahen
wand
lhre
angriff
verhalten
treten
quatsch
trifft
polizist
blumen
neuigkeiten
bringst
flasche
rief
schuss
fassen
konntest
schafft
maschine
spreche
bekommst
verbringen
bücher
blöd
frühstück
bilder
aufpassen
freuen
engel
offenbar
gelegenheit
lüge
ohren
angetan
beeil
brechen
brüder
zeitpunkt
ecke
brücke
druck
mitgebracht
seufzt
haufen
auftrag
entkommen
weißen
lösung
irre
gestellt
gebrochen
weinen
nutzen
wünschen
fragt
maul
verantwortung
schloss
lächeln
grad
hinaus
mitkommen
vorhin
fahrt
gemeint
ernsthaft
gebaut
hasst
versteh
kosten
zeige
traf
haar
fragte
befehle
schmerzen
erklärt
dach
folge
gelaufen
schwarze
dankbar
gehirn
töte
mädels
heilige
tier
mannes
wahnsinn
geschlossen
hintern
thema
gehalten
dorthin
urlaub
steig
vorwärts
überprüfen
besseres
beweis
gebt
funktionieren
anscheinend
lehrer
hoffen
bessere
isst
nachmittag
risiko
knast
entschuldigt
gilt
held
brauchte
gewalt
liebes
schaffst
nachdenken
erfahrung
pläne
jagen
katze
runde
deutsche
schwanz
taten
dringend
großvater
sommer
gezeigt
hinterlassen
gewissen
getrunken
wahre
kunden
zeugen
geplant
erreicht
stören
atmen
hose
weiße
sprichst
schickt
prinz
behandelt
tote
überlegen
karten
natur
verschwindet
lautet
streit
küssen
sprich
längst
fängt
drüber
gingen
erlaubt
einzigen
schmeckt
kugel
normalerweise
schwarzen
rauf
flug
beruhigen
halbe
geschieht
entdeckt
morgens
schlechter
vollkommen
gelogen
verfolgt
schwert
steigen
verdammter
dürfte
riecht
mindestens
fisch
füße
stehst
erschießen
kuchen
versuchte
zustand
wunsch
gäste
erwähnt
farbe
zufall
garten
junger
abgesehen
vertraut
koffer
hieß
kurs
wirkt
idioten
netter
angegriffen
geschichten
wahnsinnig
ähnlich
aufgeben
entführt
mistkerl
geschossen
besprechen
reihe
polizisten
legt
amerikaner
schwarz
fick
scherz
erzählte
wichser
langweilig
womit
geschäfte
kapiert
nachher
verlangt
schlägt
überzeugt
irgendjemand
vorbereitet
geschah
reisen
termin
stehlen
bemerkt
frankreich
stört
beruhige
pferde
vertrag
arbeitest
dienst
zählt
fragst
bürgermeister
fluss
woran
geblieben
durcheinander
direktor
wichtiger
karriere
akte
erinnerung
großmutter
erzähle
lösen
verfolgen
zweifel
sprache
nerven
ziehe
entlassen
zweimal
abholen
kollegen
fass
szene
scheinen
bösen
schaffe
pflicht
wache
neulich
beeilen
knie
lauter
spannende
unschuldig
folgt
schutz
geheiratet
woanders
wurdest
kuss
verhindern
erklärung
klug
kräfte
verlangen
außerhalb
selbstverständlich
aufstehen
hassen
gebrauchen
geglaubt
milch
trink
gefeuert
erinnerungen
müssten
suchst
fährst
kochen
schwach
schreibt
schulden
hinein
grenze
braut
gebraucht
peinlich
klappt
geheimnisse
aufmerksamkeit
umsonst
kennenzulernen
überlebt
nirgendwo
meilen
einfacher
blöde
mond
ergibt
merken
schande
fühlte
blödsinn
pfund
handeln
enden
raten
übersetzung
kapitän
desto
einsatz
schweigen
krankheit
schatten
wachen
tatsache
hingehen
verboten
gäbe
anzug
leichen
beendet
freitag
verflucht
dunkel
enttäuscht
klopfen
spuren
dreck
seiten
mühe
gezogen
kontrollieren
knochen
schick
getrennt
trage
nachbarn
bieten
bestes
fuhr
verlässt
freundlich
dennoch
rauchen
stuhl
dreh
schicke
vergeben
ausgehen
behandeln
trotz
gast
ändert
passierte
annehmen
herzlichen
hexe
erwachsen
saß
dreht
aussage
liebte
genießen
eifersüchtig
teuer
zähne
beobachtet
wählen
helft
fliegt
regen
feinde
erlauben
zulassen
schnappen
komplett
panik
flughafen
bewusst
deutschen
voraus
sterbe
solltet
begleiten
erlebt
weiterhin
stärker
fahrer
konzentrieren
streiten
angeht
selben
überzeugen
alkohol
übersetzt
verrückte
begann
angenommen
weitermachen
echter
mitgenommen
botschaft
ideen
fehlen
aufgeregt
selbstmord
dumme
zurückkommen
irgendein
schlage
handelt
treffe
untersuchen
flucht
verliert
irgendeine
gegenteil
betrifft
scharf
gehofft
kennengelernt
schlimmste
projekt
trottel
immerhin
mehrere
erwarte
schwimmen
zählen
innerhalb
schwestern
schlau
absicht
spielst
zuletzt
verletzen
schüler
schien
gewinnt
älter
merkwürdig
vermisse
größe
trauen
präsidenten
roten
überlegt
größten
vorstellung
schrieb
reinkommen
unterstützung
antun
rechnung
verändern
möglicherweise
definitiv
abends
frisch
kohle
fing
hure
familien
einsam
lebendig
heiligen
ebenfalls
überprüft
artikel
gesetzt
jederzeit
kompliziert
spüren
stich
probieren
tode
wundervoll
geöffnet
kerle
begraben
prozent
stoppen
hoheit
zugang
liest
vorn
wichtige
aufmachen
erlaubnis
leichter
halben
priester
herauszufinden
packen
inzwischen
sitze
machten
geklaut
helden
geduld
bühne
reparieren
gerechtigkeit
fälle
selten
anrufe
unterschreiben
drücken
lügner
endet
medizin
schreibe
verhaften
prozess
samstag
abhauen
schönheit
beinahe
lebst
tolles
anhalten
fremden
akzeptieren
norden
ärzte
anziehen
dingen
umgehen
bauch
gesamte
hübsche
ertragen
kiste
brennt
teile
deckung
landen
straßen
aufgenommen
gerufen
untersuchung
alarm
blieb
vertraue
entspann
beobachten
eindruck
tschüs
babys
wehtun
herrgott
echten
springen
nackt
existiert
befreien
gerät
gezwungen
perfekte
erzählst
bastard
interessieren
schlechten
steigt
gekriegt
fliehen
trug
freundschaft
papiere
abgeschlossen
schnauze
beruf
gebiet
beten
verbunden
sprachen
verräter
wichtigste
brust
aufgehört
kleider
jacke
bestellt
herkommen
nenne
angesehen
zuhören
trennen
schlafzimmer
vorschlag
meins
vermissen
angekommen
beantworten
deutlich
träumen
verwirrt
akten
riskieren
erkannt
beerdigung
müll
weisst
möge
stellte
mitte
erleben
geburt
decke
wege
schritte
gibts
gemeldet
hilfst
mittagessen
weint
vernichten
türen
gewehr
arbeitete
spiegel
hauen
geraten
wetter
schwul
regel
befindet
einheit
gucken
anstatt
champagner
gründe
strafe
öfter
langen
altes
ruiniert
kleidung
kenn
agenten
herausgefunden
brot
erfreut
lügt
nehm
harte
staaten
gaben
hinterher
verpassen
geholt
hemd
trinke
klären
praktisch
theorie
zunge
notfall
besseren
versuchst
schwere
feuern
schießt
anführer
schief
bestens
wartest
gehts
unrecht
leck
wonach
entwickelt
bedeutung
strom
krebs
gemein
minister
lhnen
zahl
schiffe
schüsse
bricht
spitze
fernseher
treiben
ausgezeichnet
tatort
möglichkeiten
trinkt
täter
wahren
dieb
offiziell
dienen
entscheidungen
dauernd
geschmack
gegenseitig
gewählt
pech
verteidigen
schauspieler
personen
überlassen
publikum
trägst
wechseln
begegnet
betrogen
besucht
vertrau
deutschland
süßer
loswerden
melde
bestätigt
sturm
setze
briefe
null
schlafe
wirken
geführt
starten
götter
festhalten
geheim
übergeben
abteilung
wetten
gefolgt
verschiedene
gleichzeitig
hungrig
inspektor
zwingen
atmet
unterstützen
geworfen
verlor
süden
menschheit
versteck
tötete
fähigkeiten
beruhigt
rechtzeitig
streng
sendung
gelebt
treppe
richtiger
aufnehmen
öffnet
dämon
schlange
medikamente
geschenkt
nenn
gelegt
anfassen
schlechtes
hütte
behauptet
kilometer
beeilung
angeblich
reiten
mittag
gewarnt
wohne
dunkelheit
spazieren
hiermit
schließt
vieles
erfüllt
tausend
eindeutig
unterhaltung
gründen
zugeben
gefangenen
frische
verdächtigen
neugierig
leitung
kennenlernen
fliege
lebte
menschliche
auseinander
fressen
beides
ficken
stoff
spüre
eilig
stammt
vorgestellt
wichtiges
gehörte
glaubte
oberst
schrank
fremde
gnade
entspannen
schläfst
einladung
vernünftig
fein
greifen
schickte
mitglied
einziger
umzubringen
zurückkehren
feld
mexiko
erschaffen
hergekommen
beweg
stärke
vermögen
verbracht
gewisse
waschen
staat
geister
behaupten
schrei
würdet
vögel
warnen
chancen
treibt
nannte
mitternacht
freundinnen
lecker
klinik
dicht
befinden
ließen
bürger
verursacht
klang
aufregend
grenzen
politik
zurecht
besitz
eingesperrt
irren
kommando
schlug
krankenwagen
öffne
richten
erfunden
schnee
fühl
behalte
beschützt
punkte
entfernen
abgehauen
geträumt
dämonen
tränen
erfolgreich
höher
musstest
heimat
liebsten
leiter
kauf
spinnst
schlacht
beziehungen
abgemacht
schreie
bestätigen
erschreckt
offizier
affäre
empfangen
zweck
kämpfe
ergeben
häuser
verliere
gedanke
tausende
heutzutage
gefühlt
schnitt
lebend
holz
spielte
begonnen
ziehst
gelandet
scheidung
beschlossen
riechen
vergisst
begeistert
durchs
geil
nieder
erkläre
schreckliche
beeindruckt
aufgegeben
aufgrund
momentan
solch
meistens
sterne
heilen
soviel
kannten
stattdessen
dinger
stimmung
aufgefallen
kämpft
geräusch
künstler
wachsen
verurteilt
himmels
urteil
schweine
verlust
verließ
wirf
schulter
kalifornien
lernt
beigebracht
anbieten
verwenden
gratuliere
fluch
übers
grün
unterricht
dachtest
verarschen
gewöhnt
anklage
tollen
lippen
fett
lege
feigling
erfährt
gewohnt
äußerst
einladen
käse
aufwachen
verfügung
uniform
zusehen
abenteuer
hosen
kurze
scheck
täglich
fresse
übernehme
wiederholen
bestellen
freiwillig
universum
zeuge
fähig
revier
reifen
führe
durchgemacht
führte
schenken
schädel
realität
albern
brav
schwerer
jagd
versagt
steckst
geschenke
sicherlich
öffentlichkeit
merkt
verbrecher
maske
verstärkung
liefern
starke
grunde
würd
verschwand
schulde
russen
gemerkt
loslassen
berichten
verabschieden
antrag
schieß
benehmen
verdacht
hübsches
schreibtisch
vampir
probe
schaff
verzeih
geküsst
ertönt
nahmen
zahlt
vorbereiten
verbrannt
verdammtes
informiert
einziges
zucker
stinkt
schnappt
schreib
standen
klamotten
besitzer
hinweis
verteidigung
lügst
magen
beeilt
einst
behandlung
applaus
markt
korrekt
besessen
bewahren
gekämpft
angreifen
tiefer
truppen
kommandant
osten
beeindruckend
besitzt
heut
clever
verrückten
freien
hass
antworte
posten
schneiden
sammeln
gesteckt
wissenschaft
ursache
gewiss
bereich
meinetwegen
senator
ausziehen
verzweifelt
anteil
stets
viertel
pünktlich
erfüllen
kauft
basis
schock
empfang
wiederhole
wünscht
besondere
titel
stil
fingerabdrücke
einfluss
anweisungen
zahle
opfern
sparen
gehörst
erstaunlich
schwachsinn
miete
verwandelt
bereiten
wüste
prüfen
hundert
erscheinen
laß
besiegen
verpiss
umständen
angelegenheit
dienstag
folgendes
fürchten
mordes
nennst
angestellt
aufgetaucht
rausfinden
ächzt
rauskommen
suppe
erwischen
sitz
vorteil
amerikanische
schönste
rufst
berührt
kaufe
gedächtnis
wirklichkeit
bestraft
kreis
schlimmes
bestehen
erscheint
staatsanwalt
ewigkeit
störung
hässlich
lauft
angezogen
zigarette
mutig
ausruhen
linken
hauptmann
umstände
unglück
üben
wissenschaftler
gelöst
reaktion
dusche
mitarbeiter
bedroht
gehöre
befreit
stöhnen
reagiert
identität
fieber
hirn
leiten
donnerstag
unheimlich
jahrhundert
diener
extrem
ausweis
sicht
juden
studiert
angelogen
schaue
text
nebenan
lektion
mäuse
staub
kugeln
dutzend
ratte
mitleid
testen
auftritt
gegner
verdienst
langsamer
wunde
linie
bedrohung
kurzem
fische
einkaufen
kreuz
afrika
begangen
nachsehen
bäume
leidenschaft
geliebte
bereuen
spieler
verwendet
steuern
gekümmert
voran
wieviel
verabredung
verlasse
überfallen
umdrehen
negativ
schild
tanzt
verbrennen
gefreut
blauen
stücke
kühlschrank
identifizieren
lehrerin
kameras
zentrale
jäger
wenden
suchte
füßen
unglücklich
frohe
pfarrer
brachten
zauber
berühren
rückkehr
hafen
indianer
verschwenden
untersucht
königs
lese
hättet
affen
worten
kindheit
vermeiden
fabrik
aussagen
wunderbare
grandpa
miststück
verrückter
einfache
laufe
reingelegt
seltsame
heiratet
angenehm
daheim
planen
klauen
geruch
klingen
nächster
hörten
trafen
ungern
abgelehnt
erstens
abmachung
zeigte
hohen
ladys
verkauf
verbergen
sorgt
sohnes
berühmt
aussteigen
ginge
reingehen
korrektur
wirft
titten
betreten
todes
blöden
rausholen
hohe
aufnahme
hübscher
stellung
höhle
schokolade
angeboten
befreundet
weib
ausgerechnet
beibringen
belohnung
seelen
steine
scheißkerl
gestört
ruhen
gepäck
amerikanischen
telefonieren
heirate
erkenne
grüß
hurensohn
mögliche
scheinbar
fakten
informieren
jugend
feier
wenigen
söhne
benzin
erkennt
sicherer
zigaretten
dummes
mauer
erneut
flügel
schluck
hierbleiben
abschluss
christus
bezahle
böses
dummkopf
gerüchte
eingestellt
weitergehen
technik
bezweifle
gekostet
anzeige
wohnst
ergebnis
bedingungen
aufzuhalten
versprich
verdiene
geschnappt
eile
innen
verhandeln
weswegen
nützlich
inneren
vergesse
dunkle
warnung
gemeinde
diamanten
wächst
gewöhnlich
seil
bär
großartige
traurige
persönliche
figur
roboter
anschauen
kürzlich
käme
stellst
bereitet
einfallen
käfig
brach
satz
kommissar
exzellenz
schuldest
nass
rächen
womöglich
begrüßen
überraschen
menschlichen
repariert
führung
gestanden
schütze
störe
filmen
maschinen
unterlagen
palast
graben
kette
auftauchen
wovor
springt
terroristen
bekämpfen
lärm
flehe
aufgewachsen
arbeiter
größere
betrachten
widerstand
hausaufgaben
vögeln
bescheuert
weggehen
mädel
verbinden
ermittlungen
steck
wäsche
rätsel
besonderen
hunderte
versetzt
bibel
heiliger
reiß
kopie
besitzen
zeitungen
zurückgekommen
süßes
ungewöhnlich
höhe
geschaffen
beschreiben
ausgesucht
notwendig
dunklen
ignorieren
toter
narr
scheißegal
höchstens
übersehen
geirrt
außen
einzig
stirbst
lhren
spielchen
fahrrad
nutte
bequem
rauch
verschiedenen
kamst
hubschrauber
wüssten
erstmal
kollege
vernichtet
gesichter
konto
freie
haken
sünde
militär
gefasst
anzeichen
geklappt
hintergrund
erwähnen
tipp
reißen
keins
berichte
kram
schnapp
solle
umziehen
keinerlei
typisch
bietet
john-boy
ruinieren
jünger
umso
starben
triffst
unhöflich
anzurufen
universität
heben
katastrophe
prüfung
gesetze
versicherung
getragen
ehefrau
mitmachen
tauschen
ergebnisse
einstellen
reagieren
gefehlt
verwandeln
gedauert
senden
abgeben
anhören
bibliothek
japan
hinsetzen
motiv
schalten
gewöhnen
lernte
vereinigten
gewicht
badezimmer
schieben
dreimal
weich
echtes
zweitens
drachen
bahnhof
erschöpft
genauer
verlange
hexen
legende
freu
konzert
hopp
wiederzusehen
doppelt
vergleich
böser
herzlich
taschen
genügt
besucher
spanien
großzügig
hauses
leihen
scheiden
einstellung
köstlich
einheiten
wichtigen
warne
russland
angeschossen
sklaven
laune
gesamten
stille
asche
geflogen
spion
weihnachtsmann
hervorragend
verärgert
puppe
überfall
unwichtig
linke
übung
franzosen
wehgetan
schwäche
couch
atme
irgendeinem
unterstützt
ausdruck
pleite
beleidigt
knopf
schlimme
beweist
dramatische
heutigen
leere
trinkst
eingehen
greift
mächtig
sinnlos
versaut
netz
atem
anstellen
milliarden
umgebung
mitbringen
beteiligt
dunkeln
entwickeln
schämen
erwachsene
durchsuchen
rollen
vergesst
tricks
plätze
gefangene
sünden
sender
verlass
räumen
lerne
rettet
hinweise
ausreden
mommy
nächte
herrscht
jahres
romantisch
flüstert
drück
bedanken
verabredet
nigger
reizend
leib
stecke
scheisse
ärztin
vergewaltigt
lieferung
botschafter
studieren
köpfe
duschen
kopfschmerzen
knarre
sekretärin
handschellen
versehen
treu
positiv
meiste
albtraum
verlobt
besiegt
existieren
könne
proben
beschissen
gewinne
bewaffnet
fällen
wecken
wirkung
therapie
amüsieren
ordentlich
weglaufen
aufgewacht
nähern
decken
sinne
leutnant
zauberer
bittet
ankunft
klopft
abstand
bewusstsein
kontrolliert
treffer
abnehmen
ratten
anwälte
tempel
vergiftet
kunde
wunden
unangenehm
ausrüstung
segen
präsentiert
schließ
kehle
krone
garantiert
durchsucht
verfluchte
bestimmten
ladung
beinen
kapitel
benutze
ziele
nirgends
wohnzimmer
beute
schwarzer
schmutzig
liebhaber
ersetzen
verfahren
"""
let germanForceList: Set<String> = Set(germanForceListRaw.split(separator: "\n").map(String.init))
func isGermanForced(_ token: String) -> Bool { germanForceList.contains(token.lowercased()) }

// 法语特征字符 / 高频词（含省音 l' d' 处理）
// 第6批：把 é/É 从「法语独有」触发集中移除——葡语/西语也大量使用 é/É，
// 单独的 é/É 不能作为「法语 vs 葡/西」判据（否则 CAZÉTV 仅因 É 被误判法语）。
// 保留 è ê ë î ï ô œ æ à â ù û ç 等真正法语倾向字符；é/É 改为中性，交给 fastText/forceWords 判。
let frenchChars: Set<Character> = ["è","ê","ë","î","ï","ô","œ","æ","à","â","ù","û","ç",
                                   "È","Ê","Ë","Î","Ï","Ô","Œ","À","Â","Ù","Û","Ç"]
let frenchStopwords: Set<String> = [
    "le","la","les","un","une","des","du","de","au","aux","et","ou","sur","tout","tous",
    "toute","pour","dans","avec","par","sans","chez","vers","ce","cette","qui","que",
    "est","sont","collection","européenne","européen","juillet","artiste","érudit",
    "géant","beaux","arts",
    // 采样补充
    "non","affiche","affiches","française","françaises","graphique","contemporaine",
    "contemporaines","illustration","concours","guinguette","jeunesse","internationale",
    "éditions","étoile","graphiste","edition","nocturne","insolites","authentiques",
    "balade","autour","lieux","nuit"
]
func stripElision(_ lower: String) -> String {
    for p in ["l'","d'","j'","qu'","n'","s'","t'","c'","m'"] {
        if lower.hasPrefix(p) { return String(lower.dropFirst(p.count)) }
    }
    return lower
}
func tokenLooksFrench(_ token: String) -> Bool {
    if token.contains(where: { frenchChars.contains($0) }) { return true }
    if frenchStopwords.contains(stripElision(token.lowercased())) { return true }
    let lowerF = stripElision(token.lowercased())
    if lowerF.count >= 6 {
        // 第9批·改动2 根本修复：从 tokenLooksFrench 后缀集中删除 "tion"/"sion"。
        //   原因：英语高频词 nation/action/information/mission 等均以 -tion/-sion 结尾，
        //   无护栏地把它们判成法语是历史误判根源。真正法语的 -tion/-sion 词几乎都带法语
        //   变音符（会在上方 frenchChars 命中）或属于 frenchForceList；无变音符裸词交由
        //   suffixMorphologyLang(英语护栏)/fastText/NL 处理，不再在此硬判法语。
        //   保留真正区分度高的法语形态后缀（-ique/-aine/-esse/-eur/-euse/-ité/-ais/-aise/-iste）。
        for suf in ["ique","aine","esse","eur","euse","ité","ais","aise","iste"] where lowerF.hasSuffix(suf) { return true }
    }
    return false
}

// 法语强制词（星期/月份/活动词，命中即高权重判法语，不区分大小写）
let frenchForceListRaw = """
journée
journee
vendredi
lundi
mardi
mercredi
jeudi
samedi
dimanche
janvier
février
fevrier
mars
avril
mai
juin
juillet
août
aout
septembre
octobre
novembre
décembre
decembre
théâtre
theatre
rencontres
ateliers
projections
réfugié
refugie
réfugiés
refugies
billetterie
entrée
entree
adresse
association
mondiale
concert
danse
repas
expo
expos
méliès
melies
pratique
plein
air
caravanes
passe-partout
partir
famille
balades
balade
stationnement
nouvelles
nouvelle
déjà
deja
surprises
surprise
découverte
decouverte
autour
gratuit
gratuite
spectacle
spectacles
exposition
expositions
atelier
bayonne
roubaix
bordeaux
toulouse
marseille
nantes
strasbourg
grenoble
montpellier
rennes
brest
reims
dijon
lyon
nice
lille
nancy
angers
tours
orléans
orleans
hybride
hybrides
mode
actus
statistiques
renversent
litterature
littérature
tech
têtu
tetu
utile
mobilise
printemps
présidentielle
presidentielle
contre
pour
lucie
agnès
agnes
jean-baptiste
stratégies
strategies
chaleurs
sanglier
munitions
ventes
protégées
protegees
chasseurs
séquence
sequence
apaisée
apaisee
désir
desir
postures
jardins
ça
ca
entretien
épargne
epargne
coach
coachs
le
les
la
des
du
nos
dans
sur
economiste
économiste
états
etats
cinéma
musée
musee
séance
liberté
liberte
société
societe
prochainement
abord
absolument
afin
aient
aies
ailleurs
ainsi
allaient
allons
allô
alors
anterieur
anterieure
anterieures
apres
après
assez
attendu
aucun
aucune
aucuns
aujourd
aujourd'hui
aupres
auquel
aura
aurai
auraient
aurais
aurait
auras
aurez
auriez
aurions
aurons
auront
aussi
autant
autre
autrefois
autrement
autres
autrui
auxquelles
auxquels
avaient
avais
avait
avant
avec
avez
aviez
avions
avoir
avons
ayant
ayez
ayons
basee
beau
beaucoup
bigre
boum
brrr
ceci
cela
celle
celle-ci
celle-là
celles
celles-ci
celles-là
celui
celui-ci
celui-là
celà
cent
cependant
certain
certaine
certaines
certains
certes
cette
ceux
ceux-ci
ceux-là
chacun
chacune
chaque
cher
chers
chez
chiche
chut
chère
chères
cinq
cinquantaine
cinquante
cinquantième
cinquième
clac
clic
combien
comme
comment
comparable
comparables
compris
concernant
couic
crac
debout
dedans
dehors
delà
depuis
dernier
derniere
derriere
derrière
desormais
desquelles
desquels
dessous
dessus
deux
deuxième
deuxièmement
devant
devers
devra
devrait
different
differentes
differents
différent
différente
différentes
différents
directe
directement
dite
dits
divers
diverse
diverses
dix-huit
dix-neuf
dix-sept
dixième
doit
doivent
donc
dont
douze
douzième
dring
droite
duquel
durant
dès
début
désormais
effet
egale
egalement
egales
elle-même
elles
elles-mêmes
encore
enfin
envers
environ
essai
etant
etre
eues
eurent
eusse
eussent
eusses
eussiez
eussions
eux-mêmes
exactement
excepté
extenso
exterieur
eûmes
eût
eûtes
fais
faisaient
faisant
fait
faites
façon
feront
flac
floc
fois
font
force
furent
fusse
fussent
fusses
fussiez
fussions
fûmes
fût
fûtes
gens
haut
hein
holà
hormis
hors
houp
huit
huitième
hurrah
hélas
importe
jusqu
jusque
juste
laisser
laquelle
lequel
lesquelles
lesquels
leur
leurs
longtemps
lors
lorsque
lui-meme
lui-même
lès
maint
maintenant
malgre
malgré
maximale
meme
memes
merci
mien
mienne
miennes
miens
mille
mince
mine
minimale
moi-meme
moi-même
moindres
moins
moyennant
multiple
multiples
même
mêmes
naturel
naturelle
naturelles
neanmoins
necessaire
necessairement
neuf
neuvième
nombreuses
nombreux
nommés
notamment
notre
nous
nous-mêmes
nouveau
nouveaux
néanmoins
nôtre
nôtres
ohé
ollé
olé
onzième
ouias
oust
ouste
outre
ouvert
ouverte
ouverts
parce
parfois
parle
parlent
parler
parmi
parole
parseme
partant
particulier
particulière
particulièrement
passé
pendant
pense
permet
personne
personnes
peut
peuvent
peux
pfft
pfut
pire
pièce
plouf
plupart
plus
plusieurs
plutôt
possessif
possessifs
possible
possibles
pouah
pourquoi
pourrais
pourrait
pouvait
prealable
precisement
premier
première
premièrement
pres
probable
probante
procedant
proche
près
psitt
puis
puisque
quand
quant
quant-à-soi
quarante
quatorze
quatre
quatre-vingt
quatrième
quatrièmement
quelconque
quelles
quelqu'un
quelque
quelques
quels
quiconque
quoi
quoique
rare
rarement
rares
relative
relativement
remarquable
rend
rendre
restant
reste
restent
restrictif
retour
revoici
revoilà
rien
sacrebleu
sait
sans
sapristi
sauf
seize
selon
semblable
semblaient
semble
semblent
sent
sept
septième
serai
seraient
serais
serait
seras
serez
seriez
serions
serons
seront
seul
seule
seulement
sien
sienne
siennes
siens
sinon
sixième
soi-même
soient
soit
soixante
sommes
sont
sous
souvent
soyez
soyons
specifique
specifiques
speculatif
stop
strictement
subtiles
suffisant
suffisante
suffit
suis
suit
suivant
suivante
suivantes
suivants
suivre
sujet
superpose
surtout
tandis
tant
tardive
telle
tellement
telles
tels
tenant
tend
tenir
tien
tienne
tiennes
tiens
toi-même
touchant
toujours
tous
tout
toute
toutefois
toutes
treize
trente
trois
troisième
troisièmement
trop
très
tsoin
tsouin
unes
uniformement
unique
uniques
valeur
vers
vifs
vingt
vivat
vive
vives
vlan
voici
voie
voient
voilà
voire
vont
votre
vous
vous-mêmes
vôtre
vôtres
étaient
étais
était
étant
état
étiez
étions
été
étée
étées
étés
êtes
être
veux
chose
vraiment
voir
besoin
faut
peut-être
sûr
père
crois
ouais
homme
viens
vrai
veut
mieux
mère
fille
vois
désolé
prendre
savoir
choses
nuit
raison
arrive
voulais
aider
problème
peur
regarde
gars
trouvé
fils
attends
savez
trouver
travail
tête
appelle
arrête
voiture
enfants
tuer
idée
jours
demain
tard
truc
passer
connais
sens
pouvez
sortir
heure
comprends
entendu
vient
désolée
rester
prends
hommes
tué
question
histoire
devrais
aide
dernière
chercher
mois
frère
mettre
laisse
arrivé
parlé
avez-vous
heures
putain
savais
endroit
donné
est-il
écoute
yeux
trouve
pouvoir
perdu
côté
enfant
vieux
matin
venu
là-bas
demandé
venez
arrêter
attendez
chambre
droit
compte
dirait
espère
aimerais
loin
as-tu
croire
boulot
prêt
filles
mourir
jouer
demander
voulait
jeune
docteur
a-t-il
confiance
appeler
années
vérité
école
femmes
propos
semaine
vivre
regardez
téléphone
affaires
meilleur
devez
mains
prie
équipe
vas-y
manger
arriver
appelé
sécurité
essaie
important
dites
presque
mariage
parents
tomber
attendre
souviens
fête
génial
pays
cours
bientôt
numéro
parfait
laissé
essayé
instant
penser
essayer
prend
mauvais
travailler
rentrer
regarder
choix
êtes-vous
voyez
faute
croyais
changer
entendre
plaisir
heureux
entrer
voudrais
es-tu
propre
ensuite
garder
allait
travaille
amie
allons-y
lieu
année
voit
commence
devoir
attend
drôle
sûre
perdre
voulu
faisait
oublié
arrêtez
ferai
tôt
inquiète
payer
pouvais
reviens
prenez
pensez
cherche
montrer
parles
problèmes
cœur
sûrement
verre
aimes
devons
veulent
doute
musique
courant
moyen
puis-je
avis
sauver
hôpital
questions
meurtre
sérieux
trucs
comprendre
allais
esprit
fous
laisse-moi
malade
changé
allé
semaines
appris
seigneur
dîner
sors
commencé
suppose
chemin
bras
prochaine
meilleure
soirée
retard
écrit
chéri
voulez-vous
vaut
ferais
morts
boire
président
plait
erreur
ecoute
rentre
devait
revenir
joue
pauvre
devenir
rencontrer
sort
commencer
occupe
entends
reçu
intérieur
honneur
faux
groupe
rêve
appel
manque
envoyé
puisse
écoutez
laissez-moi
content
venue
dis-moi
voyons
acheter
voix
occuper
gagner
grâce
mauvaise
général
âge
tirer
apprendre
cheveux
avocat
accident
probablement
laissez
ordre
déteste
retrouver
millions
incroyable
oublie
ressemble
bienvenue
disparu
protéger
utiliser
petits
veux-tu
connaissez
simplement
scène
sœur
prête
oncle
devriez
soeur
complètement
armée
paix
battre
anniversaire
finir
réussi
agit
retourner
bouge
contrôle
rappelle
arrêté
rencontré
restez
mots
victime
impression
décidé
sympa
pars
habitude
système
médecin
bateau
faim
croyez
devais
ligne
colère
savait
gagné
risque
heureuse
parlez
présent
cadeau
expliquer
gauche
ferait
passe-t-il
ouvre
disais
disent
pouvons
allez-y
pourra
inspecteur
réponse
lumière
pieds
montre
marcher
envoyer
vraie
espèce
pareil
vas-tu
fallait
coin
moitié
vouloir
vieille
devenu
continuer
sortie
arrière
doucement
joli
exact
disait
arrivée
poser
chaud
aimé
fais-tu
professeur
quitter
tueur
donne-moi
flics
connaître
lettre
connaît
conseil
dangereux
essaye
bonnes
froid
allez-vous
prêts
gamin
joué
attaque
boîte
enquête
juge
envoie
preuve
oublier
vivant
aimer
faites-vous
télé
écouter
pourtant
gueule
ouvrir
santé
jeunes
coucher
cuisine
pouvez-vous
signifie
entrez
relation
foutre
âme
manière
flic
décision
mange
déjeuner
ordres
clé
vaisseau
secondes
enfer
sortez
vendre
faisais
mecs
aille
acheté
étrange
diable
viennent
monter
là-dedans
capable
emmener
écrire
honte
bouche
préfère
coupable
rire
payé
soin
prochain
cerveau
blague
choisi
époque
réunion
connu
allée
intérêt
cheval
combat
coups
retourne
trou
oeil
pleine
cacher
amoureux
drogue
garçons
faisons
tient
est-elle
gouvernement
client
contact
dingue
récupérer
preuves
présente
peau
peuple
exemple
promets
blessé
tort
pourriez
savent
héros
quitté
sauvé
bière
assis
ecoutez
devient
félicitations
opération
prévu
tenez
répondre
seuls
dommage
dites-moi
ramener
règles
découvert
départ
bruit
secours
vérifier
enceinte
témoin
dirais
directeur
intéressant
humain
apparemment
avenir
rêves
œil
bête
sérieusement
approche
nourriture
fric
lycée
empêcher
longue
sexe
banque
éviter
pitié
expérience
procès
thé
partez
utilisé
revenu
asseyez-vous
ridicule
appelez
copine
baiser
anglais
toilettes
faudra
occupé
grands
dérange
rôle
censé
savez-vous
croit
cour
église
obtenir
conneries
ennuis
personnel
conduire
tombé
espoir
comprenez
spécial
vidéo
vêtements
défense
grand-mère
intéresse
paraît
excuser
magasin
marier
revient
douleur
merveilleux
asseoir
aimais
amérique
fenêtre
sergent
peux-tu
projet
planète
certainement
assurer
rendu
tourne
danser
clients
petites
aimez
présenter
importance
mérite
derniers
meilleurs
honnête
essayez
irai
connard
occasion
prouver
travaillé
glace
parie
fier
discuter
mangé
rencontre
apprécie
réalité
savons
respect
remettre
vacances
détruire
choisir
découvrir
idées
officier
frères
sert
solution
informations
attendais
monstre
ordinateur
retrouvé
rappeler
énergie
utilise
pression
chaussures
faite
histoires
marié
espace
portable
préparer
nécessaire
offrir
ai-je
ennemi
arrivent
immédiatement
finalement
énorme
grand-père
gagne
réfléchir
victimes
chanter
futur
lâche
copain
enlever
pensez-vous
retrouve
épouser
fleurs
salope
arranger
riche
faits
ancien
accepter
restes
sauter
suspect
vies
politique
dents
urgence
cartes
jambes
conversation
tourner
toucher
mémoire
mariée
contraire
vent
donnez-moi
trouves
continuez
contrat
couteau
carrière
excuse-moi
regardé
descendre
université
sentiments
remarqué
noms
vécu
beauté
tais-toi
après-midi
excellent
assieds-toi
propres
couple
aiment
permis
différence
faudrait
humains
dégage
accès
cible
joyeux
bonheur
aimait
manqué
aidé
vouliez
trouvez
emmène
dernières
marrant
raisons
refuse
apporté
cassé
mettez
dis-lui
tuée
maladie
rentré
excuses
voudrait
rends
quitte
couché
disons
totalement
remercier
partis
pensait
île
remercie
caméra
pensent
suis-je
pleurer
régler
ouvrez
entier
foutu
types
fermer
animaux
dise
étage
rejoindre
soldats
amuser
suivi
oubliez
langue
frais
veuillez
couleur
bouger
frappé
frapper
venait
raté
évidemment
sacré
clés
épouse
jésus
failli
courir
américain
détails
regarde-moi
attraper
papiers
poisson
chiens
intention
procureur
goût
pourras
shérif
sais-tu
arrêt
sourire
lait
chasse
parlait
destin
marre
français
princesse
paie
chier
dois-je
présence
doigts
partenaire
préféré
entreprise
calme-toi
lien
appartient
attendant
amené
moindre
amener
amène
enfoiré
recherches
discours
données
appelles
salaud
penses-tu
bouteille
justement
raconter
rapidement
bref
viendra
passée
superbe
pourrai
pièces
obligé
identité
couper
morceau
lettres
gâteau
dépend
jeux
compter
reprendre
joie
gardes
regard
demandez
balles
vendu
majesté
menace
appareil
demandais
là-haut
privé
fonctionne
méchant
jambe
empreintes
noire
imbécile
gentille
labo
résultats
nouvel
malheureusement
décider
voulons
détruit
parfaitement
produit
réparer
chapeau
gérer
écoute-moi
échange
bougez
parfaite
meurt
fout
vitesse
fermé
succès
au-dessus
comprend
odeur
falloir
aise
caché
règle
imaginer
raconte
accepté
trouvée
dors
ministre
voitures
lever
arbre
maire
faveur
pourraient
prendra
surpris
jeté
également
apporter
peut-on
comptes
échapper
réel
couverture
article
doux
parc
toit
unité
resté
partager
recevoir
inquiétez
coffre
ramène
extérieur
membre
prévenir
cache
inquiéter
hasard
réponds
génie
parlais
parlons
montré
gosses
abandonner
assure
apporte
prépare
mètres
souhaite
ouest
poids
répondu
créer
aidez-moi
univers
saura
réalisé
américains
perds
membres
viande
sont-ils
crois-moi
amoureuse
changement
compliqué
conduit
piège
ressens
accepte
fais-le
amusant
donnez
traces
trésor
fesses
fantôme
naissance
retraite
regardes
franchement
côtés
étranger
poulet
vienne
débarrasser
enlève
mens
fantastique
beaux
entendez
bâtiment
a-t-elle
devrions
embrasser
tombée
manquer
chevaux
habite
fatigué
heureusement
billets
convaincre
appelait
paradis
émission
nettoyer
agréable
conscience
ennemis
disant
connaissance
douce
sentiment
bataille
pourrez
relations
espérais
fais-moi
souci
doigt
mensonge
volonté
direct
abandonné
joindre
proches
droits
nerveux
patients
invités
arrivés
descends
pleure
traitement
répète
reposer
regrette
aide-moi
flingue
vérifié
crains
douche
interdit
théorie
contrôler
signer
demandes
cherchez
appels
protection
pantalon
rappelles
ravie
semblant
offert
vieil
humaine
médicaments
acte
moyens
meurs
laisserai
aéroport
mauvaises
détective
témoins
coincé
mariés
innocent
créé
supporter
milliers
infirmière
métier
crétin
retirer
surveillance
oreilles
trouvera
militaire
atteindre
fuir
pilote
appelée
risques
leçon
paquet
défendre
immeuble
récemment
chinois
battu
aveugle
oiseau
propriétaire
ancienne
saviez
amies
cherché
tirez
gardez
assassin
célèbre
bague
dépêche-toi
devenue
connaissais
genoux
vert
refusé
hâte
réveiller
commande
commun
souris
partons
perdue
verras
chante
viré
fiston
étoiles
laisses
parlant
là-dessus
signé
virer
permettre
pouvoirs
pluie
passez
vrais
enlevé
blesser
épisode
assurance
angleterre
couche
gardé
chemise
voulaient
emploi
précédemment
surveiller
privée
entière
réfléchi
attendent
facilement
joues
voleur
véritable
entend
chaise
accusé
zéro
clairement
mouvement
sommeil
blancs
survivre
semblait
craint
traduction
repos
siège
policier
allés
puissance
familles
engagé
spéciale
violence
ours
gorge
dieux
obtenu
évident
distance
titre
exploser
rivière
paye
revenez
écoutes
logique
lève
essayais
pauvres
tenu
auprès
lèvres
plat
lunettes
journaux
attaquer
pistolet
divorce
noirs
meurtres
premiers
forêt
respirer
réponses
devraient
reviendra
mène
responsabilité
erreurs
épée
travaillait
tableau
cabinet
meurtrier
libérer
commis
sérieuse
sous-titrage
réveillé
mesure
secrétaire
images
fuite
amitié
pousser
brisé
raconté
cardiaque
minuit
humeur
physique
lieux
crier
permission
romantique
vache
courses
casser
études
modèle
pensées
prudent
plaisante
emmené
réfléchis
blessure
midi
souvenez
puissant
moteur
répond
coûte
reculez
construire
démon
achète
caméras
pousse
cesse
rentrée
finit
couilles
ignorais
usine
lâche-moi
ont-ils
délicieux
oreille
réellement
posé
avancer
maisons
voisins
dites-lui
deviens
crédit
ambulance
gamins
fière
tourné
puce
finie
liquide
prennent
traverser
rues
criminel
sombre
agence
comportement
artiste
bosser
paroles
résoudre
période
cherches
croyez-moi
donnes
préparé
soucis
traiter
reconnais
pourriez-vous
fromage
essence
tenté
chaleur
objet
ouai
disparaître
oiseaux
supposé
supplie
résultat
vérifie
souffrir
occupée
gardien
déranger
fatiguée
dégagez
anciens
tués
forcément
cadeaux
herbe
menteur
vivante
riches
sacrée
siècle
endroits
écris
rapports
rentrez
lendemain
fumer
concours
ment
passait
vous-même
inviter
fausse
élevé
chair
magique
chaîne
chèque
réseau
enfance
mensonges
pourrions
choisis
taire
inquiet
enfuir
profiter
revenue
billet
crâne
jaloux
arrestation
laver
nuits
caisse
scientifique
traité
attaqué
écoutez-moi
sénateur
blessures
murs
attrape
représente
esprits
réputation
étudier
trompe
plainte
grand-chose
sorcière
venant
californie
journaliste
chouette
avocats
cherchais
surveille
département
abandonne
prendrai
peinture
refaire
honnêtement
étais-tu
poitrine
médecins
remonte
aventure
réglé
amuse
mener
cauchemar
soupe
prêtre
trompé
conférence
répondez
attrapé
racontes
deviner
recommencer
dis-tu
complet
construit
excusez
entraînement
centaines
calmer
joueur
couloir
horreur
propriété
admettre
matériel
verrez
foule
réaction
ennuie
hiver
manteau
débile
trouverai
conseiller
humanité
lapin
désert
combattre
états-unis
reviendrai
ramené
discussion
connaissait
fiancée
remonter
incendie
arbres
conseils
géniale
messages
surface
appellent
atteint
recommence
curieux
ascenseur
apprend
larmes
dites-vous
impliqué
répéter
pardonner
donnerai
cadavre
uniquement
traîner
morceaux
réussir
empêche
traversé
américaine
décide
doué
gloire
communauté
plaisantes
déclaration
portait
croient
projets
frontière
saute
hais
laissée
suivez-moi
prénom
tenter
cérémonie
fasses
vivent
océan
vélo
aimerait
réaliser
poupée
navire
saches
remplacer
prisonnier
employés
dépêchez-vous
bouton
acteur
médecine
lourd
chargé
au-delà
survécu
bite
soudain
voyais
travailles
prévenu
regardez-moi
baisse
filer
rompu
véhicule
sauve
rencontrés
emmerde
estomac
couvrir
meilleures
rater
terminée
tâche
réserve
brûler
réveille
sentez
ferme-la
réveille-toi
etait
rêvé
pouviez
poursuivre
actions
absence
lâcher
tempête
souffre
touchez
rempli
dis-le
affreux
enterrement
inconnu
feriez
installer
va-t-il
rythme
étudiants
calmez-vous
travaillez
équipage
signes
élèves
faites-le
attirer
récompense
reconnu
irait
loup
traite
lâchez-moi
imaginez
navré
finis
lutte
opportunité
personnage
arrêtes
convaincu
allons-nous
accompagner
essayons
panique
afrique
nourrir
région
passent
salaire
veille
appelle-moi
ceinture
explication
chansons
profond
professionnel
possède
étonnant
venais
casier
jouez
arrives
nommé
incident
retournez
chine
technique
haine
identifier
célibataire
annoncer
portée
roule
tromper
attendait
abruti
disiez
normalement
circonstances
appelez-moi
canapé
sommes-nous
protège
est-à-dire
affronter
connait
élève
pêche
masque
couvert
extraordinaire
sentais
royaume
porc
envoyez
brûle
objets
gêne
aidera
conduis
excellente
brûlé
sauté
trouvent
ferez
laisse-le
rencard
concentrer
étoile
engager
fallu
prisonniers
essayait
pardonnez-moi
étape
davantage
collègues
rayon
correct
gâcher
assassiné
soif
conditions
remis
russes
personnellement
entièrement
impressionnant
créature
kilomètres
sers
échappé
prouve
associé
monnaie
moque
voisin
clinique
têtes
lentement
classique
produits
prenne
échoué
écouté
existence
correspond
mystère
maîtresse
tension
qualité
respecte
vierge
secteur
espérons
devoirs
contacter
secrète
cigarette
manques
bouffe
jugement
idiots
courageux
bibliothèque
condition
courrier
volant
merveilleuse
fumée
chanceux
lève-toi
poussé
étrangers
censée
permettez
approcher
japonais
soigner
urgences
effets
fruits
remplir
commençons
donnera
soins
risqué
avouer
passés
épreuve
vivants
conduite
découvre
avantage
retenir
miroir
procédure
verres
jaune
dames
efforts
proposé
blessée
disque
annuler
section
aube
précis
appellerai
etes-vous
lumières
briser
fait-il
échec
mexique
repose
urgent
médical
chiffres
carrément
interroger
fiancé
chaude
sacs
vivait
aimerai
alliez
partage
assise
accusation
bagages
boule
copains
suivez
criminels
poissons
fermez
bleue
égal
organiser
œuvre
attitude
documents
étiez-vous
effort
enchantée
diriger
apprends
proposition
pareille
terres
serpent
voyait
télévision
intéressé
pattes
possibilité
maudit
cochon
reconnaître
paire
condamné
croyait
sauvage
domaine
drogues
poussière
visiter
policiers
ajouter
chambres
séparer
valise
idéal
exprès
empereur
forcer
juger
montagnes
t-il
avoue
profondément
aides
collègue
fantômes
légende
embrasse
suffisamment
disparition
commencez
poule
semblez
éducation
restée
plaque
prenons
auparavant
peut-il
malades
connaissent
bijoux
refuser
pensée
saurais
adultes
préviens
appart
chasser
critique
fièvre
irais
terminer
monstres
essaies
coïncidence
née
suggère
raisonnable
conséquences
jouait
décisions
déposer
imagination
objection
faites-moi
ordinaire
rouges
voyez-vous
voudra
vieilles
matière
rentres
vend
pourrais-je
libéré
posez
bagarre
lié
cercle
sûrs
sortira
étudiant
extrêmement
digne
congé
prenait
meurent
beurre
émotions
sortes
stade
entraîner
préférée
allemand
sortis
malheureux
personnelle
épaule
était-ce
pigé
menacé
arrivait
taux
tireur
supporte
lignes
voyant
examiner
nerveuse
ouverture
patiente
huile
trouverez
mignonne
retourné
fêter
invitée
incapable
couleurs
sainte
accompagne
demi-heure
camarade
éliminer
détail
thérapie
troupes
froide
signature
pensons
donnée
assistante
éloigner
trahi
adaptation
jeunesse
guérir
officiers
recule
machines
sommet
géant
démons
taper
territoire
organisé
portefeuille
adorer
scénario
emprunter
etes
respecter
marchera
tentative
décès
rappelez
livrer
blessés
donnent
fêtes
pressé
supérieur
précieux
poil
progrès
objectif
bains
officiellement
enculé
difficiles
renvoyer
invitation
allemagne
loyer
plateau
trés
actes
êtres
cinglé
moche
douée
obligée
boit
juifs
travaux
approchez
jolies
expression
cherchait
injuste
trafic
déplacer
exercice
travaillent
forts
épousé
baise
tenait
changera
populaire
descend
ferons
énervé
électrique
devrais-je
furieux
placé
traître
juif
ouah
péché
instinct
remise
allemands
sexuel
excitant
enregistrement
foutez
arrangé
agression
rendez
commandé
ailes
employé
boite
petit-déjeuner
coupez
avons-nous
participer
neveu
activité
coucou
température
bleus
cherchent
bourse
reçois
éternité
poubelle
milliards
vol.
compétition
viol
coté
pouls
laissez-le
illégal
élever
places
autorité
échelle
commission
voleurs
comédie
seules
accueil
premières
autorisé
taule
souffrance
rattraper
demi-tour
transformer
parle-moi
mérites
dégâts
fermée
réception
réservé
annulé
négatif
deviennent
durer
bombes
ivre
avancez
témoigner
langage
chats
poudre
oeuvre
jour-là
influence
méchants
numéros
récupéré
biens
garce
hauteur
revienne
pensiez
crois-tu
déçu
bible
gants
sous-sol
oeufs
pouvons-nous
rumeurs
intérêts
regardais
ministère
témoignage
œufs
effrayant
fouiller
prier
actrice
suspects
soirs
causer
entrepôt
oxygène
inquiètes
conclu
souviens-toi
devras
salade
matinée
amiral
perdus
gagnant
mettent
sachant
opérations
tuera
lâchez
blagues
fauteuil
prises
vampires
apprécier
auteur
tuerai
séparés
pouvaient
bottes
semblerait
foutue
espion
sortent
violent
terroristes
énerve
voudras
serment
unités
restait
viendrai
puisses
pardonne
mères
joueurs
rejoint
taisez-vous
collection
stupides
communication
bizarres
rigole
anges
vague
innocents
laboratoire
soutenir
naturellement
vends
floride
adjoint
trouvait
terroriste
paraître
livraison
jalouse
revenus
diplôme
piégé
ennuyeux
électricité
ignorer
buvez
gâché
trouvés
repris
enregistré
besoins
révolution
passons
valait
connue
commerce
habiller
fichu
renseignements
bêtises
parent
commissariat
tuyau
couvre
convient
adoré
éteint
étude
fenêtres
actuellement
écart
charger
habitants
comté
étudié
rêver
interrompre
liens
plastique
rompre
éteindre
dégoûtant
deviez
minable
égoïste
léger
cigarettes
sœurs
réveillée
culpabilité
adorerais
pourrons
produire
nucléaire
russie
rejoins
descendez
espagnol
volée
vaisseaux
régime
pilules
aïe
empreinte
sain
identifié
évidence
fidèle
trouveras
remède
cimetière
couler
emporter
fâché
exécution
evidemment
devrez
cellules
éléments
autorités
laissera
fierté
vérifiez
travaillais
congrès
détends-toi
pratiquement
enfui
métro
diamants
façons
processus
âmes
lecture
rond
camarades
ressemblait
écraser
caractère
trous
renforts
résister
sous-titres
ressenti
instructions
plaindre
voudrez
exprimer
survie
couches
pourri
esclave
aidez
commencent
stratégie
chasseur
intéressante
guitare
loué
attaché
améliorer
termes
soeurs
vidéos
amant
courte
escalier
bêtes
défi
gentils
rentrons
créatures
chirurgien
montre-moi
changent
souvenez-vous
accent
parlez-vous
personnalité
durs
commandement
crever
espérer
goûter
nerfs
grandir
préférerais
feux
dépassé
tuez
faut-il
passant
rencontrée
méchante
ressentir
déclaré
dessin
généreux
attendons
bourré
officiel
reconnaissance
boisson
embrassé
savaient
commandes
risquer
entendue
excité
rouler
câble
réveil
avère
levé
cuisiner
groupes
envoyée
dépêche
assister
comptez
manières
mangez
équipes
gère
mortel
voies
événements
enterrer
stylo
gamine
homicide
vais-je
laissons
détendre
dis-leur
regardant
correctement
ailles
crée
complexe
accueillir
ongles
criminelle
définitivement
présenté
remarque
désastre
vraies
métal
traverse
italie
laissez-nous
degrés
connaissez-vous
coincée
etats-unis
pardonne-moi
drapeau
raclette
galette
baguette
croissant
crêpe
crepe
crêpes
crepes
soiree
café
cafe
vos
interieur
intérieure
interieure
superieur
inférieur
inferieur
annee
annees
maman
bébé
bebe
sante
beaute
égalité
egalite
fraternité
fraternite
"""
let frenchForceList: Set<String> = Set(frenchForceListRaw.split(separator: "\n").map(String.init))
func isFrenchForced(_ token: String) -> Bool { frenchForceList.contains(token.lowercased()) }
// 法语缩略前缀：s' l' d' n' j' c' m' qu' —— 出现即视为法语特征
func hasFrenchElision(_ token: String) -> Bool {
    let lower = token.lowercased()
    for p in ["s'","l'","d'","n'","j'","c'","m'","qu'","s’","l’","d’","n’","j’","c’","m’","qu’"] {
        if lower.hasPrefix(p) { return true }
    }
    return false
}

// 意大利语特征字符 / 高频词 / 词缀
let italianChars: Set<Character> = ["à","è","é","ì","í","ò","ó","ù","ú",
                                    "À","È","É","Ì","Í","Ò","Ó","Ù","Ú"]
let italianStopwords: Set<String> = [
    "di","del","dei","della","delle","degli","dal","dalla","il","lo","la","le","gli","i",
    "un","uno","una","con","per","che","chi","nel","nella","nei","negli","sul","sulla",
    "e","ed","o","od","ma","se","come","dove","quando","tra","fra","su","da","in","a",
    // 实义高频词（含采样新增）
    "presentano","concerto","concerti","sabato","domenica","lunedì","martedì","mercoledì",
    "giovedì","venerdì","settembre","ottobre","novembre","dicembre","gennaio","febbraio",
    "vite","immagini","manifesto","manifesti","locandina","grafica","grafico","evento",
    "eventi","sagra","sagre","serata","estiva","serigrafia","artigianale","teatro",
    "edizioni","illustrazione","poster","festival","giochi","musicale","progetto",
    "moderna","contemporanea","popolare","romanesca","italiano","italiana","ribellione",
    "velocità","città","società",
    "illustratori","associazione","culturale","stamperia","laboratori","creatività",
    "animazioni","illustrazioni","animazione","artistica","grafica","grafico",
    "tipografico","impaginazione","editoria","mostre","pubblicità","napoletano"
]
// 意大利语典型词缀（含最小词长，避免误伤英文短词）
let italianSuffixes: [String] = ["zione","zioni","ità","sione","ione","ismo","ista",
                                 "iere","mente","ale","ano","ana","etto","etta","esca",
                                 "aggio","ezza",
                                 "atori","azione","azioni","eria","iero","iera","ico","ica"]
func tokenLooksItalian(_ token: String) -> Bool {
    if token.contains(where: { italianChars.contains($0) }) { return true }
    let lower = token.lowercased()
    if italianStopwords.contains(lower) { return true }
    if lower.count >= 6 {
        for suf in italianSuffixes where lower.hasSuffix(suf) { return true }
    }
    return false
}

// 意大利语强制词：命中即高权重判意大利语（不区分大小写），修复意大利语词被误判英语人名/其他语种。
let italianForceListRaw = """
adesso
presto
subito
ancora
sempre
bello
bella
buono
buona
tutto
tutta
tutti
tutte
cosa
cose
molto
bene
male
siracusa
palermo
sicilia
siciliano
siciliana
amore
caro
cara
amico
amica
cuore
vita
mondo
piazza
palazzo
chiesa
duomo
museo
teatro
spettacolo
cultura
sport
feste
settimana
giorno
anno
mio
mia
tuo
tua
suo
sua
noi
voi
loro
nel
nella
nelle
negli
nello
alle
agli
alla
al
del
della
delle
degli
dello
una
uno
non
per
che
chi
come
dove
quando
perché
perche
giornale
rivista
mensile
settimanale
turandot
orfeo
vespri
siciliani
biennale
venezia
giacomo
puccini
giuseppe
verdi
monteverdi
claudio
rossini
donizetti
bellini
vivaldi
boccherini
lei
lui
lo
la
le
li
gli
nessuno
nessuna
eppure
eccola
stesso
stessa
sente
sembra
prenderò
prendero
conferma
profumo
pulito
persona
donna
uomo
cervello
valigia
torino
pelleteria
opinione
richiesta
invadere
inarrestabile
voglio
vorrei
chiesto
concesso
arriva
sicuro
convenzionale
superficiale
sentirsi
essere
tornare
servire
prendere
biglietto
aereo
giorni
mese
cuoio
così
cosi
il
serve
complice
giudice
boccia
brillare
testa
abbastanza
abbia
abbiamo
abbiano
abbiate
accidenti
affinché
ahime
ahimè
alcuna
alcuni
alcuno
allora
altre
altri
altrimenti
altro
altrove
altrui
anche
anni
ansa
anticipo
assai
attesa
attraverso
avanti
avemmo
avendo
avente
aver
avere
averlo
avesse
avessero
avessi
avessimo
aveste
avesti
avete
aveva
avevamo
avevano
avevate
avevi
avevo
avrai
avranno
avrebbe
avrebbero
avrei
avremmo
avremo
avreste
avresti
avrete
avrà
avrò
avuta
avute
avuti
avuto
basta
benissimo
brava
caso
certa
certe
certi
certo
chicchessia
chiunque
ciascuna
ciascuno
cinque
cioe
cioè
circa
citta
città
ciò
codesta
codesti
codesto
cogli
colei
coll
coloro
colui
cominci
comprare
comunque
concernente
conclusione
consecutivi
consecutivo
consiglio
contro
cortesia
dagl
dagli
dall
dalla
dalle
dallo
dappertutto
davanti
degl
dell
detto
devo
dietro
dirimpetto
diventa
diventare
diventato
dopo
doppio
dovra
dovrà
dovunque
dunque
ebbe
ebbero
ebbi
ecco
effettivamente
egli
entrambi
erano
eravamo
eravate
esempio
essendo
esser
essi
faccia
facciamo
facciano
facciate
faccio
facemmo
facendo
facesse
facessero
facessi
facessimo
faceste
facesti
faceva
facevamo
facevano
facevate
facevi
facevo
fanno
farai
faranno
fare
farebbe
farebbero
farei
faremmo
faremo
fareste
faresti
farete
farà
farò
fatto
favore
fece
fecero
feci
finalmente
finche
fine
fino
forse
forza
fossero
fossi
fossimo
fosti
frattempo
fummo
fuori
furono
futuro
generale
giacche
già
gliela
gliele
glieli
glielo
gliene
grazie
gruppo
haha
hanno
ieri
improvviso
indietro
infatti
inoltre
insieme
intanto
intorno
invece
lasciato
lato
lontano
lungo
luogo
macche
magari
maggior
malgrado
malissimo
medesimo
meglio
meno
mentre
mesi
mezzo
miei
mila
miliardi
milioni
minimi
molta
molti
moltissimo
negl
nell
nemmeno
neppure
nessun
niente
nondimeno
nonostante
nonsia
nostra
nostre
nostri
nostro
novanta
nulla
nuovi
nuovo
oggi
ogni
ognuna
ognuno
oltre
oppure
ossia
ottanta
otto
paese
parecchi
parecchie
parecchio
partendo
peccato
peggio
perchè
percio
perciò
perfino
persino
persone
però
piedi
pieno
piglia
piuttosto
più
pochissimo
poiche
possa
possedere
posteriore
posto
potrebbe
preferibilmente
presa
press
prima
primo
probabilmente
promesso
purtroppo
può
qualche
qualcosa
qualcuna
qualcuno
quale
quali
qualunque
quante
quanti
quantunque
quasi
quattro
quella
quelli
quello
quest
questa
queste
questi
questo
quindi
realmente
recente
recentemente
registrazione
relativo
riecco
rispetto
sara
sarai
saranno
sarebbe
sarebbero
sarei
saremmo
saremo
sareste
saresti
sarete
sarà
sarò
scola
scopo
scorso
secondo
seguente
seguito
sembrare
sembrato
sembrava
sembri
senza
sette
siamo
siano
siate
solito
soltanto
sono
sopra
soprattutto
sotto
spesso
stai
stando
stanno
starai
staranno
starebbe
starebbero
starei
staremmo
staremo
stareste
staresti
starete
starà
starò
stata
state
stati
stato
stava
stavamo
stavano
stavate
stavi
stavo
stemmo
stesse
stessero
stessi
stessimo
steste
stesti
stette
stettero
stetti
stia
stiamo
stiano
stiate
successivamente
successivo
sugl
sugli
sull
sulla
sulle
sullo
suoi
tale
tali
talvolta
terzo
titolo
tranne
trenta
triplo
troppo
trovato
tuoi
tuttavia
uguali
ulteriore
vale
vari
varia
varie
vario
verso
vicino
visto
volta
volte
vostra
vostre
vostri
vostro
davvero
vero
vuoi
andare
puoi
lavoro
bisogno
cazzo
vuole
vedere
dobbiamo
dispiace
parlare
possiamo
successo
giusto
aspetta
altra
farlo
ragazzi
appena
soldi
sapere
piace
figlio
accordo
vieni
pensi
stare
ragazza
famiglia
ragazzo
volevo
sentito
ragione
vado
scusa
pensavo
moglie
storia
succede
cercando
dici
dovuto
capisco
venire
polizia
letto
amici
aiuto
paura
fratello
uomini
domani
ucciso
macchina
trovare
vediamo
andato
vedo
neanche
pensato
diavolo
piacere
dovrei
colpa
andata
dovrebbe
vedi
migliore
figlia
dovresti
almeno
quei
passato
minuti
strada
credi
uscire
parlato
stasera
dollari
occhi
possibile
scuola
sapevo
potrei
bambini
riesco
chiama
messo
traduzione
tardi
marito
venuto
spero
ricordi
dovremmo
ascolta
chiamato
parlando
fatta
veramente
entrare
qualsiasi
dicendo
acqua
portato
stanza
problemi
lascia
sentire
voleva
piccola
sacco
capire
potuto
strano
sappiamo
ragazze
genere
attimo
sorella
ufficio
farti
morire
vecchio
domanda
vivere
nuova
ricordo
divertente
sicura
paio
perdere
dimmi
farmi
figli
lavorare
esattamente
esatto
possono
sapete
dottor
parola
cavolo
finita
volete
potresti
gioco
perfetto
mangiare
credere
tratta
chiamo
passare
controllo
affari
spiace
tizio
dammi
sicurezza
vogliono
fuoco
cercare
potremmo
puttana
inizio
voglia
mettere
fammi
uccidere
vogliamo
genitori
sesso
potete
ricevuto
succedendo
ospedale
scritto
smettila
vada
attenzione
bere
situazione
omicidio
revisione
ottimo
provato
lasciare
dicono
prossima
arrivato
capisci
immagino
tieni
oddio
sbagliato
dirmi
venuta
scelta
voluto
portare
assolutamente
molte
chiedo
scoperto
fatti
settimane
dirlo
prigione
giornata
aspettare
parli
arrivare
avvocato
deciso
messaggio
dormire
dieci
stupido
guardare
bagno
tornato
vuol
giù
conosci
verita
restare
chiamare
poter
giovane
signori
provare
saperlo
arrivo
realta
domande
insomma
bambina
capelli
trova
onore
aiutare
verità
funziona
credevo
preoccuparti
cibo
fretta
morti
intenzione
speciale
cambiare
semplice
dirti
riguardo
aspetto
viaggio
chiaro
chiamata
bocca
permesso
piacerebbe
dovete
giocare
ordine
ovviamente
finire
occhio
scusami
mattina
cercato
crede
devono
prossimo
pronti
saputo
scusate
potere
armi
fermo
chiedere
venite
controllare
appuntamento
chiami
vecchia
metti
vanno
iniziato
informazioni
stronzo
pezzo
segreto
colpo
piacciono
vederti
veloce
sapeva
finché
ormai
giusta
tenere
pazzo
vittima
giuro
alcune
semplicemente
specie
sogno
lasci
doveva
brutto
aspetti
incredibile
legge
guardate
cambiato
scena
volevi
lasciami
gentile
fara
zitto
incontro
servono
rapporto
errore
sanno
occhiata
risposta
servizio
usato
schifo
dolore
personale
saro
addio
addosso
dovevo
poteva
diverso
vestiti
sparato
realtà
programma
sappia
migliori
notizie
riesci
posizione
rimanere
compagnia
ricorda
arrivando
chiuso
terribile
ritardo
attento
dimenticato
bisogna
impossibile
conosce
uscita
vattene
guai
manca
esserci
tanti
chiave
coraggio
guardi
rubato
compleanno
potrebbero
relazione
spalle
seconda
qualcun
diritto
sicuramente
appartamento
pranzo
denaro
riuscito
continuare
serata
vestito
dottoressa
potevo
iniziare
lavora
conosciuto
intendo
negozio
trovo
aspettando
partita
spazio
andra
notizia
tempi
riguarda
soli
parliamo
poliziotto
scappare
vinto
tranquillo
silenzio
andati
simile
pezzi
ricerca
aspettate
esiste
scoprire
diceva
lettera
salvare
canzone
vengono
pubblico
sentite
rimasto
lavorando
scherzando
stamattina
missione
scelto
stupida
aiutarti
contatto
pericolo
parlo
freddo
esercito
ultimi
trovi
possibilita
intendi
buonanotte
caccia
arrivata
lavori
regole
dovrai
secondi
ballo
ascoltami
ovunque
arrivati
bellissima
cucina
decisione
tornata
incontrato
occasione
stanotte
porti
possibilità
cellulare
necessario
ferma
borsa
prometto
palle
nonno
piena
attacco
affatto
colpito
salvato
siediti
parlarne
diciamo
brutta
braccio
fermati
crimine
andrà
effetti
sapevi
scrivere
scommetto
paziente
scarpe
livello
fermi
lunga
mentito
alcun
precedenti
direttore
comprato
scorsa
farla
tavolo
stagione
dannazione
cavallo
sergente
incinta
rotto
aiuti
rispondere
conoscere
inglese
volo
riesce
differenza
apri
passi
uscito
codice
maggiore
uniti
trovata
eccolo
lavorato
umano
miglior
pagato
vorrebbe
leggere
pomeriggio
documenti
destra
ringrazio
pericoloso
buone
affare
figliolo
ordini
caffè
maledizione
vederlo
lezione
intero
partire
venuti
sogni
chiedendo
pensate
parlarti
congratulazioni
sposato
treno
comune
cattivo
imparato
smettere
ottima
aiutarmi
intera
responsabile
lascio
farcela
agenti
pochi
clienti
segno
mangiato
calmati
chiudi
posti
bellissimo
quegli
dovrebbero
speranza
rischio
caffe
combattere
tocca
operazione
pazza
ufficiale
vorresti
vincere
gambe
farle
nascosto
benvenuto
offerta
scherzo
testimone
fratelli
aprire
potesse
stronzate
indirizzo
ottenere
potessi
esperienza
portata
messa
piangere
segreti
lasciate
andremo
uccisa
darmi
torni
pianeta
darti
esci
vittime
diversi
guida
prezzo
strana
arrabbiato
vecchi
verrà
orribile
gesu
ritorno
entrato
animali
metto
passaggio
imparare
progetto
colpevole
ragazzino
metri
chiavi
finestra
suppongo
saltare
correre
frega
colazione
collo
difesa
diro
vicini
fiducia
aiutato
avermi
saprei
ristorante
scegliere
chiedi
discorso
avra
segnale
perfetta
fortunato
libri
carriera
cominciare
proteggere
dubbio
dati
stazione
emergenza
giustizia
immediatamente
odore
umani
ascolti
preoccupare
battaglia
aiutarla
notato
chiamate
sceriffo
sembrano
evitare
spirito
seduto
dipartimento
controllato
riunione
rumore
guardami
dirò
accanto
eroe
piccoli
entrambe
dovremo
potrai
londra
vedrai
punti
fiori
vederla
ovvio
furgone
coppia
ridere
inizia
vedete
dovevi
aiutami
tranquilla
naso
nemico
mangia
chiudere
felici
colonnello
palla
giovani
nuove
laggiù
scatola
torniamo
albero
tribunale
razza
anello
piede
ferita
ferito
cerchi
preoccupato
sentimenti
averla
soldato
cominciato
prendiamo
colore
basso
anzi
storie
digli
preferito
dirle
cattiva
cani
sparare
parigi
chiamano
ascoltare
decidere
professore
fidanzato
sensazione
andartene
compito
stronza
provi
pesce
pensano
obiettivo
incontrare
visti
accesso
risolvere
povero
stavolta
affrontare
poliziotti
buoni
ballare
resti
funzionato
sbaglio
giochi
continui
fianco
alzati
accettare
metà
piaciuto
corsa
entrata
soluzione
fanculo
contratto
arrabbiata
fermare
meraviglioso
guidare
denti
mandare
fidati
sveglia
creato
prendermi
dipende
coltello
effetto
procuratore
ricordare
smesso
vendere
pantaloni
azione
cadavere
chiusa
nipote
andro
soldati
finisce
riuscita
troveremo
stampa
debole
risultati
ridicolo
vaffanculo
andarci
dirtelo
gesù
francese
chiederti
sottotitoli
creare
peggiore
bevuto
rimasta
angolo
buio
malattia
gatto
suona
troviamo
scomparsa
fargli
risposto
condizioni
muoviti
fiume
schiena
sindaco
reso
campagna
andrai
tenuto
cerchiamo
coglione
dettagli
chiaramente
rispondi
capace
distrutto
forze
importanza
debba
importanti
particolare
stanco
piani
mantenere
piaceva
insegnato
faccenda
immaginare
dimenticare
matto
convinto
rovinato
campione
buonasera
braccia
laggiu
decisamente
momenti
sbagliata
andrò
pensarci
mercato
valore
sbrigati
salire
riuscire
spiegare
principessa
avro
attenta
zitta
bellezza
prendete
morendo
rilassati
buco
conversazione
speravo
pensiero
rimane
benvenuti
conoscenza
malato
sedia
vedremo
omicidi
impronte
sistemare
pensiamo
succedere
ghiaccio
tracce
bottiglia
accettato
indagine
passata
fottuto
cadere
sguardo
perdita
milione
camminare
eccoci
americani
primi
villaggio
scuse
trovarlo
potevi
preferisco
scusatemi
ispettore
chiamami
dovere
parco
privato
dovreste
troia
chiede
volessi
preoccupata
aspettavo
prenderti
accusa
crederci
direttamente
aiuta
esserlo
fidanzata
andarmene
terza
desiderio
preoccupi
mentendo
ubriaco
tradurre
popolo
infermiera
altezza
seduta
minaccia
età
controlla
nazionale
caduto
passati
tetto
voci
suono
copertura
conosciamo
vissuto
piaci
lettere
occupato
sposata
numeri
diamo
credimi
compagno
merito
società
spada
vedermi
scendere
pazienti
dirgli
leggi
sentita
diventata
perfettamente
ragazzina
bicchiere
dargli
vuoto
azienda
sabato
spiaggia
ordinato
rotta
dovesse
telefonata
lasciamo
entri
mezza
innamorato
doccia
guardato
stanca
arrestato
esce
venduto
gara
comincia
orologio
erba
viso
bevi
metta
ascoltate
distanza
maledetto
chiamarmi
esame
uccidermi
andarsene
sposa
partito
lascialo
strade
cappello
giardino
intendevo
testimoni
nera
taglio
velocemente
potrà
muore
segni
paradiso
rabbia
biglietti
toccare
collega
assurdo
dimmelo
insegnante
spaventato
naturale
vicina
coinvolto
immagini
umana
amiche
girare
libertà
rubare
venendo
immagine
conoscerti
tantissimo
allarme
militare
padrone
prenderlo
arrivano
azioni
sveglio
potremo
preparato
direzione
cantare
distruggere
lasciata
funzionare
invitato
regola
servizi
ruolo
cavalli
mattino
funerale
ospiti
venti
ottenuto
intende
domenica
tette
sig.
vorrà
spia
rimani
dritto
presenza
succedera
offerto
atto
apprezzo
discutere
mentire
gestire
chilometri
migliaia
lasciarmi
volevano
guardati
domattina
lasciatemi
pensavi
vacanza
nemici
speriamo
scappato
informazione
sposare
andarcene
accaduto
violenza
articolo
crescere
suonare
forti
caduta
presi
parlarle
cugino
messaggi
famiglie
povera
sentivo
sospetto
guardie
trappola
attenti
diventando
criminale
giacca
unita
rossa
dormito
scomparso
modi
entrate
commesso
pugno
chiamava
cresciuto
mettiamo
ossa
carico
fermato
sopravvivere
studenti
battuta
profondo
arrivi
cella
finora
macchine
risposte
piccole
mostri
percento
vorra
colpi
amicizia
diritti
protezione
disturbo
assieme
dicevo
diretto
pane
scusarmi
creduto
risponde
dirci
disastro
uova
tirato
sedere
veri
preparare
versione
costruire
rete
potra
puzza
sposati
crisi
dirmelo
raggiungere
traccia
inghilterra
albergo
tornate
dirglielo
ucciderlo
polvere
gioia
fucile
maniera
sessuale
orecchie
privata
tentativo
sicuri
sentirmi
aspettiamo
svegliati
parlano
scherzi
trucco
trovate
dovevamo
nascondere
aiutarci
succederà
rendere
urla
aspettato
dovessi
ambulanza
superiore
volare
mancato
errori
proprietario
piaccia
raccontato
ospite
dovro
dovrò
dillo
poteri
fatemi
telecamere
bravi
regno
volevamo
stomaco
membri
licenziato
preferirei
tirare
chiedevo
analisi
muoversi
merita
volesse
capita
farvi
credete
sissignore
dannato
assicuro
abbandonato
scale
attorno
darò
smetterla
corpi
sospettato
mettendo
cinese
verranno
imbarazzante
mancano
studiare
divano
risultato
societa
bloccato
tornati
scrivania
complicato
tolto
desideri
traffico
eccoti
prestito
potreste
chissà
sentiamo
lavorava
ferite
proiettile
motore
specialmente
lontana
riuscivo
mettiti
lasciati
piatto
rapporti
cazzate
affascinante
simili
prenderla
bugie
prese
sterline
trovarmi
esplosione
ricerche
ascolto
riusciamo
ladro
spaventata
compagni
facciamolo
tentato
sorpreso
pioggia
debito
occhiali
conoscete
taglia
resynch
pietra
uccello
maiale
dubito
parcheggio
serviva
camicia
montagna
respirare
uccisi
seguendo
costruito
formaggio
sparo
uscite
sapessi
diretta
averne
spazzatura
divorzio
innamorata
tagliato
possano
fatte
tazza
agenzia
intervento
creda
mucchio
permettere
rimasti
puntate
pensieri
soccorso
giuria
modello
darci
giornali
ricordate
portate
tavola
trovarla
carica
pensione
sorveglianza
dichiarazione
costretto
smetti
neri
portarlo
bugia
mettermi
centinaia
affitto
appartiene
idioti
bugiardo
governatore
riusciti
venne
daro
farne
impressione
strega
malata
dimostrare
tradito
veniva
impegnato
interessi
vorrai
speciali
portarti
ragioni
gelato
spara
metterti
vergogna
adorabile
iniziamo
castello
pazienza
organizzato
sonno
trovati
colleghi
toccato
malapena
conoscerla
maschio
ascoltando
mostrato
festeggiare
indovinare
liberi
attaccato
togliere
risolto
sporco
passate
sentirti
voti
complimenti
miracolo
vicenda
meriti
volere
troppe
lezioni
giocando
cercavo
parlava
nazione
argomento
sbagli
pillole
firmato
telecamera
auguri
stupidi
abito
uguale
preoccupa
meravigliosa
ginocchio
alberi
veloci
familiare
interessato
troppi
muovetevi
andiamocene
diamine
sparire
onesto
fuggire
portami
università
fortunata
usciamo
stara
provarci
patto
ovest
magazzino
commissione
bastardi
vantaggio
spese
mezzanotte
contanti
avvocati
caspita
fallito
indossare
occupo
pensaci
rendi
andrebbe
saltato
fondi
firmare
incubo
babbo
fattoria
presenti
senatore
conosciuti
secolo
corridoio
bersaglio
parlarmi
vedono
sorelle
superare
esistono
eccellente
muoverti
stammi
sopportare
sparito
probabile
lasciala
credono
riposo
indovina
muovere
buttato
maestà
episodi
troverai
scappa
calmi
riposare
vendita
togliti
criminali
carcere
legame
mancanza
materiale
superato
passeggiata
impazzire
lasciarlo
opportunità
causato
lasciarti
follia
attività
dirvi
messi
trovarti
divertiti
unità
personali
supporto
tratti
medicine
giornalista
scala
aiutarvi
opportunita
scienza
rompere
scendi
sembro
uccide
rischi
conseguenze
passione
cercate
essermi
coscienza
discussione
beccato
profilo
vorremmo
compiti
esca
attivita
assicurazione
foresta
ucciderti
mappa
lieto
manchi
ripeto
portarla
trattato
gioca
figurati
fabbrica
federale
cieco
responsabilità
messico
lancio
motivi
assegno
tornerà
tizi
dicessi
conosceva
sufficiente
calci
istante
amare
lasciar
sorta
ammettere
retta
pulire
uscendo
tempesta
chiamiamo
trovano
difficili
crediamo
maschera
visione
cominciamo
reazione
cattivi
dormendo
eccomi
regali
sapesse
oggetto
vivono
esco
vederci
sfortunatamente
contatti
prendono
sezione
onestamente
segreta
ascensore
miglia
rifugio
spalla
rischiare
coincidenza
portarmi
alcol
ricevere
inventato
impegno
brutte
zucchero
chiedermi
giudizio
spari
pochino
personaggio
lacrime
esami
conoscevo
crimini
scemo
usata
pazzesco
benzina
dissi
creatura
fumare
pulita
raccontare
fidi
capite
canzoni
spiegazione
lascero
proviamo
confine
propri
significato
letteralmente
oggetti
ione
televisione
struttura
accusato
disgustoso
specchio
venerdi
butta
perdonami
dosso
cambiamento
svegliato
proprieta
venisse
reputazione
partenza
punizione
organizzare
portiamo
uccelli
influenza
tedesco
dodici
nascita
scambio
distretto
incontri
direbbe
inviato
universita
piacevole
tagliare
chiederle
cioccolato
farli
seduti
preferita
rovinare
decisioni
talmente
urlare
dolcezza
pubblica
esserne
desidera
ricchi
soffrire
labbra
controlli
stronzi
mangi
superiori
potrò
risorse
tornerò
settore
portano
veleno
ufficialmente
continuate
proprietà
spiega
adulti
aprite
studi
offesa
legato
metterci
incontrati
incarico
ricominciare
troppa
agio
maglietta
orgoglioso
impazzito
recuperare
organizzazione
emozioni
esplodere
biscotti
guadagnare
attore
vecchie
aiutatemi
sigaretta
grasso
gradi
umore
rapito
ragazzini
parlargli
accada
levati
convincere
condividere
consegna
finiti
relazioni
colpire
legno
eventi
cercava
dolci
abiti
studente
dottori
aiutarlo
poveri
divertendo
raggio
scientifica
raggiunto
resistenza
partecipare
disponibile
estremamente
aspettano
richiamo
agire
fegato
stretto
pessima
imbarazzo
sfida
aiutando
fermata
prenderemo
indagini
professionale
fredda
adatto
dille
strane
potevamo
droghe
sieda
grida
orso
darsi
istinto
dubbi
lascerò
tornera
chiacchiere
scoprirlo
maledetta
ringraziamento
ricordati
fantasmi
staro
blocco
considerato
dovrete
inizi
splendida
dovuta
diventi
cammina
alti
progetti
ammazzo
prodotto
pensavamo
fingere
prendilo
succeda
circostanze
lassù
benvenuta
presentato
aperti
crudele
becco
parleremo
esseri
delitto
febbre
averci
spinto
armadio
battere
olio
mutande
professionista
arriviamo
rinforzi
notti
parlate
capirlo
cina
aggressione
mangio
vetro
sistemato
racconti
stupendo
elicottero
consigli
mistero
cadaveri
nastro
datemi
resistere
giocato
penna
prenditi
cameriera
dannata
viviamo
condizione
assassini
fortunati
poterlo
prendersi
offro
cresciuta
tornero
smettetela
coda
fidarti
rifiutato
funzioni
corretto
tratto
rivederti
cassetta
improvvisamente
chieda
sottofondo
sistemi
mettono
russi
splendido
giri
lontani
tedeschi
normali
litigare
percorso
battute
confronti
prigionieri
germania
puttane
giovanotto
velocità
orario
scappata
deluso
ditemi
federali
saggio
sposarmi
miele
fregato
conferenza
straordinario
sciocco
prigioniero
finto
noioso
accetto
trasferito
piantala
segretario
demone
bevo
sciocchezze
buffo
tenuta
occupata
cucinare
pericolosa
eroina
scritta
fiamme
chiamarti
sapevamo
studiato
orecchio
campi
assicurati
innocenti
fermarlo
parenti
ascoltato
figlie
ritornare
responsabilita
preoccuparsi
richiesto
servito
disposizione
mettilo
pesci
bassa
raccogliere
combattimento
bruciato
morso
usano
piatti
incastrato
vasca
contea
fottuta
stronzata
arrabbiare
limiti
entriamo
simpatico
portati
delizioso
fottiti
coraggioso
ricordato
registrato
assicurarmi
cittadini
potenza
onesta
canale
tramite
mezzi
lasciarla
salutare
vuota
preferisci
dirà
apre
sconosciuto
ebbene
stanze
argento
geloso
incantesimo
maesta
arriverà
colloquio
udienza
inglesi
dicevi
presentare
tappeto
eccitante
accadere
cognome
dacci
conosciuta
lavorano
esistenza
furbo
giocatore
lasciando
chiamando
novità
soggetto
chissa
chiamarlo
muove
cattive
troverò
appassiona
vedevo
passiamo
pessimo
credeva
prossimi
uccido
trovero
amano
equipaggio
cassa
diglielo
tenete
essersi
zuppa
metterlo
lottare
immaginavo
matematica
orgoglio
volontà
succo
restate
patatine
scelte
lavoriamo
traditore
ebrei
sigarette
andranno
guardarmi
procedura
cavo
offrire
collegamento
aggiungere
immaginato
peggiori
quindici
annuncio
panino
attraente
sospetti
tradimento
accorto
cartello
ripreso
divisione
pancia
veicolo
raccolto
rinunciare
proiettili
autorità
vergine
ubriaca
litigato
usciti
vacanze
dopotutto
conoscono
meraviglia
fatelo
arrestare
colori
auguro
infanzia
scegli
gabbia
sognato
cambiata
bambine
avventura
vorranno
intervista
fidarmi
resa
pianto
nascosta
attacchi
appunto
piange
combinato
gioielli
tornerai
fiato
sabbia
gatti
locali
possesso
capitolo
scrive
piangendo
notare
indossa
vampiri
giapponese
frutta
viveva
mettete
spagnolo
apposta
ufficiali
nascondendo
istruzioni
volentieri
continuiamo
girato
felicità
comincio
nozze
giurato
chiusi
farmaci
novita
picchiato
uccidendo
sospeso
pacco
riserva
coperta
cammino
incredibilmente
concentrati
strani
leggenda
amavo
eccezionale
telefilm
identita
busta
femminile
occupa
alzare
catturato
scopare
scorta
cancello
riprendere
chiamarla
viaggiare
richiede
ipotesi
battuto
giudicare
preparati
spetta
bibbia
potevano
perdonare
confessione
singolo
persi
piaccio
sapevano
venerdì
mettersi
produzione
abbandonare
ringraziare
programmi
scrittore
velocita
addirittura
intenzioni
riescono
veniamo
croce
calore
riesca
buttare
darà
nobile
sposo
spieghi
impegnata
funzionano
confermato
torneremo
muori
elezioni
bagagli
successa
minacciato
creature
attrice
scrivi
campioni
militari
plastica
verrò
giappone
finestre
riconosciuto
espressione
sapore
potessimo
versi
tocco
conosca
disagio
parlami
disegno
spostati
fatica
saluti
dritta
cancellato
esagerato
impero
immagina
scimmia
dimentica
servirà
andatevene
secoli
catena
femmina
racconto
coglioni
fermarmi
ruota
spiegato
rifiuto
battito
ammazzare
civili
flotta
uccidi
rivedere
spostare
imbecille
attaccare
allenamento
paghi
sodo
massima
casini
ossigeno
affetto
convinta
colpita
buca
combattuto
questioni
testimoniare
dispiacerebbe
fermarti
ladri
rimanga
riportato
indizio
spezzato
sessuali
tiri
"""
let italianForceList: Set<String> = Set(italianForceListRaw.split(separator: "\n").map(String.init))
func isItalianForced(_ token: String) -> Bool { italianForceList.contains(token.lowercased()) }
// 意大利语 L' 省音前缀（如 L'ORFEO / L'Elisir）：命中即视为意大利语特征，优先于法语省音
func hasItalianElision(_ token: String) -> Bool {
    let lower = token.lowercased()
    for p in ["l'", "l’", "dell'", "dell’", "all'", "all’", "nell'", "nell’", "sull'", "sull’", "un'", "un’"] {
        if lower.hasPrefix(p) {
            let rest = String(lower.dropFirst(p.count))
            // L'ORFEO / L'Elisir 等：去掉省音前缀后是意大利语强制词或意语形态 → 判意语
            if !rest.isEmpty && (italianForceList.contains(rest) || tokenLooksItalian(rest)) { return true }
        }
    }
    return false
}

// ============================================================
// MARK: - 越南语识别（独有字符权重最高）
// ============================================================
// 越南语独有字符（带下点/角标/特殊字母），出现即可判越南语。
// 注意：ê ô â ç 等与葡/意/法共享，不放入独有集，避免误判。
let vietnameseDistinctChars: Set<Character> = [
    "đ","Đ","ă","Ă","ơ","Ơ","ư","Ư",
    "ạ","ả","ấ","ầ","ẩ","ẫ","ậ","ắ","ằ","ẳ","ẵ","ặ",
    "ẹ","ẻ","ẽ","ế","ề","ể","ễ","ệ",
    "ỉ","ị","ọ","ỏ","ố","ồ","ổ","ỗ","ộ","ớ","ờ","ở","ỡ","ợ",
    "ụ","ủ","ứ","ừ","ử","ữ","ự","ỳ","ỵ","ỷ","ỹ","ý",
    "Ạ","Ả","Ấ","Ầ","Ậ","Ắ","Ặ","Ẹ","Ẻ","Ế","Ề","Ệ","Ị","Ọ","Ố","Ồ","Ộ","Ớ","Ờ","Ợ","Ụ","Ứ","Ừ","Ự"
]
func hasVietnameseChar(_ token: String) -> Bool {
    token.contains { vietnameseDistinctChars.contains($0) }
}
let vietnameseStopwords: Set<String> = [
    "và","của","trong","với","cho","được","thi","vẽ","đi","dừng","nước","thanh","toán",
    "học","sinh","tuổi","thời","gian","nhận","cuộc","chủ","đề","yêu","cầu","đối","tượng",
    "dự","gọi","lại","chậm","là","các","một","người","ngày","năm","hội","nhạc","đêm",
    "triển","lãm","văn","hóa","nghệ","thuật","mỹ","nhiếp","ảnh","kiến","trúc","thiết","kế",
    "đồ","họa","minh","họa","cổ","phục","nhà","hàng","tạp","chí","bìa","sức","khỏe",
    "tuyên","truyền","khoa","hướng","dẫn","giáo","dục","sự","kiện","lễ","áp","phích",
    "mùa","xuân","công","viên","bách","hoa","bộ","hành","tháng","năm","ngày",
    "thành","phố","nhà","ga","đường"
]
func tokenLooksVietnamese(_ token: String) -> Bool {
    if hasVietnameseChar(token) { return true }
    return vietnameseStopwords.contains(token.lowercased())
}

// 越南语无变音符高频词：单独出现不强判，仅在块内已有越南语特征字符时 +2（上下文加权）
let vietnameseWeakWords: Set<String> = [
    "trong","trang","sang","hang","bang","ban","lan","can","van","tan","con","cho",
    "chi","nha","bac","nam","son","long","pho","dong","tien","thai","dinh","ha"
]
// 法语/葡语/意语共用重音字符（用于法语上下文加权判定）
let sharedRomanceAccents: Set<Character> = ["è","é","ê","â","ô","î","û","ç","œ","à",
                                            "È","É","Ê","Â","Ô","Î","Û","Ç","Œ","À"]

// ============================================================
// MARK: - 葡萄牙语识别
// ============================================================
// 葡语较独有：ã õ（鼻化），命中权重高；â ê ô ç 与法/意共享，权重普通。
let portugueseDistinctChars: Set<Character> = ["ã","õ","Ã","Õ"]
let portugueseSharedChars: Set<Character> = ["â","ê","ô","ç","á","é","í","ó","ú","à","Â","Ê","Ô","Ç","Á","É","Í","Ó","Ú","À"]
let portugueseStopwords: Set<String> = [
    "de","do","da","dos","das","em","no","na","nos","nas","um","uma","uns","umas",
    "que","para","com","por","ao","aos","à","às","onde","como","mais","muito","não",
    "ganham","sonhos","festa","feira","feiras","cartaz","cartazes","tipografia",
    "artesanato","prefeitura","secretaria","escola","colégio","união","teatro",
    "internacional","nacional","académica","academica","estúdio","estudio"
]
// 葡语强制词：月份 + 标志词（命中即判葡语，不区分大小写）
let portugueseForceListRaw = """
aniversário
aniversario
janeiro
fevereiro
março
marco
abril
maio
junho
julho
agosto
setembro
outubro
novembro
dezembro
dez
coração
informação
edição
copa
virada
futebol
esporte
uma
era
nova
digital
obrigado
português
portugues
acerca
adeus
agora
ainda
alem
algmas
algumas
alguns
além
ambas
anos
aonde
apoio
apontar
apos
após
aquela
aquelas
aquele
aqueles
aquilo
assim
através
atrás
até
baixo
boas
bons
caminho
catorze
cedo
certamente
certeza
coisa
comprido
conhecido
conselho
contudo
corrente
cuja
cujas
cujo
cujos
custa
daquela
daquelas
daquele
daqueles
debaixo
dela
delas
dele
deles
demais
depois
desligado
dessa
dessas
desse
desses
desta
destas
deste
destes
devem
deverá
dezanove
dezasseis
dezassete
dezoito
diante
direita
dispoe
dispoem
diversa
diversas
diversos
dizem
dizer
dois
doze
duas
dão
dúvida
elas
eles
embora
enquanto
entao
então
eram
essa
essas
esses
estava
estavam
esteja
estejam
estejamos
estes
esteve
estive
estivemos
estiver
estivera
estiveram
estiverem
estivermos
estivesse
estivessem
estiveste
estivestes
estivéramos
estivéssemos
estou
estávamos
estão
exemplo
falta
fará
favor
fazeis
fazem
fazemos
fazer
fazes
fazia
faço
fomos
fora
foram
forem
forma
formos
fossem
fostes
fôramos
fôssemos
geral
grupo
haja
hajam
hajamos
havemos
havia
hoje
hora
houve
houvemos
houver
houvera
houveram
houverei
houverem
houveremos
houveria
houveriam
houvermos
houverá
houverão
houveríamos
houvesse
houvessem
houvéramos
houvéssemos
hão
iniciar
inicio
irá
isso
ista
iste
isto
lhes
ligado
local
logo
longe
maior
maioria
maiorias
meio
menor
meses
mesma
mesmas
mesmo
mesmos
meus
minha
minhas
muito
muitos
máximo
mês
naquela
naquelas
naquele
naqueles
nenhuma
nessa
nessas
nesse
nesses
nesta
nestas
neste
nestes
noite
nossa
nossas
nosso
nossos
novas
novo
novos
numa
numas
nuns
não
nível
nós
número
obra
obrigada
oitava
oitavo
oito
onde
ontem
outra
outras
outro
outros
paucas
pegar
pela
pelas
pelo
pelos
perante
perto
pessoas
pode
podem
poderá
podia
pois
ponto
pontos
porquê
portanto
posição
possivelmente
posso
possível
pouca
pouco
poucos
povo
primeira
primeiras
primeiro
primeiros
promeiro
própria
próprias
próprio
próprios
próxima
próximas
puderam
pôde
põe
põem
quais
qual
qualquer
quarta
quatro
quem
quer
quereis
querem
queremas
queres
quero
questão
quieto
quinta
quáis
quê
relação
sabem
seja
sejam
sejamos
sendo
serei
seria
seriam
serão
sete
seus
sexta
sexto
sistema
somente
suas
são
sétima
sétimo
talvez
tambem
também
tanta
tantas
temos
tendes
tenha
tenham
tenhamos
tenho
tens
tentar
tentaram
tentei
terceira
terceiro
terei
teremos
teria
teriam
terá
terão
teríamos
teus
teve
tinha
tinham
tipo
tive
tivemos
tiver
tivera
tiveram
tiverem
tivermos
tivesse
tivessem
tiveste
tivestes
tivéramos
tivéssemos
trabalhar
trabalho
treze
três
tuas
tudo
tão
tém
têm
tínhamos
umas
veja
vens
verdade
verdadeiro
vezes
viagem
vindo
vinte
você
vocês
vossa
vossas
vosso
vossos
vários
vão
vêm
vós
zero
área
acho
falar
melhor
mãe
olá
alguém
alguma
coisas
homem
ficar
ninguém
dinheiro
disso
desculpa
mulher
filho
olha
daqui
sério
sair
aconteceu
voltar
pensei
algum
achas
razão
ideia
gosto
homens
devia
pessoa
cabeça
ajudar
cidade
deixar
nenhum
chegar
quase
desculpe
amanhã
história
irmão
morrer
maneira
ajuda
medo
sinto
ouvir
acontecer
rapaz
feito
filha
acha
pessoal
olhos
senhora
disto
manhã
mãos
água
começar
acredito
acabou
disseste
nisso
chefe
jogo
fala
fizeste
ouve
deixa-me
escola
pára
equipa
rapariga
segurança
viver
muitas
mão
ouvi
vejo
mulheres
morreu
acordo
capitão
raio
poderia
crianças
força
filhos
irmã
chega
devias
rapazes
olhar
estavas
faça
estranho
muita
veio
prazer
velho
passado
jantar
dá-me
pergunta
descobrir
deixa
menina
casamento
gostava
sozinho
sequer
ficou
conheço
gosta
passou
provavelmente
palavra
licença
consegues
acreditar
pior
diz-me
gostaria
prisão
livro
oportunidade
chegou
sítio
fazê-lo
raios
atenção
quis
direito
venha
criança
haver
pôr
fogo
connosco
ganhar
milhões
manter
olhe
encontrei
miúda
arranjar
miúdo
tinhas
vês
acontece
jovem
situação
jogar
perguntas
cão
quiseres
negócio
quiser
nisto
sinal
mensagem
apanhar
banho
deves
chamada
novamente
começou
perguntar
notícias
acabei
fique
chamar
entendo
cabelo
doutor
vontade
sozinha
fugir
palavras
devíamos
gostas
lutar
escritório
peço
deixou
chão
perfeito
respeito
deveria
melhores
devemos
fiquei
mortos
faria
emprego
achei
faças
chama
linha
dizes
lembras-te
cala-te
graças
escolha
ordem
fundo
doente
acidente
provas
resposta
avião
deixe-me
acredita
miúdos
idade
fizeram
percebo
saiu
advogado
conhece
espaço
serviço
missão
louco
conhecer
perceber
amo-te
simplesmente
caixa
senhores
gostar
incrível
vai-te
loja
vítima
roupa
trouxe
luta
câmara
disse-me
fome
mamã
hipótese
telemóvel
reunião
percebi
trazer
olho
chamado
conseguiu
exército
deixe
disseram
tempos
soube
tenhas
quantos
creio
sonho
ver-te
fizemos
teres
vê-lo
diabo
parabéns
aposto
tradução
sinto-me
esperem
voltou
namorada
precisam
metade
impossível
lembro
desapareceu
cair
engraçado
chave
ouviste
escrever
piada
levou
passada
daí
segredo
decisão
surpresa
céu
negócios
receber
imediatamente
olhem
começa
ótimo
trabalha
falei
cheio
companhia
ouça
sejas
horrível
escuta
saída
namorado
senhoras
fazendo
encontrou
quente
esquece
saia
ouro
perigo
falou
raparigas
pés
velha
esquerda
avó
näo
pudesse
vejam
lidar
regras
homicídio
precisava
gajo
igreja
conheces
compreendo
quantas
sente-se
abaixo
desculpem
liberdade
cavalo
parem
espécie
cérebro
venham
belo
esquecer
contrário
cerveja
experiência
diferença
animais
tentou
lembro-me
esperança
iorque
saúde
perigoso
conheci
ideias
irei
acham
informações
roubar
dançar
suspeito
passei
senta-te
suposto
bater
rainha
aceitar
clube
dizer-me
perdeu
apesar
parece-me
disse-te
investigação
saiam
janela
realidade
prontos
entrou
provar
avô
ligação
meia
dizer-te
seguinte
menino
chama-se
afinal
calhar
loucura
disse-lhe
termos
diga-me
meninas
terrível
dar-lhe
ficas
chorar
céus
contas
ouviu
parecem
jeito
odeio
início
televisão
suponho
responsável
irmãos
percebes
acima
pediu
foda-se
esperava
almoço
xerife
cartão
estarei
cozinha
dizer-lhe
deixei
operação
preço
pele
existem
diabos
chá
vinho
lixo
mudou
relatório
necessário
imenso
nomes
defesa
laboratório
maravilhoso
dizia
ilha
opinião
acesso
braço
lembrar
desejo
correu
senão
nela
comboio
roupas
sonhos
pernas
livros
saiba
falamos
saudades
rádio
traz
silêncio
peça
escolher
cheia
limpar
ficam
carrinha
verão
direcção
justiça
costumava
foder
memória
calças
graça
façam
verdadeira
comum
confiança
estação
pressão
sapatos
inimigo
ligou
diz-lhe
várias
deviam
espírito
inteiro
maluco
bem-vindo
cheguei
apareceu
universidade
dentes
porcaria
noites
vermelho
quão
conseguia
viram
buraco
sucesso
queira
ajudá-lo
conduzir
parede
cheiro
herói
inglês
devagar
troca
batalha
férias
emergência
coragem
vergonha
caiu
longa
estrela
achar
acção
tido
juiz
perna
desculpas
edifício
vieste
terem
pescoço
fiquem
casaco
monstro
chaves
gostei
começo
irão
falando
parceiro
ajuda-me
estranha
histórias
devido
ajudar-te
encontraram
falas
serem
fale
vê-la
dê-me
vítimas
natureza
vieram
miúdas
chamo-me
haverá
prefiro
faca
matei
grávida
exatamente
tamanho
voar
carreira
limpo
velhos
porreiro
gostam
árvore
possamos
milhares
distância
conseguem
antigo
brilhante
dança
chamas
pedra
conhecemos
pensam
faculdade
imagem
majestade
caralho
comecei
doença
julgamento
sobreviver
polícias
preto
cadeira
peixe
louca
recebi
jovens
visão
dar-te
felizes
testemunha
fechar
deixes
queiras
jogos
cães
canção
deixado
notícia
perdão
barulho
estrelas
velocidade
ameaça
dar-me
vemo-nos
relógio
entanto
unidade
braços
regressar
baixa
forças
floresta
confusão
praia
acreditas
encontrámos
língua
matá-lo
sinais
descobri
perfeita
ficará
ficamos
cabrão
ouvido
receio
atirar
rosto
mudança
corpos
sentimentos
navio
soubesse
faz-me
cavalos
íamos
fugiu
tivesses
beleza
morre
mandou
magoar
agradável
vou-me
óbvio
pensou
jornal
profissional
anel
inteira
levanta-te
estejas
luzes
indo
descer
agradeço
podiam
aberta
milhão
escuro
ruas
antiga
tê-lo
cadeia
crescer
ouçam
imprensa
noiva
acorda
ajudar-me
pequenos
venho
descobriu
disser
camião
feita
segredos
solução
ouvidos
beijo
pessoalmente
andam
morreram
conhecia
garrafa
orgulho
fizer
propriedade
maiores
sensação
peito
levá-lo
bilhete
voltei
táxi
registos
boleia
matar-me
chapéu
mexer
deu-me
vingança
dever
ajude
dá-lhe
doido
raiva
lembra-te
treino
algures
foi-se
estudar
responsabilidade
esqueça
maldição
inimigos
viemos
meninos
queriam
acontecido
acalma-te
apanhado
chegaram
ouve-me
convosco
apresentar
roubou
esqueci-me
terás
lixar
serviços
frança
bocadinho
interessado
sacana
respostas
secretária
contou
efeito
aconteça
enfermeira
patrão
ouvir-me
conhecimento
ficaria
aguentar
dera
aldeia
razões
cirurgia
aberto
ter-te
gás
sociedade
direitos
leste
mantém
zangado
vinha
pede
ferido
passaram
treinador
voltas
chamadas
quisesse
duma
desligar
projecto
encontrá-lo
escreveu
câmaras
bem-vindos
afasta-te
obter
cavalheiros
encontra
deixá-lo
perfeitamente
objectivo
pedaço
assuntos
jardim
opção
deixem-me
membros
lembra-se
deixem
hipóteses
crer
ovos
usou
pequeno-almoço
presença
tornou-se
melhorar
imagens
vitória
pesquisa
cheira
centenas
pertence
ficaram
explosão
tempestade
sofrer
lembra
loucos
protecção
deuses
famílias
fiques
tratamento
acredite
dizendo
enganado
esquadra
saí
farto
vazio
fazer-te
locais
percebe
avançar
impressões
ossos
companheiro
pequenas
testemunhas
despacha-te
liceu
prédio
caça
tretas
equipamento
génio
ganhou
começaram
merdas
caraças
explodir
erros
entrem
violência
envolvido
condições
ponha
relações
chamam
montanha
fraco
mensagens
vêem
registo
prémio
vou-te
anjo
duvido
chuva
bêbado
apaixonado
deixaste
vejo-te
ladrão
ciência
fizesse
irmos
deitar
pão
comunidade
pânico
recebeu
detalhes
ficado
casal
falaste
califórnia
ganha
perdeste
orgulhoso
aguenta
consciência
percebeste
saibas
pôs
arriscar
incluindo
estiveres
digo-te
quiserem
possas
exame
faremos
sarilhos
estares
deram
autorização
castelo
limpa
perguntei
impressão
assustador
princípio
vírus
passeio
peças
dói
idéia
intenção
entrei
acabaram
decidiu
armadilha
trabalhos
falam
morrido
árvores
trabalhava
queijo
truque
roubo
francês
ires
legendas
ajudá-la
compreender
sozinhos
tirou
necessidade
maravilhosa
artigo
gelado
sabiam
mataram
conhecê-lo
comprei
liguei
lição
vigilância
levado
parvo
garota
voltamos
humanidade
oferecer
fronteira
óculos
ensinar
ferida
trocar
maluca
mexam-se
escadas
esqueças
diversão
assinar
armário
deixa-o
ficava
daquilo
possibilidade
incêndio
acabámos
voltem
cumprir
agência
felicidade
partilhar
localização
regra
achou
suicídio
dou-te
levá-la
especiais
aceito
desculpe-me
álcool
importância
adivinhar
partiu
carteira
telefonar
bilhetes
antigos
fores
digitais
dores
passagem
possam
demónio
deseja
revisão
lixe
roubado
chegue
vermelha
quilómetros
fazer-me
esquisito
identidade
ouviram
telhado
parou
campanha
iguais
levaram
ambulância
conhecem
século
discussão
noutro
identificação
contei
nasceu
chegámos
chateado
assassinos
nojento
enviou
falámos
difíceis
tiveres
urso
vivem
terminou
brincadeira
chamou
acabou-se
haveria
certas
quartos
atravessar
bruxa
vejamos
episódio
irmãs
festas
fim-de-semana
apanhou
professora
levar-te
regresso
convidado
amizade
governador
chame
permissão
criminoso
correio
começamos
confortável
carregar
estragar
pesadelo
tripulação
milagre
alemães
jornais
convidados
zangada
capacidade
estômago
provável
estranhos
adorável
acampamento
ficaste
enganar
madeira
fá-lo
acusação
brancos
importa-se
matar-te
chegaste
garagem
assustado
libertar
afastem-se
montanhas
adoro-te
advogados
erva
fazeres
ouço
ganhei
versão
relaxa
campeão
comprou
fales
vizinhos
achava
saímos
diário
digam
apanha
divisão
júri
operações
ajudou
espelho
dás
chegamos
padrão
acções
ver-me
garoto
dúvidas
conseguiram
apanhei
tesouro
ter-me
pediu-me
vantagem
escute
marinha
virá
pedras
coincidência
paciência
funcionou
precisares
deixo
feitos
legendagem
atitude
achamos
aceita
memórias
disseram-me
empregada
deixar-me
fechada
arranja
ligo
decisões
vidro
fez-me
selvagem
estarão
saudável
atirador
percebeu
macaco
importas-te
tornou
quantidade
educação
judeus
liga-me
pensamentos
vi-o
cozinhar
joelhos
usam
nação
saído
sofrimento
fazer-lhe
continuem
tomei
armazém
cavalheiro
mandei
divórcio
deixaram
saio
estudo
papéis
território
escuridão
maneiras
perguntou
preferia
postos
arranjaste
falado
falha
traseiras
faltam
passos
cópia
inteligência
prisioneiros
queixa
chamo
leis
tomou
jogador
botão
nascer
deixar-te
explicação
doces
conheceu
tornar-se
almoçar
poderíamos
linhas
autoridade
reputação
esforço
mexas
assumir
fita
estúdio
treinar
deixam
areia
tolo
fundos
trouxeste
poucas
acreditam
alunos
gostou
factos
ciúmes
bateu
noutra
conhecer-te
segurar
aguento
voltaste
sós
superfície
sessão
ponta
paixão
abram
capazes
ganho
empregado
alemão
acusações
estacionamento
jogada
criou
assustada
organização
açúcar
larga-me
tê-la
pássaro
caixas
falava
meia-noite
senhorita
ajudem-me
continuam
caçar
interromper
terras
russos
champanhe
extremamente
opções
cabeças
inacreditável
lembras
doentes
bem-vinda
esquecido
escolheu
sobretudo
vivemos
dívida
mistério
tirei
portão
ficares
assassinado
chegarmos
qualidade
percebido
alemanha
gajos
noivo
feitiço
criminosos
atingido
circunstâncias
trabalhou
tarefa
preocupação
análise
afastar
telefonema
dissesse
enfim
maravilha
piores
ripadas
pt-subs
diga-lhe
pagou
veículo
pensamento
sujo
ódio
escrevi
ouvimos
trabalhas
comunicação
sugiro
deixas
anúncio
arranjou
passam
exames
normais
virem
comissão
adivinha
engano
esqueci
trabalhei
pareceu
papai
palhaço
comissário
recebemos
encontrá-la
amostra
procuramos
cego
sermos
passamos
sujeito
limpeza
produção
sobe
museu
atende
folga
levei
índia
raça
lábios
declaração
chegado
encontramo-nos
resistência
partam
salvou
sentem-se
aliança
mostrar-te
dragão
cidades
deixá-la
secção
homicídios
deveríamos
adoraria
ficarei
ficheiros
galinha
mexe-te
palácio
poderiam
colocou
resgate
passa-se
voltarei
sexta-feira
encontrarmos
molho
pareço
aliás
chateada
digo-lhe
frango
lançar
império
convite
falhar
gravação
oficiais
glória
pacote
consequências
audiência
doutora
terias
doida
estivesses
neles
pessoais
mudanças
disponível
suspeitos
fizeres
prisioneiro
pedaços
feio
assistir
combustível
adaptação
condição
olhes
janelas
mudei
apaixonada
solta
febre
violação
acontecendo
buscá-lo
foge
graus
desliga
virgem
infância
sabendo
exercício
conferência
duplo
trabalham
refeição
conhecê-la
beijar
instruções
andei
produto
lenda
sócio
destruição
poderei
começam
descobrimos
comece
péssimo
passámos
desapareceram
atraente
venhas
ajudar-nos
bruxas
compreende
lançamento
romântico
gostamos
cuecas
reais
livrar
feitas
estarmos
expressão
perigosa
asas
ombro
origem
trânsito
morrem
velhote
vê-los
incomodar
filhas
tensão
lealdade
judeu
capitã
satisfeito
turma
compromisso
bíblia
sorrir
desculpa-me
cabana
farta
queimar
imperador
milhas
mamãe
rússia
moeda
vizinho
paragem
mostra-me
mães
traseiro
esquerdo
combater
trinta
impostos
camisola
gostavas
levem
escreve
sonhar
monstros
assassínio
competição
união
região
prazo
resolvido
conta-me
frequência
aviões
descobre
recolher
cale-se
passear
odeia
imaginação
custódia
porém
espião
contou-me
desporto
endereço
arquivos
escolhe
traição
resultou
questões
peixes
ladrões
cartões
pudéssemos
vigiar
trata-se
poderemos
acalmar
certos
ajude-me
estarem
juízo
deixou-me
entendeu
conseguirmos
chinês
reforços
pegou
corajoso
aproveitar
chegada
hei-de
abriu
posse
riscos
experiências
passaste
levam
estranhas
detetive
suspeita
souber
recebe
prata
desconhecido
interessada
emoções
ficheiro
salão
jornalista
efeitos
analisar
engraçada
direção
besta
dou-lhe
dei-lhe
surpreendido
mexa
aborrecido
equipas
ligo-te
multidão
usei
sentir-se
rasto
imaginei
reacção
mortas
reféns
saíram
fazerem
uísque
andou
podermos
costuma
orgulhosa
águas
disparou
mantenha
escolhido
voltará
foda
demónios
geração
revolução
deverias
morar
pergunto-me
meritíssimo
dar-nos
matá-la
gravar
desejar
farias
comeu
dizeres
desejos
joga
chegam
estudante
existência
sofreu
guerreiro
novidades
pássaros
sentes-te
séculos
rodas
basebol
deixa-te
alô
coroa
compreendes
beco
cerimónia
atirou
construção
coelho
afaste-se
conseguires
nobre
tragam
sincronizadas
oxigénio
levas
deixa-a
cores
julgar
acordei
imensa
geralmente
invasão
faziam
confissão
esperei
sensível
viagens
puxar
linguagem
administração
cavaleiro
redor
vai-se
quilos
heróis
caminhar
baixar
caridade
cidadãos
curto
rips
dali
vazia
testar
apostas
piadas
personagem
acompanhar
saibam
atingir
disfarce
voltaram
relatórios
poderias
manteiga
atira
ultrapassar
exposição
ginásio
mentiu
abençoe
tiroteio
lembre-se
acontecem
sítios
estudos
descobriste
patrulha
jóias
voltares
condutor
salário
goste
pergunte
trabalhamos
olhadela
tradição
pensem
noção
deter
anjos
boneca
vão-se
abertos
trazido
assinatura
relaxar
reparei
dizemos
abraço
preparem-se
dizer-nos
bloco
população
cassete
tragédia
empregados
cometeu
cientista
religião
corações
civis
caneta
cientistas
sobrinho
verdadeiros
meias
deixares
bandeira
mudaram
falhado
japão
feira
itália
respiração
descoberto
recebido
arquivo
imediato
apanhá-lo
dêem
arranjei
diz-lhes
asneira
níveis
reuniões
tchau
produtos
influência
espetáculo
voltes
tecido
piorar
cobrir
gatilho
horário
ocorreu
leva-me
luxo
estudantes
apoiar
pudesses
nojo
lembrem-se
testemunhar
sexuais
escravos
publicidade
tentamos
sacrifício
perguntar-lhe
atacou
feridas
doer
olhada
cometi
transferência
baseado
perderam
aparelho
saberia
duche
excelência
índios
dá-nos
"""
let portugueseForceList: Set<String> = Set(portugueseForceListRaw.split(separator: "\n").map(String.init))
func isPortugueseForced(_ token: String) -> Bool { portugueseForceList.contains(token.lowercased()) }
let portugueseSuffixes: [String] = ["ção","ções","ário","ária","eiro","eira","eiras",
                                    "dade","mente","agem","ença","ança","ura","ense"]
func tokenLooksPortuguese(_ token: String) -> Bool {
    if token.contains(where: { portugueseDistinctChars.contains($0) }) { return true }
    if isPortugueseForced(token) { return true }
    let lower = token.lowercased()
    if portugueseStopwords.contains(lower) { return true }
    if lower.count >= 5 {
        for suf in portugueseSuffixes where lower.hasSuffix(suf) { return true }
    }
    return false
}

// ============================================================
// MARK: - 西班牙语识别（新增 · 修复西/葡语被误判德语，最高优先级）
// ============================================================
// 西班牙语独有强特征：ñ（西语专属字母）、¿ ¡（西语倒置标点）。命中即强判西语。
let spanishDistinctChars: Set<Character> = ["ñ","Ñ","¿","¡"]
// 西语重音字符 á é í ó ú（与葡/意/法共享）：作为西语强特征，含之即优先判西语。
let spanishAccentChars: Set<Character> = ["á","é","í","ó","ú","Á","É","Í","Ó","Ú"]
// 西班牙语强制词库：命中即高权重判西语（不区分大小写）。
let spanishForceListRaw = """
qué
años
año
también
español
española
españa
historia
literatura
viajante
sábado
ciudad
vinhas
centro
histórico
historico
bairro
arquitetura
oscura
venecia
leer
partir
familia
tiempo
ahora
siempre
nunca
todo
todas
todos
toda
está
están
estás
estoy
después
despues
través
traves
según
segun
además
ademas
mientras
aunque
porque
cuando
dónde
donde
cómo
como
pero
para
del
las
los
una
uno
por
sin
más
mas
muy
tan
ser
estar
hacer
tener
poder
querer
saber
ver
dar
comer
beber
vivir
trabajar
ellos
ellas
nosotros
vosotros
este
esta
esto
estos
estas
ese
esa
eso
aquel
aquella
hola
gracias
buenos
buenas
dias
días
noche
noches
mundo
vida
amor
tierra
fuego
agua
luz
mujer
hombre
niño
niña
gente
trabajo
escuela
universidad
cultura
fiesta
fiestas
semana
mes
domingo
lunes
martes
miércoles
miercoles
jueves
viernes
enero
febrero
marzo
abril
mayo
junio
julio
agosto
septiembre
setiembre
octubre
noviembre
diciembre
sostenibilidad
elaborado
cifras
hormigón
hormigon
desafíos
desafios
corazón
corazon
actualmente
acuerdo
adelante
adrede
afirmó
agregó
ahí
alguna
algunas
alguno
algunos
algún
alli
allí
alrededor
ampleamos
antano
antaño
ante
anterior
aproximadamente
aquellas
aquello
aquellos
aquél
aquélla
aquéllas
aquéllos
aquí
arriba
arribaabajo
aseguró
así
atras
ayer
añadió
aún
bajo
buen
buena
bueno
casi
cerca
cierta
ciertas
cierto
ciertos
claro
comentó
conmigo
conocer
conseguimos
conseguir
considera
consideró
consigo
consigue
consiguen
consigues
contigo
cosas
creo
cual
cuales
cualquier
cuanta
cuantas
cuanto
cuantos
cuatro
cuenta
cuál
cuáles
cuándo
cuánta
cuántas
cuánto
cuántos
dado
debajo
debe
deben
debido
decir
dejó
delante
demasiado
demás
deprisa
despacio
detras
detrás
dicen
dicho
dieron
diferente
diferentes
dijeron
dijo
día
ejemplo
ello
embargo
empleais
emplean
emplear
empleas
empleo
encima
encuentra
enfrente
enseguida
entonces
erais
eramos
eran
eras
eres
esas
esos
estaba
estabais
estaban
estabas
estad
estada
estadas
estados
estais
estan
estando
estaremos
estarán
estarás
estaré
estaréis
estaría
estaríais
estaríamos
estarían
estarías
estemos
estuve
estuviera
estuvierais
estuvieran
estuvieras
estuvieron
estuviese
estuvieseis
estuviesen
estuvieses
estuvimos
estuviste
estuvisteis
estuviéramos
estuviésemos
estuvo
estábamos
estáis
esté
estéis
estén
estés
excepto
existe
existen
explicó
expresó
fuera
fuerais
fueran
fueras
fueron
fuese
fueseis
fuesen
fueses
fuimos
fuiste
fuisteis
fuéramos
fuésemos
general
gran
gueno
haber
habia
habida
habidas
habido
habidos
habiendo
habla
hablan
habremos
habrá
habrán
habrás
habré
habréis
habría
habríais
habríamos
habrían
habrías
habéis
había
habíais
habíamos
habían
habías
hace
haceis
hacemos
hacen
hacerlo
haces
hacia
haciendo
hago
hasta
haya
hayamos
hayan
hayas
hayáis
hecho
hemos
hicieron
hizo
hube
hubiera
hubierais
hubieran
hubieras
hubieron
hubiese
hubieseis
hubiesen
hubieses
hubimos
hubiste
hubisteis
hubiéramos
hubiésemos
hubo
igual
incluso
indicó
informo
informó
intenta
intentais
intentamos
intentan
intentar
intentas
intento
junto
largo
lejos
llegó
lleva
llevar
luego
manera
manifestó
mayor
medio
mejor
mencionó
menudo
mias
mios
misma
mismas
mismo
mismos
mucha
muchas
mucho
muchos
mía
mías
mío
míos
nadie
ninguna
ningunas
ninguno
ningunos
ningún
nosotras
nuestra
nuestras
nuestro
nuestros
nueva
nuevas
nuevo
nuevos
ocho
otra
otras
otro
otros
pais
pasada
pasado
paìs
peor
pesar
poca
pocas
pocos
podeis
podemos
podria
podriais
podriamos
podrian
podrias
podrá
podrán
podría
podrían
poner
por qué
posible
primer
primera
primero
primeros
pronto
propia
propias
propio
proximo
pudo
pueda
puede
pueden
puedo
pues
quedó
queremos
quien
quienes
quiere
quiza
quizas
quizá
quizás
quién
quiénes
raras
realizado
realizar
realizó
repente
respecto
sabeis
sabemos
saben
sabes
seamos
sean
seas
serán
serás
seré
seréis
sería
seríais
serían
serías
seáis
señaló
sido
siendo
sigue
siguiente
sino
sola
solamente
solas
solos
soyos
supuesto
suya
suyas
suyo
suyos
sólo
tambien
tampoco
temprano
tendremos
tendrá
tendrán
tendrás
tendré
tendréis
tendría
tendríais
tendríamos
tendrían
tendrías
tened
teneis
tenemos
tenga
tengamos
tengan
tengas
tengo
tengáis
tenida
tenidas
tenido
tenidos
teniendo
tenéis
tenía
teníais
teníamos
tenían
tenías
tercera
tiene
tienen
tienes
todavia
todavía
total
trabaja
trabajais
trabajamos
trabajan
trabajas
tras
trata
tuve
tuviera
tuvierais
tuvieran
tuvieras
tuvieron
tuviese
tuvieseis
tuviesen
tuvieses
tuvimos
tuviste
tuvisteis
tuviéramos
tuviésemos
tuvo
tuya
tuyas
tuyo
tuyos
unas
unos
usais
usamos
usan
usas
usted
ustedes
vamos
varias
varios
vaya
veces
verdad
verdadera
verdadero
vosotras
vuestra
vuestras
vuestro
vuestros
ésa
ésas
ése
ésos
ésta
éstas
éste
éstos
última
últimas
últimos
quieres
siento
puedes
alguien
hablar
mañana
hijo
necesito
dije
crees
razón
debería
cabeza
cariño
hombres
debo
pasó
hice
personas
hablando
muerto
ayuda
supongo
entiendo
puerta
pasar
niños
suerte
siquiera
hija
gustaría
dejar
realidad
dijiste
miedo
haré
debes
ojos
viejo
déjame
escucha
equipo
necesita
llegar
clase
dices
pequeño
llama
hiciste
mujeres
vuelta
juego
deberías
cuerpo
debemos
oportunidad
teléfono
necesitamos
listo
quieren
hermana
abajo
fuerte
diciendo
pregunta
chicas
pasando
conozco
haga
necesitas
hijos
probablemente
habitación
creer
joven
podrías
hagas
pequeña
seguridad
palabra
iré
oído
recuerdo
ayudar
murió
pueblo
venido
deberíamos
anoche
llamar
piensa
perdón
pienso
diablos
diez
llamado
prueba
increíble
empezar
afuera
perro
puesto
cuarto
haría
preguntas
piensas
diré
suena
jugar
millones
llamada
extraño
irme
ropa
vuelve
palabras
información
hará
entiendes
trabajando
perfecto
derecho
conoces
quieras
podríamos
asesino
decirle
recuerdas
asunto
mensaje
atención
cállate
daño
error
jamás
siente
baño
decirte
pensaba
novia
sueño
fuerza
supone
encontré
vuelto
dile
edad
ganar
verlo
asesinato
adónde
llegado
disculpe
situación
abogado
hablas
mató
llamo
sientes
ocurre
recuerda
mitad
quiera
compañía
relación
conoce
pase
montón
mejores
creí
caja
línea
caballeros
haremos
quédate
tienda
hambre
respuesta
imposible
pruebas
novio
gustan
dirección
profesor
servicio
reunión
dejado
quisiera
cumpleaños
canción
hermosa
decirme
cualquiera
hacía
llevo
decisión
necesario
interesante
escuchar
suelo
cárcel
acá
siéntate
decía
intentando
maldición
muerta
salió
broma
gobierno
cámara
llamó
amable
muertos
querías
navidad
pudiera
avión
investigación
acabó
mantener
ejército
diría
teniente
deseo
vayas
basura
tren
hazlo
disculpa
saberlo
locura
permiso
peligro
libertad
derecha
pies
maravilloso
espacio
abuelo
esperaba
miren
infierno
tía
crimen
conocido
consejo
iglesia
mayoría
hicimos
escena
señal
llamas
veras
viendo
pregunto
cocina
vieja
caballo
vienen
sucedió
agradable
parecía
duda
víctima
energía
frío
hablo
misión
listos
ayudarte
izquierda
deje
daré
sabías
puedas
puso
creía
regresar
llega
cambiado
hermoso
opinión
cerveza
harás
creen
oír
hablado
hablamos
prisión
vuelva
ocurrió
veré
joder
cenar
compañero
llevó
solía
irse
perra
encuentro
encontró
pelea
quise
apuesto
peligroso
vienes
necesitan
juicio
podamos
llave
posición
trasero
irnos
espalda
éxito
ventana
veamos
escúchame
hogar
volveré
regreso
lleno
dejé
respeto
escribir
estación
pidió
enfermo
duele
sueños
darme
órdenes
sigues
dejes
darte
salida
decirlo
hacerte
necesitaba
hermanos
zapatos
vistazo
juez
jugando
llevas
sepa
precio
culpable
ganas
verla
volvió
libros
cielos
irte
acción
reglas
cuestión
río
bienvenido
tomó
empieza
empezó
vayan
llaman
ojalá
vuelvo
quedarme
llamaré
nueve
quedar
probar
majestad
traer
común
hacerle
vuelo
debía
rojo
bromeando
doble
dejaré
cuello
conocí
tiempos
pareja
verano
escuché
tarjeta
perdí
llegue
haberlo
ayudarme
opción
cierra
piel
enemigo
dejo
imbécil
jóvenes
entiende
justicia
despierta
pido
luces
refiero
batalla
déjalo
brazo
llena
hacerme
quedan
piernas
parís
ganado
movimiento
vacaciones
cine
confianza
embarazada
esperen
pantalones
defensa
terminó
salido
presión
inmediatamente
testigo
deberían
olvidado
sentimientos
parecen
llaves
perros
quedarse
operación
ayúdame
elección
beso
conversación
brazos
espíritu
dejas
interesa
refieres
asuntos
muestra
encantaría
saliendo
cálmate
bienvenida
caer
llevaré
leche
estrellas
prefiero
viejos
oiga
cuentas
anillo
preguntar
héroe
pequeños
películas
volverá
árbol
ibas
dientes
camión
llame
detente
luchar
ruido
lucha
muere
reloj
vayamos
vendrá
corriendo
yendo
colegio
sonido
caballero
hagamos
imagen
riesgo
llegamos
millón
hielo
cayó
vengan
caminar
televisión
pasará
coger
posibilidad
asiento
herido
proyecto
pared
sentí
sospechoso
naturaleza
perdió
policías
arreglar
ideas
obtener
felices
señoría
cantidad
mírame
llorar
locos
escuche
quedarte
pedí
enfermedad
encontraron
bajar
nervioso
sirve
puertas
fuerzas
déjeme
velocidad
cabello
huellas
haberte
debí
unidad
oigan
tonterías
perfecta
hable
gustaba
robo
uds.
puse
conocerte
perdone
botella
viento
extraña
apoyo
puente
olvídalo
desea
dejarlo
pelear
pierna
echar
orgulloso
datos
sube
dejaste
llevaba
necesitar
clases
vergüenza
monstruo
autobús
huevos
podrás
enferma
paseo
detalles
llamadas
belleza
abierto
viviendo
envió
puntos
conducir
aceptar
caballos
trajo
bienvenidos
hechos
sociedad
quede
diste
lleve
conocía
sentía
hiciera
hablé
recibir
agradezco
robar
sepas
herida
ayude
supe
inmediato
profesional
cerdo
llegué
acuerdas
debió
piedra
habló
intención
querría
víctimas
asesinado
compañeros
escuchado
llevan
podré
oscuridad
llevado
comenzó
regresa
mirada
abierta
llámame
siguen
jardín
amenaza
comenzar
podremos
necesidad
dueño
rayos
mintiendo
creerlo
llamé
efecto
felicidad
relaciones
entró
recibido
limpio
juegos
correo
confía
perfectamente
harán
quedado
calles
créeme
responsabilidad
búsqueda
recuerdos
razones
escuchando
elegir
huele
almuerzo
cien
pasé
dígame
levántate
llamando
interés
comienzo
olvidé
quedo
voluntad
teoría
roja
cuento
escenario
propiedad
agujero
campamento
matarme
quiso
impresionante
proceso
intentado
fuente
alcalde
ocurrido
malos
carretera
desapareció
desayuno
comienza
intentarlo
miembro
perdiendo
valiente
deber
pecho
gustó
oyes
periódico
piensan
limpiar
crear
robado
poniendo
llevará
niñas
harías
sensación
alcohol
disculpas
antiguo
guapa
asustado
puedan
creemos
lengua
ladrón
montaña
durmiendo
entrenador
entero
papeles
pones
fútbol
detener
miembros
mataron
vuelvas
descubrir
hables
conocemos
haberme
dispuesto
tamaño
dejen
maravillosa
invitado
derechos
declaración
pérdida
iban
pudiste
aeropuerto
olvidar
olvides
volviendo
coge
fué
llamaba
encuentras
querían
hablemos
pertenece
sienta
pensó
gracia
doctora
escuchen
cuerpos
preguntaba
francés
techo
íbamos
protección
venganza
contó
enemigos
escribió
llevamos
testigos
recoger
truco
pide
sobrevivir
compartir
pequeñas
veía
empezando
continúa
viniste
cientos
relájate
siéntese
pedazo
olor
ciencia
conexión
vieron
salón
sucio
pidiendo
casarse
tercer
propios
fuertes
lluvia
recién
tomaré
cámaras
visión
llego
diversión
pareció
leído
consiguió
entera
decirles
cáncer
jodido
guste
inteligencia
podías
señoras
helado
mueve
hablaba
verle
tarea
cambió
móvil
vacío
felicitaciones
computadora
estudiante
muriendo
conocen
solución
tecnología
cabrón
condiciones
dudo
robó
escucho
mensajes
sujeto
acciones
fría
saldrá
suponía
empezamos
errores
siglo
sabéis
muevas
archivos
presencia
oficiales
comunidad
muévete
pieza
estómago
disparó
conseguí
estudiantes
alegría
barrio
podéis
esfuerzo
trabajaba
perdóname
compré
cirugía
dejamos
desearía
pregunté
ayudarle
llorando
duerme
dejarme
intentó
campaña
amistad
corriente
viven
huesos
invitados
respuestas
llevaron
poquito
ruego
dejan
aburrido
llevarte
canciones
mataré
muchísimo
asistente
llegaron
pondré
salgan
empecé
pasan
limpia
volví
confío
venta
huir
apareció
compromiso
gustas
aseguro
promesa
decírselo
importancia
lección
hablaré
hacerse
bolsillo
desgracia
artículo
labios
taza
preguntarte
pelota
caminando
chaqueta
importaría
llegará
interesado
atrapado
supiera
matarlo
árboles
amaba
hablaremos
entrenamiento
dioses
nerviosa
vueltas
encontrarlo
preguntarle
estudiar
sonrisa
olvida
secundaria
descubierto
convirtió
coches
venía
charla
bruja
rompió
vean
veinte
matarte
palacio
convierte
pasamos
daría
piense
oigo
alemanes
milagro
soportar
dejaron
disculpen
vecinos
dejarte
explosión
regla
acaban
siguiendo
cadena
comiendo
educación
maneras
madera
mayores
tratamiento
blancos
comisario
millas
cumplir
quedará
quedaré
aléjate
lío
preguntó
humanidad
guardias
leyes
funcionó
mires
escaleras
decisiones
queréis
salvaje
preguntando
pasos
ambulancia
traducción
trabajado
básicamente
especiales
servicios
pedirle
vivía
medios
conocimiento
armario
quedamos
ciertamente
alemania
ciento
invierno
encuentre
conductor
equipos
licencia
tíos
dijera
espejo
coincidencia
análisis
llegando
azúcar
sótano
volvamos
sabrá
ocasión
ponerme
dímelo
quedé
conciencia
pesadilla
heridas
pienses
llamarme
posibilidades
elegido
recibí
escuchas
mirad
pierde
abogados
trataba
llevando
regrese
dilo
hermanas
alemán
iría
salí
miras
frontera
ventaja
regalos
comportamiento
señales
salimos
hecha
imágenes
llegas
paciencia
crisis
asesinos
oíste
dejando
vigilancia
desierto
asustada
cuerda
despierto
gobernador
sección
casarme
trabajos
murieron
curiosidad
impresión
pasaba
escuchaste
sientas
pasillo
juega
suéltame
sencillo
ruta
enamorada
apuesta
vinieron
ayudarnos
hazme
lárgate
sigan
compró
pongas
alarma
identidad
iguales
daba
muchacha
opciones
vernos
llamaste
ponerse
sacó
orgullo
esperan
vuelves
serlo
enfadado
ponen
archivo
ayudará
viniendo
vendría
refiere
llamamos
versión
preferiría
recibió
concierto
casualidad
excusa
rodillas
dulces
zorra
perdiste
salgamos
ganó
firmar
muñeca
pájaro
ducha
déjenme
condición
actitud
personaje
dudas
cambios
perdimos
decidí
volveremos
traigo
asesinatos
orgullosa
vivimos
difíciles
hagámoslo
jefa
trató
ayudando
campeón
bebiendo
ayudó
ciego
deseos
celda
llevarlo
aguanta
vengas
montañas
pensamientos
medianoche
llevarme
sesión
diles
muera
creas
escribe
identificación
preguntado
súper
preocuparse
virgen
decidió
reputación
encontraré
dígale
límite
ponerte
líneas
estudios
muévanse
audiencia
nació
jugador
humo
nación
conocimos
sucediendo
explicación
salen
discúlpeme
presentar
competencia
envía
mantén
verlos
ésto
misterio
ganador
vehículo
escapó
traeré
lograr
muero
quítate
golpeó
tontería
parezca
rescate
llegaste
decírtelo
adivina
pánico
quieran
pasión
llegan
guau
tierras
demostrar
asegurarme
asegúrate
darles
cabezas
impuestos
encantan
ayudarlo
leyendo
adecuado
cajas
traté
tomen
darnos
gustado
luchando
apesta
periódicos
detenido
asco
usó
decirnos
enseñó
mírate
debiste
océano
nuevamente
cuán
escalera
acepto
autoridad
encuentran
cubierta
hierba
crecer
extranjero
prometí
veas
capaces
vuelvan
suelta
peces
podían
sabían
salvó
fotografía
patrón
desafío
asombroso
pedazos
atrapar
experto
desagradable
nacido
empezado
fiebre
compañera
ayudarla
desgraciado
organización
echa
deuda
digan
cocinar
sentimiento
pudieras
operaciones
maravilla
quita
pantalla
pusieron
judíos
tripulación
pagan
arrestado
extraños
guía
preocuparte
enseñar
irán
habitaciones
galletas
hablarle
ruedas
recientemente
huevo
violación
regresó
sufrir
habilidad
práctica
haberle
volvemos
pastillas
aprendí
nacimiento
alquiler
ordenador
escribí
intentaré
pensamiento
metió
piezas
ladrones
recuerde
actuación
harto
reacción
paliza
ocurra
quitar
amanecer
corazones
llames
celoso
olvide
prácticamente
intentaba
vecino
fondos
grados
instrucciones
treinta
adonde
hablarte
emperador
cigarrillo
cuéntame
haberse
cuídate
cierre
colores
rusia
botón
hijas
espía
empleados
detalle
rusos
déjala
contesta
casarte
prisioneros
echado
trajiste
flota
criminales
platos
crímenes
dispararon
dejará
sabría
abran
ayudante
revolución
hombro
olvidó
saludos
deme
serpiente
romántico
posiblemente
adivinar
peores
buscan
capacidad
aliento
entendí
cuadro
puestos
japón
división
subtítulos
sugiero
calla
ventanas
mejorar
comisaría
deseas
pasara
ocurrir
pondrá
muestras
personales
imaginación
volverás
ceremonia
almacén
sentarse
unión
aviones
calidad
citas
pusiste
querrá
cinturón
chiste
consecuencias
hablaste
vuelven
prisionero
apellido
morirá
traiga
mueva
emociones
parezco
excelencia
asalto
asusta
pasaría
discusión
verán
antiguos
requiere
cogido
comunicación
manzana
joyas
ee.uu.
encontrarla
piedras
gané
vía
efectos
resistencia
arreglado
tarjetas
descubrió
desconocido
entienden
bandera
llamarte
faltan
imperio
esperaré
enfadada
cartera
periodista
comprobar
tensión
involucrado
vacía
ruso
judío
empecemos
resultó
váyanse
escribiendo
pasen
supo
ascensor
quedarnos
actuando
pasas
apúrate
limpieza
querrás
hueso
trabajadores
dejaría
ejercicio
lealtad
pasaron
invitación
decimos
leyenda
gilipollas
costumbre
cabaña
ensayo
pagó
gimnasio
lenguaje
pájaros
quedes
garaje
oídos
espaldas
apuestas
incluyendo
pelotas
actividad
dragón
necesite
aguantar
primeras
generación
sexuales
dejemos
conocerlo
pudimos
convertirse
publicidad
probado
llamaron
váyase
intereses
madres
deba
niñera
movimientos
recibe
nací
cubierto
reír
producto
daños
abrazo
gafas
arreglarlo
sobrino
elecciones
construcción
ayudaré
buscado
dejarla
trozo
bendiga
vecindario
razonable
ríe
izquierdo
personalidad
camina
traes
secretario
sorprendido
conoció
pagaré
límites
moneda
piedad
seguía
ciudadanos
creado
acepta
opinas
empiezo
llevarla
pudieron
profesora
dejame
expresión
asesinada
escándalo
nervios
emoción
sienten
rumbo
viejas
buscaba
juventud
preocupación
desnudo
guión
carreras
sucia
háblame
pedirte
principios
mostraré
sentarme
verdaderamente
enhorabuena
peligrosa
ánimo
viajes
lujo
religión
risas
hierro
inmunidad
grabación
producción
puesta
buscarlo
llamarlo
comprender
volviste
alianza
siglos
desafortunadamente
hacían
estrategia
vinimos
frecuencia
discúlpame
llevé
prohibido
caray
existencia
bromas
trasera
monstruos
conseguiré
colección
empleado
petición
ayudado
presentación
coraje
rubia
pierdes
gano
almorzar
sepan
llegada
disculparme
viniera
sentirse
entren
quédese
tarta
volvería
mataría
llévame
suceda
cigarrillos
haberla
confesión
dijimos
coartada
desnuda
payaso
rayo
guay
diseño
vendrán
extrañas
equipaje
sufrimiento
salieron
mantente
sabiendo
maten
soltero
descubrí
oxígeno
algun
ponerle
empiece
propuesta
tómalo
abrió
traición
cementerio
pozo
patrulla
procedimiento
fantasía
billetes
ganamos
secuestro
sabrás
béisbol
ciudades
conejo
pregúntale
billete
esperanzas
díselo
mueren
cincuenta
jugadores
apropiado
alcanzar
patatas
continuación
tradición
"""
let spanishForceList: Set<String> = Set(spanishForceListRaw.split(separator: "\n").map(String.init))
func isSpanishForced(_ token: String) -> Bool { spanishForceList.contains(token.lowercased()) }
// 西语高频功能词/停用词
let spanishStopwords: Set<String> = [
    "el","la","lo","los","las","un","una","unos","unas","de","del","al","a","en","y","o",
    "que","se","su","sus","le","les","me","te","nos","os","yo","tú","tu","él","ella","es","son",
    "fue","era","ha","han","hay","muy","más","pero","como","porque","cuando","donde","quien"
]
// 西语典型词缀（含最小词长，避免误伤英文短词）
let spanishSuffixes: [String] = ["ción","ciones","dad","dades","mente","ando","iendo",
                                 "ado","ada","ados","adas","ería","aje","ísimo","ísima"]
func tokenLooksSpanish(_ token: String) -> Bool {
    // ñ / ¿ / ¡ 是西语独有强特征
    if token.contains(where: { spanishDistinctChars.contains($0) }) { return true }
    // 含 á é í ó ú 的词优先作西语强特征
    if token.contains(where: { spanishAccentChars.contains($0) }) { return true }
    if isSpanishForced(token) { return true }
    let lower = token.lowercased()
    if spanishStopwords.contains(lower) { return true }
    if lower.count >= 5 {
        for suf in spanishSuffixes where lower.hasSuffix(suf) { return true }
    }
    return false
}

// ============================================================
// MARK: - 印尼语识别（强制词优先于德语/意大利语/英语）
// ============================================================
// 印尼语强制词：命中即高权重判印尼语（不区分大小写）。Dirgahayu 单列超高权重。
let indonesianForceList: Set<String> = [
    "dirgahayu","republik","indonesia","nusantara","merdeka","pancasila",
    "kelana","tahta","perjuangan","cinta","bangsa","rakyat","negara",
    "bioskop","sutradara","agustus","januari","februari","maret","april",
    "mei","juni","juli","oktober","november","desember",
    "dari","produser","cerita","kehidupan","bersama","untuk",
    "baru","maju","jawa","bali","lombok","sultan","agung"
]
func isIndonesianForced(_ token: String) -> Bool { indonesianForceList.contains(token.lowercased()) }
// 印尼语高频功能词
let indonesianStopwords: Set<String> = [
    "dan","yang","di","ke","dari","untuk","dengan","pada","ini","itu","atau","juga",
    "sudah","bisa","ada","akan","tidak","adalah","dalam","oleh","para","sebagai"
]
// 印尼语典型词缀（含最小词长，避免误伤短英文词）
let indonesianSuffixes: [String] = ["kan","ber","per","me","ke","nya","lah"]
func tokenLooksIndonesian(_ token: String) -> Bool {
    let lower = token.lowercased()
    if indonesianForceList.contains(lower) { return true }
    if indonesianStopwords.contains(lower) { return true }
    if lower.count >= 6 {
        for suf in indonesianSuffixes where lower.hasSuffix(suf) { return true }
        if lower.hasPrefix("ber") || lower.hasPrefix("per") || lower.hasPrefix("meng") || lower.hasPrefix("mem") { return true }
    }
    // di 前缀：加强校验，避免误伤英语/德语词（如 direction/dialog/dinner）
    if lower.count >= 7 && lower.hasPrefix("di") {
        let h = spellHits(token)
        if !h.en && !h.de { return true }
    }
    return false
}

// 波兰语特征字符 / 高频词
let polishChars: Set<Character> = ["ą","ę","ó","ś","ź","ż","ń","ł","ć",
                                   "Ą","Ę","Ó","Ś","Ź","Ż","Ń","Ł","Ć"]
let polishStopwords: Set<String> = [
    "się","nowe","oraz","jest","dla","nie","tydzień","taniej","tylko","że","już",
    "co","to","opłaca","okazje","zł","na","do","tak","albo","bardzo"
]
func tokenLooksPolish(_ token: String) -> Bool {
    if token.contains(where: { polishChars.contains($0) }) { return true }
    let lower = token.lowercased()
    if lower == "zł" || lower.hasSuffix("zł") { return true }
    return polishStopwords.contains(lower)
}

// 拼音音节判定：用于识别中文地名/人名拼音（YIWU/CHUIWAN/GEBI）
let pinyinInitials = ["zh","ch","sh","b","p","m","f","d","t","n","l","g","k","h","j","q","x","r","z","c","s","y","w"]
let pinyinFinals: Set<String> = [
    "a","o","e","i","u","ai","ei","ao","ou","an","en","ang","eng","ong","er",
    "ia","ie","iao","iu","ian","in","iang","ing","iong","ua","uo","uai","ui",
    "uan","un","uang","ueng","ue"
]
func isPinyinSyllable(_ s: String) -> Bool {
    if pinyinFinals.contains(s) { return true }
    for ini in pinyinInitials where s.hasPrefix(ini) {
        if pinyinFinals.contains(String(s.dropFirst(ini.count))) { return true }
    }
    return false
}
// 整词能被切分为若干合法拼音音节 → 视为拼音
func looksPinyin(_ token: String) -> Bool {
    let lower = token.lowercased()
    guard lower.count >= 2, lower.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
    let chars = Array(lower)
    var pos = 0
    while pos < chars.count {
        var matched = false
        var len = min(6, chars.count - pos)
        while len >= 1 {
            if isPinyinSyllable(String(chars[pos..<pos+len])) { pos += len; matched = true; break }
            len -= 1
        }
        if !matched { return false }
    }
    return true
}

// token 的德/英拼写词典命中情况（分别返回，供 deOnly / enOnly 判定）
func spellHits(_ token: String) -> (de: Bool, en: Bool) {
    if germanSpellLang == nil && englishSpellLang == nil { return (false, false) }
    var deHit = false, enHit = false
    // 候选：原词 + 全大写转 Title Case（WERK→Werk）
    var cands = [token]
    let hasLetter = token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    if hasLetter && token == token.uppercased() && token != token.lowercased() {
        let low = token.lowercased(); cands.append(low.prefix(1).uppercased() + low.dropFirst())
    }
    for c in cands {
        if !deHit && spellValid(c, language: germanSpellLang) { deHit = true }
        if !enHit && spellValid(c, language: englishSpellLang) { enHit = true }
    }
    return (deHit, enHit)
}

// 多语种得分
struct LangScore { var de = 0; var en = 0; var fr = 0; var pl = 0; var it = 0; var vi = 0; var pt = 0; var id = 0; var es = 0 }

func latinLangScore(_ tokens: [String]) -> LangScore {
    var s = LangScore()
    // ---- Pass 0: 上下文标志 ----
    let ctxHasVietChar = tokens.contains { hasVietnameseChar($0) }
    let ctxHasFrench = tokens.contains { isFrenchForced($0) || hasFrenchElision($0) || frenchStopwords.contains($0.lowercased()) }
    // 西语上下文：块内出现 ñ/¿/¡ 或西语强制词时，含 á é í ó ú 的 token 偏西语
    let ctxHasSpanish = tokens.contains {
        $0.contains(where: { spanishDistinctChars.contains($0) }) || isSpanishForced($0)
    }
    // ---- Pass 1: 逐 token 打分（保留全部既有信号）----
    for tok in tokens {
        let lower = tok.lowercased()
        // 拼写词典命中情况（提前算，供意/印尼语词缀保护使用）
        let h = spellHits(tok)
        // 英语强制
        if isEnglishForced(tok) { s.en += 3 }
        // 德语（强制词/停用词/词根词缀+人名/拼写词典）
        if isGermanForced(tok) { s.de += 3 }
        if germanStopwords.contains(lower) { s.de += 3 }
        if englishStopwords.contains(lower) { s.en += 2 }
        if tokenLooksGerman(tok) || isGermanGivenName(tok) { s.de += 2 }
        // 法语（强制词/缩略前缀/停用词/特征）
        if isFrenchForced(tok) { s.fr += 4 }
        if hasFrenchElision(tok) { s.fr += 3 }
        if tokenLooksFrench(tok) { s.fr += 2 }
        // 意大利语：强制词高权重（不受英语拼写命中屏蔽）；词缀/词根匹配仅在英语词典未命中时计权，
        // 避免 BOTSWANA/ESSENTIAL 等英语词被误伤为意大利语。
        if isItalianForced(tok) { s.it += 4 }
        else if !h.en && tokenLooksItalian(tok) { s.it += 2 }
        // 意大利语 L' 省音（L'ORFEO 等）：高权重判意语，压过法语省音
        if hasItalianElision(tok) { s.it += 4 }
        // 波兰语
        if tokenLooksPolish(tok) { s.pl += 2 }
        // 葡萄牙语
        if tok.contains(where: { portugueseDistinctChars.contains($0) }) { s.pt += 3 }
        if isPortugueseForced(tok) { s.pt += 3 }
        else if tokenLooksPortuguese(tok) { s.pt += 2 }
        // 印尼语：强制词高权重（不受英语拼写命中屏蔽）；停用词/词缀匹配仅在英语词典未命中时计权，
        // 避免英语词被误伤为印尼语。
        if lower == "dirgahayu" { s.id += 5 } else if isIndonesianForced(tok) { s.id += 4 }
        if indonesianStopwords.contains(lower) { s.id += 2 } else if !h.en && tokenLooksIndonesian(tok) { s.id += 2 }
        // 越南语：独有字符 +8；停用词 +3
        if hasVietnameseChar(tok) { s.vi += 8 }
        else if vietnameseStopwords.contains(lower) { s.vi += 3 }
        // 西班牙语：ñ/¿/¡ 独有字符 +6；强制词 +4；停用词/词缀 +2
        // 防御：仅对"含字母"的 token 计西语分，避免纯数字/年份(如 2026)被误判西语
        let tokHasLetter = tok.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if tokHasLetter {
            if tok.contains(where: { spanishDistinctChars.contains($0) }) { s.es += 6 }
            if isSpanishForced(tok) { s.es += 4 }
            else if !h.en && !h.de && (spanishStopwords.contains(lower) || tokenLooksSpanish(tok)) { s.es += 2 }
        }
        // 拼写词典：仅德语命中→de；仅英语命中→en；两者都命中(loanword)→偏英语 en+1
        if h.de && !h.en { s.de += 2 }
        else if h.en && !h.de { s.en += 2 }
        else if h.de && h.en { s.en += 1 }
        // ---- 上下文加权 ----
        // 越南语上下文加权只作用于非英语词：英语停用词/强制词不受越南语上下文污染
        if !englishStopwords.contains(lower) && !isEnglishForced(tok) {
            // 越南语无变音符高频词：仅当块内已有越南语特征字符
            if ctxHasVietChar && vietnameseWeakWords.contains(lower) { s.vi += 2 }
            if ctxHasVietChar && !hasVietnameseChar(tok) { s.vi += 2 } // 块内其他 token 也获越南语上下文加成
        }
        // 法语上下文：块内已有明确法语词时，含共用重音字符的 token 偏法语
        if ctxHasFrench && tok.contains(where: { sharedRomanceAccents.contains($0) }) { s.fr += 2 }
        // 西语上下文：块内已有明确西语标志时，含 á é í ó ú 的 token 偏西语
        if ctxHasSpanish && tok.contains(where: { spanishAccentChars.contains($0) }) { s.es += 2 }
    }
    return s
}

// 返回得分最高的语种及其相对亚军的领先分
func bestLatinLang(_ s: LangScore) -> (code: String, score: Int, margin: Int) {
    let arr = [("de", s.de), ("en", s.en), ("fr", s.fr), ("pl", s.pl), ("it", s.it), ("vi", s.vi), ("pt", s.pt), ("id", s.id), ("es", s.es)].sorted { $0.1 > $1.1 }
    return (arr[0].0, arr[0].1, arr[0].1 - arr[1].1)
}

// ============================================================
// MARK: - 任务A：短词字符特征规则（NL 不可信时的字符级覆盖）
// ============================================================
// 意大利语专有重音（grave à è ì ò ù + acuto é）——刻意不含法语 circonflexe/ç 及西/葡的 á í ó ú。
let italianAccentChars: Set<Character> = ["à","è","é","ì","ò","ù","À","È","É","Ì","Ò","Ù"]
// 法语专有字符：circonflexe â ê î ô û + ç + tréma ë ï ü(注:ü 归德) + œ
let frenchOnlyChars: Set<Character> = ["â","ê","î","ô","û","ç","ë","ï","œ","æ",
                                       "Â","Ê","Î","Ô","Û","Ç","Ë","Ï","Œ","Æ"]

// ============================================================
// MARK: - 第7批·方向6：字符集硬规则（在 fastText/NL 之前生效的字符→语种映射）
// ============================================================
// ß/ä/ö/ü→de、ñ/¿/¡→es 已由 germanChars/spanishDistinctChars 在前置链处理（确认保留）。
// 以下为本批新增：
//   ã/ê → 倾向葡萄牙语 pt（ê 与法语 circonflexe 冲突，故本集仅收葡语更独有的 ã；
//         纯 ê 的处理仍交给既有 frenchOnlyChars，避免误伤法语，见下方规则顺序说明）
let portugueseTendChars: Set<Character> = ["ã","õ","Ã","Õ"]
//   œ/æ/à/è → 倾向法语 fr（单独 é/É 保持中性，不纳入本集）
let frenchTendChars: Set<Character> = ["œ","æ","à","è","Œ","Æ","À","È"]
//   ő/ű → 倾向匈牙利语 hu；App 未支持 hu(不在 allowedLangCodes)，命中则归 und 交后续，不崩
let hungarianDistinctChars: Set<Character> = ["ő","ű","Ő","Ű"]

// ============================================================
// MARK: - 第10批·改动A：葡语专属重音锁定（页面主语种预判阶段使用）
// ============================================================
// 葡语高区分度重音字符：ê ã ç õ â ô（西语几乎不用——西语专有只有 ñ á é í ó ú）。
//   规则（用户明确要求，不额外加护栏）：只要全页任一 token 含以下任意字符，且页面主语种
//   pageLang ∈ {es, fr}，即在页面预判阶段强制把 pageLang 覆盖为 pt（优先级高于 fastText
//   的页面级判断）。
// ⚠️ 已知重叠风险：ç 在法语中也很常见（garçon/français 等），â/ô 亦为法语 circonflexe；
//   因此本规则可能把「真法语页面」误锁成 pt。此处遵从用户指令按规则实现，不加法语护栏。
//   （逐块级仍有 frenchOnlyChars / frenchTendChars 等既有规则保护单块判定，本覆盖只作用于
//    页面主语种 pageLang，用于低置信行纠错的归并目标。）
// 大小写均纳入，便于全大写 OCR 文本命中。
let portugueseLockChars: Set<Character> = ["ê","ã","ç","õ","â","ô",
                                           "Ê","Ã","Ç","Õ","Â","Ô"]

// ============================================================
// MARK: - 第11批·改动C：德语专属字符硬锁页面主语种
// ============================================================
// 德语高区分度字符：ä ö ü ß（含大写，ß 无大写但保留兼容）。只要全页任一 token 含以下任意
//   字符 → 强制把 pageLang 覆盖为 de。优先级高于 fastText 页面判断，与葡语锁定（改动A）同级。
// ⚠️ 冲突规则（用户明确）：若同页既满足德语锁定又满足葡语锁定（例如既有 ß 又有 ã）→ 德语优先
//   （德语变音符 ä/ö/ü/ß 比葡语 ç/â/ô 更唯一）。实现上把德语锁定判断放在葡语锁定「之前」，
//    并用 if/else 保证 de 覆盖胜出（葡语锁定仅在 pageLang∈{es,fr} 时触发，德语已改为 de 后即绕过）。
let germanLockChars: Set<Character> = ["ä","ö","ü","Ä","Ö","Ü","ß"]

// ============================================================
// MARK: - 第11批·改动D：德语高频功能词加权页面主语种
// ============================================================
// 补充改动C：处理「无变音符」的德语页面（如 POSTMODERNE DENKMAL BIRKHÄUSER 中若无 Ä 时）。
//   C 是「字符级铁证」（变音符唯一），D 是「词汇级信号」（功能词命中），D 覆盖 C 无法命中的无变音符情形。
// 合并功能词 + 动词/介词为同一 Set（小写，token 精确匹配、不区分大小写）。
//   注意：für 含 ü，本身也会触发改动C；das/die/der 等已在 germanForceList，不冲突。
let germanFunctionWords: Set<String> = [
    // 冠词/功能词
    "und","der","die","das","des","dem","den","ein","eine","einen","eines","einer",
    // 动词/介词/副词
    "ist","sind","von","mit","für","fur","auf","bei","oder","nach","nicht","sich","auch","an","im","zu","wie"
]

// ============================================================
// MARK: - 第13批·改动K：葡语功能词加权页面主语种（仿改动D 的德语 deHits）
// ============================================================
// 葡语高频功能词（小写，token 精确匹配、不区分大小写）。用于「无葡语专属字符」的葡语页面
//   （改动A 的 portugueseLockChars 只能覆盖含 ê/ã/ç/õ/â/ô 的页面；本 K 覆盖纯 ASCII 葡语页面）。
// 优先级链（见 pageLevelCorrect 注释）：德语锁定(C/D) > 葡语字符锁定(A) > 葡语功能词(K)。
let portugueseFunctionWords: Set<String> = [
    "que","com","uma","por","seu","sua","nos","das","dos","para","mais","também","tambem",
    "sobre","este","esta","estes","estas","entre","muito","quando","porque","depois","sempre",
    "apenas","outro","outra","outros","outras","todo","toda","todos","todas","mesmo","essa",
    "esse","isso","pelo","pela","pelos","pelas","num","numa","neste","nesta","nessa","nesse"
]

// ============================================================
// MARK: - 第10批·改动B：纯 ASCII 拉丁行判定（用于硬排除非拉丁语种误判）
// ============================================================
// 判定「一行/块」是否为纯 ASCII 拉丁行：不含任何 CJK/假名/韩文/阿拉伯/希伯来/泰文/西里尔字符，
//   且至少含一个 ASCII 字母（a–z / A–Z）。用于纠正「全 ASCII 行被判成 ja/ko/ar/he/th 等
//   完全不含拉丁字母的语种」这类字符集级错误（如 "LET'S GO!" 被判 ja）。
//   注意：真正的 ja/ko/ar 文本必含非拉丁字符 → 落入下列区间 → 返回 false，绝不误伤真实 CJK 块。
func isPureAsciiLatinLine(_ text: String) -> Bool {
    var hasAsciiLetter = false
    for s in text.unicodeScalars {
        let v = s.value
        // 落在任一非拉丁脚本区间 → 立即判非纯 ASCII 拉丁行
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)     // CJK 汉字
            || (0x3040...0x30FF).contains(v)                                  // 日文假名
            || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
            || (0x3130...0x318F).contains(v)                                  // 韩文
            || (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
            || (0x08A0...0x08FF).contains(v) || (0xFB50...0xFDFF).contains(v)
            || (0xFE70...0xFEFF).contains(v)                                  // 阿拉伯文
            || (0x0590...0x05FF).contains(v) || (0xFB1D...0xFB4F).contains(v) // 希伯来文
            || (0x0E00...0x0E7F).contains(v)                                  // 泰文
            || (0x0400...0x04FF).contains(v) {                                // 西里尔文
            return false
        }
        // ASCII 字母存在性（a–z / A–Z）
        if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { hasAsciiLetter = true }
    }
    return hasAsciiLetter
}

// ============================================================
// MARK: - 第11批·改动E：Apple NL 人名/地名 token 剔除
// ============================================================
// 用 NLTagger(.nameType) 判断某 token 是否为人名(.personalName)或地名(.placeName)。
//   命中者应「从统计中完全剔除」：不画框、不计入任何语种百分比、也不计入 und（不影响 total）。
// 与既有专名逻辑（isProperNounLike / properNounForce*）的协调：
//   • 既有逻辑把「疑似专名」归入 name 语种类别（仍计入 breakdown 展示，但不算真实语种）。
//   • 改动E 更进一步——NL 确认的人名/地名直接从统计剔除，不再进入语种统计，避免与 name 重复计数。
//   • 顺序上：先用 NL nameType 剔除；剔除后的 token 才进入既有识别管线（含 name 归类）。
// ⚠️ 运行时依赖：NLTagger 仅真机(macOS/NL 框架)可用；容器无 NL。风险：NL nameType 在非英语
//   输入准确率低，最坏「少标一行」，用户已确认可接受。为避免误剔大量正文，仅按「token 级」剔除
//   （单 token 判定），调用方对「整行 token 全部命中人名/地名」时才整行跳过。
// token 首尾修剪标点集（与 latinTokens 的 trim 集一致），用于改动E token 剥离。
let _NAME_TRIM_PUNCT = ".,:;!?\"'()[]{}·—-"
func isPersonOrPlaceName(_ token: String, lineUppercaseRun: Int = 0) -> Bool {
    // 空/纯数字/过短 token 不判（降低误剔风险）
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || isNumericToken(t) || t.count < 2 { return false }
    // ---- 第13批·改动J：大写书名/标题保护（满足任一条件即「不当人名、不跳过、保留正文」）----
    //   即使 NL 判为 personalName/placeName，以下三条任一命中即 return false：
    //   条件1：命中任意语种 forceWords —— forceList 是语言词汇不是人名。
    //   条件2：所在行含 ≥3 个连续全大写词（书名/标题特征）—— 由调用处传入 lineUppercaseRun。
    //          isPersonOrPlaceName 本身是 token 级、拿不到整行上下文，故新增可选参数
    //          lineUppercaseRun 由 ocrBlocks 调用处按「该 token 所在行的连续全大写词数」传入。
    //   条件3：含德语变音符 ä/ö/ü/Ä/Ö/Ü/ß —— 一定是语言词汇（如 LÜGEN）。
    // 例：LÜGEN 含 Ü → 条件3命中保留；NACHT 若在 germanForceList 或同行≥3全大写 → 保留。
    if isEnglishForced(t) || isGermanForced(t) || isFrenchForced(t) || isItalianForced(t)
        || isSpanishForced(t) || isPortugueseForced(t) || isIndonesianForced(t) {
        return false   // 条件1：语种 forceWords → 不是人名
    }
    if lineUppercaseRun >= 3 { return false }   // 条件2：同行 ≥3 连续全大写词 → 书名/标题
    let deUmlaut: Set<Character> = ["ä","ö","ü","Ä","Ö","Ü","ß"]
    if t.contains(where: { deUmlaut.contains($0) }) { return false }   // 条件3：德语变音符 → 语言词汇
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = t
    var hit = false
    let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
    tagger.enumerateTags(in: t.startIndex..<t.endIndex, unit: .word,
                         scheme: .nameType, options: opts) { tag, _ in
        if let tag = tag, tag == .personalName || tag == .placeName {
            hit = true
            return false   // 命中即停止
        }
        return true
    }
    return hit
}

// 短词字符特征 → 语种码（confident=true 表示可直接采信）。无明显特征返回 nil。
// 优先级：德语特殊字符(ä ö ü ß) > 法语专有(â ê î ô û ç) > 意语重音(à è é ì ò ù)。
func shortWordCharFeature(_ token: String) -> String? {
    // ä ö ü ß → 强制德语（德语独有，绝不可能是阿拉伯语/其他）
    if token.contains(where: { germanChars.contains($0) }) { return "de" }
    // â ê î ô û ç ë ï œ → 法语专有
    if token.contains(where: { frenchOnlyChars.contains($0) }) { return "fr" }
    // à è é ì ò ù 且不含法语专有字符 → 意大利语
    if token.contains(where: { italianAccentChars.contains($0) }) &&
       !token.contains(where: { frenchOnlyChars.contains($0) }) { return "it" }
    return nil
}

// ============================================================
// MARK: - 第9批·改动2：罗曼语族 + 英语 词尾形态学规则（字符集前置阶段）
// ============================================================
// 取词末（小写）做后缀匹配，作为「字符集硬规则同区」的前置判据，优先级高于 fastText/NL。
// 关键设计：
//   1) 先匹配「更长更具体」的后缀（-zione 先于 -ione；-ción 先于 -ión），避免误归。
//   2) 罗曼语 es/it/pt 的后缀区分度高（且多含重音/特有形态），可直接硬判。
//   3) 法语 -tion/-sion/-ment/-eur/-eux/-eau/-ais 与英语高度撞车（nation/action/
//      information/management…），故法语这几个后缀**加护栏**：仅当 token 含法语变音符
//      (frenchChars/frenchOnlyChars) 时才判 fr；否则不判法语。
//   4) 无变音符的纯 ASCII 词若以 -tion/-tions/-sion/-sions/-ment/-ments 结尾（拉丁字母
//      文本中这些词尾绝大多数是英语；罗曼语用 -ción/-zione/-ção、-mente 等），判英语 en。
//      —— 这是「-tion 英语也极多」的根本护栏：英语不因后缀被误判法语。
// 未命中任何后缀返回 nil，交给后续既有链路（tokenLooks*/fastText/NL）。
func suffixMorphologyLang(_ token: String) -> String? {
    let lower = token.lowercased()
    guard lower.count >= 4 else { return nil }
    let hasFrenchChar = token.contains(where: { frenchChars.contains($0) || frenchOnlyChars.contains($0) })

    // ① 葡语（含鼻化/重音，最具体）：-ção/-ções 先于 -ão；-ões
    for suf in ["ção","ções","ões","ão"] where lower.hasSuffix(suf) { return "pt" }
    // ② 意语：-zione/-zioni 先于 -ione；-ità/-aggio/-ello/-elli/-ismo
    for suf in ["zione","zioni","aggio","ione","ità","ello","elli","ismo"] where lower.hasSuffix(suf) { return "it" }
    // ③ 西语：-ción/-ciones 先于 -ión；-ería/-ías/-ario/-amos/-emos
    for suf in ["ción","ciones","ería","ías","ario","amos","emos","ión"] where lower.hasSuffix(suf) { return "es" }
    // ④ 葡语（无重音形态）：-eiro/-eira/-inha
    for suf in ["eiro","eira","inha"] where lower.hasSuffix(suf) { return "pt" }
    // ⑤ 法语（撞车后缀，加护栏：需含法语变音符）
    if hasFrenchChar {
        for suf in ["tion","sion","ment","eur","eux","eau","ais"] where lower.hasSuffix(suf) { return "fr" }
    }
    // ⑥ 英语护栏：纯 ASCII 无变音符 + 以 -tion/-sion/-ment 结尾 → en（不误判法语）
    let pureASCIINoDiacritic = token.unicodeScalars.allSatisfy { $0.isASCII }
    if pureASCIINoDiacritic {
        for suf in ["tion","tions","sion","sions","ment","ments"] where lower.hasSuffix(suf) { return "en" }
    }
    return nil
}

// ============================================================
// MARK: - Apple NaturalLanguage 判定（封装，供 NL + fastText 协同）
// ============================================================
// NL 引擎"高置信"阈值：≥ 此值直接采信 NL；< 此值触发 fastText 补充验证（任务B）。
let NL_HIGH_CONF: Double = 0.70
// 纯 ASCII ≤3 短词：NL 概率低于此值则不强判，归 und（任务A）。
let SHORT_ASCII_MIN_PROB: Double = 0.50

func nlDetect(_ nlInput: String) -> (code: String, prob: Double)? {
    let r = NLLanguageRecognizer()
    r.languageConstraints = targetLangs
    r.processString(nlInput)
    let hyp = r.languageHypotheses(withMaximum: 1)
    guard let lang = r.dominantLanguage?.rawValue else { return nil }
    let code = lang.hasPrefix("zh") ? "zh" : lang
    let prob = hyp[NLLanguage(lang)] ?? 0
    return (code, prob)
}

// ============================================================
// MARK: - 任务B：fastText 语种识别（NL 补充验证层）
// ============================================================
// 通过 Process() 调用本地 fasttext CLI + lid.176.bin 模型（Facebook 开源，176 语言，完整版约126MB，精度高于 .ftz 压缩版）。
// 二进制或模型缺失时自动降级（fastTextLang 返回 nil），完全不影响既有规则/NL 流程。
// 可用环境变量覆盖：FASTTEXT_BIN / FASTTEXT_MODEL；LANGBAR_DISABLE_FASTTEXT=1 可整体关闭。
let fastTextEnabled: Bool = ProcessInfo.processInfo.environment["LANGBAR_DISABLE_FASTTEXT"] == nil
// fastText 结果采信的最低概率（旧：仅在 NL 低置信时用于补充验证的阈值）
let FASTTEXT_TRUST_PROB: Double = 0.50
// fastText 升级为「主判」后的采信阈值：prob ≥ 此值即直接采信 fastText 结果（任务：fastText 主判、NL 兜底）
let FASTTEXT_PRIMARY_PROB: Double = 0.35

func resolveFastTextBinary() -> String? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["FASTTEXT_BIN"], fm.isExecutableFile(atPath: p) { return p }
    var cands = ["/opt/homebrew/bin/fasttext", "/usr/local/bin/fasttext", "/usr/bin/fasttext"]
    cands.append((NSHomeDirectory() as NSString).appendingPathComponent("lang-detect-mac/bin/fasttext"))
    for c in cands where fm.isExecutableFile(atPath: c) { return c }
    return nil
}
func resolveFastTextModel() -> String? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["FASTTEXT_MODEL"], fm.fileExists(atPath: p) { return p }
    var cands: [String] = []
    if let res = Bundle.main.resourcePath { cands.append(res + "/lid.176.bin") }
    cands.append((NSHomeDirectory() as NSString).appendingPathComponent("lang-detect-mac/Resources/lid.176.bin"))
    cands.append("Resources/lid.176.bin")
    for c in cands where fm.fileExists(atPath: c) { return c }
    return nil
}
let fastTextBin: String? = fastTextEnabled ? resolveFastTextBinary() : nil
let fastTextModel: String? = fastTextEnabled ? resolveFastTextModel() : nil
let fastTextAvailable: Bool = (fastTextBin != nil && fastTextModel != nil)

// fastText 结果缓存（含负缓存），避免对同一文本重复启动进程
struct FTCacheEntry { let value: (code: String, prob: Double)? }
let ftCacheLock = NSLock()
var ftCache: [String: FTCacheEntry] = [:]

// fastText 标签(__label__xx) → 内部语种码
// lid.176 模型标签多为 ISO 639-1（两字母，如 en/fr/de），但为稳妥同时兼容
// ISO 639-3（三字母，如 eng/fra/deu）。映射到 App 内部两字母码；无法映射的返回 nil（走 NL 兜底）。
func ftLabelToCode(_ label: String) -> String? {
    let raw = label.replacingOccurrences(of: "__label__", with: "").lowercased()
    switch raw {
    // 中文各变体归一
    case "zh", "zh-cn", "zh-tw", "wuu", "yue", "zho", "cmn": return "zh"
    // ISO 639-3 → 内部两字母码
    case "eng": return "en"
    case "fra", "fre": return "fr"
    case "deu", "ger": return "de"
    case "ita": return "it"
    case "spa": return "es"
    case "por": return "pt"
    case "nld", "dut": return "nl"
    case "pol": return "pl"
    case "hrv": return "hr"
    case "vie": return "vi"
    case "ind": return "id"
    case "rus": return "ru"
    case "jpn": return "ja"
    case "kor": return "ko"
    case "tha": return "th"
    case "ara": return "ar"
    // 已是两字母码：原样返回（en/fr/de/it/es/pt/nl/pl/hr/vi/id/ja/ko/th/ar…）
    default:
        // 仅接受 2~3 位字母的合法语言码，其余归 nil（如空串/噪声）
        if raw.count >= 2 && raw.count <= 3 && raw.allSatisfy({ $0.isLetter }) { return raw }
        return nil
    }
}

// 调用 fastText 判定单块文本语种；不可用/失败/超时 → nil
func fastTextLang(_ text: String) -> (code: String, prob: Double)? {
    guard fastTextAvailable, let bin = fastTextBin, let model = fastTextModel else { return nil }
    let key = normalizedKey(text)
    ftCacheLock.lock()
    if let cached = ftCache[key] { ftCacheLock.unlock(); return cached.value }
    ftCacheLock.unlock()

    let result: (code: String, prob: Double)? = {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        // predict-prob <model> - 1 : 从 stdin 读入，输出 top-1 标签及概率
        proc.arguments = ["predict-prob", model, "-", "1"]
        let inPipe = Pipe(); let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        // fastText 按行分样本：换行折叠成空格，保证单行输入
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\r", with: " ") + "\n"
        inPipe.fileHandleForWriting.write(oneLine.data(using: .utf8) ?? Data())
        inPipe.fileHandleForWriting.closeFile()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: outData, encoding: .utf8) else { return nil }
        // 输出形如: "__label__it 0.8734"
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard parts.count >= 2, let code = ftLabelToCode(String(parts[0])),
              let prob = Double(parts[1]) else { return nil }
        return (code, prob)
    }()

    ftCacheLock.lock(); ftCache[key] = FTCacheEntry(value: result); ftCacheLock.unlock()
    return result
}

// ============================================================
// MARK: - 第12批·改动G：lingua-py 短文本复判层
// ============================================================
// 复判层位置：位于「单块语种判定」出口（detectBlockLangImpl 包装层），在既有规则/
//   fastText/NL 全部判完之后。触发条件严格：**≤5 个词的 token 行 且 fastText 置信度 <0.55**。
//   通过 Process 调用本目录下 lingua_detect.py（Python + lingua-language-detector），
//   对短文本做一次跨语种复判。决策：若 lingua 语种与 fastText 不同 **且 lingua.confidence >
//   fastText.prob** → 采用 lingua（须经语种码白名单校验）；否则保留既有结果。
//   找不到 python3 / 脚本、超时(2s)、异常 → 返回 nil，完全不影响既有流程。
//   环境变量 LANGBAR_DISABLE_LINGUA=1 可整体关闭。
let linguaEnabled: Bool = ProcessInfo.processInfo.environment["LANGBAR_DISABLE_LINGUA"] == nil
// 仅对这些「易混拉丁语种」的既有结果做复判，避免误伤非拉丁脚本(ru/ja/ko/…)硬命中结果。
let linguaReconsiderLangs: Set<String> = ["en", "de", "fr", "es", "it", "pt", "nl"]

// 解析 lingua_detect.py 路径：仿照 fastText 二进制/模型的多候选查找。
func resolveLinguaScript() -> String? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["LINGUA_SCRIPT"], fm.fileExists(atPath: p) { return p }
    var cands: [String] = []
    if let res = Bundle.main.resourcePath { cands.append(res + "/lingua_detect.py") }
    cands.append((NSHomeDirectory() as NSString).appendingPathComponent("lang-detect-mac/lingua_detect.py"))
    cands.append("lingua_detect.py")
    cands.append("./lingua_detect.py")
    for c in cands where fm.fileExists(atPath: c) { return c }
    return nil
}
// 解析 python3 可执行文件路径
func resolvePython3() -> String? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["PYTHON3_BIN"], fm.isExecutableFile(atPath: p) { return p }
    for c in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where fm.isExecutableFile(atPath: c) { return c }
    return nil
}
let linguaScript: String? = linguaEnabled ? resolveLinguaScript() : nil
let python3Bin: String? = linguaEnabled ? resolvePython3() : nil
let linguaAvailable: Bool = (linguaScript != nil && python3Bin != nil)

// lingua 结果缓存（含负缓存），避免同 token 重复启动进程（类似 ftCache）。
struct LinguaCacheEntry { let value: (code: String, confidence: Double)? }
let linguaCacheLock = NSLock()
var linguaCache: [String: LinguaCacheEntry] = [:]

// 调用 lingua_detect.py 判定文本语种；不可用/失败/超时 → nil。超时 2 秒。
func linguaLang(_ text: String) -> (code: String, confidence: Double)? {
    guard linguaAvailable, let py = python3Bin, let script = linguaScript else { return nil }
    let key = normalizedKey(text)
    linguaCacheLock.lock()
    if let cached = linguaCache[key] { linguaCacheLock.unlock(); return cached.value }
    linguaCacheLock.unlock()

    let result: (code: String, confidence: Double)? = {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [script, text]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        // 2 秒超时：后台看门狗到点 terminate 进程，回退 fastText 结果。
        let timedOut = NSLock()
        var didTimeout = false
        let watchdog = DispatchWorkItem {
            if proc.isRunning {
                timedOut.lock(); didTimeout = true; timedOut.unlock()
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: watchdog)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        timedOut.lock(); let to = didTimeout; timedOut.unlock()
        if to { return nil }
        guard let out = String(data: outData, encoding: .utf8),
              let jd = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let lang = obj["lang"] as? String else { return nil }
        let conf = (obj["confidence"] as? Double) ?? 0.0
        if lang == "und" { return nil }
        return (lang.lowercased(), conf)
    }()

    linguaCacheLock.lock(); linguaCache[key] = LinguaCacheEntry(value: result); linguaCacheLock.unlock()
    return result
}

// lingua 短文本复判：给定文本与既有判定结果 base，返回应覆盖的新结果（否则 nil）。
//   触发：token 行词数 1...5 且 fastText.prob<0.55；且 base 语种属易混拉丁语种白名单。
//   决策：lingua 语种 != fastText 语种 且 lingua.confidence > fastText.prob → 采用 lingua。
//   lingua 结果需在 allowedLangCodes 白名单内（映射不到 App 支持语种则忽略）。
func linguaReconsider(_ nlInput: String, base: (String, Bool)) -> (String, Bool)? {
    guard linguaEnabled, linguaAvailable else { return nil }
    // 只对易混拉丁语种既有结果复判，避免误伤非拉丁脚本硬命中。
    guard linguaReconsiderLangs.contains(base.0) else { return nil }
    let toks = latinTokens(nlInput).filter { !isNumericToken($0) }
    guard toks.count >= 1 && toks.count <= 5 else { return nil }
    let ft = fastTextLang(nlInput)
    let ftProb = ft?.prob ?? 0
    guard ftProb < 0.55 else { return nil }
    guard let lg = linguaLang(nlInput) else { return nil }
    guard allowedLangCodes.contains(lg.code) else { return nil }
    if lg.code != (ft?.code ?? base.0) && lg.confidence > ftProb {
        return (lg.code, true)
    }
    return nil
}

// fastText 主判 + NL 兜底：
//   1) 先调 fastText（主判）：prob ≥ FASTTEXT_PRIMARY_PROB(0.35) 且在白名单内 → 直接采信；
//   2) fastText 不可用 / 概率不足 → 回退 Apple NL：NL 高置信直接用，否则按长度阈值放宽/从严；
// 返回 (code, confident)；两者都不可信时返回 nil，交回上层规则。
func nlPlusFastText(_ nlInput: String, letters: Int) -> (code: String, confident: Bool)? {
    // ① fastText 主判
    if let ft = fastTextLang(nlInput), ft.prob >= FASTTEXT_PRIMARY_PROB, allowedLangCodes.contains(ft.code) {
        return (ft.code, true)
    }
    // ② Apple NL 兜底
    let nl = nlDetect(nlInput)
    let nlProb = nl?.prob ?? 0
    if let nl = nl, nlProb >= NL_HIGH_CONF, allowedLangCodes.contains(nl.code) {
        return (nl.code, true)
    }
    if let nl = nl, allowedLangCodes.contains(nl.code) {
        let need = letters >= 12 ? 0.50 : NL_PROB_MIN
        if nlProb >= need { return (nl.code, true) }
    }
    return nil
}


// ============================================================
// MARK: - 语种判定（稳定入口 + 实现）
// ============================================================

// ---- 稳定性缓存：同一段文字（归一化后）永远返回同一结果，消除 Apple NL 随机性 ----
let detectCacheLock = NSLock()
var detectCache: [String: (String, Bool)] = [:]

// 归一化 key：小写 + 折叠所有空白为单空格 + 去首尾空白，
// 让「同一段文字」即使 OCR 空格/换行略有差异，也命中同一缓存键，结果可复现。
func normalizedKey(_ text: String) -> String {
    return text.lowercased()
        .split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        .joined(separator: " ")
}

// 返回 (语种code, 是否可信) —— 带缓存的稳定入口
// prevContext / nextContext：相邻 block 文本（方向2 短词上下文窗口用）。
func detectBlockLang(_ text: String, prevContext: String? = nil, nextContext: String? = nil) -> (String, Bool) {
    // 上下文纳入缓存键，避免「同词不同邻居」串味
    let key = normalizedKey(text) + "|<" + (prevContext ?? "") + ">|<" + (nextContext ?? "") + ">"
    detectCacheLock.lock()
    if let cached = detectCache[key] { detectCacheLock.unlock(); return cached }
    detectCacheLock.unlock()
    // 取相邻 block 最靠近当前词的一个 token 作为前/后上下文
    let prevTok = prevContext.flatMap { latinTokens($0).last }
    let nextTok = nextContext.flatMap { latinTokens($0).first }
    var result = detectBlockLangImpl(text, prevToken: prevTok, nextToken: nextTok)
    // 第12批·改动G：lingua 短文本复判层（≤5 词 token 行 且 fastText<0.55 时触发）。
    //   放在既有单块判定出口、写缓存之前；不可用/超时/异常时 linguaReconsider 返回 nil，保留原结果。
    let nlKey = normalizedKey(text)
    if let lg = linguaReconsider(nlKey, base: result) { result = lg }
    detectCacheLock.lock()
    detectCache[key] = result
    detectCacheLock.unlock()
    return result
}

// 分类桶：具体语种 / name(专名) / num(数字) / und(未识别)
// prevToken / nextToken：可选的相邻 token 上下文（方向2）。当被判定的 block 只含一个
// 短词(≤4字符)时，单独送 fastText 极易误判(Con/Ti/LA/MODE…)，故把「前一词 + 当前词 +
// 后一词」空格拼接后整体送 fastText 判定；拼不出上下文时退回对该词本身判定。
func detectBlockLangImpl(_ text: String, prevToken: String? = nil, nextToken: String? = nil) -> (String, Bool) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // 归一化后的 NL 输入：折叠空白，保留大小写；让轻微 OCR 空格差异不改变 NL 结果（稳定性）
    let nlInput = t.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }.joined(separator: " ")
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

    // ===== 第8批·最高：西里尔字母 → 强制俄语（字符集硬规则，先于一切拉丁/数字判定）=====
    //   token 含 U+0400–U+04FF 任一字符即判俄语 ru，属"硬命中"，优先级与 ä/ö/ü、ñ 同级，
    //   在 fastText / Apple NL 之前。注意：CharacterSet.letters 会把西里尔计入 latinLetters，
    //   故必须在使用 latinLetters 做分支判断前先在此拦截。
    if t.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
        return ("ru", true)
    }

    // ① 无字母（含非拉丁脚本）但有数字 → 数字 token 彻底跳过（第7批·最高优先级）
    //   返回 "zh" 作为「跳过哨兵」：ocrBlocks 中 guessed=="zh" 会直接 continue，
    //   于是该 block 不进入 blocks，既不画框、不计入 counts/breakdown、也不进入 total 分母，
    //   顶部汇总永不出现「数字 X%」。与下方「整块全数字」跳过口径一致。
    if latinLetters == 0 && nonLatinTotal == 0 {
        if digitCount > 0 { return ("zh", true) }   // 纯数字/年份(如 12/4/2026) → 跳过
        return ("und", false)   // 纯符号
    }
    // ② 非拉丁脚本占主导 → 脚本判定高度可信
    if nonLatinTotal >= latinLetters, let top = scriptCount.max(by: { $0.value < $1.value }) {
        return (top.key, true)
    }
    // ③ 拉丁字母为主：短文本（尤其是单词专名/缩写/编号）NaturalLanguage 极易误判
    //    （如 Rosengarten→荷兰语、SODDY→斯洛伐克语、Mo.→印尼语）。
    let letters = latinLetters
    let tokens = latinTokens(t)
    // 第13批·改动I：跳过 token = 数字/月份名/时间格式，均不计入语种统计（tokensNZ 剔除）。
    let tokensNZ = tokens.filter { !isSkipToken($0) }
    // 整块都是数字/日期/时间/价格/月份 → 跳过，不识别不标注（与中文跳过一致，返回 "zh" 令 ocrBlocks 直接 continue）
    if !tokens.isEmpty && tokensNZ.isEmpty { return ("zh", true) }
    // 任务3：著名人名/地名整块短语（如 LE CORBUSIER）→ 强制「英语人名/地名」
    if properNounForcePhrases.contains(normalizedKey(t)) { return ("name", true) }
    // ③-黑名单：挪威语拦截 —— 文本足够长且 fastText/NL 首选为挪威语(no/nb/nn)且置信达标 →
    //   直接判「未识别」，避免回退误判成德语/英语等次优白名单语种。
    if letters >= BLACKLIST_MIN_LETTERS {
        if let ft = fastTextLang(nlInput), blacklistLangCodes.contains(ft.code), ft.prob >= BLACKLIST_MIN_PROB {
            return ("und", false)
        }
        if let nl = nlDetect(nlInput), blacklistLangCodes.contains(nl.code), nl.prob >= BLACKLIST_MIN_PROB {
            return ("und", false)
        }
    }
    let score = latinLangScore(tokensNZ)

    // ③-a 单 token：先判德语形态（词根 werk/statt/verlag/kunst/bast/tier…、
    //     构词后缀 -ung/-keit/-schaft/-bau…、特殊字符 ä ö ü ß，或德语人名 Else/Otto…），
    //     避免「大写德语词/复合词/德语人名」（如 WERK、STATT、BASTO、Kunstverlag）被
    //     isProperNounLike 误判为「英语（人名/地名）」。—— 修复问题 1/2/3
    if tokensNZ.count <= 1 {
        if let one = tokensNZ.first {
            // 0) 西班牙语独有字符 ñ/¿/¡ → 西语（最高优先，绝无歧义）
            if one.contains(where: { spanishDistinctChars.contains($0) }) { return ("es", true) }
            // 任务3：著名人名/地名单词（AHMEDABAD/CORBUSIER 等）→ 强制专名
            if isProperNounForced(one) { return ("name", true) }
            // 任务2：纯 ASCII 无变音符的孤立短词/断词碎片，NL 不自信 → 优先英语
            //   （Con→en 而非 es；Disobed→en 而非 id）。德语词与保护名单/专名不受影响。
            if one.allSatisfy({ $0.isASCII }) && !one.contains("'") && !one.contains("’") {
                let lo = one.lowercased()
                let firstUpper = one.first.map { $0.isUppercase } ?? false
                let allUpper = (one == one.uppercased()) && (one != one.lowercased())
                let capForm = allUpper || firstUpper
                let claimedByGermanic = isGermanForced(one) || tokenLooksGerman(one)
                                      || isGermanGivenName(one) || germanStopwords.contains(lo)
                if capForm && !claimedByGermanic && !shortWordEnglishKeepList.contains(lo) {
                    // ≤4 短碎片：可覆盖罗曼语强制词(如 con)；>4 长碎片：尊重显式强制词表，仅覆盖弱启发
                    let eligible = !isFrenchForced(one) && !isSpanishForced(one)
                        && !isItalianForced(one) && !isIndonesianForced(one)
                        && !isPortugueseForced(one) && !isEnglishForced(one)
                    if eligible {
                        // fastText 主判优先：拼写碎片先送 fastText，≥0.35 即采信；
                        // 否则再看 NL 置信度，仍不足则英语兜底。
                        if let ft = fastTextLang(nlInput), ft.prob >= FASTTEXT_PRIMARY_PROB,
                           allowedLangCodes.contains(ft.code) { return (ft.code, true) }
                        let p = nlDetect(nlInput)?.prob ?? 0
                        if p < 0.6 {
                            return ("en", true)
                        }
                    }
                }
            }
            // 1) 英语强制白名单（EXPOSURE/COFFEE/…）→ 英语（最高优先）
            if tokenLooksVietnamese(one) { return ("vi", true) }
            if isIndonesianForced(one) { return ("id", true) }
            // 意大利语 L' 省音（L'ORFEO）优先于法语省音判定
            if hasItalianElision(one) { return ("it", true) }
            if isFrenchForced(one) { return ("fr", true) }
            if hasFrenchElision(one) { return ("fr", true) }
            if isSpanishForced(one) { return ("es", true) }
            if isEnglishForced(one) { return ("en", true) }
            if isGermanForced(one) { return ("de", true) }
            // 意大利语强制词优先于英语人名（如 ADESSO/SICILIA）
            if isItalianForced(one) { return ("it", true) }
            // 葡语强制词前置（第2轮校准）：obrigado/português 等 curated 词须先于
            //   suffixMorphology/tokenLooksFrench，避免 português 被误判 fr、obrigado 误判 es。
            if isPortugueseForced(one) { return ("pt", true) }
            // 任务A：短词(≤4字符)字符特征覆盖 —— 意语重音 à è é ì ò ù → it；
            //   法语专有 â ê î ô û ç → fr；德语 ä ö ü ß → de（不走 NL，直接采信）。
            //   放在强制词表之后，保证 qué/café 等被强制词表认领的词不被误抢。
            if one.count <= 4, let cf = shortWordCharFeature(one) { return (cf, true) }
            // 第9批·改动2：罗曼语族 + 英语 词尾形态学（字符集前置阶段，优先级高于 fastText/NL）。
            //   放在 forceWords / 变音符硬规则之后、tokenLooks*(French/Polish/…) 之前，
            //   使 -ção→pt、-ción→es、-zione→it 等在裸字符启发式之前生效，且英语 -tion/-sion/-ment
            //   走英语护栏（不再被 tokenLooksFrench 误判法语）。
            if let sfx = suffixMorphologyLang(one) { return (sfx, true) }
            // 2) 德语词根/词缀/特殊字符/德语人名 → 德语
            if tokenLooksGerman(one) || isGermanGivenName(one) { return ("de", true) }
            // 3) 法语 / 波兰语特征 → 对应语种
            if tokenLooksFrench(one) { return ("fr", true) }
            if tokenLooksPolish(one) { return ("pl", true) }
            if tokenLooksItalian(one) { return ("it", true) }
            if tokenLooksPortuguese(one) { return ("pt", true) }
            if tokenLooksIndonesian(one) { return ("id", true) }
            // 3.5) 含 á é í ó ú 且未被上述任何语种认领的重音词 → 西语
            if tokenLooksSpanish(one) { return ("es", true) }
            // ===== 第7批·方向6：字符集硬规则（forceWords/既有字符特征之后、fastText/NL 之前）=====
            //   ä/ö/ü/ß→de、ñ/¿/¡→es 已在前面处理；此处补充本批新增的倾向规则。
            //   走到这里的 token 未被任何 forceWords/语言特征认领，故不会误伤已认领词。
            if one.contains(where: { hungarianDistinctChars.contains($0) }) {
                // ő/ű → 匈牙利语；App 未支持 hu → 归 und 交后续，绝不崩
                return ("und", false)
            }
            if one.contains(where: { portugueseTendChars.contains($0) }) { return ("pt", true) } // ã/õ → 葡
            if one.contains(where: { frenchTendChars.contains($0) })     { return ("fr", true) } // œ/æ/à/è → 法
            // ===== fastText 主判（在字符特征/forceWords 之后、Apple NL 之前）=====
            //   方向2：≤4 字符短词不单独送 fastText（易误判），改用「前词+当前词+后词」
            //   拼接串作为上下文整体判定；无上下文时退回对该词本身判定。
            //   prob ≥ FASTTEXT_PRIMARY_PROB(0.35) 且在白名单内 → 直接采信。
            let ftInput: String = {
                if one.count <= 4 {
                    let ctx = [prevToken, one, nextToken]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if ctx.count >= 2 { return ctx.joined(separator: " ") }
                }
                return nlInput
            }()
            if let ft = fastTextLang(ftInput), ft.prob >= FASTTEXT_PRIMARY_PROB,
               allowedLangCodes.contains(ft.code) {
                // 第6批（低优先级）：极小字碎词乱判小语种防护。
                //   当 token 为纯 ASCII 且无变音符、词长 ≤5、且置信度 <0.5，而 fastText 又输出了
                //   越南语/印尼语/波兰语/克罗地亚语等小语种时，不采信小语种：优先归英语
                //   （若含德语特征线索则德语）。放在小语种输出之后、返回之前。
                //   注意：此处未被 forceWords/字符特征命中（前面已 return），故不会影响那些已认领的词。
                let smallLangs: Set<String> = ["vi","id","pl","hr","cs","sk","sl","ro","hu","tr","nl","da","sv","no","fi"]
                let noDiacritic = one.unicodeScalars.allSatisfy { $0.isASCII }
                if smallLangs.contains(ft.code) && ft.prob < 0.5 && noDiacritic && one.count <= 5 {
                    if tokenLooksGerman(one) || isGermanForced(one) { return ("de", true) }
                    return ("en", true)
                }
                return (ft.code, true)
            }
            // 任务A：纯 ASCII ≤3 短词且 NL 置信度低 → 不强判，先试 fastText，仍不可信则归 und
            //   （避免 SGN/ARS/Mo. 等碎片被瞎猜为某语种）
            if one.count <= 3 && one.allSatisfy({ $0.isASCII }) {
                let p = nlDetect(nlInput)?.prob ?? 0
                if p < SHORT_ASCII_MIN_PROB {
                    if let ft = fastTextLang(nlInput), ft.prob >= FASTTEXT_TRUST_PROB,
                       allowedLangCodes.contains(ft.code) {
                        return (ft.code, true)
                    }
                    return ("und", false)
                }
            }
            // 4) 拼写词典：仅德语命中→德语；仅英语命中→英语；两者都命中→偏英语
            let h = spellHits(one)
            if h.de && !h.en { return ("de", true) }
            if h.en && !h.de { return ("en", true) }
            if h.de && h.en { return isProperNounLike(t) ? ("name", true) : ("en", true) }
            // 5) 两词典都未命中：拼音（中文地名/人名）→ 未识别，绝不判德语/专名
            if looksPinyin(one) { return ("und", false) }
            // 6) 像专名/缩写/编号 → 专名
            if isProperNounLike(t) { return ("name", true) }
        }
    }

    // ③-b 规则强信号（稳定、可复现）：德/英功能词+词根+人名计分，某一方明显占优（且领先≥2）
    //     直接判定。用于消解「双语对照排版」德英交替行互判，及德语人名/复合词被判英语的问题。
    //     —— 修复问题 1/2（Else Stadler-Jacobs 等德语人名走此路径）
    if letters >= 3 {
        let best = bestLatinLang(score)
        if best.score >= 2 && best.margin >= 2 { return (best.code, true) }
    }

    // ④ 多词/普通词：NL + fastText 协同判定（NL<0.7 时用 fastText 覆盖），输入已归一化保证同文本同结果
    if letters >= 3 {
        if let res = nlPlusFastText(nlInput, letters: letters) {
            let code = res.code
            // 规则强信号覆盖 NL/fastText：修复把 法语/波兰语/英语 误判为德语
            let best = bestLatinLang(score)
            if best.score >= 2 && best.margin >= 2 && best.code != code {
                return (best.code, true)
            }
            // 判德语但无任何真实德语特征，且英/法/波有信号 → 不默认德语（问题4）
            if code == "de" && !hasGermanFeature(tokensNZ) && best.score >= 2 && best.code != "de" {
                return (best.code, true)
            }
            return (code, true)
        }
    }
    // ⑤ NL 判不准，但整体像专名/缩写/编号（如多词全大写 ARS SGN）→ 默认专名；
    //    但收窄专名路径：只要含任何德语特征（词根/词缀/特殊字符/德语人名）且无明显英语信号，
    //    一律判德语，不再走「英语（人名/地名）」。—— 修复问题 1/2
    if isProperNounLike(t) {
        if hasGermanFeature(tokensNZ) && score.en < 2 {
            return ("de", true)
        }
        return ("name", true)
    }
    // ⑥ 太短的拉丁碎片 → 未识别
    if letters < 2 { return ("und", false) }
    // ⑦ 仍拿不准：先用 fastText 主判兜底（≥0.35 即采），再取 NL 首选（限定目标白名单内），否则未识别
    if let ft = fastTextLang(nlInput), ft.prob >= FASTTEXT_PRIMARY_PROB, allowedLangCodes.contains(ft.code) {
        return (ft.code, true)
    }
    // 第8批·最高：未识别兜底 —— fastText 与 Apple NL 置信度均 < UND_MIN_CONF(0.2)（或都不可用）
    //   → 不强归任何语种，返回 und（灰色显示、顶部按"未识别 X%"统计，区别于数字跳过）。
    let ftLow = fastTextLang(nlInput)?.prob ?? 0
    let nlLow = nlDetect(nlInput)?.prob ?? 0
    if ftLow < UND_MIN_CONF && nlLow < UND_MIN_CONF { return ("und", false) }
    let r2 = NLLanguageRecognizer()
    r2.languageConstraints = targetLangs
    r2.processString(nlInput)
    if let lang = r2.dominantLanguage?.rawValue {
        let code = lang.hasPrefix("zh") ? "zh" : lang
        if allowedLangCodes.contains(code) { return (code, true) }
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
            // 先抽取每个 block 的首选文本，便于取相邻 block 作为短词上下文（方向2）
            let texts: [String] = obs.map { $0.topCandidates(1).first?.string ?? "" }
            for (i, o) in obs.enumerated() {
                guard let cand = o.topCandidates(1).first else { continue }
                let s = cand.string
                if s.isEmpty { continue }
                // ---- 第11批·改动E：Apple NL 人名/地名 token 级剔除（在识别管线「之前」）----
                //   对本块每个 token 用 NLTagger(.nameType) 判定；命中人名/地名者从统计中完全剔除
                //   （不画框、不计入任何语种、也不计入 und）。剔除后剩余 token 才进入识别管线。
                //   • 整行 token 全部命中人名/地名 → keptToks 为空 → 整行跳过（类似数字块 continue，
                //     语义是「忽略」——不进入 blocks，故不影响 total）。
                //   • 与既有专名逻辑（isProperNounLike→name 类别）协调：先 NL 剔除，剔除后的 token
                //     才可能被后续判成 name，避免重复计数。NL 仅真机可用，容器无 NL 时该函数不命中。
                let rawToks = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                // 第13批·改动J·条件2：计算该行「连续全大写词」的最大长度，传入 isPersonOrPlaceName。
                //   全大写词判定：含字母且去标点后等于其大写形态（如 NACHT/LÜGEN/BUDGET）。
                var maxUpperRun = 0
                var curUpperRun = 0
                for tok in rawToks {
                    let core = tok.trimmingCharacters(in: CharacterSet(charactersIn: _NAME_TRIM_PUNCT))
                    let hasLetter = core.contains { $0.isLetter }
                    if hasLetter && core == core.uppercased() && core.count >= 2 {
                        curUpperRun += 1
                        maxUpperRun = max(maxUpperRun, curUpperRun)
                    } else {
                        curUpperRun = 0
                    }
                }
                var keptToks: [Substring] = []
                for tok in rawToks {
                    let core = tok.trimmingCharacters(in: CharacterSet(charactersIn: _NAME_TRIM_PUNCT))
                    if !core.isEmpty && isPersonOrPlaceName(core, lineUppercaseRun: maxUpperRun) { continue }   // NL 人名/地名 → 剔除
                    keptToks.append(tok)
                }
                if keptToks.isEmpty { continue }                 // 整行仅人名/地名 → 整行忽略
                // 若有 token 被剔除，用剩余 token 重组文本；否则沿用原文（保留原始间隔语义）
                let s2 = keptToks.count == rawToks.count ? s : keptToks.joined(separator: " ")
                // 相邻 block 文本（跳过空串）作为前/后上下文
                let prevCtx = i > 0 ? texts[..<i].last(where: { !$0.isEmpty }) : nil
                let nextCtx = i + 1 < texts.count ? texts[(i+1)...].first(where: { !$0.isEmpty }) : nil
                // 判定语种可信度
                var lang: String
                let (guessed, ok) = detectBlockLang(s2, prevContext: prevCtx, nextContext: nextCtx)
                // 中文片段：直接跳过，不识别、不标注、不计入统计
                if guessed == "zh" { continue }
                // 三重不猜条件：OCR置信度低 / 文字太小 / 语种判定不可信
                if cand.confidence < OCR_CONFIDENCE_MIN ||
                   o.boundingBox.height < MIN_TEXT_HEIGHT_RATIO ||
                   !ok {
                    lang = "und"
                } else {
                    lang = guessed
                }
                blocks.append(Block(text: s2, box: o.boundingBox, lang: lang))
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
        req.recognitionLanguages = ["en-US","fr-FR","de-DE","pl-PL","it-IT","pt-BR","vi-VN","id-ID","ja-JP","ko-KR","th-TH","ar-SA","zh-Hans","zh-Hant"]
    }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    sem.wait()
    return blocks
}

func annotate(_ cg: CGImage, blocks: [Block], breakdown: [(String, Int)], mixed: Bool,
              singleDominant: Bool, dominantLang: String, outPath: String) {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)

    // ---- 预先计算顶部信息条（浅色，独立于原图，不遮挡内容）----
    let total = breakdown.reduce(0) { $0 + $1.1 }
    let hFont = NSFont.boldSystemFont(ofSize: max(20, H * 0.020))
    let hAttrs: [NSAttributedString.Key: Any] = [.font: hFont, .foregroundColor: NSColor.black]
    let dotR = hFont.pointSize * 0.62
    let sidePad = max(16, W * 0.012)
    let itemGap = hFont.pointSize * 1.1
    let lineH = hFont.pointSize * 1.7

    // 组装条目：单语简洁模式只显示「整体：X」；混语显示标题 + 各语种占比
    struct HItem { let text: String; let color: NSColor?; let width: CGFloat }
    var items: [HItem] = []
    if singleDominant {
        let t = "整体：\(cnName(dominantLang))"
        let tw = (t as NSString).size(withAttributes: hAttrs).width
        items.append(HItem(text: t, color: color(dominantLang), width: dotR + 6 + tw))
    } else {
        let title = "语种占比（混语）"
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

    // ---- 逐块标注框 + 标签（画在原图区域内）：始终绘制彩色分块标注 ----
    //   任务【最高优先级】：即使某语言占比 ≥80%（singleDominant），也必须保留混语分块彩色标注，
    //   否则「多本杂志封面(含德语副标题)」这类会退化为只显示「整体：英语」而丢失分块信息。
    if true {
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
    }   // end if !singleDominant

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
    let singleDominant: Bool
    let dominantLang: String
    let mostlyChinese: Bool
}

func runDetect(shotPath: String, annoPath: String) -> DetectResult? {
    guard let cg = loadCGImage(shotPath) else { return nil }
    let rawBlocks = ocrBlocks(cg)

    // ============================================================
    // 第7批·方向3(平滑) + 方向7(白名单)：识别主语种后，对碎词/白名单外 token 重新归并
    // ============================================================
    // 平滑口径说明（方向3）：当前 Block 未保存 token 级置信度（Vision→detectBlockLang 只回传
    //   (code, ok)，未透传概率）。为避免大改识别管线，采用任务允许的“退而求其次”口径：
    //   把「词长≤5 且非 forceWords/非变音符硬命中」的碎词作为可平滑对象。硬命中(forceWords/
    //   变音符独有字符)一律豁免，避免误伤真实混语。
    // 白名单（方向7）：主语种确定后，落在白名单外的 token（尤其 id/vi/pl/sw 小语种）改判主语种。
    func firstPassDominant(_ bs: [Block]) -> String {
        var c: [String: Int] = [:]
        for b in bs where b.lang != "und" && b.lang != "num" && b.lang != "name" {
            c[b.lang, default: 0] += letterCount(b.text)
        }
        return c.sorted { $0.value > $1.value }.first?.key ?? "und"
    }
    // block 是否为“硬命中”（forceWords / 含某语种独有变音符 / 西里尔 / 后缀硬规则）→ 高置信，
    //   豁免 平滑/白名单强改 与 第9批·改动1 页面级纠错。
    func blockHardHit(_ text: String) -> Bool {
        // 西里尔 → 俄语硬命中
        if text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return true }
        for tok in latinTokens(text) where !isNumericToken(tok) {
            let lo = tok.lowercased()
            if isFrenchForced(tok) || isGermanForced(tok) || isSpanishForced(tok)
                || isItalianForced(tok) || isPortugueseForced(tok) || isEnglishForced(tok)
                || isIndonesianForced(tok) || germanStopwords.contains(lo) { return true }
            if tok.contains(where: { germanChars.contains($0) || spanishDistinctChars.contains($0)
                || frenchOnlyChars.contains($0) || italianAccentChars.contains($0)
                || portugueseTendChars.contains($0) || frenchTendChars.contains($0)
                || hungarianDistinctChars.contains($0) }) { return true }
            // 第9批·改动2 后缀硬规则命中（es/it/pt/fr，排除英语护栏 en）→ 视为硬命中，
            //   避免被页面主语种/白名单覆盖（如页面英语但某词是 -zione 意语）。
            if let s = suffixMorphologyLang(tok), s != "en" { return true }
        }
        return false
    }
    // 方向7：主语种 → 候选白名单（nil 表示不限制）
    func whitelist(forMain m: String) -> Set<String>? {
        switch m {
        case "de": return ["de","en","fr","nl","da","sv","no"]
        case "fr": return ["fr","en","it","es","pt"]
        case "pt": return ["pt","en","es"]
        case "en": return ["en","de","fr","es","pt","it"]
        default:   return nil   // 其它主语种：宽松，不加限制
        }
    }

    // ============================================================
    // 第9批·改动1【最高】页面级主语种预判 + 低置信行纠错（取代旧「方向3 碎词平滑」）
    // ============================================================
    // 流程：
    //   1) 收集所有 OCR 块文本，排除「数字块」与「中文块」，拼成一整段送 fastText，
    //      得页面主语种 pageLang + 置信度 pageConf（复用现有 fastTextLang）。
    //   2) 逐块纠错：对某块，若其 fastText 置信度 <0.45 且 Apple NL 置信度 <0.45（该块本身低置信），
    //      且非「硬命中」(blockHardHit：forceWords/变音符/西里尔/后缀硬规则) → 归入 pageLang。
    //   3) 若 pageConf < 0.4（真正混语页面）→ 整页不纠错，保持逐块原判。
    // 与旧口径合并说明：
    //   • 旧「方向3」用「词长≤5 碎词 + 主语种占比≥80%」这种碎词启发式来平滑，属"堆规则"。
    //     本改动1改为「模型置信度」口径（该块 ft<0.45 且 nl<0.45 才算低置信），是根本解法，
    //     故删除旧方向3分支，统一为页面级预判。
    //   • 「方向7 白名单」保留：负责把「落在主语种白名单外的小语种（id/vi/pl…）」强并主语种，
    //     与改动1职责不同（一个管低置信、一个管越界小语种），互补不冲突。
    // 置信度回传口径：不改 detectBlockLang 签名（避免大改识别管线），而是在此对每块文本
    //   旁路调用 fastTextLang / nlDetect 取其置信度（两者均带缓存，OCR 阶段多为命中，开销可控）。
    func pageLevelCorrect(_ bs: [Block]) -> [Block] {
        // 收集非数字、非中文块文本（每块取其非数字 token 拼接）
        let parts: [String] = bs.compactMap { b in
            if b.lang == "zh" { return nil }   // 中文块（含跳过哨兵）不参与
            if b.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return nil }
            let toks = latinTokens(b.text).filter { !isNumericToken($0) }
            return toks.isEmpty ? nil : toks.joined(separator: " ")
        }
        // 页面主语种 + 置信度：行数过少 / fastText 不可用时置为「未知」（pageLang=nil），
        //   此时跳过「改动1 低置信行纠错」与「改动A 葡语锁定」，但仍需执行「改动B 纯拉丁行硬排除」。
        var pageLang: String? = nil
        var pageConf: Double = 0
        if parts.count >= 2 {
            let pageText = parts.joined(separator: " ")
            if let pageFt = fastTextLang(pageText), allowedLangCodes.contains(pageFt.code) {
                pageLang = pageFt.code
                pageConf = pageFt.prob
            }
        }

        // ---- 第11批·改动C：德语专属字符硬锁（放在葡语锁定「之前」，保证德语优先）----
        //   全页任一 token 含 germanLockChars(ä/ö/ü/ß) → 强制 pageLang 覆盖为 de。
        //   优先级高于 fastText，与葡语锁定同级；此处先执行 → 若命中 de，后面葡语锁定因
        //   pageLang 已非 {es,fr} 而自动绕过 → 实现「同页既有 ß 又有 ã 时德语优先」的冲突规则。
        let hasDeLock = bs.contains { b in
            b.text.contains { germanLockChars.contains($0) }
        }
        if hasDeLock {
            pageLang = "de"                              // 德语字符级铁证，覆盖任何 fastText 判断
        }

        // ---- 第11批·改动D：德语高频功能词加权（词汇级信号，覆盖无变音符的德语页面）----
        //   统计全页 token 精确命中 germanFunctionWords 的次数 deHits（lowercase 精确匹配）。
        //   C 是字符级铁证，D 是词汇级信号；D 处理 C 无法命中（无变音符）的情形，如 "und der die"。
        var deHits = 0
        for b in bs {
            for tok in latinTokens(b.text) where !isNumericToken(tok) {
                if germanFunctionWords.contains(tok.lowercased()) { deHits += 1 }
            }
        }
        //   deHits≥2 且 pageLang != de → 覆盖为 de（德语功能词密集出现，几乎必为德语页面）。
        //   deHits==1 时不在此覆盖，仅作为下方「低置信行纠错」的加权信号（见改动D-2）。
        if deHits >= 2 && pageLang != "de" {
            pageLang = "de"
        }

        // ---- 第10批·改动A：葡语专属重音锁定（在 pageLang 确定后、用于纠错之前立即执行）----
        //   扫描全页所有 OCR 块字符，若任一块含 portugueseLockChars(ê/ã/ç/õ/â/ô)，且当前
        //   pageLang ∈ {es, fr} → 强制覆盖为 pt。优先级高于 fastText 的页面级判断。
        //   pageLang 已是 pt / 其它语种 / nil 时不改（按用户规则仅拦截 es/fr）。
        if let pl = pageLang, pl == "es" || pl == "fr" {
            let hasPtLock = bs.contains { b in
                b.text.contains { portugueseLockChars.contains($0) }
            }
            if hasPtLock { pageLang = "pt" }             // 葡语重音锁定，覆盖 es/fr
        }

        // ---- 第13批·改动K：葡语功能词加权（仿改动D）----
        //   统计全页 token 精确命中 portugueseFunctionWords 的次数 ptHits（lowercase 精确匹配）。
        //   优先级链（用户排定）：德语锁定(C/D) > 葡语字符锁定(A) > 葡语功能词(K)。
        //     • 德语变音符最唯一：若 C/D 已把 pageLang 锁为 de，则 K 一律不覆盖（下方显式 pageLang != "de" 守卫）。
        //     • 葡语字符锁定(A) 已在上方执行（可能已置 pt）；K 在其后，作为更弱的词汇级信号补充。
        //   规则：
        //     • ptHits≥2 且 pageLang ∉ {pt, de} → 覆盖为 pt（葡语功能词密集，几乎必为葡语页面）。
        //     • ptHits==1 → 行级加权（见下方 result 处理，仅当 pageLang != de）。
        var ptHits = 0
        for b in bs {
            for tok in latinTokens(b.text) where !isSkipToken(tok) {
                if portugueseFunctionWords.contains(tok.lowercased()) { ptHits += 1 }
            }
        }
        if ptHits >= 2 && pageLang != "pt" && pageLang != "de" {
            pageLang = "pt"                              // 德语已锁 de 时不进入（德语优先）
        }

        // ---- 第9批·改动1：页面级低置信行纠错（仅当 pageLang 已知且 pageConf≥0.4）----
        var result = bs
        if let pl = pageLang, pageConf >= 0.4 {          // pageConf<0.4：真正混语页面 → 不纠错
            result = bs.map { b in
                guard b.lang != "name" && b.lang != "zh" && b.lang != "num" else { return b }
                if b.lang == pl { return b }
                if blockHardHit(b.text) { return b }     // 硬命中豁免
                let ftP = fastTextLang(b.text)?.prob ?? 0
                let nlP = nlDetect(b.text)?.prob ?? 0
                if ftP < 0.45 && nlP < 0.45 {            // 该块本身低置信 → 归页面主语种
                    return Block(text: b.text, box: b.box, lang: pl)
                }
                return b
            }
        }

        // ---- 第11批·改动D-2：deHits==1 加权（词汇级弱信号，仅在低置信行纠错阶段生效）----
        //   当全页恰有 1 个德语功能词命中（不足以直接覆盖 pageLang），把它作为加权信号：
        //   对某行，若其 fastText 结果为 en 且置信度 <0.55（英语判定不牢靠）→ 改判 de。
        //   复用改动1旁路取 fastText 结果/置信度的方式（fastTextLang 带缓存，开销可控）。
        //   硬命中行豁免；name/zh/num 不动。与改动C(字符铁证)关系：C 命中即已锁 de 不进此分支。
        if deHits == 1 {
            result = result.map { b in
                guard b.lang != "name" && b.lang != "zh" && b.lang != "num" else { return b }
                if b.lang == "de" { return b }
                if blockHardHit(b.text) { return b }
                if let ft = fastTextLang(b.text), ft.code == "en", ft.prob < 0.55 {
                    return Block(text: b.text, box: b.box, lang: "de")
                }
                return b
            }
        }

        // ---- 第13批·改动K-2：ptHits==1 行级加权（词汇级弱信号）----
        //   当全页恰有 1 个葡语功能词命中（不足以直接覆盖 pageLang），作为加权信号：
        //   对某行，若其 fastText 结果为 en 或 es 且置信度 <0.55（判定不牢靠）→ 改判 pt。
        //   德语优先：pageLang 已锁 de 时整个 K-2 跳过（不与德语打架）。硬命中行豁免；name/zh/num 不动。
        if ptHits == 1 && pageLang != "de" {
            result = result.map { b in
                guard b.lang != "name" && b.lang != "zh" && b.lang != "num" else { return b }
                if b.lang == "pt" { return b }
                if blockHardHit(b.text) { return b }
                if let ft = fastTextLang(b.text), (ft.code == "en" || ft.code == "es"), ft.prob < 0.55 {
                    return Block(text: b.text, box: b.box, lang: "pt")
                }
                return b
            }
        }

        // ---- 第10批·改动B：纯 ASCII 拉丁行 硬排除非拉丁语种（在最终判定确定后执行）----
        //   若某块被判成完全不含拉丁字母的语种 {ja,ko,ar,he,th,id}，但其文本是「纯 ASCII 拉丁行」
        //   （无任何 CJK/假名/韩文/阿拉伯/希伯来/泰文/西里尔字符），则属字符集级错误，直接覆盖：
        //     • 优先归入页面主语种 pageLang（且 pageConf≥0.4）；
        //     • 否则（pageLang 未知或 pageConf<0.4）→ 归入英语 en。
        //   注意：把拉丁行判成 ja 本身即错误，故此处不适用「硬命中豁免」——正常拉丁行也不会硬命中
        //   ja/ko 等，直接对最终语种做覆盖即可。真实 CJK/阿拉伯等文本含非拉丁字符 → isPureAsciiLatinLine
        //   返回 false → 不受影响。与 und/白名单/后缀规则不冲突（针对不同错误类型，可叠加）。
        let nonLatinLangs: Set<String> = ["ja", "ko", "ar", "he", "th", "id"]
        result = result.map { b in
            guard nonLatinLangs.contains(b.lang), isPureAsciiLatinLine(b.text) else { return b }
            if let pl = pageLang, pageConf >= 0.4 {
                return Block(text: b.text, box: b.box, lang: pl)
            }
            return Block(text: b.text, box: b.box, lang: "en")
        }
        return result
    }

    // 先做页面级纠错（改动1），再进入既有白名单归并（方向7）
    let pageBlocks = pageLevelCorrect(rawBlocks)

    let domForSmoothing = firstPassDominant(pageBlocks)
    let wl = whitelist(forMain: domForSmoothing)
    let blocks: [Block] = pageBlocks.map { b in
        // 只处理真实语种 token；und/name/zh(已跳过)/num 保持原样
        guard b.lang != "und" && b.lang != "name" && b.lang != "num" && domForSmoothing != "und"
              && b.lang != domForSmoothing else { return b }
        // 硬命中豁免：forceWords/变音符/西里尔/后缀硬规则命中 → 保留原判，避免误伤真实混语
        if blockHardHit(b.text) { return b }
        // 方向7：语种 ∉ 主语种白名单 → 归主语种
        if let wl = wl, !wl.contains(b.lang) {
            return Block(text: b.text, box: b.box, lang: domForSmoothing)
        }
        return b
    }

    // 占比汇总：包含 专名；排除 未识别 与 数字(num)。
    //   第7批：数字 token 早在 detectBlockLang 阶段即以 "zh" 哨兵被 continue 跳过，
    //   理论上 blocks 不含 "num"；此处仍显式排除 "num"，双保险确保 total 分母与顶部条目都不含数字。
    var counts: [String: Int] = [:]
    for b in blocks where b.lang != "und" && b.lang != "num" {
        counts[b.lang, default: 0] += letterCount(b.text)
    }
    let sorted = counts.sorted { $0.value > $1.value }
    // 第8批·最高：未识别(und) 需在顶部按"未识别 X%"统计并以灰色显示（区别于数字跳过：数字不显示）。
    //   仅用于展示的 breakdown：在真实语种之后追加 und 条目；不影响 mainLang/mixed 的真实语种判断。
    let undCount = blocks.filter { $0.lang == "und" }.reduce(0) { $0 + letterCount($1.text) }
    var displayBreakdown = sorted
    if undCount > 0 { displayBreakdown.append(("und", undCount)) }
    // 主体语种 / 混语：仅按"真实语种"判断（排除 name/num/und）
    let realLangs = sorted.filter { $0.key != "name" && $0.key != "num" }
    let mainLang = realLangs.first?.key ?? (sorted.first?.key ?? "und")
    var mixed = false
    let total = realLangs.reduce(0) { $0 + $1.1 }
    if realLangs.count >= 2, total > 0 {
        let share = Double(realLangs[1].value) / Double(total)
        if share >= 0.15 && realLangs[1].value >= 3 { mixed = true }
    }
    // 单语简洁模式：某一真实语言占比 ≥80%（或仅一种真实语言）→ 只显示「整体：X」，不画分行色块
    var singleDominant = false
    var dominantLang = mainLang
    if let top = realLangs.first, total > 0 {
        dominantLang = top.key
        // 任务【最高优先级】：仅当"真实只有一种语言"才用简洁模式；只要有≥2种真实语言，
        //   即使某语占比≥80% 也保留混语分块+占比，绝不退化为"整体判断一种语言"。
        if realLangs.count <= 1 && Double(top.value) / Double(total) >= 0.80 { singleDominant = true }
    }
    // 问题5：非中文真实语言 token 极少（<3）且截图含中文/拼音 → 判「未识别（主要为中文）」，不触发整体德语
    let realBlockCount = blocks.filter { $0.lang != "und" && $0.lang != "name" && $0.lang != "num" && $0.lang != "zh" }.count
    let hasHan = blocks.contains { $0.text.unicodeScalars.contains { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) } }
    let hasPinyinUnd = blocks.contains { $0.lang == "und" && looksPinyin($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var mostlyChinese = false
    if realBlockCount < 3 && (hasHan || hasPinyinUnd) {
        mostlyChinese = true
        singleDominant = false
    }
    annotate(cg, blocks: blocks, breakdown: displayBreakdown, mixed: mixed,
             singleDominant: singleDominant, dominantLang: dominantLang, outPath: annoPath)
    let textLen = blocks.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines).count
    return DetectResult(mainLang: mainLang, mixed: mixed, breakdown: sorted,
                        blockCount: blocks.count, textLen: textLen, annotatedPath: annoPath,
                        singleDominant: singleDominant, dominantLang: dominantLang,
                        mostlyChinese: mostlyChinese)
}

// ============================================================
// MARK: - 结果展示窗口（点击任意处关闭）
// ============================================================

// 无边框窗口：需允许成为 key/main，否则无法接收鼠标事件
final class ResultWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// 容器视图：拦截整块区域的鼠标点击（含图片区域），点击即关闭窗口
final class ClickToCloseView: NSView {
    weak var targetWindow: NSWindow?
    var onClose: (() -> Void)?
    // 让所有点击都落到本视图（子视图 NSImageView 不再单独吞掉事件），
    // 从而实现「点击窗口内任意位置（含图片）都能关闭」
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
}

// ============================================================
// MARK: - 菜单栏 App
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    let shotPath = NSTemporaryDirectory() + "langbar_shot.png"
    let annoPath = NSTemporaryDirectory() + "langbar_annotated.png"

    // 结果窗口 + 窗口外点击监听
    var resultWindow: NSWindow?
    var globalClickMonitor: Any?
    // 记录本次截图所在的屏幕，供汇总弹窗 / 标注图窗口定位到同一块屏幕
    var captureScreen: NSScreen?
    // 第9批·改动3：截图完成后，用「输出图片的真实像素宽高」辅助校正的结果屏。
    //   本 App 用 screencapture -i（交互框选），图片尺寸=选区大小≠整屏，故不能纯用图片
    //   宽高反推屏幕；仅当选区恰为某屏整屏（像素宽高 ±10px 命中）时用它校正，否则回退
    //   captureScreen（热键触发瞬间锁定的鼠标屏）。所有弹窗只用 dialogScreen() 返回值。
    var resultScreen: NSScreen?

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
        // 热键触发瞬间锁定屏幕，全程复用，禁止重算：
        // 在进入任何截图逻辑之前，第一行就用鼠标当前所在屏幕锁定 captureScreen，
        // 之后所有弹窗（汇总弹窗 / 标注图窗口）都只用这个锁定值，避免异步回调期间鼠标移动导致弹窗跑屏。
        self.captureScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
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

        // 屏幕已在 capture() 入口首行锁定（captureScreen），此处不再重算，避免跑屏。

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-i", shotPath]   // -x 静音；-i 交互框选（系统原生，无自绘覆盖层）
        do { try task.run(); task.waitUntilExit() }
        catch { showDialog(title: "语种识别", msg: "无法启动截图：\(error.localizedDescription)"); return }

        guard FileManager.default.fileExists(atPath: shotPath) else { return }  // 用户取消

        // ===== 第9批·改动3：用输出图片真实像素宽高辅助校正结果屏 =====
        //   本 App 是 screencapture -i（交互框选）：图片尺寸=选区大小，通常 ≠ 整屏，
        //   故「图片宽高=屏幕宽高」不成立，纯图片反推不可用。此处仅做「整屏选区」的辅助校正：
        //   读图真实像素宽高（用 NSBitmapImageRep.pixelsWide/High，避免 NSImage.size 点单位误差），
        //   遍历各屏 frame.width*backingScaleFactor / frame.height*backingScaleFactor（像素），
        //   若某屏与图片像素宽高误差 ±10px 内 → 认定选区即该整屏，用它作 resultScreen；
        //   否则（普通局部框选）回退到 captureScreen（热键锁定的鼠标屏），绝不跑屏。
        resultScreen = captureScreen   // 默认：热键锁定屏（最稳）
        if let img = NSImage(contentsOfFile: shotPath),
           let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            let pxW = CGFloat(rep.pixelsWide), pxH = CGFloat(rep.pixelsHigh)
            if pxW > 0 && pxH > 0 {
                let tol: CGFloat = 10
                var best: (screen: NSScreen, diff: CGFloat)? = nil
                for s in NSScreen.screens {
                    let sw = s.frame.width * s.backingScaleFactor
                    let sh = s.frame.height * s.backingScaleFactor
                    let diff = abs(sw - pxW) + abs(sh - pxH)
                    if best == nil || diff < best!.diff { best = (s, diff) }
                }
                if let b = best, abs(b.screen.frame.width * b.screen.backingScaleFactor - pxW) <= tol,
                   abs(b.screen.frame.height * b.screen.backingScaleFactor - pxH) <= tol {
                    resultScreen = b.screen   // 选区恰为整屏 → 用图片像素反推校正
                }
                // 非整屏框选：resultScreen 保持 captureScreen（不用尺寸最接近屏，避免误判）
            }
        }

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
                // 汇总弹窗（双按钮）：显示在截图所在屏幕
                let total = r.breakdown.reduce(0) { $0 + $1.1 }
                let msg: String
                if r.mostlyChinese {
                    msg = """
                    整体：未识别（主要为中文）

                    （非中文文字过少，且多为拼音，不做语种判定）
                    """
                } else if r.singleDominant {
                    // 单语简洁模式：整体一种语言 ≥80%，直接给结论，不列分行占比
                    msg = """
                    整体：\(cnName(r.dominantLang))
                    文本块数：\(r.blockCount)

                    （单一语言占比 ≥80%，不再分行标注）
                    """
                } else {
                    var lines: [String] = []
                    for (code, cnt) in r.breakdown {
                        let pct = total > 0 ? Int((Double(cnt) / Double(total) * 100).rounded()) : 0
                        lines.append("\(cnName(code))  \(pct)%")
                    }
                    let breakStr = lines.isEmpty ? "（无可信语种）" : lines.joined(separator: "\n")
                    msg = """
                    主体语种：\(cnName(r.mainLang))
                    是否混语：\(r.mixed ? "是" : "否")
                    文本块数：\(r.blockCount)

                    各语种占比：
                    \(breakStr)

                    （专名=人名/地名，数字=纯数字，虚线灰框=未识别）
                    """
                }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "语种识别结果"
                alert.informativeText = msg
                alert.addButton(withTitle: "查看详细标注")   // 左：默认按钮 → 打开标注图
                alert.addButton(withTitle: "好的")           // 右：取消按钮 → 直接关闭
                // 布局后把弹窗居中到「弹窗时刻鼠标所在屏幕」（任务4 防护），再走模态
                alert.layout()
                self.center(alert.window, on: self.dialogScreen())
                let resp = NSApp.runModal(for: alert.window)
                alert.window.orderOut(nil)
                if resp == .alertFirstButtonReturn {
                    // 「查看详细标注」→ 打开标注图窗口
                    if FileManager.default.fileExists(atPath: r.annotatedPath) {
                        self.openInPreview(r.annotatedPath)
                    }
                }
                // 「好的」(.alertSecondButtonReturn) → 什么都不做，直接关闭
            }
        }
    }

    // 第9批·改动3：结果弹窗应显示的屏幕。
    //   定位优先级：resultScreen（截图完成后经图片像素校正/回退得到）→ captureScreen
    //   （热键触发瞬间锁定的鼠标屏）→ 主屏。彻底不再调用 targetScreen()/NSEvent.mouseLocation，
    //   避免异步 OCR 回调期间鼠标移动导致弹窗跑屏。targetScreen() 已废弃删除。
    func dialogScreen() -> NSScreen? {
        return resultScreen ?? captureScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    // 把窗口居中到指定屏幕的可视区域；screen 为空则回退到系统默认居中
    func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen = screen else { window.center(); return }
        let vf = screen.visibleFrame
        let f = window.frame
        let x = vf.origin.x + (vf.width - f.width) / 2
        let y = vf.origin.y + (vf.height - f.height) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
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

        • 覆盖语种：意/葡/越/印尼/日/韩/泰/阿/德/法/英
        • 中文文字：自动跳过，不识别、不标注、不计入占比统计
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

    // 自定义窗口展示标注图：点击窗口内任意位置（含图片区域）或点击窗口外部即可关闭，
    // 无需点左上角关闭按钮。窗口无边框、自适应图片尺寸、居中、带圆角与阴影。
    func openInPreview(_ path: String) {
        guard let image = NSImage(contentsOfFile: path) else {
            // 兜底：读图失败则退回系统默认方式打开
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        // 先关闭上一次的结果窗口，避免叠加
        closeResultWindow()

        // 计算窗口尺寸：自适应图片，但不超过（弹窗时刻鼠标所在）屏幕可视区域的 85%
        let screen = dialogScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = visible.width * 0.85
        let maxH = visible.height * 0.85
        var imgSize = image.size
        if imgSize.width <= 0 || imgSize.height <= 0 { imgSize = NSSize(width: 800, height: 600) }
        let scale = min(maxW / imgSize.width, maxH / imgSize.height, 1.0)
        let winSize = NSSize(width: floor(imgSize.width * scale),
                             height: floor(imgSize.height * scale))

        // 无边框窗口（透明背景，便于展示圆角与阴影）
        let win = ResultWindow(contentRect: NSRect(origin: .zero, size: winSize),
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true                 // 轻微阴影
        win.level = .floating                // 浮在其它窗口之上
        win.isReleasedWhenClosed = false
        win.delegate = self

        // 圆角容器（点击任意位置关闭）
        let container = ClickToCloseView(frame: NSRect(origin: .zero, size: winSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.targetWindow = win
        container.onClose = { [weak self] in self?.closeResultWindow() }

        let imageView = NSImageView(frame: container.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        win.contentView = container
        center(win, on: screen)   // 居中到截图所在屏幕

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        resultWindow = win

        // 点击「窗口外部 / 其它 App」也关闭：监听全局鼠标按下事件
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeResultWindow()
        }
    }

    // 关闭结果窗口并清理全局点击监听
    func closeResultWindow() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
        resultWindow?.orderOut(nil)
        resultWindow?.close()
        resultWindow = nil
    }

    // 结果窗口失去焦点（点了别处/切到别的 App）时也关闭
    func windowDidResignKey(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === resultWindow {
            closeResultWindow()
        }
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
