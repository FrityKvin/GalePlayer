#!/usr/bin/env python3
"""为分发包生成第三方许可证目录。

为什么要做：把 Homebrew 的 dylib 打进 .app 再分发 = 再分发 GPL/LGPL 二进制。
GPL 的义务是附许可证全文 + 提供对应源码的获取途径，所以打包时必须带上这些。

产出（在 .app/Contents/Resources/licenses/ 下）：
  mpv/LICENSE.GPL, LICENSE.LGPL
  ffmpeg/COPYING.GPLv2, COPYING.LGPLv2.1, ...
  <其它库>/<许可证文件>
  THIRD-PARTY-NOTICES.md   ← 逐库列出版本/许可证/源码地址
"""
import glob
import json
import os
import shutil
import subprocess
import sys

# 库名(内嵌 dylib 前缀) → Homebrew formula 名
LIB_TO_FORMULA = {
    "libmpv": "mpv",
    "libavcodec": "ffmpeg", "libavformat": "ffmpeg", "libavutil": "ffmpeg",
    "libavfilter": "ffmpeg", "libavdevice": "ffmpeg",
    "libswscale": "ffmpeg", "libswresample": "ffmpeg",
    "libplacebo": "libplacebo",
    "libass": "libass",
    "dav1d": "dav1d",
    "x264": "x264", "x265": "x265",
    "libvpx": "libvpx",
    "libSvtAv1Enc": "svt-av1",
    "libvmaf": "libvmaf",
    "libcrypto": "openssl@4", "libssl": "openssl@4",
    "libluajit": "luajit",
    "libfreetype": "freetype",
    "libharfbuzz": "harfbuzz",
    "libfontconfig": "fontconfig",
    "libfribidi": "fribidi",
    "libpng16": "libpng",
    "libjpeg": "jpeg-turbo",
    "libzimg": "zimg",
    "libarchive": "libarchive",
    "libbluray": "libbluray",
    "libudfread": "libudfread",
    "libuchardet": "uchardet",
    "libunibreak": "libunibreak",
    "libsamplerate": "libsamplerate",
    "librubberband": "rubberband",
    "libmpg123": "mpg123",
    "libmp3lame": "lame",
    "libopus": "opus",
    "libvulkan": "vulkan-loader",
    "libshaderc_shared": "shaderc",
    "libglib-2.0": "glib",
    "libpcre2": "pcre2",
    "libgraphite2": "graphite2",
    "liblcms2": "little-cms2",
    "libmujs": "mujs",
    "libzstd": "zstd", "liblzma": "xz", "liblz4": "lz4",
    "libbrotli": "brotli",
    "libintl": "gettext",
    "libb2": "libb2",
    "libsixel": "libsixel",
}


def formula_info(name):
    r = subprocess.run(["brew", "info", "--json=v2", name],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        f = json.loads(r.stdout)["formulae"][0]
    except Exception:
        return None
    return {
        "version": f.get("versions", {}).get("stable", "?"),
        "license": f.get("license"),
        "homepage": f.get("homepage"),
    }


def license_files(formula, version):
    """找 formula 的许可证文件。

    只取**当前版本**的 Cellar 目录：Cellar 里可能同时留着多个版本
    （如 ffmpeg 8.0.1 与 9.0.2），全扫会让同一份许可证在清单里重复列好几遍。
    """
    bases = []
    if version and version != "?":
        exact = f"/opt/homebrew/Cellar/{formula}/{version}"
        if os.path.isdir(exact):
            bases = [exact]
        else:
            # Homebrew 的 stable 版本号常有修订后缀（stable=9.0.2，目录=9.0.2_1），
            # 精确匹配不到时按前缀找，并取最新的那个 —— 不能用全量 glob，
            # 否则 Cellar 里留着的旧版本会让同一份许可证在清单里列两遍。
            prefixed = sorted(d for d in glob.glob(f"/opt/homebrew/Cellar/{formula}/*")
                              if os.path.basename(d).startswith(version))
            if prefixed:
                bases = [prefixed[-1]]
    if not bases:
        all_dirs = sorted(glob.glob(f"/opt/homebrew/Cellar/{formula}/*"))
        if all_dirs:
            bases = [all_dirs[-1]]
    out = []
    for b in bases:
        for name in sorted(os.listdir(b)):
            up = name.upper()
            if up.startswith(("COPYING", "LICENSE", "NOTICE")):
                p = os.path.join(b, name)
                if os.path.isfile(p):
                    out.append(p)
    return sorted(set(out))


def main(app_path):
    frameworks = os.path.join(app_path, "Contents", "Frameworks")
    res = os.path.join(app_path, "Contents", "Resources", "licenses")
    if os.path.exists(res):
        shutil.rmtree(res)
    os.makedirs(res, exist_ok=True)

    libs = sorted(glob.glob(os.path.join(frameworks, "*.dylib")))
    if not libs:
        sys.exit("Frameworks/ 是空的 —— 先跑 bundle_deps.py")

    # 内嵌库 → formula
    formulas = {}
    for lib in libs:
        base = os.path.basename(lib).split(".dylib")[0]
        stem = base.split(".")[0]
        for prefix, formula in LIB_TO_FORMULA.items():
            if stem.startswith(prefix):
                formulas.setdefault(formula, set()).add(os.path.basename(lib))
                break

    lines = [
        "# 第三方组件许可",
        "",
        "Gale Player 内嵌了以下第三方库。它们由各自作者以相应开源许可证授权，",
        "本应用按原许可证条款再分发。",
        "",
    ]
    copied = 0
    for formula in sorted(formulas):
        info = formula_info(formula) or {}
        lic = info.get("license") or "见许可证文件"
        home = info.get("homepage") or ""
        lines.append(f"## {formula}")
        lines.append("")
        lines.append(f"- 版本：{info.get('version', '?')}")
        lines.append(f"- 许可证：{lic}")
        if home:
            lines.append(f"- 项目主页 / 源码：{home}")
        files = license_files(formula, info.get("version", ""))
        if files:
            dest_dir = os.path.join(res, formula)
            os.makedirs(dest_dir, exist_ok=True)
            names = []
            for f in files:
                shutil.copy2(f, os.path.join(dest_dir, os.path.basename(f)))
                names.append(os.path.basename(f))
                copied += 1
            lines.append(f"- 许可证全文：`licenses/{formula}/` —— {', '.join(names)}")
        else:
            lines.append("- 许可证全文：见上游项目主页")
        lines.append("")

    lines += [
        "---",
        "",
        "## GPL 相关的额外说明",
        "",
        "本应用内嵌的 mpv 与 FFmpeg 是按 GPL 配置构建的版本（含 x264 / x265）。",
        "根据 GPL 第 3 条，任何获得本软件二进制副本的人都有权获得对应源码。",
        "对应源码可从上述项目主页取得，或联系分发者索取。",
        "",
    ]

    with open(os.path.join(res, "THIRD-PARTY-NOTICES.md"), "w") as fh:
        fh.write("\n".join(lines))

    print(f"已生成许可证目录：{len(formulas)} 个组件，{copied} 份许可证全文")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("用法: make_licenses.py <Gale Player.app 路径>")
    main(os.path.abspath(sys.argv[1]))
