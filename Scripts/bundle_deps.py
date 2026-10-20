#!/usr/bin/env python3
"""把 .app 依赖的非系统 dylib 全部内嵌进 Contents/Frameworks/ 并改写加载路径。

为什么必须做：主二进制现在链的是 /opt/homebrew/opt/mpv/lib/libmpv.2.dylib，
闭包 50 个库。没装 Homebrew 的机器启动即 dyld 报错。

做法：
  1. 遍历依赖闭包，把每个非系统库拷进 Contents/Frameworks/
  2. 主二进制里指向 Homebrew 的 load command 改成 @rpath/<名字>
  3. 给主二进制加 LC_RPATH = @executable_path/../Frameworks
  4. 重复项：让每个内嵌 dylib 用 @rpath 引用同目录的其它库，并各加 @loader_path

幂等：每次从主二进制重新遍历，Frameworks/ 先清空再填。
"""
import os
import shutil
import subprocess
import sys
from collections import defaultdict

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def load_commands(path):
    """返回 otool -L 里的依赖路径列表（跳过自身 id 行）。"""
    out = run("otool", "-L", path).stdout
    deps = []
    for i, line in enumerate(out.splitlines()):
        if i == 0:
            continue
        line = line.strip()
        if not line or line.startswith("("):
            continue
        dep = line.split(" (")[0].strip()
        if dep:
            deps.append(dep)
    return deps


def own_id(path):
    """dylib 的 LC_ID_DYLIB 值。"""
    out = run("otool", "-D", path).stdout.splitlines()
    for line in out[1:]:
        line = line.strip()
        if line:
            return line
    return None


def is_system(path):
    return path.startswith(SYSTEM_PREFIXES)


def resolve(dep, owner):
    """把 @rpath/@loader_path 解析成真实文件路径。"""
    if dep.startswith("/"):
        return dep if os.path.exists(dep) else None
    name = dep.split("/", 1)[1] if "/" in dep else dep
    if dep.startswith("@rpath/"):
        bases = ["/opt/homebrew/lib", "/opt/homebrew/opt/mpv/lib",
                 os.path.dirname(owner)]
        for base in bases:
            cand = os.path.join(base, name)
            if os.path.exists(cand):
                return cand
        return None
    if dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
        cand = os.path.join(os.path.dirname(owner), name)
        return cand if os.path.exists(cand) else None
    return None


def has_rpath(path, rpath):
    """检查 Mach-O 里是否已有指定的 LC_RPATH。

    坑：不能用「LC_RPATH 条数是否为 0」来判断 —— Swift 编出来的二进制
    天生带着 /usr/lib/swift 和 Xcode 工具链两条 rpath，条数永远不是 0，
    于是守卫条件恒假、自己的 rpath 永远加不上，@rpath 引用解析不到，
    App 启动直接 dyld 报错。
    """
    out = run("otool", "-l", path).stdout.splitlines()
    for i, line in enumerate(out):
        if "LC_RPATH" in line:
            for j in range(i, min(i + 5, len(out))):
                s = out[j].strip()
                if s.startswith("path "):
                    if s.split("path ", 1)[1].split(" ")[0] == rpath:
                        return True
                    break
    return False


def ensure_rpath(path, rpath):
    if not has_rpath(path, rpath):
        run("install_name_tool", "-add_rpath", rpath, path)


def closure(main):
    seen = {}
    order = []
    queue = [os.path.realpath(main)]
    while queue:
        cur = queue.pop()
        if cur in seen:
            continue
        seen[cur] = True
        for dep in load_commands(cur):
            real = resolve(dep, cur)
            if real is None:
                continue
            real = os.path.realpath(real)
            if real not in seen:
                queue.append(real)
                order.append((real, dep))
    return [p for p, _ in order if not is_system(p)]


def main(app_path):
    binary = os.path.join(app_path, "Contents", "MacOS", "GalePlayer")
    frameworks = os.path.join(app_path, "Contents", "Frameworks")
    if not os.path.exists(binary):
        sys.exit(f"找不到主二进制：{binary}")

    libs = closure(binary)
    if not libs:
        print("没有需要内嵌的库（可能已经处理过）")
        return

    # 同名不同路径的冲突检测：扁平放进 Frameworks 会互相覆盖
    by_name = defaultdict(set)
    for p in libs:
        by_name[os.path.basename(p)].add(p)
    clashes = {n: ps for n, ps in by_name.items() if len(ps) > 1}
    if clashes:
        print("⚠ 存在同名库，将保留来源子目录：")
        for n, ps in clashes.items():
            print(f"   {n}: {sorted(ps)}")

    if os.path.exists(frameworks):
        shutil.rmtree(frameworks)
    os.makedirs(frameworks, exist_ok=True)

    # ① 拷贝，记录 旧路径 → 包内相对名
    mapping = {}
    for path in libs:
        name = os.path.basename(path)
        if name in clashes:
            # 冲突时带回退的子目录名，保证唯一
            name = os.path.basename(os.path.dirname(os.path.dirname(path))) + "_" + name
        dest = os.path.join(frameworks, name)
        shutil.copy2(path, dest)
        os.chmod(dest, 0o755)
        mapping[path] = name
        mapping[os.path.basename(path)] = name

    # ② 改写每个内嵌库：自己的 id + 对其它库的引用
    for path, name in [(p, mapping[p]) for p in libs]:
        dest = os.path.join(frameworks, name)
        run("install_name_tool", "-id", f"@rpath/{name}", dest)
        for dep in load_commands(dest):
            real = resolve(dep, path) or resolve(dep, dest)
            if real is None:
                continue
            real = os.path.realpath(real)
            if real in mapping:
                run("install_name_tool", "-change", dep,
                    f"@rpath/{mapping[real]}", dest)
            elif is_system(dep):
                pass
            else:
                print(f"   ⚠ 未内嵌的依赖: {dep}  (被 {name} 引用)")
        # 让库能在同目录内解析 @rpath
        ensure_rpath(dest, "@loader_path")

    # ③ 改写主二进制
    for dep in load_commands(binary):
        real = resolve(dep, binary)
        if real is None:
            continue
        real = os.path.realpath(real)
        if real in mapping:
            run("install_name_tool", "-change", dep,
                f"@rpath/{mapping[real]}", binary)
    ensure_rpath(binary, "@executable_path/../Frameworks")

    total = sum(os.path.getsize(os.path.join(frameworks, f))
                for f in os.listdir(frameworks))
    print(f"已内嵌 {len(libs)} 个库，{total / 1048576:.1f} MB → Contents/Frameworks/")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("用法: bundle_deps.py <Gale Player.app 路径>")
    main(os.path.abspath(sys.argv[1]))
