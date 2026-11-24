#!/usr/bin/env python3
"""Compile TwinPlay's Dolphin host with one of Dolphin's own compile lines.

This checks that twinplay_gc_host.cpp still matches the pinned Dolphin API.
It does not link the host into the app. Pass --ios to compile the JIT-less path.
"""
import json
import shlex
import subprocess
import sys
from pathlib import Path


def command_of(entry: dict) -> list[str]:
    if entry.get("arguments"):
        return list(entry["arguments"])
    return shlex.split(entry["command"])


def main() -> int:
    args = sys.argv[1:]
    ios = False
    if "--ios" in args:
        ios = True
        args.remove("--ios")
    if len(args) != 2:
        print("usage: compile-gc-host.py COMPILE_COMMANDS HOST_CPP [--ios]", file=sys.stderr)
        return 2
    db, host = Path(args[0]), Path(args[1])
    data = json.loads(db.read_text())
    donor = next((e for e in data if e.get("file", "").endswith("PowerPC.cpp")), None)
    if donor is None:
        print("no PowerPC.cpp compile command to reuse", file=sys.stderr)
        return 1
    cmd = command_of(donor)
    donor_file = donor.get("file", "")
    out = db.parent / ("twinplay_gc_host_ios.o" if ios else "twinplay_gc_host_mac.o")
    replaced_c = False
    replaced_o = False
    new: list[str] = []
    skip_next = False
    for tok in cmd:
        if skip_next:
            skip_next = False
            continue
        if donor_file and (tok == donor_file or tok.endswith("/PowerPC.cpp")):
            new.append(str(host))
            replaced_c = True
            continue
        if tok == "-c":
            new.append("-c")
            replaced_c = True
            continue
        if tok == "-o":
            new.extend(["-o", str(out)])
            skip_next = True
            replaced_o = True
            continue
        if tok.startswith("-o") and tok != "-o":
            new.append("-o" + str(out))
            replaced_o = True
            continue
        new.append(tok)
    if not replaced_c or not replaced_o:
        print("could not rewrite the Dolphin compile line", file=sys.stderr)
        return 1
    new.append("-DTWINPLAY_GC_HOST=1")
    if ios:
        new.append("-DTWINPLAY_GC_IOS=1")
    print("compiling", host.name, "ios" if ios else "mac")
    subprocess.check_call(new, cwd=donor["directory"])
    print("host object:", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
