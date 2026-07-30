#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对每个 forceList / stopwords Set 做重复元素检测，报告 dups 数。"""
import re, os, collections
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "LangBarApp.swift"), encoding="utf-8").read()
NAMES = ["englishForceList", "germanForceList", "frenchForceList", "italianForceList",
         "portugueseForceList", "spanishForceList", "indonesianForceList", "properNounForceList",
         "germanFunctionWords", "portugueseFunctionWords", "monthNames"]


RAW_NAMES = ["germanForceList", "frenchForceList", "italianForceList",
             "portugueseForceList", "spanishForceList"]


def span(src, name):
    m = re.search(r"let\s+" + re.escape(name) + r"\b.*?=\s*\[", src)
    if not m:
        return None
    i = m.end() - 1
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


def raw_words(src, name):
    """五语 forceList 现为多行字符串块 let <name>Raw = \"\"\"...\"\"\"，逐行一个词。"""
    m = re.search(r"let\s+" + re.escape(name) + r"Raw\s*=\s*" + '"' * 3, src)
    if not m:
        return None
    start = m.end()
    end = src.find('"' * 3, start)
    if end == -1:
        return None
    return [l.strip().lower() for l in src[start:end].split("\n") if l.strip()]


total_dups = 0
for n in NAMES:
    if n in RAW_NAMES:
        words = raw_words(SRC, n)
        if words is None:
            print("  %-24s : (未找到)" % n)
            continue
        dup = [w for w, c in collections.Counter(words).items() if c > 1]
        total_dups += len(dup)
        print("  %-24s : n=%-5d dups=%d %s" % (n, len(words), len(dup), dup[:8] if dup else ""))
        continue
    b = span(SRC, n)
    if b is None:
        print("  %-24s : (未找到)" % n)
        continue
    b = "\n".join(l.split("//")[0] for l in b.splitlines())
    words = [w.lower() for w in re.findall(r'"((?:[^"\\]|\\.)*)"', b)]
    dup = [w for w, c in collections.Counter(words).items() if c > 1]
    total_dups += len(dup)
    print("  %-24s : n=%-5d dups=%d %s" % (n, len(words), len(dup), dup[:8] if dup else ""))
print("TOTAL dups =", total_dups)
