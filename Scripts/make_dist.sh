#!/bin/bash
# 构建可分发的 Gale Player 分发包（DMG）。
#
# 与 make_app.sh 的区别：
#   make_app.sh  —— 本机开发用。链接 Homebrew 的 libmpv，只有本机能跑。
#   make_dist.sh —— 分发用。把 50+ 个依赖内嵌进 .app，产出 DMG。
#
# 用法：./Scripts/make_dist.sh [release|debug]
#
# 产出：
#   dist/Gale Player-<版本>-arm64.dmg
#
# 签名的两个阶段（当前 = 阶段 1）：
#   阶段 1（现在）：ad-hoc 签名。用户首次打开需「右键 → 打开」一次，
#                   或执行 xattr -dr com.apple.quarantine "/Applications/Gale Player.app"
#   阶段 2（需要 $99/年 Apple 开发者账号）：把下面 SIGN_ID 换成
#                   "Developer ID Application: <你的名字> (TEAMID)"，
#                   加上 --options runtime 与 entitlements，然后再执行
#                   xcrun notarytool submit --wait + xcrun stapler staple
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

CONFIG="${1:-release}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Scripts/Info.plist)"
ARCH="$(uname -m)"
APP="${ROOT}/build/Gale Player.app"
DIST="${ROOT}/dist"
DMG="${DIST}/Gale Player-${VERSION}-${ARCH}.dmg"
SIGN_ID="-"                     # 阶段 2 改成 Developer ID

echo "==> [1/7] 构建并组装 App 包"
./Scripts/make_app.sh "${CONFIG}"

echo "==> [2/7] 内嵌依赖库"
python3 Scripts/bundle_deps.py "${APP}"

echo "==> [3/7] 生成应用图标"
# 优先用仓库里版本化的图标；没有才现场生成（make_icon.swift 是确定性的）
if [ -f Assets/GalePlayer.icns ]; then
    ICNS="Assets/GalePlayer.icns"
else
    ICON_WORK="${TMPDIR:-/tmp}/gale-icon"
    mkdir -p "${ICON_WORK}"
    swift Scripts/make_icon.swift "${ICON_WORK}/GalePlayer.iconset"
    iconutil -c icns "${ICON_WORK}/GalePlayer.iconset" -o "${ICON_WORK}/GalePlayer.icns"
    ICNS="${ICON_WORK}/GalePlayer.icns"
fi
cp "${ICNS}" "${APP}/Contents/Resources/GalePlayer.icns"
# Info.plist 里登记图标（重复执行不会重复写入）
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${APP}/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string GalePlayer' "${APP}/Contents/Info.plist"
fi

echo "==> [4/7] 收集第三方许可证"
python3 Scripts/make_licenses.py "${APP}"

echo "==> [5/7] 签名（由内向外）"
# 注意顺序：改过 install_name 的 dylib 签名已失效，必须先签库再签包。
# arm64 上签名无效的二进制会被内核直接杀掉，不是可选项。
find "${APP}/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null \
    | while IFS= read -r -d '' lib; do
        codesign --force --sign "${SIGN_ID}" "${lib}" >/dev/null 2>&1
    done
codesign --force --sign "${SIGN_ID}" "${APP}/Contents/MacOS/GalePlayer" >/dev/null 2>&1
codesign --force --sign "${SIGN_ID}" "${APP}" >/dev/null 2>&1

echo "==> [6/7] 校验自包含性"
python3 Scripts/verify_dist.py "${APP}"

echo "==> [7/7] 制作 DMG"
mkdir -p "${DIST}"
STAGE="${TMPDIR:-/tmp}/gale-dmg-stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
# diskutil image create 是 hdiutil create 的官方替代（新系统上 hdiutil 已标废弃）。
# 老系统没有子命令时回退到 hdiutil。
if diskutil image create from "${STAGE}" "${DMG}" \
        --volumeName "Gale Player" --format UDZO >/dev/null 2>&1; then
    :
else
    hdiutil create -volname "Gale Player" \
        -srcfolder "${STAGE}" \
        -ov -format UDZO \
        "${DMG}" >/dev/null
fi
rm -rf "${STAGE}"

SIZE="$(du -h "${DMG}" | cut -f1)"
echo
echo "==> 完成"
echo "    ${DMG}  (${SIZE})"
echo
echo "    用户首次打开（阶段 1，未公证）："
echo "      · 右键点击 App → 打开 → 在弹窗里再点「打开」"
echo "      · 或终端执行：xattr -dr com.apple.quarantine \"/Applications/Gale Player.app\""
