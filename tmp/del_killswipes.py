# -*- coding: utf-8 -*-
import io, sys

P = r"d:\woekbude\2026-11-15-11-58-50\Safari16Enhance\Tweak.xm"
lines = io.open(P, encoding="utf-8").read().split("\n")

start = end = None
for i, l in enumerate(lines):
    if l.startswith("// 找到胶囊栏，把它所有 pan 打上标记"):
        start = i
    if l.startswith("// MARK: - 入口"):
        end = i
        break
if start is None or end is None or end <= start:
    print("BOUND NOT FOUND", start, end); sys.exit(1)

removed = end - start
out = lines[:start] + lines[end:]
io.open(P, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print("removed lines %d..%d (%d lines)" % (start + 1, end, removed))
