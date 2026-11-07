#!/usr/bin/env python3
"""Post-condition guard for evidence receipts.

A heredoc or patch that "succeeds" while silently dropping content is a no-op that
reports success. That already happened once here (two quoted phrases eaten by an
unquoted heredoc), and it was caught only by reading the file back.

This asserts, after the fact, that every receipt is structurally intact:
  - no line where a quoted/backticked phrase vanished, leaving '()' or ', ,' or a
    dangling ' ,' fragment;
  - every 8-40 hex commit id cited resolves in this repo;
  - every file is non-empty and ends with a newline.
Exit code 1 on any violation, so a silent no-op becomes a failure.
"""
import glob
import re
import subprocess
import sys

problems = []

for path in sorted(glob.glob("evidence/*.txt")):
    text = open(path, encoding="utf-8").read()

    if not text.strip():
        problems.append(f"{path}: empty")
    if not text.endswith("\n"):
        problems.append(f"{path}: missing trailing newline")

    for n, line in enumerate(text.splitlines(), 1):
        # Distinguish TWO different things that both contain '()':
        #   an identifier call, e.g. `ServerSettings.committedAccountIdentity()` - legitimate;
        #   a DROPPED phrase, which leaves '()' standing alone at a sentence boundary, i.e.
        #   preceded by whitespace/line-start rather than by an identifier character.
        # An earlier version excluded any line containing an identifier call, which silenced
        # real drops on those same lines - detection got weaker to remove a false positive.
        for dropped in re.finditer(r"(?<![A-Za-z0-9_.:`])\(\s*\)", line):
            problems.append(f"{path}:{n}: empty parentheses - a phrase was dropped")
        if re.search(r"(^|\s),\s*,", line):
            problems.append(f"{path}:{n}: doubled comma - a phrase was dropped")

    for commit in sorted(set(re.findall(r"`([0-9a-f]{8,40})`", text))):
        ok = subprocess.run(
            ["git", "cat-file", "-t", commit], capture_output=True, text=True
        )
        if ok.returncode != 0:
            problems.append(f"{path}: cited commit {commit} does not resolve")

if problems:
    print("RECEIPT INTEGRITY: FAIL")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print(f"RECEIPT INTEGRITY: OK ({len(glob.glob('evidence/*.txt'))} files)")
