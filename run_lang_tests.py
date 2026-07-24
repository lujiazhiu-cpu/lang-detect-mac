#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_lang_tests.py — macOS 语种识别 App 离线文本测试集运行器

用途：
    改完 LangBarApp.swift 的词库（*ForceList / *Stopwords / 字符集）后，
    无需截图，直接跑本脚本秒验：读取 lang_test_cases.json，对每个 token 做
    语种判定，输出通过/失败统计与失败明细。

判定策略（与 LangBarApp.swift 的 detectBlockLangImpl 对齐）：
    1) 动态解析同目录下 LangBarApp.swift，提取全部词库（force list / stopwords /
       字符集 / 后缀 / 词根 / 人名），因此改词库后本脚本自动跟随，无需改代码。
    2) 复刻数字判定 → 单 token 优先级链 → 多 token 打分（latinLangScore/bestLatinLang）。
    3) 规则无法判定时，回退到 macOS NaturalLanguage 的 NLLanguageRecognizer
       （通过 PyObjC；若未安装则跳过该回退，判为 und 并在明细中标注）。

限制：
    - NSSpellChecker 词典命中（spellHits）无法在纯 Python 侧复刻，故涉及拼写词典
      的分支被降级为“未命中”。绝大多数词库相关用例不依赖拼写词典，不影响验证。

运行：python3 run_lang_tests.py   （在 macOS 上，Python 3）
"""

import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT_PATH = os.path.join(HERE, "LangBarApp.swift")
CASES_PATH = os.path.join(HERE, "lang_test_cases.json")

# ============================================================
# Swift 词库解析
# ============================================================

def _read_swift():
    with open(SWIFT_PATH, "r", encoding="utf-8") as f:
        return f.read()


def _extract_bracket_block(src, name):
    """定位 `let <name> ... = [ ... ]`，返回方括号内的原始文本（含注释）。"""
    m = re.search(r"\blet\s+" + re.escape(name) + r"\b[^\[]*=\s*\[", src)
    if not m:
        return None
    i = m.end() - 1  # 指向 '['
    depth = 0
    start = i
    while i < len(src):
        c = src[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return src[start + 1:i]
        i += 1
    return None


def _strip_comments(block):
    """逐行去掉 // 行内注释。"""
    out = []
    for line in block.splitlines():
        idx = line.find("//")
        if idx != -1:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)


_STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def parse_string_set(src, name, lower=True):
    """解析 Set<String> / [String] 字面量为 python set（默认小写）。"""
    block = _extract_bracket_block(src, name)
    if block is None:
        return set()
    block = _strip_comments(block)
    vals = _STR_RE.findall(block)
    vals = [v.encode("utf-8").decode("unicode_escape") if "\\" in v else v for v in vals]
    return set(v.lower() for v in vals) if lower else set(vals)


def parse_string_list(src, name):
    """解析为保持顺序、原样（不小写）的列表——用于后缀集。"""
    block = _extract_bracket_block(src, name)
    if block is None:
        return []
    block = _strip_comments(block)
    return _STR_RE.findall(block)


def parse_char_set(src, name):
    """字符集：每个元素是单字符（去重后放入 set）。"""
    block = _extract_bracket_block(src, name)
    if block is None:
        return set()
    block = _strip_comments(block)
    return set(_STR_RE.findall(block))


def parse_suffix_minlen(src, name):
    """解析 germanSuffixMinLen 形如 ("schaft", 7) 的元组列表。"""
    block = _extract_bracket_block(src, name)
    if block is None:
        return []
    block = _strip_comments(block)
    pairs = re.findall(r'\(\s*"([^"]+)"\s*,\s*(\d+)\s*\)', block)
    return [(s.lower(), int(n)) for s, n in pairs]


# ============================================================
# 载入全部词库
# ============================================================

SRC = _read_swift()

englishForceList   = parse_string_set(SRC, "englishForceList")
germanForceList    = parse_string_set(SRC, "germanForceList")
frenchForceList    = parse_string_set(SRC, "frenchForceList")
italianForceList   = parse_string_set(SRC, "italianForceList")
portugueseForceList = parse_string_set(SRC, "portugueseForceList")
spanishForceList   = parse_string_set(SRC, "spanishForceList")
indonesianForceList = parse_string_set(SRC, "indonesianForceList")

