#!/usr/bin/env bash
# 译键 YiKey 一键安装（不需要 sudo，不改系统设置）
#   在仓库目录里：./install.sh
#   或直接：curl -fsSL https://raw.githubusercontent.com/rengs/YiKey/main/install.sh | bash
# 选项：--no-sign 跳过自签名证书（ad-hoc 签名，每次重装需重新授予辅助功能）
#       --no-restart 安装后不启动输入法进程
set -euo pipefail

REPO_URL="${YIKEY_REPO:-https://github.com/rengs/YiKey.git}"
APP_NAME="TranslateIME.app"
DEST="$HOME/Library/Input Methods"
SIGN=1; RESTART=1
for a in "$@"; do
  case "$a" in
    --no-sign) SIGN=0 ;;
    --no-restart) RESTART=0 ;;
    -h|--help) sed -n '2,7p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 1) 环境检查
[ "$(uname -s)" = "Darwin" ] || die "只支持 macOS"
[ "$(id -u)" -ne 0 ] || die "请不要用 sudo / root 运行（输入法安装在当前用户目录）"
MACOS="$(sw_vers -productVersion)"; MAJOR="${MACOS%%.*}"
[ "$MAJOR" -ge 14 ] || die "需要 macOS 14 或更高（当前 $MACOS）"
[ "$MAJOR" -ge 15 ] || warn "macOS 14 没有系统翻译 API，只能用可选的在线备用翻译（默认关闭）"
[ "$(uname -m)" = "arm64" ] || die "目前只构建 Apple Silicon（arm64）"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  die "缺少 Xcode 命令行工具：请先运行  xcode-select --install  安装后重试"
fi
say "macOS $MACOS · $(swift --version 2>/dev/null | head -1)"

# 2) 定位源码：脚本在仓库里就用仓库；通过 curl | bash 运行时 clone 到临时目录
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$HERE/Package.swift" ] && [ -f "$HERE/scripts/build.sh" ] && SRC="$HERE"
fi
if [ -z "$SRC" ]; then
  command -v git >/dev/null 2>&1 || die "需要 git"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/yikey.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  say "下载源码到临时目录 $TMP"
  git clone --depth 1 "$REPO_URL" "$TMP/YiKey"
  SRC="$TMP/YiKey"
fi
cd "$SRC"

# 3) 自签名证书（只创建一次；之后重装“辅助功能”授权不会失效）
SIGN_DIR="$HOME/Library/Application Support/TranslateIME/signing"
KC="$HOME/Library/Keychains/translateime-signing.keychain-db"
if [ "$SIGN" = 1 ]; then
  if [ -f "$KC" ] && [ -f "$SIGN_DIR/cert.pem" ] && [ -f "$SIGN_DIR/keychain.pass" ]; then
    say "使用已有的本机签名证书"
  else
    say "创建本机自签名代码签名证书（专用钥匙串，不碰登录钥匙串）"
    bash scripts/setup_signing.sh || warn "证书创建失败，改用 ad-hoc 签名"
  fi
fi

# 4) 编译 release + 组装 .app + 签名
say "编译（swift build -c release）…"
bash scripts/build.sh
[ -d "build/$APP_NAME" ] || die "构建失败：找不到 build/$APP_NAME"

# 5) 安装到 ~/Library/Input Methods（只替换 TranslateIME.app）
say "安装到 $DEST/$APP_NAME"
mkdir -p "$DEST"
pkill -x TranslateIME 2>/dev/null || true
rm -rf "${DEST:?}/$APP_NAME"
cp -R "build/$APP_NAME" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

# 6) 注册输入源并重启输入法进程
"$DEST/$APP_NAME/Contents/MacOS/TranslateIME" --install >/dev/null 2>&1 || true
if [ "$RESTART" = 1 ]; then
  open "$DEST/$APP_NAME" 2>/dev/null || true
fi
AX="$("$DEST/$APP_NAME/Contents/MacOS/TranslateIME" --ax-status 2>/dev/null || true)"

# shellcheck disable=SC1111  # 中文提示里的引号是字面文字
cat <<MSG

✅ 译键 YiKey 已安装：$DEST/$APP_NAME

接下来（只需做一次）：
  1. 系统设置 › 键盘 › 文字输入 › 输入法 › 编辑… › “+” › 搜索 “Translate IME”（简体中文分类）添加。
     看不到时注销并重新登录一次。
  2. 系统设置 › 通用 › 语言与地区 › 翻译语言… 下载“中文（简体）”和“英语”（离线翻译需要）。
  3. 系统设置 › 隐私与安全性 › 辅助功能 › 打开 TranslateIME
     （回车自动填入原应用输入框、读取选中文字需要；当前状态：${AX:-未知}）。
  4. 任意应用里按 ⌃⌥T 打开翻译面板；复制一段英文会自动弹出中文译文。

卸载：./uninstall.sh
MSG
