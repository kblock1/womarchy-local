#!/usr/bin/env python3
"""Repair the debug fprintf in the lab Mesa tree (a shell layer turned \\n into a real newline)."""
import re
import sys

p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r'fprintf\(stderr, "subdata %ux%u: create %\.2f map %\.2f copy %\.2f unmap %\.2f gpu %\.2f ms\s*\n"',
           'fprintf(stderr, "subdata %ux%u: create %.2f map %.2f copy %.2f unmap %.2f gpu %.2f ms\\\\n"', s)
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("ok" if 'ms\\n"' in s else "NOT FIXED")