germanStopwords     = parse_string_set(SRC, "germanStopwords")
englishStopwords    = parse_string_set(SRC, "englishStopwords")
frenchStopwords     = parse_string_set(SRC, "frenchStopwords")
italianStopwords    = parse_string_set(SRC, "italianStopwords")
portugueseStopwords = parse_string_set(SRC, "portugueseStopwords")
spanishStopwords    = parse_string_set(SRC, "spanishStopwords")
indonesianStopwords = parse_string_set(SRC, "indonesianStopwords")
polishStopwords     = parse_string_set(SRC, "polishStopwords")
vietnameseStopwords = parse_string_set(SRC, "vietnameseStopwords")
vietnameseWeakWords = parse_string_set(SRC, "vietnameseWeakWords")

germanRoots      = parse_string_set(SRC, "germanRoots")
germanGivenNames = parse_string_set(SRC, "germanGivenNames")

italianSuffixes    = [s.lower() for s in parse_string_list(SRC, "italianSuffixes")]
spanishSuffixes    = [s.lower() for s in parse_string_list(SRC, "spanishSuffixes")]
indonesianSuffixes = [s.lower() for s in parse_string_list(SRC, "indonesianSuffixes")]
portugueseSuffixes = [s.lower() for s in parse_string_list(SRC, "portugueseSuffixes")]
germanSuffixMinLen = parse_suffix_minlen(SRC, "germanSuffixMinLen")

germanChars   = parse_char_set(SRC, "germanChars")
frenchChars   = parse_char_set(SRC, "frenchChars")
italianChars  = parse_char_set(SRC, "italianChars")
spanishDistinctChars = parse_char_set(SRC, "spanishDistinctChars")
spanishAccentChars   = parse_char_set(SRC, "spanishAccentChars")
portugueseDistinctChars = parse_char_set(SRC, "portugueseDistinctChars")
vietnameseDistinctChars = parse_char_set(SRC, "vietnameseDistinctChars")
polishChars   = parse_char_set(SRC, "polishChars")
sharedRomanceAccents = parse_char_set(SRC, "sharedRomanceAccents")

# 法语固定后缀（在 tokenLooksFrench 中硬编码，非独立词库）
FRENCH_SUFFIXES = ["tion", "sion", "ique", "aine", "esse", "eur", "euse", "ité", "ais", "aise"]

# ============================================================
# 谓词函数（对齐 Swift）
# ============================================================

_TRIM_PUNCT = ".,:;!?\"'()[]{}·—-"


def latin_tokens(text):
    toks = re.split(r"[ \n\t]+", text)
    out = []
    for t in toks:
        t = t.strip(_TRIM_PUNCT)
        if t:
            out.append(t)
    return out


def is_numeric_token(token):
    lower = token.lower()
    if not any(ch.isdigit() for ch in lower):
        return False
    s = lower
    for unit in ["uhr", "cm", "mm", "px", "kg", "km"]:
        s = s.replace(unit, "")
    strip = set("0123456789.,-:/%€$£×xh '’")
    s = "".join(ch for ch in s if ch not in strip)
    return s == ""


def is_capitalized_token(token):
    if not token:
        return False
    f = token[0]
    return f == f.upper() and f != f.lower()


def is_proper_noun_like(text):
    tokens = latin_tokens(text)
    if not tokens:
        return False
    has_letter = False
    for tok in tokens:
        has_digit = any(ch.isdigit() for ch in tok)
        letters = [ch for ch in tok if ch.isalpha()]
        if letters:
            has_letter = True
        first_is_upper = (tok[0] == tok[0].upper() and tok[0] != tok[0].lower()) if tok else False
        all_upper = bool(letters) and tok.upper() == tok
        if first_is_upper or all_upper or has_digit:
            continue
        return False
    return has_letter


# ---- 德语 ----
def token_looks_german(token):
    if any(ch in germanChars for ch in token):
        return True
    lower = token.lower()
    for suf, minlen in germanSuffixMinLen:
        if len(lower) >= minlen and lower.endswith(suf):
            return True
    for root in germanRoots:
        if root in lower:
            return True
    return False


def is_german_given_name(token):
    if not is_capitalized_token(token):
        return False
    return token.lower() in germanGivenNames


def is_german_forced(token):
    return token.lower() in germanForceList


def has_german_feature(tokens):
    return any(token_looks_german(t) or is_german_given_name(t) for t in tokens)


# ---- 英语 ----
def is_english_forced(token):
    return token.lower() in englishForceList


# ---- 法语 ----
_ELISION = ["l'", "d'", "j'", "qu'", "n'", "s'", "t'", "c'", "m'"]


def strip_elision(lower):
    for p in _ELISION:
        if lower.startswith(p):
            return lower[len(p):]
    return lower


