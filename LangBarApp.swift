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
    "de", "fr", "en", "pl", "es", "zh"
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
let germanForceList: Set<String> = [
    "blauer","reiter","kosmos","fotografie","fotografien","herausgeber",
    "verlag","kunst","werk","statt","bau","kunstverlag","blaue","blau",
    // 德语小说/名词
    "roman",
    // 德语城市/街道地址词（命中即判德语）
    "berlin","hamburg","münchen","muenchen","köln","koeln","frankfurt","stuttgart",
    "düsseldorf","duesseldorf","leipzig","straße","strasse","str",
    // 德语语言名称（全大写形态常见）
    "deutsch","englisch","französisch","franzosisch","italienisch","spanisch",
    "japanisch","koreanisch","russisch","polnisch","arabisch","türkisch","turkisch",
    "chinesisch","griechisch","lateinisch","schwedisch","niederländisch","niederlandisch",
    "dänisch","danisch","norwegisch","finnisch","ungarisch","tschechisch","slowakisch",
    // 德语杂志/出版特有词
    "perfekt","deutschperfekt","leserbriefe","abitur","grammatik","schreiben","lesen",
    "sprechen","hörverstehen","horverstehen","vokabeln","übungen","ubungen",
    // ADESSO是意大利文（在意大利词里加），ÖSTERREICH等
    "österreich","osterreich","schweiz","österreichisch","osterreichisch",
    // 学习类词
    "lernen","lernhilfe","lernkarte",
    // 出版社/机构
    "zeitschrift","magazin","ausgabe","heft","seite",
    // 纯德语词（修复被误判「英语人名/地名」）
    "freizeit","steuersparakademie","wissen","größtes","groesstes","eisfeld",
    "jahre","jahr","werbung","medien","daten","fahren","sonntag","zahnbehandlung",
    "winterparadies","programm","größte","groesste","größer","groesser",
    "freiheit","gesundheit","sicherheit","zukunft","erfolg","angebot","angebote",
    // 德语专有月份（英德共用的 April/August/September/November 归英语，此处仅收德语独有拼写）
    "januar","februar","märz","maerz","mai","juni","juli","oktober","dezember",
    // 德语冠词/限定词（修复全大写冠词被误判为其他语种或人名/地名）
    "die","das","der","den","dem","des","ein","eine","einen","einem","einer","eines",
    // 德语音乐/出版词汇（命中即判德语，修复被判英语/意大利语）
    "operetten","musicals","spielliteratur","musikpädagogik","musikpadagogik",
    "musikbuch","neuerscheinungen","frühjahr","fruehjahr","herbst",
    "printausgaben","sonderwerbeformen","noten","notenausgabe","klavier","gesang",
    // 德语编辑注释语/常见词（命中即判德语）
    "herausgegeben","von","metropole","herausgeber","auflage","verlag","band",
    // 第6批：德语词被判英语修复（eco.nova/eco.seminare 品牌靠 seminare；feiern in Tirol 靠 feiern/tirol）
    "berge","feiern","tirol","seminare"
]
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
        for suf in ["tion","sion","ique","aine","esse","eur","euse","ité","ais","aise"] where lowerF.hasSuffix(suf) { return true }
    }
    return false
}

