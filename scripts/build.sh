#!/usr/bin/env bash
# 用 SwiftPM 编译 arm64 release，并手工组装 TranslateIME.app（含 Info.plist、图标、本地化、ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TranslateIME"

APP="build/TranslateIME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TranslateIME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
for l in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$l.lproj"
  cp "Resources/$l.lproj/InfoPlist.strings" "$APP/Contents/Resources/$l.lproj/"
done
# 内置术语表（离线）
mkdir -p "$APP/Contents/Resources/Glossaries"
cp Resources/Glossaries/*.csv "$APP/Contents/Resources/Glossaries/"
swift scripts/make_icon.swift "$APP/Contents/Resources/icon.tiff"

plutil -lint "$APP/Contents/Info.plist"
# 签名：如已运行 scripts/setup_signing.sh，用本机固定的自签名证书签名（指定稳定的 designated requirement），
# 这样重新编译安装后“辅助功能”授权不会失效；否则退回 ad-hoc（每次重装都要重新授权）。
SIGN_DIR="$HOME/Library/Application Support/TranslateIME/signing"
KC="$HOME/Library/Keychains/translateime-signing.keychain-db"
if [ -f "$KC" ] && [ -f "$SIGN_DIR/keychain.pass" ] && [ -f "$SIGN_DIR/cert.pem" ]; then
  SHA1=$(openssl x509 -in "$SIGN_DIR/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain.pass")" "$KC"
  codesign --force --keychain "$KC" --sign "$SHA1" --timestamp=none \
    -r="designated => identifier \"com.example.inputmethod.TranslateIME\" and certificate leaf = H\"$SHA1\"" "$APP"
  echo "🔏 已用本机固定证书签名（${SHA1}）"
else
  codesign --force --sign - --timestamp=none "$APP"
  echo "⚠️ ad-hoc 签名：重新安装后需在 系统设置 › 隐私与安全性 › 辅助功能 里重新添加 TranslateIME"
fi
echo "✅ 已生成 $APP"