def token_looks_french(token):
    if any(ch in frenchChars for ch in token):
        return True
    if strip_elision(token.lower()) in frenchStopwords:
        return True
    lowerf = strip_elision(token.lower())
    if len(lowerf) >= 6:
        for suf in FRENCH_SUFFIXES:
            if lowerf.endswith(suf):
                return True
    return False


def is_french_forced(token):
    return token.lower() in frenchForceList


def has_french_elision(token):
    lower = token.lower()
    for p in ["s'", "l'", "d'", "n'", "j'", "c'", "m'", "qu'",
              "s’", "l’", "d’", "n’", "j’", "c’", "m’", "qu’"]:
        if lower.startswith(p):
            return True
    return False


# ---- 意大利语 ----
def token_looks_italian(token):
    if any(ch in italianChars for ch in token):
        return True
    lower = token.lower()
    if lower in italianStopwords:
        return True
    if len(lower) >= 6:
        for suf in italianSuffixes:
            if lower.endswith(suf):
                return True
    return False


def is_italian_forced(token):
    return token.lower() in italianForceList


def has_italian_elision(token):
    lower = token.lower()
    for p in ["l'", "l’", "dell'", "dell’", "all'", "all’", "nell'", "nell’",
              "sull'", "sull’", "un'", "un’"]:
        if lower.startswith(p):
            rest = lower[len(p):]
            if rest and (rest in italianForceList or token_looks_italian(rest)):
                return True
    return False


# ---- 葡萄牙语 ----
def is_portuguese_forced(token):
    return token.lower() in portugueseForceList


def token_looks_portuguese(token):
    if any(ch in portugueseDistinctChars for ch in token):
        return True
    if is_portuguese_forced(token):
        return True
    lower = token.lower()
    if lower in portugueseStopwords:
        return True
    if len(lower) >= 5:
        for suf in portugueseSuffixes:
            if lower.endswith(suf):
                return True
    return False


# ---- 西班牙语 ----
def is_spanish_forced(token):
    return token.lower() in spanishForceList


def token_looks_spanish(token):
    if any(ch in spanishDistinctChars for ch in token):
        return True
    if any(ch in spanishAccentChars for ch in token):
        return True
    if is_spanish_forced(token):
        return True
    lower = token.lower()
    if lower in spanishStopwords:
        return True
    if len(lower) >= 5:
        for suf in spanishSuffixes:
            if lower.endswith(suf):
                return True
    return False


# ---- 印尼语 ----
def is_indonesian_forced(token):
    return token.lower() in indonesianForceList


def token_looks_indonesian(token):
    lower = token.lower()
    if lower in indonesianForceList:
        return True
    if lower in indonesianStopwords:
        return True
    if len(lower) >= 6:
        for suf in indonesianSuffixes:
            if lower.endswith(suf):
                return True
        if lower.startswith(("ber", "per", "meng", "mem")):
            return True
    # di 前缀分支依赖拼写词典（spellHits），纯 Python 侧无法复刻，安全跳过
    return False


# ---- 波兰语 ----
def token_looks_polish(token):
    if any(ch in polishChars for ch in token):
        return True
    lower = token.lower()
    if lower == "zł" or lower.endswith("zł"):
        return True
    return lower in polishStopwords


# ---- 越南语 ----
def has_vietnamese_char(token):
    return any(ch in vietnameseDistinctChars for ch in token)


def token_looks_vietnamese(token):
    if has_vietnamese_char(token):
        return True
    return token.lower() in vietnameseStopwords


# ============================================================
# latinLangScore / bestLatinLang（多 token 打分）
#   注：spellHits 无法复刻，h.de/h.en 恒为 False（词库用例不依赖拼写词典）
# ============================================================

