#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
local_calibrate.py — 无需 Starling 凭证的离线语种识别校准

背景：Starling skill 需要 AK/SK 且账号无权限。本脚本用完全离线、免费、
      无需凭证的本地语言检测库 lingua 充当"带置信度的参考裁判"，
      角色与 starling-language-detector 完全一致，且更贴合 App 的离线定位。

作用：
  1) 用 lingua 逐条给出 langCode + 置信度（confidence）；
  2) 与 lang_test_cases.json 的 expected 及现有离线判定对比，定位混淆用例
     （重点：意/法、葡/英边界）；
  3) 输出准确率对比、混淆明细，以及词库补丁建议（lingua 高置信但离线判错
     → 建议加入对应 *ForceList）。

依赖：pip install lingua-language-detector
用法：python3 local_calibrate.py [--min-conf 0.60] [--tokens file]
"""
import argparse
import json
import os
import sys

from lingua import Language, LanguageDetectorBuilder

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "lang_test_cases.json")

# 与项目覆盖语种对齐（意/葡/越/印尼/日/韩/泰/阿/德/法/英/中/西）
LANGS = [
    Language.ITALIAN, Language.PORTUGUESE, Language.VIETNAMESE,
    Language.INDONESIAN, Language.JAPANESE, Language.KOREAN, Language.THAI,
    Language.ARABIC, Language.GERMAN, Language.FRENCH, Language.ENGLISH,
    Language.CHINESE, Language.SPANISH,
]
CODE = {
    "ITALIAN": "it", "PORTUGUESE": "pt", "VIETNAMESE": "vi", "INDONESIAN": "id",
    "JAPANESE": "ja", "KOREAN": "ko", "THAI": "th", "ARABIC": "ar",
    "GERMAN": "de", "FRENCH": "fr", "ENGLISH": "en", "CHINESE": "zh",
    "SPANISH": "es",
}
FORCE_LIST_NAME = {
    "en": "englishForceList", "de": "germanForceList", "fr": "frenchForceList",
    "it": "italianForceList", "pt": "portugueseForceList", "es": "spanishForceList",
    "id": "indonesianForceList",
}

_detector = (LanguageDetectorBuilder.from_languages(*LANGS)
             .with_preloaded_language_models().build())


def local_detect(text):
    """返回 (code, confidence)。"""
    langs = _detector.detect_language_of(text)
    if langs is None:
        return None, 0.0
    conf = 0.0
    for c in _detector.compute_language_confidence_values(text):
        if c.language == langs:
            conf = c.value
            break
    return CODE.get(langs.name, langs.name.lower()), conf


def offline_detect(token):
    try:
        import run_lang_tests as R  # noqa
        for fn in ("detect_lang", "detect_token", "decide", "detect"):
            if hasattr(R, fn):
                res = getattr(R, fn)(token)
                # detect_lang 返回 (code, reason)，仅取 code
                if isinstance(res, (tuple, list)) and res:
                    return res[0]
                return res
    except Exception:
        pass
    return None


def load_tokens(path, cases=None):
    if cases:
        with open(cases, encoding="utf-8") as f:
            return json.load(f)
    if path:
        with open(path, encoding="utf-8") as f:
            return [{"token": l.strip(), "expected": None, "desc": ""}
                    for l in f if l.strip()]
    with open(CASES, encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", default=None)
    ap.add_argument("--cases", default=None, help="独立标注样本集 JSON")
    ap.add_argument("--min-conf", type=float, default=0.60)
    ap.add_argument("--out", default="local_calibration_report.json")
    args = ap.parse_args()

    cases = load_tokens(args.tokens, args.cases)
    rows, patch = [], {}
    n_off_ok = n_ref_ok = n_exp = 0
    for c in cases:
        # 兼容两类用例：单 token / 页面级（page_a..page_e + expected_page_lang）
        if "token" in c:
            tok, exp = c["token"], c.get("expected")
        else:
            words = []
            for k in ("page_a", "page_b", "page_c", "page_d", "page_e"):
                if isinstance(c.get(k), list):
                    for w in c[k]:
                        if isinstance(w, str):
                            words.append(w)
                        elif isinstance(w, dict) and w.get("text"):
                            words.append(w["text"])
            tok, exp = " ".join(words), c.get("expected_page_lang")
            if not tok:
                continue
        r_code, r_conf = local_detect(tok)
        o_code = offline_detect(tok)
        rows.append({"token": tok, "expected": exp, "offline": o_code,
                     "ref": r_code, "conf": round(r_conf, 3), "desc": c.get("desc", "")})
        if exp:
            n_exp += 1
            n_off_ok += (o_code == exp)
            n_ref_ok += (r_code == exp)
            if r_code == exp and o_code != exp and r_conf >= args.min_conf:
                patch.setdefault(FORCE_LIST_NAME.get(exp, exp + "ForceList"), []).append(tok)

    report = {"total": len(cases), "labeled": n_exp,
              "offline_acc": round(n_off_ok / n_exp, 4) if n_exp else None,
              "ref_acc": round(n_ref_ok / n_exp, 4) if n_exp else None,
              "rows": rows, "suggested_force_patches": patch}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print(f"用例总数 {len(cases)}，有标签 {n_exp}")
    if n_exp:
        print(f"现有离线判定 : {n_off_ok}/{n_exp} = {report['offline_acc']}")
        print(f"lingua 参考  : {n_ref_ok}/{n_exp} = {report['ref_acc']}")
    print("\n混淆/分歧明细（离线 != lingua 或 != expected）：")
    for r in rows:
        if r["offline"] != r["ref"] or (r["expected"] and r["expected"] != r["offline"]):
            print(f"  token={r['token']!r:30} exp={r['expected']} "
                  f"offline={r['offline']} lingua={r['ref']}(c={r['conf']})")
    if patch:
        print("\n建议词库补丁（lingua 高置信、现有离线判错）：")
        for k, v in patch.items():
            print(f"  {k} += {v}")
    print(f"\n完整报告已写入 {args.out}")


if __name__ == "__main__":
    main()
