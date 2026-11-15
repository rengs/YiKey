#!/usr/bin/env bash
set -euo pipefail
pkill -x TranslateIME 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/TranslateIME.app"
echo "已删除。请在 系统设置 › 键盘 › 输入法 里移除残留项，并注销一次。"
