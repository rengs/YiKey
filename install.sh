#!/usr/bin/env bash
# 译键 YiKey 一键安装（不需要 sudo，不改系统设置）
#   在仓库目录里：./install.sh
#   或直接：curl -fsSL https://raw.githubusercontent.com/rengs/YiKey/main/install.sh | bash
# 选项：--no-sign 跳过自签名证书（ad-hoc 签名，每次重装需重新授予辅助功能）
#       --no-restart 安装后不启动输入法进程
# 环境变量：DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer 指定用哪个 Xcode/工具链编译
set -euo pipefail

REPO_URL="${YIKEY_REPO:-https://github.com/rengs/YiKey.git}"
APP_NAME="TranslateIME.app"
DEST="$HOME/Library/Input Methods"
SIGN=1; RESTART=1
for a in "$@"; do
  case "$a" in
    --no-sign) SIGN=0 ;;
    --no-restart) RESTART=0 ;;
    -h|--help) sed -n '2,9p' "$0" 2>/dev/null || true; exit 0 ;;
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
[ "$MAJOR" -ge 14 ] || die "需要 macOS 14 或更高（当前 ${MACOS}）"
[ "$MAJOR" -ge 15 ] || warn "macOS 14 没有系统翻译 API，只能用可选的在线备用翻译（默认关闭）"
[ "$(uname -m)" = "arm64" ] || die "目前只构建 Apple Silicon（arm64）"

LOG_DIR="$HOME/Library/Logs/TranslateIME"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG"

# 1b) 工具链：优先用户自设的 DEVELOPER_DIR；xcode-select 指向命令行工具而本机装了 Xcode 时，只对本脚本临时改用 Xcode
#     （不改 xcode-select、不用 sudo）
find_xcode() {
  local x
  for x in /Applications/Xcode.app /Applications/Xcode*.app; do
    # Xcode 的 swift 在 Toolchains/XcodeDefault.xctoolchain 里，不在 Developer/usr/bin
    [ -x "$x/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ] \
      && [ -x "$x/Contents/Developer/usr/bin/xcodebuild" ] \
      && { printf '%s\n' "$x/Contents/Developer"; return 0; }
  done
  return 1
}
XCODE_DEV="$(find_xcode || true)"
if [ -n "${DEVELOPER_DIR:-}" ]; then
  [ -d "$DEVELOPER_DIR" ] || die "DEVELOPER_DIR=$DEVELOPER_DIR 不存在"
  say "使用你设置的 DEVELOPER_DIR=$DEVELOPER_DIR"
  export DEVELOPER_DIR
else
  SELECTED="$(xcode-select -p 2>/dev/null || true)"
  [ -n "$SELECTED" ] || [ -n "$XCODE_DEV" ] || die "缺少 Xcode 命令行工具：请先运行  xcode-select --install  安装后重试"
  case "$SELECTED" in
    *CommandLineTools*)
      if [ -n "$XCODE_DEV" ]; then
        export DEVELOPER_DIR="$XCODE_DEV"
        say "检测到 Xcode：本次编译使用 DEVELOPER_DIR=${XCODE_DEV}（不修改 xcode-select）"
      fi ;;
  esac
fi
command -v swift >/dev/null 2>&1 || die "找不到 swift：请先运行  xcode-select --install"
SWIFT_VER="$(swift --version 2>>"$LOG" | grep -m1 -o 'Swift version [0-9.]*' || true)"
[ -n "$SWIFT_VER" ] || die "swift 无法运行（详见日志 ${LOG}）。如果刚装好 Xcode，请先打开一次 Xcode 同意许可协议"
say "macOS $MACOS · Apple $SWIFT_VER · $(xcode-select -p 2>/dev/null || echo '-')${DEVELOPER_DIR:+（DEVELOPER_DIR=${DEVELOPER_DIR}）}"
SV="${SWIFT_VER##* }"; SV_MAJOR="${SV%%.*}"
[ "${SV_MAJOR:-0}" -ge 6 ] || die "需要 Swift 6.0 或更高（当前 ${SV}）：请安装 Xcode 16+ 或最新的命令行工具"

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

# 2b) 预检：编译 Package.swift 清单（命令行工具损坏/版本不一致时会在这里失败）
manifest_help() {
  printf '\n'
  warn "Swift 包清单（Package.swift）无法编译。完整报错已写入：$LOG"
  if grep -q "Undefined symbols" "$LOG" && grep -q "PackageDescription" "$LOG"; then
    echo "   原因：命令行工具里的 PackageDescription 库与 swiftc 版本不一致（命令行工具损坏或升级不完整）。"
  elif grep -qi "license" "$LOG"; then
    echo "   原因：还没有同意 Xcode 许可协议。请打开一次 Xcode（或在终端运行 sudo xcodebuild -license accept），然后重新运行本脚本。"
  fi
  echo
  echo "   修复方法（任选其一）："
  if [ -n "$XCODE_DEV" ] && [ "${DEVELOPER_DIR:-}" != "$XCODE_DEV" ]; then
    echo "   A. 用已安装的 Xcode 编译："
    echo "        DEVELOPER_DIR=$XCODE_DEV ./install.sh"
  elif [ -n "$XCODE_DEV" ]; then
    echo "   A. 本次已经在用 Xcode（${XCODE_DEV}）仍然失败：打开一次 Xcode 让它完成组件安装/同意许可，"
    echo "      或把 Xcode 更新到最新版后重新运行 ./install.sh；也可以试试只用命令行工具（见 B）。"
  else
    echo "   A. 安装 Xcode 16 或更高（App Store），打开一次后重新运行 ./install.sh（脚本会自动使用 Xcode）。"
  fi
  echo "   B. 重装命令行工具（需要你自己在终端执行，本脚本不会使用 sudo）："
  echo "        sudo rm -rf /Library/Developer/CommandLineTools"
  echo "        xcode-select --install"
  echo "      装完后重新运行 ./install.sh"
  echo
}
say "预检 Swift 工具链（编译 Package.swift）…"
if ! swift package dump-package >/dev/null 2>>"$LOG"; then
  manifest_help
  exit 1
fi

# 3) 自签名证书（只创建一次；之后重装“辅助功能”授权不会失效）
SIGN_DIR="$HOME/Library/Application Support/TranslateIME/signing"
KC="$HOME/Library/Keychains/translateime-signing.keychain-db"
if [ "$SIGN" = 1 ]; then
  if [ -f "$KC" ] && [ -f "$SIGN_DIR/cert.pem" ] && [ -f "$SIGN_DIR/keychain.pass" ]; then
    say "使用已有的本机签名证书"
  else
    say "创建本机自签名代码签名证书（专用钥匙串，不碰登录钥匙串）"
    if bash scripts/setup_signing.sh >>"$LOG" 2>&1; then
      say "签名证书就绪"
    else
      warn "证书创建失败，改用 ad-hoc 签名（详见 ${LOG}）"
    fi
  fi
fi

# 4) 编译 release + 组装 .app + 签名
say "编译（swift build -c release，首次约 1–3 分钟；详细输出写入 ${LOG}）…"
if ! bash scripts/build.sh >>"$LOG" 2>&1 || [ ! -d "build/$APP_NAME" ]; then
  printf '\n'
  warn "编译失败。关键报错："
  grep -E "error:|Undefined symbols" "$LOG" | grep -v "^warning" | head -8 | cut -c1-220 || true
  echo "   完整日志：$LOG"
  if grep -q "Undefined symbols" "$LOG" && grep -q "PackageDescription" "$LOG"; then manifest_help; fi
  exit 1
fi
grep -E "签名|ad-hoc" "$LOG" | tail -1 || true

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
