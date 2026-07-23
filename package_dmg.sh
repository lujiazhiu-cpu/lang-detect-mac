#!/bin/bash
#
# package_dmg.sh —— 把已安装的「语种识别.app」打包成可分发的 DMG
#   产物：~/Applications/语种识别_installer.dmg
#   DMG 内含：语种识别.app + 指向 /Applications 的软链接（方便拖拽安装）
#
# 用法（先跑 build_app.sh 生成 App，再运行本脚本）：
#   bash package_dmg.sh
#

set -e

APP_NAME="语种识别"
DEST_DIR="$HOME/Applications"
APP="$DEST_DIR/$APP_NAME.app"
DMG_OUT="$DEST_DIR/${APP_NAME}_installer.dmg"
STAGING="$(mktemp -d)/${APP_NAME}"

echo "==================================================="
echo " 语种识别 · DMG 打包"
echo "==================================================="

[ -d "$APP" ] || { echo "❌ 找不到已安装的 App：$APP（请先运行 build_app.sh）"; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { echo "❌ 未找到 hdiutil，需在 macOS 上运行"; exit 1; }

# 1) 准备暂存目录：App + Applications 软链接
echo "[1/3] 准备 DMG 内容 ..."
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 2) 删除旧 DMG
[ -f "$DMG_OUT" ] && { echo "     🗑  删除旧 DMG：$DMG_OUT"; rm -f "$DMG_OUT"; }

# 3) 生成压缩 DMG
echo "[2/3] 生成 DMG ..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_OUT" >/dev/null

rm -rf "$(dirname "$STAGING")"

echo "[3/3] 完成"
echo "==================================================="
echo " ✅ DMG 已生成：$DMG_OUT"
echo "==================================================="
