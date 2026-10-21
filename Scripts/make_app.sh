#!/bin/bash
# 构建 Gale Player.app（本地开发用：ad-hoc 签名，链接 Homebrew 的 libmpv）
#
# 用法：./Scripts/make_app.sh [debug|release]
#
# 说明（路线 A → B 切换）：
#   现在链接的是 brew 的 GPL 版 libmpv（仅本机自用）。
#   将来若要闭源分发，换成自建 LGPL 版 libmpv 后：
#     1) 把 libmpv 及其依赖打进 Contents/Frameworks/
#     2) install_name_tool 改写为 @rpath/...
#     3) 重新签名并加 com.apple.security.cs.disable-library-validation 豁免
# 注意：脚本里的变量引用一律用 ${VAR} 形式 —— 中文全角括号紧贴 $VAR 时
# bash 会把多字节字符并进变量名，导致 "unbound variable"。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

CONFIG="${1:-release}"
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "==> building (${CONFIG})"
swift build -c "${CONFIG}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
APP="${ROOT}/build/Gale Player.app"

echo "==> assembling bundle"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/GalePlayer" "${APP}/Contents/MacOS/GalePlayer"
cp "${ROOT}/Scripts/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> adding icon"
# 图标必须在签名之前放进 Resources 并写进 Info.plist，否则本地装的应用是通用图标。
# （之前只有 make_dist.sh 做这步，导致 make_app.sh 装出来的应用没图标。）
if [ -f "${ROOT}/Assets/GalePlayer.icns" ]; then
    cp "${ROOT}/Assets/GalePlayer.icns" "${APP}/Contents/Resources/GalePlayer.icns"
    if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string GalePlayer' "${APP}/Contents/Info.plist"
    fi
fi

echo "==> ad-hoc signing"
codesign --force --sign - "${APP}/Contents/MacOS/GalePlayer" >/dev/null 2>&1
codesign --force --sign - "${APP}" >/dev/null 2>&1

echo "==> done: ${APP}"
codesign -dv "${APP}" 2>&1 | sed -n '1,4p'
