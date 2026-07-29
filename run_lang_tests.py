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
    """定位 `let <name> ... = [ ... ]`，返回方括号内的原始文本（含注释）。

    注意：声明可能带类型标注 `let italianSuffixes: [String] = [...]`，其中 `[String]`
    含有 `[`，故用非贪婪匹配定位到真正的 `= [` 起始处（而非类型标注里的 `[`）。
    """
    m = re.search(r"\blet\s+" + re.escape(name) + r"\b.*?=\s*\[", src)
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


def parse_raw_force_list(src, name, lower=True):
    """解析 `let <name>Raw = \"\"\" ... \"\"\"` 多行字符串块为 python set。
    对齐 Swift：`Set(<name>Raw.split(separator: \"\\n\").map(String.init))`。
    每行一个词，空行忽略。"""
    m = re.search(r"\blet\s+" + re.escape(name) + r"Raw\s*=\s*\"\"\"", src)
    if not m:
        return set()
    start = m.end()
    end = src.find('"""', start)
    if end == -1:
        return set()
    block = src[start:end]
    words = set()
    for line in block.split("\n"):
        w = line.strip()
        if w:
            words.add(w.lower() if lower else w)
    return words


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
# 五语 forceList 现为多行字符串块（let xxxForceListRaw = \"\"\"...\"\"\"），用 parse_raw_force_list 解析
germanForceList    = parse_raw_force_list(SRC, "germanForceList")
frenchForceList    = parse_raw_force_list(SRC, "frenchForceList")
italianForceList   = parse_raw_force_list(SRC, "italianForceList")
portugueseForceList = parse_raw_force_list(SRC, "portugueseForceList")
spanishForceList   = parse_raw_force_list(SRC, "spanishForceList")
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
frenchOnlyChars = parse_char_set(SRC, "frenchOnlyChars")
italianChars  = parse_char_set(SRC, "italianChars")
spanishDistinctChars = parse_char_set(SRC, "spanishDistinctChars")
spanishAccentChars   = parse_char_set(SRC, "spanishAccentChars")
portugueseDistinctChars = parse_char_set(SRC, "portugueseDistinctChars")
vietnameseDistinctChars = parse_char_set(SRC, "vietnameseDistinctChars")
polishChars   = parse_char_set(SRC, "polishChars")
sharedRomanceAccents = parse_char_set(SRC, "sharedRomanceAccents")
# 第7批·方向6：新增字符集硬规则字符集
portugueseTendChars    = parse_char_set(SRC, "portugueseTendChars")
frenchTendChars        = parse_char_set(SRC, "frenchTendChars")
hungarianDistinctChars = parse_char_set(SRC, "hungarianDistinctChars")
# 第10批·改动A：葡语专属重音锁定字符集（ê ã ç õ â ô，含大写）
portugueseLockChars    = parse_char_set(SRC, "portugueseLockChars")
# 第11批·改动C：德语专属字符硬锁字符集（ä ö ü ß，含大写）
germanLockChars        = parse_char_set(SRC, "germanLockChars")
# 第11批·改动D：德语高频功能词集（小写，token 精确匹配）
germanFunctionWords    = parse_string_set(SRC, "germanFunctionWords")
# 第13批·改动I：月份名集（小写，token 精确匹配跳过）
monthNames             = parse_string_set(SRC, "monthNames")
# 第13批·改动K：葡语功能词集（小写，token 精确匹配加权页面主语种）
portugueseFunctionWords = parse_string_set(SRC, "portugueseFunctionWords")

# 法语固定后缀（在 tokenLooksFrench 中硬编码，非独立词库）
# 第9批·改动2 根本修复：删除 "tion"/"sion"（英语 nation/action/information 高频撞车），
#   与 Swift tokenLooksFrench 对齐；无变音符裸词交 suffix_morphology_lang(英语护栏) 处理。
FRENCH_SUFFIXES = ["ique", "aine", "esse", "eur", "euse", "ité", "ais", "aise", "iste"]

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


