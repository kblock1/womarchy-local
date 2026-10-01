#!/usr/bin/env python3
"""Derive a womarchy PKGBUILD from an Arch one: same package name(s), pkgrel suffixed with .1,
our patches added to source[] (SKIP checksums) and applied at the start of prepare().

usage: derive-pkgbuild.py <arch PKGBUILD> <out PKGBUILD> <patch-dir-in-srcdir> [--rel N] [--only NAME...] -- <patch files...>
  <patch-dir-in-srcdir>: directory (relative to $srcdir) to `cd` into before applying patches
  --rel N: womarchy revision, pkgrel becomes <arch pkgrel>.N (default 1); bump it when our patches change
  --only NAME: keep only these split packages (drops the other package_* functions)
"""
import re
import sys

args = sys.argv[1:]
src, dst, workdir = args[0], args[1], args[2]
rest = args[3:]
rel = "1"
if "--rel" in rest:
    i = rest.index("--rel")
    rel = rest[i + 1]
    rest = rest[:i] + rest[i + 2:]
only = []
if "--only" in rest:
    i = rest.index("--only")
    j = rest.index("--")
    only = rest[i + 1:j]
    rest = rest[:i] + rest[j:]
patches = [p.split("/")[-1] for p in rest[rest.index("--") + 1:]]

s = open(src, encoding="utf-8").read()
s = re.sub(r"^pkgrel=(\d+)$", lambda m: f"pkgrel={m.group(1)}.{rel}", s, count=1, flags=re.M)

if only:
    if re.search(r"^pkgname=\(", s, flags=re.M):
        s = re.sub(r"^pkgname=\((.*?)\)", "pkgname=(" + " ".join(only) + ")", s, count=1, flags=re.S | re.M)
    for fn in re.findall(r"^package_([\w-]+)\(\)", s, flags=re.M):
        if fn not in only:
            s = re.sub(rf"\npackage_{re.escape(fn)}\(\) \{{.*?\n\}}\n", "\n", s, count=1, flags=re.S)

s = re.sub(r"^source=\(", "source=(" + " ".join(patches) + "\n        ", s, count=1, flags=re.M)
for arr in ("sha256sums", "b2sums", "sha512sums"):
    s = re.sub(rf"^{arr}=\(", lambda m: m.group(0) + " ".join(["'SKIP'"] * len(patches)) + "\n  ", s, count=1, flags=re.M)

apply = "\n".join([f'\tpatch -d "{workdir}" -Np1 -i "$srcdir/{p}"' for p in patches])
if re.search(r"^prepare\(\) \{", s, flags=re.M):
    # run after upstream's prepare (which may create symlinks/dirs our workdir relies on)
    s = re.sub(r"(^prepare\(\) \{.*?)(\n\}\n)", lambda m: m.group(1) + "\n\tcd \"$srcdir\"\n" + apply + m.group(2), s, count=1, flags=re.S | re.M)
else:
    s = re.sub(r"^build\(\) \{", "prepare() {\n\tcd \"$srcdir\"\n" + apply + "\n}\n\nbuild() {", s, count=1, flags=re.M)

s = "# womarchy: generated from Arch's PKGBUILD by derive-pkgbuild.py — do not edit by hand\n" + s
open(dst, "w", encoding="utf-8", newline="\n").write(s)
print(f"wrote {dst} (patches: {patches}{', only ' + ' '.join(only) if only else ''})")
