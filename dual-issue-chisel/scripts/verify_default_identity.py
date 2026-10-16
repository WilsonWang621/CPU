#!/usr/bin/env python3
"""Compare the entire measured v13 RTL with a newly elaborated default CPU.

Only comments, inter-token whitespace and Scala source line numbers inside
diagnostic strings are ignored. All hardware tokens and assertion conditions
are compared; this is stronger than matching selected outputs on test programs.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1]
REPORT = PROJECT / "reports/requirements-2026-10-16"
TOKENS = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/|\\\S+|[A-Za-z_$][\w$]*|\d+\x27[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|\d+(?:\.\d+)?|===|!==|<<|>>|<=|>=|==|!=|&&|\|\||[^\s]', re.S)


def tokens(text):
    result = []
    for match in TOKENS.finditer(text):
        token = match.group()
        if token.startswith(("//", "/*")):
            continue
        if token.startswith('"'):
            token = re.sub(r"(?<=\.scala:)\d+", "LINE", token)
        result.append(token)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, default=PROJECT / "rtl/student_top.sv")
    parser.add_argument("--out", type=Path, default=REPORT / "default-circuit-equivalence.json")
    args = parser.parse_args()
    old = gzip.decompress((REPORT / "baseline-v13.sv.gz").read_bytes())
    new = args.rtl.read_bytes()
    digest = lambda data: hashlib.sha256(data).hexdigest()
    assert digest(old) == "9ea7ed6c12f131da8d045ecae9484aea52fe75d4bf8e96e53a52e0feaf05e977"
    a, b = tokens(old.decode()), tokens(new.decode())
    if a != b:
        first = next((i for i, pair in enumerate(zip(a, b)) if pair[0] != pair[1]), min(len(a), len(b)))
        raise SystemExit(f"Circuit tokens differ at {first}: {a[max(0, first-4):first+5]} versus {b[max(0, first-4):first+5]}")
    result = {"equivalent": True, "method": __doc__, "tokens": len(a),
              "old_rtl_sha256": digest(old), "new_rtl_sha256": digest(new),
              "normalized_sha256": digest("\n".join(a).encode()),
              "script_sha256": digest(Path(__file__).read_bytes())}
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS: {len(a)} identical complete-circuit tokens")


if __name__ == "__main__":
    main()
