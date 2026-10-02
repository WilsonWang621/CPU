#!/usr/bin/env python3
"""Regenerate the selected verified CPU from its frozen Chisel sources."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code(text):
    # Keep SV string literals; discard source-location and generator comments.
    token = r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
    text = re.sub(token, lambda m: m[0] if m[0].startswith('"') else " ", text)
    return re.sub(r'"(?:\\.|[^"\\])*"|\s+', lambda m: m[0] if m[0].startswith('"') else "", text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="baseline.json")
    parser.add_argument("--out", default="rtl")
    args = parser.parse_args()
    baseline = json.loads((PROJECT / args.baseline).read_text())
    report = PROJECT / baseline["report"]
    summary = json.loads((report / "summary.json").read_text())
    manifest = json.loads((report / "manifest.json").read_text())
    if not summary["tier2_pass"]:
        raise ValueError("Selected baseline has not passed Tier2")
    for name, expected in manifest["source_sha256"].items():
        if sha(report / "source" / name) != expected:
            raise ValueError("Frozen source changed: " + name)
    frozen = report / "rtl/student_top.sv"
    if sha(frozen) != summary["rtl_sha256"]:
        raise ValueError("Frozen RTL changed")
    generator = PROJECT / "build/baseline/generator"
    scala = generator / "src/main/scala/tier2"
    scala.mkdir(parents=True, exist_ok=True)
    for path in scala.glob("*.scala"):
        path.unlink()
    for path in (report / "source").glob("*.scala"):
        shutil.copy2(path, scala / path.name)
    shutil.copy2(report / "source/build.sbt", generator / "build.sbt")
    (generator / "project").mkdir(exist_ok=True)
    shutil.copy2(report / "source/build.properties", generator / "project/build.properties")
    output = PROJECT / "build/baseline/rtl"
    command = "run --out " + str(output)
    command += "".join(" --" + k + " " + str(v) for k, v in manifest["parameters"].items() if k != "issue-width")
    subprocess.run([str(Path.home() / ".local/bin/sbt"), "-batch", command], cwd=generator, check=True)
    generated = output / "student_top.sv"
    if code(generated.read_text()) != code(frozen.read_text()):
        raise ValueError("Regenerated circuit differs from verified baseline")
    destination = PROJECT / args.out
    destination.mkdir(parents=True, exist_ok=True)
    # Publish the byte-identical measured artifact after regeneration checks.
    shutil.copy2(frozen, destination / "student_top.sv")
    (destination / "filelist.f").write_text("student_top.sv\n")
    print("Verified regeneration:", baseline["report"], summary["rtl_sha256"])


if __name__ == "__main__":
    main()
