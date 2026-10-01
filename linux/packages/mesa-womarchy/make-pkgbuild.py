#!/usr/bin/env python3
"""Derive the womarchy Mesa PKGBUILD from Arch's current one.

Keeps Arch's package names (mesa, vulkan-dzn, ...) so a [womarchy] repo placed before [extra]
overrides them, trims the driver set to what WSL2 can use (d3d12 GL/VA, Dozen Vulkan, and the
llvmpipe/lavapipe/zink software fallbacks), and applies patches/mesa/*.patch.

usage: make-pkgbuild.py [--rel N] <arch PKGBUILD> <out PKGBUILD> <patch files...>
  --rel N: womarchy revision, pkgrel becomes <arch pkgrel>.N (default 1); bump it when our patches change
"""
import re
import sys

argv = sys.argv[1:]
rel = "1"
if argv[:1] == ["--rel"]:
    rel, argv = argv[1], argv[2:]
src, dst, patches = argv[0], argv[1], [p.split("/")[-1] for p in argv[2:]]
s = open(src, encoding="utf-8").read()

KEEP = ["mesa", "vulkan-dzn", "vulkan-swrast", "vulkan-mesa-implicit-layers", "vulkan-mesa-layers"]
PICK_KEEP = {"vkd3d12", "vkswrast", "vkdevice", "vklayer"}

# 1. split package list
s = re.sub(r"pkgname=\((.*?)\)", "pkgname=(\n  " + "\n  ".join(KEEP) + "\n)", s, count=1, flags=re.S)

# 2. release: mark as ours
s = re.sub(r"^pkgrel=(\d+)$", lambda m: f"pkgrel={m.group(1)}.{rel}", s, count=1, flags=re.M)

# 3. driver set / options
opts = {
    "gallium-drivers": "d3d12,llvmpipe,softpipe,zink",
    "vulkan-drivers": "swrast,microsoft-experimental",
    "vulkan-layers": "device-select,overlay,screenshot,anti-lag",
    "gallium-rusticl": "false",
    "html-docs": "disabled",
    "intel-rt": "disabled",
    "valgrind": "disabled",
}
drop = ["amdgpu-virtio", "freedreno-kmds", "gallium-rusticl-enable-drivers", "intel-virtio-experimental"]
for k, v in opts.items():
    s, n = re.subn(rf"(-D {re.escape(k)}=)\S+", rf"\g<1>{v}", s)
    assert n == 1, k
for k in drop:
    s = re.sub(rf"\n\s*-D {re.escape(k)}=\S+", "", s)

# 4. drop _pick lines for packages we no longer build
def keep_pick(m):
    return m.group(0) if m.group(1) in PICK_KEEP else ""
s = re.sub(r"\n\s*_pick (\w+) [^\n]*", keep_pick, s)

# 5. drop package_* functions of removed packages
for fn in re.findall(r"^package_([\w-]+)\(\)", s, flags=re.M):
    if fn in KEEP:
        continue
    s = re.sub(rf"\npackage_{re.escape(fn)}\(\) \{{.*?\n\}}\n", "\n", s, count=1, flags=re.S)

# 6. makedepends not needed for the trimmed build (Rust OpenCL, docs, valgrind, Intel CL)
for dep in ["rust", "rust-bindgen", "libclc", "spirv-llvm-translator", "python-sphinx", "python-sphinx-hawkmoth",
            "valgrind", "clang", "cbindgen", "python-pycparser"]:
    s = re.sub(rf"\n\s*{re.escape(dep)}(\s*#[^\n]*)?(?=\n)", "", s)

# 7. our patches (applied by Arch's prepare(), which patches every *.patch in source[])
s = re.sub(r"source=\(", "source=(\n  " + "\n  ".join(patches), s, count=1)
for arr in ("sha256sums", "b2sums"):
    s = re.sub(rf"^{arr}=\(", lambda m: m.group(0) + " ".join(["'SKIP'"] * len(patches)) + "\n  ", s, count=1, flags=re.M)

s = "# womarchy: generated from Arch's mesa PKGBUILD by make-pkgbuild.py — do not edit by hand\n" + s
open(dst, "w", encoding="utf-8", newline="\n").write(s)
print(f"wrote {dst}: packages {KEEP}, patches {patches}")
