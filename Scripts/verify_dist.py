#!/usr/bin/env python3
"""校验 .app 是否自包含 —— 分发前的最后一道门。

检查项：
  1. 包内每个 Mach-O 都不含 /opt/homebrew、/Users/... 等外部绝对路径
  2. 主二进制引用的每个非系统库都能在 Contents/Frameworks/ 里找到
  3. 每个 Frameworks 里的库签名有效
  4. 主二进制有 @executable_path/../Frameworks 这条 rpath

任何一项失败都以非零码退出，让 make_dist.sh 停下来 —— 宁可不出包，
也不要出一个在别人机器上打不开的包。
"""
import os
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def is_macho(path):
    try:
        with open(path, "rb") as fh:
            magic = fh.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def machos(app):
    out = []
    for root, _dirs, files in os.walk(app):
        for f in files:
            p = os.path.join(root, f)
            if is_macho(p):
                out.append(p)
    return sorted(out)


BAD_PATTERN = re.compile(r"(/opt/homebrew|/usr/local/Cellar|/Users/[^/]+/(?!\.\.)/)")


def main(app):
    app = os.path.abspath(app)
    frameworks = os.path.join(app, "Contents", "Frameworks")
    binary = os.path.join(app, "Contents", "MacOS", "GalePlayer")
    errors = []

    # ---- 1. 外部绝对路径 ----
    bad = []
    for m in machos(app):
        for line in run("otool", "-L", m).stdout.splitlines()[1:]:
            line = line.strip()
            if not line or line.startswith("("):
                continue
            dep = line.split(" (")[0]
            if BAD_PATTERN.search(dep):
                bad.append((os.path.relpath(m, app), dep))
    if bad:
        errors.append(f"仍有 {len(bad)} 处外部依赖引用（分发后会 dyld 报错）：")
        for rel, dep in bad[:8]:
            errors.append(f"    {rel} → {dep}")

    # ---- 2. 主二进制的库是否都在包内 ----
    missing = []
    have = set(os.listdir(frameworks)) if os.path.isdir(frameworks) else set()
    for line in run("otool", "-L", binary).stdout.splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("("):
            continue
        dep = line.split(" (")[0]
        if dep.startswith(("/usr/lib/", "/System/")):
            continue
        if dep.startswith("@rpath/") and dep.split("/", 1)[1] not in have:
            missing.append(dep)
        elif dep.startswith("/"):
            missing.append(dep)
    if missing:
        errors.append(f"主二进制引用了包内不存在的库：{missing}")

    # ---- 3. rpath ----
    if "@executable_path/../Frameworks" not in run("otool", "-l", binary).stdout:
        errors.append("主二进制缺少 LC_RPATH = @executable_path/../Frameworks")

    # ---- 4. 签名 ----
    v = run("codesign", "--verify", "--deep", "--strict", app)
    if v.returncode != 0:
        errors.append(f"签名校验失败：{v.stderr.strip()[:300]}")

    libcount = len(have)
    totalsize = sum(os.path.getsize(os.path.join(frameworks, f)) for f in have) if have else 0

    if errors:
        print("自包含校验未通过 ✗")
        for e in errors:
            print("  " + e)
        sys.exit(1)

    print(f"自包含校验通过 ✓")
    print(f"    内嵌库 {libcount} 个 / {totalsize / 1048576:.1f} MB")
    print(f"    包内 Mach-O {len(machos(app))} 个，零外部路径引用")
    print(f"    签名有效")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("用法: verify_dist.py <Gale Player.app 路径>")
    main(sys.argv[1])
