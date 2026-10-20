#!/usr/bin/env python3
"""遍历二进制依赖闭包，挑出非系统库（分发时必须打进 .app 的那些）。"""
import subprocess, sys, os

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")

def deps(path):
    try:
        out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    except Exception:
        return []
    result = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("("):
            continue
        dep = line.split(" (")[0].strip()
        if dep:
            result.append(dep)
    return result

def resolve(dep, owner):
    """解析 @rpath/@loader_path 等相对路径。"""
    if dep.startswith("/"):
        return dep if os.path.exists(dep) else None
    if dep.startswith("@rpath/"):
        name = dep.split("/", 1)[1]
        for base in ("/opt/homebrew/lib", "/opt/homebrew/opt/mpv/lib",
                     os.path.dirname(owner) if owner else ""):
            cand = os.path.join(base, name)
            if os.path.exists(cand):
                return cand
    if dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
        name = dep.split("/", 1)[1]
        cand = os.path.join(os.path.dirname(owner), name)
        return cand if os.path.exists(cand) else None
    return None

def main(root_binary):
    seen, queue = {}, [os.path.realpath(root_binary)]
    while queue:
        cur = queue.pop()
        if cur in seen:
            continue
        seen[cur] = True
        for dep in deps(cur):
            real = resolve(dep, cur)
            if real and real not in seen:
                queue.append(os.path.realpath(real))

    external, system = [], []
    for p in sorted(seen):
        if p.startswith(SYSTEM_PREFIXES):
            system.append(p)
        elif p != os.path.realpath(root_binary):
            external.append(p)
    return external, system

if __name__ == "__main__":
    ext, syslibs = main(sys.argv[1])
    total = 0
    print(f"非系统库 {len(ext)} 个（分发时必须打包）：")
    for p in ext:
        size = os.path.getsize(p)
        total += size
        print(f"  {size/1048576:7.2f} MB  {p}")
    print(f"\n合计 {total/1048576:.1f} MB")
    print(f"系统库 {len(syslibs)} 个（不用打包）")
