#!/usr/bin/env python3
"""Fail if a Dolphin build does not match TwinPlay's GameCube rules.

macos: ARM64 JIT sources compiled, Metal and Vulkan backends compiled.
ios:   generic (no JIT) build, cached interpreter and Metal compiled,
       no JitArm64 objects, no -ffast-math.
"""
import json
import sys
from pathlib import Path


def load(build: Path):
    path = build / "compile_commands.json"
    data = json.loads(path.read_text())
    files = "\n".join(e.get("file", "") for e in data)
    commands = "\n".join(e.get("command", "") or " ".join(e.get("arguments", [])) for e in data)
    return files, commands


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check-dolphin-build.py macos|ios BUILD_DIR", file=sys.stderr)
        return 2
    kind, build = sys.argv[1], Path(sys.argv[2])
    files, commands = load(build)
    if kind == "macos":
        missing = [n for n in ("JitArm64", "VideoBackends/Metal", "VideoBackends/Vulkan") if n not in files]
        if missing:
            print("macOS Dolphin build is missing:", ", ".join(missing), file=sys.stderr)
            return 1
        if "_M_ARM_64" not in commands and "-D_M_ARM_64" not in commands:
            print("macOS build did not pass _M_ARM_64", file=sys.stderr)
            return 1
        print("macOS: JIT ARM64, Metal and Vulkan are in the compile database")
        return 0
    if kind == "ios":
        if "JitArm64" in files:
            print("iOS build compiled JitArm64; ENABLE_GENERIC did not stick", file=sys.stderr)
            return 1
        for n in ("CachedInterpreter", "VideoBackends/Metal"):
            if n not in files:
                print(f"iOS build is missing {n}", file=sys.stderr)
                return 1
        if "_M_GENERIC" not in commands:
            print("iOS build did not pass _M_GENERIC", file=sys.stderr)
            return 1
        if "-ffast-math" in commands:
            print("iOS build used -ffast-math; the cached interpreter must not", file=sys.stderr)
            return 1
        objects = list(build.rglob("JitArm64*.o"))
        if objects:
            print("iOS build produced JIT objects:", objects[0], file=sys.stderr)
            return 1
        print("iOS: cached interpreter, Metal, no JIT objects, no fast-math")
        return 0
    print("unknown kind", kind, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