# 第13批·改动I：时间格式 token（对齐 Swift isTimeToken）
_TIME_RE = re.compile(r"^[Hh]?\s?\d{1,2}[:hH.,]\d{2}$")


def is_time_token(token):
    return bool(_TIME_RE.match(token.strip()))


# 第14批·改动M：价格 / 期刊编号 / 条形码（对齐 Swift）
_PRICE_STRIP = set("0123456789.,-–—/€$£ '’")


def is_price_token(token):
    lower = token.lower()
    if not any(ch.isdigit() for ch in lower):
        return False
    has_symbol = ("€" in lower) or ("$" in lower) or ("£" in lower)
    has_chf = lower.startswith("chf") or lower.endswith("chf")
    has_fr = lower.startswith("fr.") or lower.endswith("fr.") or lower.startswith("fr ") or lower.endswith(" fr")
    if not (has_symbol or has_chf or has_fr):
        return False
    s = lower
    for mark in ["chf", "fr.", "fr"]:
        s = s.replace(mark, "")
    s = "".join(ch for ch in s if ch not in _PRICE_STRIP)
    return s == ""


def is_journal_number_token(token):
    lower = token.lower()
    for p in ["n°", "n.º", "nr.", "nº"]:
        if lower.startswith(p):
            return True
    return False


def is_barcode_token(token):
    digits = [ch for ch in token if ch.isdigit()]
    return len(digits) >= 8 and len(digits) == len(token)


# 第14批·改动N：品牌名 / 网址（对齐 Swift）
brandSkipList = parse_string_set(SRC, "brandSkipList")
_URL_TLDS = [".com", ".ch", ".fr", ".de", ".it", ".pt", ".es", ".net", ".org"]


def looks_like_url(token):
    lower = token.lower()
    if " " in lower or "." not in lower:
        return False
    for tld in _URL_TLDS:
        if lower.endswith(tld) or (tld + "/") in lower:
            return True
    return False


def is_brand_or_url_token(token):
    if token.lower() in brandSkipList:
        return True
    if looks_like_url(token):
        return True
    return False


# 连字符低置信品牌规则：依赖运行时 fastText 置信度(<0.4)，镜像无 fastText 运行时 → stub 恒为 False。
def is_lowercase_hyphen_token(token):  # noqa: D401 - stub（对齐 Swift isLowercaseHyphenToken 的静态部分）
    return "-" in token and token == token.lower() and any(ch.isalpha() for ch in token)


def is_skip_token(token):
    """数字 / 月份名 / 时间 / 价格 / 期刊编号 / 条形码 / 品牌网址 任一命中 → 跳过。对齐 Swift isSkipToken。"""
    if is_numeric_token(token):
        return True
    if token.lower() in monthNames:
        return True
    if is_time_token(token):
        return True
    if is_price_token(token):
        return True
    if is_journal_number_token(token):
        return True
    if is_barcode_token(token):
        return True
    if is_brand_or_url_token(token):
        return True
    return False


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

ALLOWED = {"it", "pt", "vi", "id", "ja", "ko", "th", "ar", "de", "fr", "en", "pl", "es", "ru", "zh"}


