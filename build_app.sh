#!/bin/bash
#
# build_app.sh —— 把 LangBarApp.swift 编译打包成可双击的「语种识别.app」
#   ✅ 编译真正可运行的 Swift 菜单栏 App（双击后菜单栏出现「取景框+A」图标）
#   ✅ 生成带圆角矩形的 .icns 应用图标（书本+地球）
#   ✅ 先删除所有旧版，再安装新版
#
# 用法（在 macOS 终端粘贴运行一次即可）：
#   bash /private/tmp/aime-agent-shared-dir/cad26f8ba7f4/lang-detect-mac/build_app.sh
#
# 产物：~/Applications/语种识别.app
#

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SRC="$SRC_DIR/LangBarApp.swift"
RES_DIR="$SRC_DIR/Resources"
ICON_1024="$RES_DIR/AppIcon_1024.png"
APP_NAME="语种识别"
EXEC_NAME="语种识别"
DEST_DIR="$HOME/Applications"
APP="$DEST_DIR/$APP_NAME.app"

echo "==================================================="
echo " 语种识别 · 菜单栏 App 打包"
echo "==================================================="

# 0) 环境检查
if ! command -v swiftc >/dev/null 2>&1; then
    echo "⚠️ 未检测到 swiftc，正在触发安装 Xcode 命令行工具..."
    echo "👉 屏幕会弹出安装窗口，请点『安装』，装完后重新运行本脚本。"
    xcode-select --install || true
    exit 0
fi
echo "[1/7] swiftc 已就绪：$(swiftc --version 2>/dev/null | head -1)"
[ -f "$SWIFT_SRC" ] || { echo "❌ 找不到源码：$SWIFT_SRC"; exit 1; }

# 1) 彻底清理所有旧版「语种识别.app」
echo "[2/7] 清理旧版 App ..."
pkill -f "$APP_NAME.app" 2>/dev/null || true
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
for d in "$HOME/Desktop" "$HOME/Applications" "/Applications" "$HOME/Downloads"; do
    OLD="$d/$APP_NAME.app"
    [ -e "$OLD" ] && { echo "     🗑  删除：$OLD"; rm -rf "$OLD"; }
done
while IFS= read -r p; do
    [ -n "$p" ] && { echo "     🗑  删除：$p"; rm -rf "$p"; }
done < <(find "$HOME" -maxdepth 4 -name "$APP_NAME.app" -type d 2>/dev/null)
echo "     ✅ 旧版清理完成"

# 2) App 骨架
echo "[3/7] 准备 App 骨架 ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 3) 编译真正的 Swift 菜单栏 App
echo "[4/7] 编译 Swift 源码（十几秒）..."
if swiftc -O -o "$APP/Contents/MacOS/$EXEC_NAME" \
        -framework Vision -framework NaturalLanguage \
        -framework AppKit -framework ImageIO \
        -framework UserNotifications -framework Carbon \
        "$SWIFT_SRC" 2>/tmp/langbar_build.log; then
    echo "     ✅ 编译成功（真正可运行的菜单栏 App）"
else
    echo "❌ 编译失败，日志如下："
    cat /tmp/langbar_build.log
    exit 1
fi
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"

# 4) 菜单栏图标（取景框+A）放进 App Resources
echo "[5/7] 放入菜单栏图标 ..."
[ -f "$RES_DIR/menubar_icon.png" ]    && cp "$RES_DIR/menubar_icon.png"    "$APP/Contents/Resources/"
[ -f "$RES_DIR/menubar_icon@2x.png" ] && cp "$RES_DIR/menubar_icon@2x.png" "$APP/Contents/Resources/"

# 4b) 若已准备 fastText 模型（见 setup_fasttext.sh），一并打进 .app，使其自带补充验证层
if [ -f "$RES_DIR/lid.176.bin" ]; then
    cp "$RES_DIR/lid.176.bin" "$APP/Contents/Resources/"
    echo "     ✅ 已内置 fastText 模型 lid.176.bin（App 将自动启用 fastText 验证层）"
else
    echo "     ℹ️ 未发现 Resources/lid.176.bin —— 先运行 bash setup_fasttext.sh 可启用 fastText 验证层（可选，缺失不影响运行）"
fi

# 5) 生成带圆角的 .icns 应用图标
ICON_KEY=""
if [ -f "$ICON_1024" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    echo "[6/7] 生成圆角 .icns 图标 ..."
    ICONSET="/tmp/LangBar.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    # AppIcon_1024.png 已经是「圆角+透明留白」的成品，缩放即可
    sips -z 16   16   "$ICON_1024" --out "$ICONSET/icon_16x16.png"      >/dev/null
    sips -z 32   32   "$ICON_1024" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z 32   32   "$ICON_1024" --out "$ICONSET/icon_32x32.png"      >/dev/null
    sips -z 64   64   "$ICON_1024" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z 128  128  "$ICON_1024" --out "$ICONSET/icon_128x128.png"    >/dev/null
    sips -z 256  256  "$ICON_1024" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256  256  "$ICON_1024" --out "$ICONSET/icon_256x256.png"    >/dev/null
    sips -z 512  512  "$ICON_1024" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512  512  "$ICON_1024" --out "$ICONSET/icon_512x512.png"    >/dev/null
    cp "$ICON_1024" "$ICONSET/icon_512x512@2x.png"
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ICON_KEY="    <key>CFBundleIconFile</key>       <string>AppIcon</string>"
        echo "     ✅ 圆角图标已生成"
    else
        echo "     ⚠️ icns 生成失败，图标可能仍是方形"
    fi
    rm -rf "$ICONSET"
else
    echo "[6/7] ⚠️ 缺少圆角图标源或工具，跳过图标"
fi

# 6) Info.plist + 签名 + 刷新缓存
echo "[7/7] 写 Info.plist + 签名 ..."
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>      <string>com.aime.langbar</string>
    <key>CFBundleVersion</key>         <string>1.2</string>
    <key>CFBundleShortVersionString</key> <string>1.2</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
$ICON_KEY
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# 先剥离所有扩展属性（quarantine / provenance 等），再签名，避免签名后被污染导致「已损坏」
xattr -cr "$APP" 2>/dev/null || true
if codesign --force --deep --sign - "$APP" 2>/tmp/langbar_sign.log; then
    echo "     ✅ ad-hoc 签名完成"
else
    echo "❌ 签名失败，日志如下："; cat /tmp/langbar_sign.log; exit 1
fi
# 再次剥离（签名过程可能重新写入属性），并校验签名封印完整（防止「已损坏或不完整」）
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>/tmp/langbar_verify.log; then
    echo "❌ 签名校验未通过（App 可能损坏或不完整），日志如下："; cat /tmp/langbar_verify.log; exit 1
fi
echo "     ✅ 签名校验通过：valid on disk"
# 校验可执行文件为完整 Mach-O，避免半成品被打包
if ! file "$APP/Contents/MacOS/$EXEC_NAME" | grep -q "Mach-O"; then
    echo "❌ 可执行文件不是有效的 Mach-O（编译产物不完整）"; exit 1
fi
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true
killall Finder 2>/dev/null || true

echo ""
echo "==================================================="
echo " ✅ 打包完成！旧版已删除，仅保留这一个新版。"
echo " App 位置：$APP"
echo ""
echo " 已自动打开 App —— 请看屏幕右上角菜单栏，应出现「取景框+A」图标。"
echo " 首次点图标→截图识别语种（或按 ⌃⌥L）后，如提示授权："
echo "   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选『$APP_NAME』→ 重开 App"
echo "==================================================="

open "$APP" 2>/dev/null || true