// 法语强制词（星期/月份/活动词，命中即高权重判法语，不区分大小写）
let frenchForceList: Set<String> = [
    "journée","journee","vendredi","lundi","mardi","mercredi","jeudi","samedi","dimanche",
    "janvier","février","fevrier","mars","avril","mai","juin","juillet","août","aout",
    "septembre","octobre","novembre","décembre","decembre",
    "théâtre","theatre","rencontres","ateliers","projections","réfugié","refugie",
    "réfugiés","refugies","billetterie","entrée","entree","adresse","association",
    "mondiale","concert","danse","repas","expo","expos",
    "méliès","melies",
    // 法语零碎词（修复被误判越南语/意大利语）
    "pratique","plein","air","caravanes","passe-partout","partir","famille",
    "balades","balade","stationnement","nouvelles","nouvelle","déjà","deja",
    "surprises","surprise","découverte","decouverte","autour","gratuit","gratuite",
    "spectacle","spectacles","exposition","expositions","atelier","ateliers",
    // 法国城市名（命中即判法语，修复被判「英语人名/地名」）
    "bayonne","roubaix","bordeaux","toulouse","marseille","nantes","strasbourg",
    "grenoble","montpellier","rennes","brest","reims","dijon","lyon","nice",
    "lille","nancy","angers","tours","orléans","orleans",
    // 法/意同形词，上下文多为法语（如 HYBRIDE）
    "hybride","hybrides",
    "mode","actus","statistiques","renversent","litterature","littérature","tech","têtu","tetu","avril","utile","mobilise","printemps","présidentielle","presidentielle","décembre","decembre","contre","pour","lucie","agnès","agnes","jean-baptiste",
    // 第6批：法语识别率补充（含变音符原样小写 + 无变音符 ASCII 变体）
    "stratégies","strategies","chaleurs","sanglier","munitions","ventes","protégées","protegees","chasseurs"
]
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
let italianForceList: Set<String> = [
    "adesso","presto","subito","ancora","sempre","bello","bella","buono","buona",
    "tutto","tutta","tutti","tutte","cosa","cose","molto","bene","male",
    "siracusa","palermo","sicilia","siciliano","siciliana",
    "amore","caro","cara","amico","amica","cuore","vita","mondo",
    "piazza","palazzo","chiesa","duomo","museo","teatro",
    "cultura","sport","feste","settimana","giorno","anno",
    "mio","mia","tuo","tua","suo","sua","noi","voi","loro",
    "nel","nella","nelle","negli","nello","alle","agli","alla","al","del","della","delle","degli","dello",
    "una","uno","non","per","che","chi","come","dove","quando","perché","perche",
    "giornale","rivista","mensile","settimanale",
    // 歌剧名/作曲家/专有词（命中即判意大利语，修复被判英语人名/地名或法语）
    "turandot","orfeo","vespri","siciliani","biennale","venezia",
    "giacomo","puccini","giuseppe","verdi","monteverdi","claudio",
    "rossini","donizetti","bellini","vivaldi","boccherini",
    // 意大利语高频短词/代词/动词（修复被误判英语或「英语人名/地名」）
    "lei","lui","lo","la","le","li","gli","cosa","nessuno","nessuna",
    "eppure","eccola","stesso","stessa","sente","sembra","prenderò","prendero",
    "conferma","profumo","pulito","persona","donna","uomo","cervello","valigia",
    "torino","pelleteria","opinione","richiesta","invadere","inarrestabile",
    "perché","perche","voglio","vorrei","chiesto","concesso","arriva","sicuro",
    "convenzionale","superficiale","sentirsi","essere","tornare","servire",
    "prendere","biglietto","aereo","giorni","mese","cuoio","così","cosi","il",
    "serve","complice","giudice","boccia","brillare","testa"
]
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
let portugueseForceList: Set<String> = [
    "aniversário","aniversario","janeiro","fevereiro","março","marco","abril","maio",
    "junho","julho","agosto","setembro","outubro","novembro","dezembro","dez",
    "coração","informação","edição",
    // 第6批：葡语识别率补充
    "copa","virada","futebol","esporte",   // 葡语特征较强，必加
    "uma",                                  // 常见葡语词，加入
    // 以下为弱信号（也可能是英语/通用词），加入但降低副作用风险，标注为弱信号：
    "era","nova","digital"
]
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
let spanishForceList: Set<String> = [
    "qué","años","año","también","español","española","españa","historia","literatura",
    "viajante","sábado","ciudad","vinhas","centro","histórico","historico","bairro",
    "arquitetura","oscura","venecia","leer","partir","familia","tiempo","ahora","siempre",
    "nunca","todo","todas","todos","toda","está","están","estás","estoy","después","despues",
    "través","traves","según","segun","además","ademas","mientras","aunque","porque",
    "cuando","dónde","donde","cómo","como","pero","para","del","las","los","una","uno",
    "por","sin","más","mas","muy","tan","ser","estar","hacer","tener","poder","querer",
    "saber","ver","dar","comer","beber","vivir","trabajar",
    // 常见西语实义/功能词补充
    "ellos","ellas","nosotros","vosotros","este","esta","esto","estos","estas","ese","esa",
    "eso","aquel","aquella","hola","gracias","buenos","buenas","dias","días","noche","noches",
    "mundo","vida","amor","tierra","fuego","agua","luz","noche","mujer","hombre","niño","niña",
    "gente","trabajo","escuela","universidad","cultura","fiesta","fiestas","semana","mes",
    "domingo","lunes","martes","miércoles","miercoles","jueves","viernes",
    "enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre","setiembre",
    "octubre","noviembre","diciembre",
    "sostenibilidad","elaborado","cifras","hormigón","hormigon","desafíos","desafios"
]
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
// 通过 Process() 调用本地 fasttext CLI + lid.176.ftz 模型（Facebook 开源，176 语言，约1MB）。
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
    if let res = Bundle.main.resourcePath { cands.append(res + "/lid.176.ftz") }
    cands.append((NSHomeDirectory() as NSString).appendingPathComponent("lang-detect-mac/Resources/lid.176.ftz"))
    cands.append("Resources/lid.176.ftz")
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
    let result = detectBlockLangImpl(text, prevToken: prevTok, nextToken: nextTok)
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

    // ① 无字母（含非拉丁脚本）但有数字 → 数字
    if latinLetters == 0 && nonLatinTotal == 0 {
        if digitCount > 0 { return ("num", true) }
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
    let tokensNZ = tokens.filter { !isNumericToken($0) }
    // 整块都是数字/日期/时间/价格 → 跳过，不识别不标注（与中文跳过一致，返回 "zh" 令 ocrBlocks 直接 continue）
    if !tokens.isEmpty && tokensNZ.isEmpty { return ("zh", true) }
    // 任务3：著名人名/地名整块短语（如 LE CORBUSIER）→ 强制「英语人名/地名」
    if properNounForcePhrases.contains(normalizedKey(t)) { return ("name", true) }
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
            // 任务A：短词(≤4字符)字符特征覆盖 —— 意语重音 à è é ì ò ù → it；
            //   法语专有 â ê î ô û ç → fr；德语 ä ö ü ß → de（不走 NL，直接采信）。
            //   放在强制词表之后，保证 qué/café 等被强制词表认领的词不被误抢。
            if one.count <= 4, let cf = shortWordCharFeature(one) { return (cf, true) }
            // 2) 德语词根/词缀/特殊字符/德语人名 → 德语
            if tokenLooksGerman(one) || isGermanGivenName(one) { return ("de", true) }
            // 3) 法语 / 波兰语特征 → 对应语种
            if tokenLooksFrench(one) { return ("fr", true) }
            if tokenLooksPolish(one) { return ("pl", true) }
            if tokenLooksItalian(one) { return ("it", true) }
            if isPortugueseForced(one) { return ("pt", true) }
            if tokenLooksPortuguese(one) { return ("pt", true) }
            if tokenLooksIndonesian(one) { return ("id", true) }
            // 3.5) 含 á é í ó ú 且未被上述任何语种认领的重音词 → 西语
            if tokenLooksSpanish(one) { return ("es", true) }
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
                // 相邻 block 文本（跳过空串）作为前/后上下文
                let prevCtx = i > 0 ? texts[..<i].last(where: { !$0.isEmpty }) : nil
                let nextCtx = i + 1 < texts.count ? texts[(i+1)...].first(where: { !$0.isEmpty }) : nil
                // 判定语种可信度
                var lang: String
                let (guessed, ok) = detectBlockLang(s, prevContext: prevCtx, nextContext: nextCtx)
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
    annotate(cg, blocks: blocks, breakdown: sorted, mixed: mixed,
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

    // 找到截图/操作所在的屏幕：优先鼠标当前所在屏幕，fallback 到主屏
    func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    // 结果弹窗应显示的屏幕：
    // 热键触发瞬间已在 capture() 入口首行把屏幕锁定到 captureScreen，全程复用，禁止重算。
    // 这里只返回锁定值，绝不再调用 targetScreen()/重新用鼠标位置计算，避免异步 OCR 回调期间鼠标移动导致跑屏。
    func dialogScreen() -> NSScreen? {
        return captureScreen ?? NSScreen.main ?? NSScreen.screens.first
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