def latin_lang_score(tokens):
    s = {"de": 0, "en": 0, "fr": 0, "pl": 0, "it": 0, "vi": 0, "pt": 0, "id": 0, "es": 0}
    ctx_has_viet = any(has_vietnamese_char(t) for t in tokens)
    ctx_has_french = any(is_french_forced(t) or has_french_elision(t) or t.lower() in frenchStopwords for t in tokens)
    ctx_has_spanish = any(any(ch in spanishDistinctChars for ch in t) or is_spanish_forced(t) for t in tokens)

    for tok in tokens:
        lower = tok.lower()
        h_de = False  # spellHits 降级
        h_en = False
        if is_english_forced(tok):
            s["en"] += 3
        if is_german_forced(tok):
            s["de"] += 3
        if lower in germanStopwords:
            s["de"] += 3
        if lower in englishStopwords:
            s["en"] += 2
        if token_looks_german(tok) or is_german_given_name(tok):
            s["de"] += 2
        if is_french_forced(tok):
            s["fr"] += 4
        if has_french_elision(tok):
            s["fr"] += 3
        if token_looks_french(tok):
            s["fr"] += 2
        if is_italian_forced(tok):
            s["it"] += 4
        elif (not h_en) and token_looks_italian(tok):
            s["it"] += 2
        if has_italian_elision(tok):
            s["it"] += 4
        if token_looks_polish(tok):
            s["pl"] += 2
        if any(ch in portugueseDistinctChars for ch in tok):
            s["pt"] += 3
        if is_portuguese_forced(tok):
            s["pt"] += 3
        elif token_looks_portuguese(tok):
            s["pt"] += 2
        if lower == "dirgahayu":
            s["id"] += 5
        elif is_indonesian_forced(tok):
            s["id"] += 4
        if lower in indonesianStopwords:
            s["id"] += 2
        elif (not h_en) and token_looks_indonesian(tok):
            s["id"] += 2
        if has_vietnamese_char(tok):
            s["vi"] += 8
        elif lower in vietnameseStopwords:
            s["vi"] += 3
        tok_has_letter = any(ch.isalpha() for ch in tok)
        if tok_has_letter:
            if any(ch in spanishDistinctChars for ch in tok):
                s["es"] += 6
            if is_spanish_forced(tok):
                s["es"] += 4
            elif (not h_en) and (not h_de) and (lower in spanishStopwords or token_looks_spanish(tok)):
                s["es"] += 2
        # 拼写词典分支（h_de/h_en）恒 False，跳过
        # 上下文加权
        if lower not in englishStopwords and not is_english_forced(tok):
            if ctx_has_viet and lower in vietnameseWeakWords:
                s["vi"] += 2
            if ctx_has_viet and not has_vietnamese_char(tok):
                s["vi"] += 2
        if ctx_has_french and any(ch in sharedRomanceAccents for ch in tok):
            s["fr"] += 2
        if ctx_has_spanish and any(ch in spanishAccentChars for ch in tok):
            s["es"] += 2
    return s


def best_latin_lang(s):
    arr = sorted(s.items(), key=lambda kv: kv[1], reverse=True)
    return arr[0][0], arr[0][1], arr[0][1] - arr[1][1]


# ============================================================
# NaturalLanguage 回退（PyObjC，可选）
# ============================================================

def nl_detect(text):
    """返回 (code, ok)；PyObjC/NaturalLanguage 不可用时返回 (None, False)。"""
    try:
        from NaturalLanguage import NLLanguageRecognizer  # type: ignore
    except Exception:
        return None, False
    try:
        r = NLLanguageRecognizer.alloc().init()
        r.processString_(text)
        lang = r.dominantLanguage()
        if not lang:
            return None, False
        code = str(lang)
        if code.startswith("zh"):
            code = "zh"
        return code, True
    except Exception:
        return None, False


# ============================================================
# 主判定：对齐 detectBlockLangImpl（拉丁文本子集）
# ============================================================

ALLOWED = {"it", "pt", "vi", "id", "ja", "ko", "th", "ar", "de", "fr", "en", "pl", "es", "zh"}


