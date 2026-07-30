#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lingua_multi_test.py — lingua 段落级混语切分（detect_multiple_languages_of）单测

用途：
    验证 lingua_detect.py 的 --multi 分段模式（供 Swift linguaPageMono 调用的同一路径）。
    对每条样本调用 `python3 lingua_detect.py --multi "<text>"`，解析 segments，
    计算「主语种 + 主语种字符覆盖占比 ratio」，与期望比对。

判定口径（与 Swift linguaPageMono / pageLevelCorrect 对齐）：
    - mono 样本：期望 top_lang == expect_lang 且 ratio >= 0.85（整页实质单语）
    - mixed 样本：期望 ratio < 0.85（能识别出混语，不会被误判为单语）

运行：python3 lingua_multi_test.py   （在 macOS 上，lingua 已安装）
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "lingua_detect.py")
MONO_THRESHOLD = 0.85

# kind: "mono" → 期望单语且占比≥阈值；"mixed" → 期望占比<阈值（检出混语）
CASES = [
    # ---- 单语页（含封面短词场景，重点）----
    {"text": "VILLE DE ROUBAIX festival des arts", "kind": "mono", "lang": "fr",
     "desc": "法语封面短词（艺术节海报），单独看 arts 易混英语"},
    {"text": "Neu im Stift Handgemacht in Deutschland", "kind": "mono", "lang": "de",
     "desc": "德语短句，无变音符"},
    {"text": "Happy Birthday to you my dear friend", "kind": "mono", "lang": "en",
     "desc": "纯英语祝福语"},
    {"text": "Rebajas de verano hasta el cincuenta por ciento en toda la tienda",
     "kind": "mono", "lang": "es", "desc": "纯西班牙语促销文案"},
    {"text": "Buongiorno a tutti benvenuti alla nostra festa di primavera",
     "kind": "mono", "lang": "it", "desc": "纯意大利语欢迎语"},
    {"text": "Obrigado pela sua visita volte sempre que quiser",
     "kind": "mono", "lang": "pt", "desc": "纯葡萄牙语致谢"},
    # ---- 真混语页（应检出，不能被当成单语）----
    {"text": "SUMMER SALE up to 50 percent off. Soldes d'ete jusqu'a moins cinquante pour cent.",
     "kind": "mixed", "desc": "英法混排促销海报"},
    {"text": "Welcome to our shop. Willkommen in unserem Geschaeft. Besuchen Sie uns bald wieder.",
     "kind": "mixed", "desc": "英德混排"},
]


def run_multi(text):
    """调用 lingua_detect.py --multi，返回 (top_lang, ratio, segments)。"""
    try:
        p = subprocess.run(
            [sys.executable, SCRIPT, "--multi", text],
            capture_output=True, text=True, timeout=20,
        )
        obj = json.loads(p.stdout.strip() or "{}")
        segs = obj.get("segments", [])
        if not segs:
            return None, 0.0, []
        span_by_lang = {}
        total = 0
        for s in segs:
            st, en = int(s.get("start", 0)), int(s.get("end", 0))
            if en <= st:
                continue
            span = en - st
            span_by_lang[s.get("lang", "und")] = span_by_lang.get(s.get("lang", "und"), 0) + span
            total += span
        if total <= 0:
            return None, 0.0, segs
        top = max(span_by_lang.items(), key=lambda kv: kv[1])
        return top[0], top[1] / total, segs
    except Exception as e:
        return None, 0.0, [("ERR", str(e))]


def main():
    passed, failed = 0, 0
    fail_detail = []
    print("=" * 68)
    print(" lingua 段落级混语切分单测（--multi / detect_multiple_languages_of）")
    print(f" mono 阈值 ratio >= {MONO_THRESHOLD}")
    print("=" * 68)
    for c in CASES:
        top, ratio, segs = run_multi(c["text"])
        ok = False
        if c["kind"] == "mono":
            ok = (top == c["lang"]) and (ratio >= MONO_THRESHOLD)
            exp = f"mono {c['lang']} (ratio>={MONO_THRESHOLD})"
        else:
            ok = ratio < MONO_THRESHOLD
            exp = f"mixed (ratio<{MONO_THRESHOLD})"
        got = f"top={top} ratio={ratio:.2f} segs={len(segs)}"
        mark = "✓" if ok else "✗"
        print(f"  {mark} [{c['kind']:>5}] {got:<34} 期望={exp}")
        print(f"        {c['desc']}")
        if ok:
            passed += 1
        else:
            failed += 1
            fail_detail.append((c, top, ratio, segs))
    print("-" * 68)
    print(f"结果：通过 {passed} / {len(CASES)}，失败 {failed}")
    if fail_detail:
        print("\n失败明细：")
        for c, top, ratio, segs in fail_detail:
            print(f"  ✗ text={c['text']!r}")
            print(f"      kind={c['kind']} top={top} ratio={ratio:.2f}")
            print(f"      segments={segs}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
