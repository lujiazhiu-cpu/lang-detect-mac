#!/bin/bash
#
# detect_lang.sh — 快捷键框选截图 → OCR → 逐块语种标注 → 打开标注图 + 汇总弹窗
# 依赖：macOS 自带 screencapture / swift / osascript / python3 / open
#

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SHOT="/tmp/lang_detect_shot.png"
ANNO="/tmp/lang_detect_annotated.png"

# 1) 交互式框选截图（十字光标；按 esc 取消）
rm -f "$SHOT" "$ANNO"
/usr/sbin/screencapture -i "$SHOT"
[ ! -f "$SHOT" ] && exit 0   # 用户取消

# 2) OCR + 逐块语种标注（stderr 调试写日志，stdout 拿 JSON）
JSON=$(/usr/bin/swift "$DIR/detect.swift" "$SHOT" "$ANNO" 2>/tmp/lang_detect_debug.log)

if [ -z "$JSON" ]; then
    /usr/bin/osascript -e 'display dialog "识别失败：未获得结果。\n可能：未装 swift（终端跑 xcode-select --install）或屏幕录制权限未开。\n日志：/tmp/lang_detect_debug.log" with title "语种识别" buttons {"好的"} default button "好的"'
    exit 1
fi

# 3) 解析汇总
MAIN=$(/usr/bin/python3 -c "import sys,json;print(json.loads(sys.argv[1])['main'])" "$JSON")
MIXED=$(/usr/bin/python3 -c "import sys,json;print('是' if json.loads(sys.argv[1])['mixed'] else '否')" "$JSON")
NBLK=$(/usr/bin/python3 -c "import sys,json;print(json.loads(sys.argv[1])['blocks'])" "$JSON")
BREAK=$(/usr/bin/python3 -c "import sys,json;d=json.loads(sys.argv[1]);t=sum(x['count'] for x in d['breakdown']) or 1;print('  '.join(f\"{x['lang']} {round(x['count']*100/t)}%\" for x in d['breakdown']))" "$JSON")
TEXTLEN=$(/usr/bin/python3 -c "import sys,json;print(len(json.loads(sys.argv[1])['text'].strip()))" "$JSON")

# 识别不到文字时提示
if [ "$TEXTLEN" -lt 2 ]; then
    /usr/bin/osascript -e "display dialog \"⚠️ 几乎没识别到文字。\n请框住清晰的文字区域，或把图放大后再框。\n调试图：/tmp/lang_detect_shot.png\" with title \"语种识别 · 需要重试\" buttons {\"好的\"} default button \"好的\""
    exit 0
fi

# 4) 打开标注好的图（预览）
[ -f "$ANNO" ] && /usr/bin/open "$ANNO"

# 5) 顶部再弹一个汇总（可选，快速一览）
MSG="主体语种：$MAIN
是否混语：$MIXED
文本块数：$NBLK

各语种占比：
$BREAK

（标注图已用「预览」打开，每块文字旁标了语种）"
ESCAPED=$(echo "$MSG" | sed 's/"/\\"/g')
/usr/bin/osascript -e "display dialog \"$ESCAPED\" with title \"语种识别结果\" buttons {\"好的\"} default button \"好的\"" >/dev/null 2>&1 || true