def detect_lang(text):
    """返回 (code, rule) —— rule 说明命中的判定路径，便于排查。"""
    t = text.strip()
    # 统计字母/数字/非拉丁脚本
    latin_letters = 0
    digit_count = 0
    non_latin = 0
    for ch in t:
        o = ord(ch)
        if (0x0E00 <= o <= 0x0E7F or 0x0600 <= o <= 0x06FF or 0x4E00 <= o <= 0x9FFF or
                0xAC00 <= o <= 0xD7AF or 0x3040 <= o <= 0x30FF):
            non_latin += 1
        elif ch.isalpha():
            latin_letters += 1
        elif ch.isdigit():
            digit_count += 1

    # ① 无字母无非拉丁脚本
    if latin_letters == 0 and non_latin == 0:
        if digit_count > 0:
            return "num", "digits-only"
        return "und", "symbols-only"

    tokens = latin_tokens(t)
    tokens_nz = [tok for tok in tokens if not is_numeric_token(tok)]
    if tokens and not tokens_nz:
        return "zh", "all-numeric-skip"

    score = latin_lang_score(tokens_nz)
    letters = latin_letters

    # ③-a 单 token 优先级链
    if len(tokens_nz) <= 1:
        if tokens_nz:
            one = tokens_nz[0]
            if any(ch in spanishDistinctChars for ch in one):
                return "es", "single:spanish-distinct-char"
            if token_looks_vietnamese(one):
                return "vi", "single:vietnamese"
            if is_indonesian_forced(one):
                return "id", "single:indonesian-force"
            if has_italian_elision(one):
                return "it", "single:italian-elision"
            if is_french_forced(one):
                return "fr", "single:french-force"
            if has_french_elision(one):
                return "fr", "single:french-elision"
            if is_spanish_forced(one):
                return "es", "single:spanish-force"
            if is_english_forced(one):
                return "en", "single:english-force"
            if is_german_forced(one):
                return "de", "single:german-force"
            if is_italian_forced(one):
                return "it", "single:italian-force"
            if token_looks_german(one) or is_german_given_name(one):
                return "de", "single:german-feature"
            if token_looks_french(one):
                return "fr", "single:french-feature"
            if token_looks_polish(one):
                return "pl", "single:polish-feature"
            if token_looks_italian(one):
                return "it", "single:italian-feature"
            if is_portuguese_forced(one):
                return "pt", "single:portuguese-force"
            if token_looks_portuguese(one):
                return "pt", "single:portuguese-feature"
            if token_looks_indonesian(one):
                return "id", "single:indonesian-feature"
            if token_looks_spanish(one):
                return "es", "single:spanish-feature"
            # spellHits 分支跳过
            if is_proper_noun_like(t):
                return "name", "single:proper-noun"

    # ③-b 规则强信号
    if letters >= 3:
        code, sc, margin = best_latin_lang(score)
        if sc >= 2 and margin >= 2:
            return code, "multi:score(%s=%d,margin=%d)" % (code, sc, margin)

    # ④ NaturalLanguage 回退
    if letters >= 3:
        nl_input = " ".join(re.split(r"[ \n\t\r]+", t))
        code, ok = nl_detect(nl_input)
        if ok and code in ALLOWED:
            best_code, sc, margin = best_latin_lang(score)
            if sc >= 2 and margin >= 2 and best_code != code:
                return best_code, "multi:score-override-nl"
            if code == "de" and not has_german_feature(tokens_nz) and sc >= 2 and best_code != "de":
                return best_code, "nl:de-no-feature-override"
            return code, "nl:dominant"

    # ⑤ 专名兜底
    if is_proper_noun_like(t):
        if has_german_feature(tokens_nz) and score["en"] < 2:
            return "de", "propernoun:german-feature"
        return "name", "propernoun"

    if letters < 2:
        return "und", "too-short"

    # ⑦ 最后再试 NL（无约束）
    code, ok = nl_detect(t)
    if ok and code in ALLOWED:
        return code, "nl:fallback"
    return "und", "undecided(no-NL)"


# ============================================================
# 运行测试
# ============================================================

def main():
    if not os.path.exists(SWIFT_PATH):
        print("[ERROR] 找不到 LangBarApp.swift：%s" % SWIFT_PATH)
        return 2
    if not os.path.exists(CASES_PATH):
        print("[ERROR] 找不到 lang_test_cases.json：%s" % CASES_PATH)
        return 2

    with open(CASES_PATH, "r", encoding="utf-8") as f:
        cases = json.load(f)

    # 词库加载概览
    print("=" * 68)
    print("词库加载概览（来自 LangBarApp.swift）")
    print("-" * 68)
    print("  en-force=%d de-force=%d fr-force=%d it-force=%d" % (
        len(englishForceList), len(germanForceList), len(frenchForceList), len(italianForceList)))
    print("  pt-force=%d es-force=%d id-force=%d" % (
        len(portugueseForceList), len(spanishForceList), len(indonesianForceList)))
    nl_code, nl_ok = nl_detect("This is a plain english sentence for probing.")
    print("  NaturalLanguage 回退：%s" % ("可用 (PyObjC)" if nl_ok else "不可用 —— 依赖 NL 的用例将判 und"))
    print("=" * 68)

    passed, failed = 0, 0
    fail_rows = []
    for c in cases:
        token = c["token"]
        expected = c["expected"]
        got, rule = detect_lang(token)
        ok = (got == expected)
        if ok:
            passed += 1
        else:
            failed += 1
            fail_rows.append((token, expected, got, rule, c.get("desc", "")))

    total = passed + failed
    print("\n结果：通过 %d / %d，失败 %d" % (passed, total, failed))
    if fail_rows:
        print("\n失败明细：")
        print("-" * 68)
        for token, expected, got, rule, desc in fail_rows:
            print("  ✗ token=%-22r expected=%-5s got=%-5s [%s]" % (token, expected, got, rule))
            if desc:
                print("      说明：%s" % desc)
    else:
        print("\n全部用例通过 ✅")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
