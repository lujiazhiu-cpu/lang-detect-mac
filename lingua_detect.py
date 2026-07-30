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


def _detect_one(detector, text):
    """单文本判定：返回 {\"lang\":..,\"confidence\":..}，与单语模式口径完全一致。"""
    out = {"lang": "und", "confidence": 0.0}
    try:
        if not text or not text.strip():
            return out
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
                    return {"lang": "und", "confidence": 0.0}
            out = {"lang": code, "confidence": confidence}
    except Exception:
        out = {"lang": "und", "confidence": 0.0}
    return out


def main():
    is_multi = "--multi" in sys.argv[1:]
    is_batch = "--batch" in sys.argv[1:]
    is_serve = "--serve" in sys.argv[1:]

    # 常驻模式：只构建一次 detector，然后逐行读 stdin，对每行执行与单文本模式
    #   完全相同的判定逻辑（_detect_one），每行输出恰好一行 JSON 并 flush。
    #   空行/异常 → {"lang":"und","confidence":0.0}；EOF 自然退出。严格一行进一行出。
    if is_serve:
        detector = _build_detector()
        for line in sys.stdin:
            line = line.rstrip("\n").rstrip("\r")
            out = {"lang": "und", "confidence": 0.0}
            try:
                if line.strip():
                    out = _detect_one(detector, line)
            except Exception:
                out = {"lang": "und", "confidence": 0.0}
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()
        return 0

    # 批量模式：stdin 读 JSON 字符串数组，一次建 detector，输出对齐的结果数组。
    #   目的是把"每个 OCR 块一个子进程(各~0.7s 冷启动)"降为"整页一次子进程"。
    if is_batch:
        res = []
        try:
            raw = sys.stdin.read()
            texts = json.loads(raw) if raw.strip() else []
            if not isinstance(texts, list):
                texts = []
            detector = _build_detector() if texts else None
            for t in texts:
                item = {"lang": "und", "confidence": 0.0}
                try:
                    s = (t or "")
                    if s.strip() and detector is not None:
                        tfd = s
                        st = s.strip()
                        if st.upper() == st and any(c.isalpha() for c in st):
                            tfd = st.lower()
                        conf = detector.compute_language_confidence_values(tfd)
                        if conf:
                            top = conf[0]
                            c = float(top.value)
                            ok = True
                            if len(conf) >= 2:
                                sec = float(conf[1].value)
                                if c - sec < 0.10 and c < 0.50:
                                    ok = False
                            if ok:
                                item = {"lang": top.language.iso_code_639_1.name.lower(),
                                        "confidence": c}
                except Exception:
                    item = {"lang": "und", "confidence": 0.0}
                res.append(item)
        except Exception:
            res = []
        print(json.dumps(res))
        return 0

    text = _read_text()
    if is_multi:
        print(json.dumps(_detect_multi(text)))
        return 0

    if not text or not text.strip():
        print(json.dumps({"lang": "und", "confidence": 0.0}))
        return 0
    detector = _build_detector()
    print(json.dumps(_detect_one(detector, text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
