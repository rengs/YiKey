#!/usr/bin/env bash
# 一次性：在本机创建一个**专用**钥匙串和自签名代码签名证书（不需要 sudo，不改系统设置，不碰登录钥匙串）。
# 之后 scripts/build.sh 会用它签名，designated requirement 固定为“bundle id + 证书指纹”，
# 重新编译安装后系统（TCC）仍认得这是同一个 App，“辅助功能”授权不会失效。
set -euo pipefail
SUP="$HOME/Library/Application Support/TranslateIME/signing"
KC="$HOME/Library/Keychains/translateime-signing.keychain-db"
mkdir -p "$SUP"; chmod 700 "$SUP"
[ -f "$SUP/keychain.pass" ] || { openssl rand -hex 24 > "$SUP/keychain.pass"; chmod 600 "$SUP/keychain.pass"; }
PASS=$(cat "$SUP/keychain.pass")
cd "$SUP"
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = TranslateIME Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
[ -f key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
chmod 600 key.pem
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "TranslateIME Local Signing" -out id.p12 -passout pass:"$PASS"
[ -f "$KC" ] || security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import id.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
security find-identity -p codesigning "$KC"
echo "✅ 签名证书就绪（证书显示 NOT_TRUSTED 是正常的：只用于本机签名，不需要信任）"
