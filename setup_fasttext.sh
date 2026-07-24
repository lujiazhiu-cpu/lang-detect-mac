#!/usr/bin/env bash
# =============================================================================
# setup_fasttext.sh — 在 Mac 上一键准备 fastText CLI 二进制 + lid.176.ftz 模型
#
# 用途：LangBarApp 的「任务B / fastText 补充验证层」默认走 Process() 调用本地
#       fasttext CLI（方式2，最简单、免改 Xcode 工程）。本脚本负责：
#         1) 安装/编译 fasttext 可执行文件
#         2) 下载语种识别模型 lid.176.ftz（约 1MB，Facebook 官方，176 语言）
#         3) 放到 App 能自动发现的位置
#
# 运行位置：★ 必须在 Mac 本机执行 ★（sandbox 无 Swift/brew 环境）
#   cd ~/lang-detect-mac && bash setup_fasttext.sh
#
# App 自动发现顺序（见 LangBarApp.swift 的 resolveFastTextBinary / resolveFastTextModel）：
#   二进制: $FASTTEXT_BIN → /opt/homebrew/bin/fasttext → /usr/local/bin/fasttext
#           → /usr/bin/fasttext → ~/lang-detect-mac/bin/fasttext
#   模型:   $FASTTEXT_MODEL → App.app 内 Resources/lid.176.ftz
#           → ~/lang-detect-mac/Resources/lid.176.ftz → ./Resources/lid.176.ftz
# =============================================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$APP_DIR/bin"
RES_DIR="$APP_DIR/Resources"
MODEL_URL="https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz"
MODEL_PATH="$RES_DIR/lid.176.ftz"

mkdir -p "$BIN_DIR" "$RES_DIR"

echo "==> [1/2] 准备 fasttext 可执行文件"
if command -v fasttext >/dev/null 2>&1; then
  echo "    已检测到系统 fasttext: $(command -v fasttext)"
elif command -v brew >/dev/null 2>&1; then
  echo "    通过 Homebrew 安装 fasttext ..."
  brew install fasttext
else
  echo "    未找到 brew，改为从源码编译到 $BIN_DIR/fasttext ..."
  TMP="$(mktemp -d)"
  git clone --depth 1 https://github.com/facebookresearch/fastText.git "$TMP/fastText"
  ( cd "$TMP/fastText" && make -j"$(sysctl -n hw.ncpu)" )
  cp "$TMP/fastText/fasttext" "$BIN_DIR/fasttext"
  chmod +x "$BIN_DIR/fasttext"
  rm -rf "$TMP"
  echo "    编译完成: $BIN_DIR/fasttext"
fi

echo "==> [2/2] 下载语种识别模型 lid.176.ftz"
if [[ -f "$MODEL_PATH" ]]; then
  echo "    模型已存在: $MODEL_PATH （跳过下载）"
else
  echo "    下载中 -> $MODEL_PATH"
  curl -fL --retry 3 -o "$MODEL_PATH" "$MODEL_URL"
  echo "    下载完成，大小: $(du -h "$MODEL_PATH" | cut -f1)"
fi

echo ""
echo "✅ fastText 准备完成。"
echo "   - 二进制: $(command -v fasttext || echo "$BIN_DIR/fasttext")"
echo "   - 模型:   $MODEL_PATH"
echo ""
echo "自检（应输出形如 __label__it 0.98）："
FT_BIN="$(command -v fasttext || echo "$BIN_DIR/fasttext")"
echo "Ciao, come stai? Andiamo al teatro stasera." | "$FT_BIN" predict-prob "$MODEL_PATH" - 1 || true
echo ""
echo "提示：若想让打包后的 .app 自带模型，请在 build_app.sh 里把 Resources/lid.176.ftz"
echo "      拷入 *.app/Contents/Resources/ （见 FASTTEXT_INTEGRATION.md 步骤 4）。"
