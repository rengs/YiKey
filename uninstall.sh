#!/usr/bin/env bash
# 译键 YiKey 卸载：只删除 ~/Library/Input Methods/TranslateIME.app（不需要 sudo）
#   --purge  同时删除我的词表、生词本、日志、本机签名证书与专用钥匙串
set -euo pipefail
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
pkill -x TranslateIME 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/TranslateIME.app"
echo "已删除 ~/Library/Input Methods/TranslateIME.app"
if [ "$PURGE" = 1 ]; then
  security delete-keychain "$HOME/Library/Keychains/translateime-signing.keychain-db" 2>/dev/null || true
  rm -rf "$HOME/Library/Application Support/TranslateIME" "$HOME/Library/Logs/TranslateIME"
  echo "已删除用户数据、日志和签名证书"
else
  echo "保留了用户数据：~/Library/Application Support/TranslateIME（我的词表、生词本、签名证书）。彻底清除用 --purge"
fi
echo "请在 系统设置 › 键盘 › 文字输入 › 输入法 里移除 Translate IME。"
