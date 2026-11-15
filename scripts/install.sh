#!/usr/bin/env bash
# 安装到 ~/Library/Input Methods（先运行 scripts/build.sh）
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Library/Input Methods"
APP="TranslateIME.app"

[ -d "build/$APP" ] || { echo "请先运行 scripts/build.sh"; exit 1; }
mkdir -p "$DEST"
pkill -x TranslateIME 2>/dev/null || true
rm -rf "${DEST:?}/${APP:?}"
cp -R "build/$APP" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "✅ 已安装到 $DEST/$APP"
echo "下一步："
echo "  1) 注销并重新登录（新输入法通常需要这一步才会出现在列表里）"
echo "  2) 系统设置 › 键盘 › 文字输入 › 输入法 › 编辑… › + › 搜索 \"Translate IME\" 添加"
echo "     或者运行：\"$DEST/$APP/Contents/MacOS/TranslateIME\" --install"
