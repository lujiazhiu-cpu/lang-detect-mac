#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lingua_detect.py — 语种识别主力引擎（供 LangBarApp.swift 通过 Process 调用）

接口：
    单语判定：
        python3 lingua_detect.py "<text>"
        echo "<text>" | python3 lingua_detect.py
    段落级混语切分（detect_multiple_languages_of）：
        python3 lingua_detect.py --multi "<text>"

输出（stdout, JSON 一行）：
    单语模式：
        {"lang":"de","confidence":0.87}
        无法判定 / 异常 / 空输入 → {"lang":"und","confidence":0.0}
    分段模式（--multi）：
        {"segments":[{"lang":"fr","start":0,"end":15,"words":3}, ...]}
        无法判定 / 异常 / 空输入 → {"segments":[]}

改动说明（升级为主力）：
- 加载所有目标语种（13种），覆盖法/德/意/葡/西/荷/俄/波/英/越/印尼/日/韩
- 先转小写再识别，解决全大写词误判问题
- 使用 compute_language_confidence_values 返回完整置信度列表，供调用方判断
- 完全容错：任何异常输出 und 且退出码 0
"""
import sys
import json


def _read_text():
    # 支持 --multi 前缀标志
    args = [a for a in sys.argv[1:] if a != "--multi"]
    if args and args[0].strip():
        return args[0]
    try:
        return sys.stdin.read()
    except Exception:
        return ""


def _build_detector():
    from lingua import Language, LanguageDetectorBuilder

    # 加载所有目标语种（与 App 支持语种对齐）
    langs = [
        Language.ENGLISH, Language.GERMAN, Language.FRENCH,
        Language.SPANISH, Language.ITALIAN, Language.PORTUGUESE,
        Language.DUTCH, Language.RUSSIAN, Language.POLISH,
        Language.VIETNAMESE, Language.INDONESIAN,
        Language.JAPANESE, Language.KOREAN,
    ]
    return LanguageDetectorBuilder.from_languages(*langs)\
        .with_minimum_relative_distance(0.1)\
        .build()


def _detect_multi(text):
    """段落级混语切分：返回 {"segments":[{lang,start,end,words}, ...]}。"""
    out = {"segments": []}
    try:
        if not text or not text.strip():
            return out
        detector = _build_detector()
        # 全大写整体转小写，与单语模式口径一致（解决全大写误判）
        text_for_detect = text
        stripped = text.strip()
        if stripped.upper() == stripped and any(c.isalpha() for c in stripped):
            text_for_detect = text.lower()
        results = detector.detect_multiple_languages_of(text_for_detect)
        segs = []
        for r in results or []:
            try:
                code = r.language.iso_code_639_1.name.lower()
            except Exception:
                continue
            segs.append({
                "lang": code,
                "start": int(r.start_index),
                "end": int(r.end_index),
                "words": int(getattr(r, "word_count", 0)),
            })
        out["segments"] = segs
    except Exception:
        out = {"segments": []}
    return out


def main():
    is_multi = "--multi" in sys.argv[1:]
    text = _read_text()

    if is_multi:
        print(json.dumps(_detect_multi(text)))
        return 0

    out = {"lang": "und", "confidence": 0.0}
    try:
        if not text or not text.strip():
            print(json.dumps(out))
            return 0

        detector = _build_detector()

        # 全大写转小写再识别，解决 AOÛT/VOILES/NEU IM STIFT 被误判英语的问题
        text_for_detect = text
        stripped = text.strip()
        if stripped.upper() == stripped and any(c.isalpha() for c in stripped):
            text_for_detect = stripped.lower()

        conf = detector.compute_language_confidence_values(text_for_detect)
        if conf:
            top = conf[0]
            code = top.language.iso_code_639_1.name.lower()
            confidence = float(top.value)
            # 置信度太低（两个候选接近）时返回 und，不乱猜
            if len(conf) >= 2:
                second = float(conf[1].value)
                if confidence - second < 0.10 and confidence < 0.50:
                    print(json.dumps(out))
                    return 0
            out = {"lang": code, "confidence": confidence}
    except Exception:
        out = {"lang": "und", "confidence": 0.0}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