# ============================================================
# 第9批·改动2：罗曼语族 + 英语 词尾形态学（对齐 Swift suffixMorphologyLang）
# ============================================================
def suffix_morphology_lang(token):
    """取词末做后缀匹配。先匹配更长更具体的后缀。返回 es/it/pt/fr/en 或 None。"""
    lower = token.lower()
    if len(lower) < 4:
        return None
    has_french_char = any(ch in frenchChars or ch in frenchOnlyChars for ch in token)
    # ① 葡语（含鼻化/重音，最具体）
    for suf in ["ção", "ções", "ões", "ão"]:
        if lower.endswith(suf):
            return "pt"
    # ② 意语（-zione 先于 -ione）
    for suf in ["zione", "zioni", "aggio", "ione", "ità", "ello", "elli", "ismo"]:
        if lower.endswith(suf):
            return "it"
    # ③ 西语（-ción 先于 -ión）
    for suf in ["ción", "ciones", "ería", "ías", "ario", "amos", "emos", "ión"]:
        if lower.endswith(suf):
            return "es"
    # ④ 葡语（无重音形态）
    for suf in ["eiro", "eira", "inha"]:
        if lower.endswith(suf):
            return "pt"
    # ⑤ 法语（撞车后缀，需含法语变音符护栏）
    if has_french_char:
        for suf in ["tion", "sion", "ment", "eur", "eux", "eau", "ais"]:
            if lower.endswith(suf):
                return "fr"
    # ⑥ 英语护栏：纯 ASCII 无变音符 + 以 -tion/-sion/-ment 结尾 → en
    if all(ord(ch) < 128 for ch in token):
        for suf in ["tion", "tions", "sion", "sions", "ment", "ments"]:
            if lower.endswith(suf):
                return "en"
    return None


def detect_lang(text):
    """返回 (code, rule) —— rule 说明命中的判定路径，便于排查。"""
    t = text.strip()
    # ===== 第8批·最高：西里尔字母 → 强制俄语（字符集硬规则，先于一切拉丁/数字判定）=====
    #   与 Swift detectBlockLangImpl 顶部的 U+0400–U+04FF 拦截一致。
    if any(0x0400 <= ord(ch) <= 0x04FF for ch in t):
        return "ru", "cyrillic-force"
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
            # 第7批·最高优先级：数字 token 彻底跳过。Swift 侧返回 "zh" 跳过哨兵，
            #   ocrBlocks 中 guessed=="zh" 直接 continue，不计入统计/不画框/不进 total。
            return "zh", "digits-only-skip"
        return "und", "symbols-only"

    tokens = latin_tokens(t)
    tokens_nz = [tok for tok in tokens if not is_skip_token(tok)]
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
            # 第9批·改动2：罗曼语族 + 英语 词尾形态学（forceWords 之后、tokenLooks* 之前）。
            sfx = suffix_morphology_lang(one)
            if sfx is not None:
                return sfx, "single:suffix-morphology(%s)" % sfx
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
            # 第7批·方向6：字符集硬规则（forceWords/既有字符特征之后、fastText/NL 之前）
            if any(ch in hungarianDistinctChars for ch in one):
                return "und", "single:hungarian-char-und"  # ő/ű→hu 未支持→und
            if any(ch in portugueseTendChars for ch in one):
                return "pt", "single:portuguese-tend-char"  # ã/õ→葡
            if any(ch in frenchTendChars for ch in one):
                return "fr", "single:french-tend-char"      # œ/æ/à/è→法
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
# 第10批·改动A/B：页面级逻辑镜像（对齐 Swift pageLevelCorrect）
# ============================================================
# 说明：run_lang_tests.py 的 detect_lang 镜像的是 **单块** detectBlockLangImpl。
#   而改动A（葡语页面锁定）与改动B（纯 ASCII 拉丁行硬排除）位于 **页面级聚合**
#   pageLevelCorrect 中，需要「整页多块 + 页面主语种/置信度」上下文，单 token 用例无法覆盖。
#   为可离线确定性验证，这里补充与 Swift 一致的两个页面级镜像函数 + 专用 page 用例类型
#   （见 lang_test_cases.json 中带 "page_a" / "page_b" 键的用例）。

NONLATIN_LANGS = {"ja", "ko", "ar", "he", "th", "id"}


