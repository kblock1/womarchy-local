#!/usr/bin/env python3
"""Look for things that must never be committed: private keys, access tokens, and paths that would
reveal a contributor's machine (a Windows user profile, a Linux home other than the test users).

    tools/check-secrets.py          (scans the files git tracks)

Generic on purpose: it lists no personal names. For an image's root filesystem, use
lab/overlay/privacy-scan.sh, which also looks for this machine's own identifiers.
"""
import re
import subprocess
import sys

PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----"),
    "GitHub token": re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "Slack token": re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{10,}\b"),
    "OpenAI/Anthropic key": re.compile(r"\bsk-(ant-)?[A-Za-z0-9_-]{32,}\b"),
    # C:\Users\<name>\... with a real name (placeholders such as me, <you>, %USERNAME% and $env: are fine)
    "Windows user profile path": re.compile(
        r"[A-Za-z]:\\\\?Users\\\\?(?!(?:Public|Default|me|you|user|username|name)\\|<|%|\$|\{)[A-Za-z0-9._ -]+\\"
    ),
    # /home/<name>/ other than the image's test users and placeholders
    "Linux home path": re.compile(r"/home/(?!omarchy\b|lab\b|user\b|builder\b|<|\$|\*)[a-z_][a-z0-9_-]*/"),
}
# Binary files and third-party reference files are not ours to police.
SKIP = (".png", ".ico", ".bmp", ".jpg", ".gif", ".zst", ".gz", ".wsl", ".lock")


def main() -> int:
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.splitlines()
    hits = []
    for path in files:
        if path.endswith(SKIP):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for what, pattern in PATTERNS.items():
                if pattern.search(line):
                    hits.append(f"{path}:{n}: {what}")
    for h in hits:
        print(h)
    print(f"{len(files)} files scanned, {len(hits)} findings")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
