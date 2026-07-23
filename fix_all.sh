#!/bin/bash
#
# fix_all.sh —— 一键修复：系统设置 + 屏幕录制权限 + 重装语种识别 App
# 用法（在 macOS「终端」里粘贴运行）：
#   bash /private/tmp/aime-agent-shared-dir/cad26f8ba7f4/lang-detect-mac/fix_all.sh
#
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo " 第 1 步：修复卡死/空白的「系统设置」"
echo "=================================================="
killall "System Settings" 2>/dev/null || true
killall "System Preferences" 2>/dev/null || true
sleep 1
# 损坏的偏好/缓存会导致系统设置右侧空白，删除后系统会自动重建
rm -f  "$HOME/Library/Preferences/com.apple.systempreferences.plist" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.apple.systempreferences" 2>/dev/null || true
# 相关面板缓存
rm -rf "$HOME/Library/Caches/com.apple.preferencepanes"* 2>/dev/null || true
# 重启偏好同步进程，让删除立即生效
killall cfprefsd 2>/dev/null || true
echo "✅ 已清理系统设置损坏的偏好与缓存"

echo ""
echo "=================================================="
echo " 第 2 步：重置「屏幕录制」权限（下次启动会重新弹原生授权）"
echo "=================================================="
tccutil reset ScreenCapture com.aime.langbar 2>/dev/null \
  && echo "✅ 已重置本 App 的屏幕录制授权" \
  || { tccutil reset ScreenCapture 2>/dev/null && echo "✅ 已重置全部屏幕录制授权"; }

echo ""
echo "=================================================="
echo " 第 3 步：重新编译安装最新版 App"
echo "=================================================="
bash "$SRC_DIR/build_app.sh"

echo ""
echo "=================================================="
echo " 第 4 步：验证「系统设置 → 屏幕录制」页能否打开"
echo "=================================================="
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" \
  && echo "✅ 已尝试打开屏幕录制设置页，请查看是否正常显示列表" \
  || echo "⚠️ 打开设置页失败"

echo ""
echo "=================================================="
echo " 全部完成！接下来："
echo " 1) 在刚打开的「屏幕录制」列表里勾选『语种识别』（若没有，先点一次菜单栏图标触发授权）"
echo " 2) 勾选后如提示，退出并重开『语种识别』"
echo " 3) 再点菜单栏『取景框+A』图标 → 截图识别（授权后就不会再白屏）"
echo "=================================================="