def is_pure_ascii_latin_line(text):
    """镜像 Swift isPureAsciiLatinLine：不含 CJK/假名/韩文/阿拉伯/希伯来/泰文/西里尔字符，
       且至少含一个 ASCII 字母（a–z/A–Z）。"""
    has_ascii_letter = False
    for ch in text:
        v = ord(ch)
        if (0x4E00 <= v <= 0x9FFF or 0x3400 <= v <= 0x4DBF          # CJK
                or 0x3040 <= v <= 0x30FF                            # 假名
                or 0xAC00 <= v <= 0xD7AF or 0x1100 <= v <= 0x11FF
                or 0x3130 <= v <= 0x318F                            # 韩文
                or 0x0600 <= v <= 0x06FF or 0x0750 <= v <= 0x077F
                or 0x08A0 <= v <= 0x08FF or 0xFB50 <= v <= 0xFDFF
                or 0xFE70 <= v <= 0xFEFF                            # 阿拉伯文
                or 0x0590 <= v <= 0x05FF or 0xFB1D <= v <= 0xFB4F   # 希伯来文
                or 0x0E00 <= v <= 0x0E7F                            # 泰文
                or 0x0400 <= v <= 0x04FF):                          # 西里尔文
            return False
        if 0x41 <= v <= 0x5A or 0x61 <= v <= 0x7A:
            has_ascii_letter = True
    return has_ascii_letter


def page_portuguese_lock(page_lang, block_texts):
    """镜像改动A：page_lang∈{es,fr} 且任一块含 portugueseLockChars → 覆盖为 pt。"""
    if page_lang in ("es", "fr"):
        for t in block_texts:
            if any(ch in portugueseLockChars for ch in t):
                return "pt"
    return page_lang


def page_de_hits(block_texts):
    """镜像改动D：统计全页 token 精确命中 germanFunctionWords 的次数（lowercase）。"""
    hits = 0
    for t in block_texts:
        for tok in latin_tokens(t):
            if is_skip_token(tok):
                continue
            if tok.lower() in germanFunctionWords:
                hits += 1
    return hits


def page_pt_hits(block_texts):
    """镜像改动K：统计全页 token 精确命中 portugueseFunctionWords 的次数（lowercase）。"""
    hits = 0
    for t in block_texts:
        for tok in latin_tokens(t):
            if is_skip_token(tok):
                continue
            if tok.lower() in portugueseFunctionWords:
                hits += 1
    return hits


def page_lang_predict(page_lang_in, block_texts):
    """镜像 pageLevelCorrect 页面主语种预判链（改动C→D→A→K 顺序，保证优先级）：
       1) 改动C：任一块含 germanLockChars(ä/ö/ü/ß) → de（字符级铁证）。
       2) 改动D：deHits≥2 且 !=de → de（词汇级信号，覆盖无变音符德语页）。
       3) 改动A：pageLang∈{es,fr} 且含 portugueseLockChars → pt。
       4) 改动K：ptHits≥2 且 pageLang∉{pt,de} → pt（葡语功能词密集）。
       优先级链：德语锁定(C/D) > 葡语字符锁定(A) > 葡语功能词(K)。
       C/D 在 A/K 之前执行且 K 显式守卫 !=de：同页既有 ß 又葡语功能词时，德语优先。"""
    page_lang = page_lang_in
    # 改动C：德语字符硬锁
    if any(ch in germanLockChars for t in block_texts for ch in t):
        page_lang = "de"
    # 改动D：功能词 deHits≥2 覆盖
    if page_de_hits(block_texts) >= 2 and page_lang != "de":
        page_lang = "de"
    # 改动A：葡语锁定（仅 es/fr）
    page_lang = page_portuguese_lock(page_lang, block_texts)
    # 改动K：葡语功能词 ptHits≥2 覆盖（守卫 !=de 保证德语优先）
    if page_pt_hits(block_texts) >= 2 and page_lang not in ("pt", "de"):
        page_lang = "pt"
    return page_lang


def is_person_or_place_name(token):
    """镜像改动E：Apple NL(.nameType) 人名/地名判定。容器无 NL 框架 → 保守 stub：一律返回
       False（不误报、不误剔正文）。该逻辑仅真机(macOS/NLTagger)可真实验证；镜像仅保证不引入
       假阳性，不能验证真机剔除效果。"""
    return False


