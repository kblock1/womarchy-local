#!/usr/bin/env python3
"""Check that relative links in the repo's Markdown files point at files that exist.

    tools/check-links.py            (from anywhere inside the checkout)

External links (http, mailto) and in-page anchors are not checked. Exit code 1 lists the broken ones.
"""
import os
import re
import subprocess
import sys

LINK = re.compile(r"\]\(([^)\s]+)\)")


def main() -> int:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True, cwd=root).stdout.split()
    broken = []
    for md in files:
        text = open(os.path.join(root, md), encoding="utf-8").read()
        for match in LINK.finditer(text):
            target = match.group(1).split("#")[0]
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            path = os.path.normpath(os.path.join(root, os.path.dirname(md), target))
            if not os.path.exists(path):
                broken.append(f"{md}: {match.group(1)}")
    for b in broken:
        print("broken link:", b)
    print(f"{len(files)} Markdown files checked, {len(broken)} broken links")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