# 第13批·改动J：大写书名/标题保护（离线可验证条件1 forceWords、条件3 德语变音符，
#   以及条件2 同行≥3连续全大写词——由调用处传入 line_upper_run）。NL 判名部分仅真机可验。
_DE_UMLAUT = set("äöüÄÖÜß")


def person_name_protected(token, line_upper_run=0):
    """返回 True 表示该 token 被保护为「语言词汇/标题」，即使 NL 判为人名也不剔除。
       对齐 Swift isPersonOrPlaceName 内三条保护 if。"""
    t = token.strip()
    low = t.lower()
    # 条件1：命中任意语种 forceWords
    if (low in englishForceList or low in germanForceList or low in frenchForceList
            or low in italianForceList or low in spanishForceList
            or low in portugueseForceList or low in indonesianForceList):
        return True
    # 条件2：同行 ≥3 连续全大写词
    if line_upper_run >= 3:
        return True
    # 条件3：含德语变音符
    if any(ch in _DE_UMLAUT for ch in t):
        return True
    return False


def page_ascii_latin_override(block_lang, block_text, page_lang, page_conf):
    """镜像改动B：非拉丁语种 + 纯 ASCII 拉丁行 → 归 page_lang（page_conf≥0.4）否则 en。"""
    if block_lang in NONLATIN_LANGS and is_pure_ascii_latin_line(block_text):
        if page_lang is not None and page_conf >= 0.4:
            return page_lang
        return "en"
    return block_lang


# ============================================================
# 运行测试
# ============================================================

def _run_page_case(c):
    """处理页面级用例（改动A/B/C-D/E），返回 (ok, got_repr, expected_repr)。"""
    if "page_a" in c:
        # 改动A：给定 page_lang_in + 块文本列表 → 期望 expected_page_lang
        got = page_portuguese_lock(c["page_lang_in"], c["page_a"])
        return got == c["expected_page_lang"], got, c["expected_page_lang"]
    if "page_c" in c:
        # 第11批·改动C+D：页面主语种预判链（德语字符锁 / 功能词加权 / 葡语锁定冲突）
        got = page_lang_predict(c["page_lang_in"], c["page_c"])
        return got == c["expected_page_lang"], got, c["expected_page_lang"]
    if "page_e" in c:
        # 第11批·改动E：token 级人名/地名剔除（容器 NL stub 恒 False → 期望不剔除任何 token）
        got = [tok for tok in c["page_e"] if not is_person_or_place_name(tok)]
        return got == c["expected"], got, c["expected"]
    if "page_j" in c:
        # 第13批·改动J：大写书名/标题保护（条件1 forceWords / 条件3 变音符 / 条件2 同行≥3全大写）
        #   page_j = token；line_upper_run 可选（默认0）；expected = True 表示应被保护（不当人名）。
        got = person_name_protected(c["page_j"], c.get("line_upper_run", 0))
        return got == c["expected"], got, c["expected"]
    # 改动B：page_b = [{"text":.., "pre":lang}]，page_lang/page_conf 给定 → 期望 expected 列表
    page_lang = c.get("page_lang")
    page_conf = c.get("page_conf", 0.0)
    got = [page_ascii_latin_override(x["pre"], x["text"], page_lang, page_conf)
           for x in c["page_b"]]
    return got == c["expected"], got, c["expected"]


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
        # 第10/11批：页面级用例（改动A/B/C-D/E）——含 page_a / page_b / page_c / page_e 键
        if any(k in c for k in ("page_a", "page_b", "page_c", "page_e", "page_j")):
            ok, got, expected = _run_page_case(c)
            if ok:
                passed += 1
            else:
                failed += 1
                label = c.get("desc", "page-case")
                kind = ("page-A" if "page_a" in c else
                        "page-C" if "page_c" in c else
                        "page-E" if "page_e" in c else
                        "page-J" if "page_j" in c else "page-B")
                fail_rows.append(("<page>%s" % label, str(expected), str(got), kind, ""))
            continue
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
