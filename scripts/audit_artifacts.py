#!/usr/bin/env python3
"""Audit tracked artifact sizes without changing the repository."""
from __future__ import annotations

import argparse
import json
import subprocess
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def category(path: str, size: int) -> str:
    p = Path(path)
    parts = p.parts
    suffix = p.suffix.lower()
    if suffix in {".vcd", ".fst", ".wlf", ".shm", ".fsdb"}:
        return "waveforms"
    if any(x in parts for x in ("verified", "frozen-input")) or "/source/" in f"/{path}" or "/rtl/" in f"/{path}" and "reports" in parts:
        return "frozen_inputs"
    if suffix in {".log", ".rpt", ".ys", ".gz"} or (suffix == ".json" and size >= 1_000_000):
        return "complete_logs_outputs"
    if path.endswith("cpu2026-tools-x86_64.AppImage") or "packaging/appimage" in path:
        return "toolkit"
    if path.startswith("testcases/") or path.startswith("tests/"):
        return "course_inputs"
    if path in {"dual-issue-chisel/rtl/student_top.sv", "dual-issue-chisel/rtl/elaboration.json", "dual-issue-chisel/rtl/filelist.f", "single-issue-chisel/rtl/student_top.sv", "single-issue-chisel/rtl/filelist.f", "verilog/area_v2_core.v"}:
        return "required_generated_rtl"
    if suffix in {".scala", ".sv", ".v", ".py", ".sh", ".mk"} or p.name in {"Makefile", "build.sbt", "build.properties"}:
        return "source_and_config"
    if suffix in {".md", ".csv", ".json"}:
        return "experiment_summaries"
    return "other_tracked"


def tracked_sizes():
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    rows = []
    for name in names:
        if not name:
            continue
        if name in {"docs/artifact-audit.json", "docs/artifact-audit.md"}:
            continue
        path = ROOT / name
        if path.is_file():
            size = path.stat().st_size
            rows.append({"path": name, "bytes": size, "category": category(name, size)})
    return rows


def history_objects():
    command = ["git", "rev-list", "--objects", "--all"]
    objects = subprocess.check_output(command, cwd=ROOT, text=True).splitlines()
    batch = subprocess.Popen(["git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    output, _ = batch.communicate("\n".join(line.split(" ", 1)[0] for line in objects) + "\n")
    paths = {parts[0]: (parts[1] if len(parts) > 1 else "unknown")
             for line in objects if (parts := line.split(" ", 1))}
    result = []
    for line in output.splitlines():
        oid, kind, size = line.split()
        if kind == "blob" and int(size) >= 1_000_000:
            result.append({"oid": oid, "bytes": int(size), "path": paths.get(oid, "unknown")})
    return sorted(result, key=lambda row: (-row["bytes"], row["path"], row["oid"]))


def human(n: int) -> str:
    value = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{n} B"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=ROOT / "docs/artifact-audit.json")
    parser.add_argument("--history", action="store_true", help="also scan blobs reachable from local refs")
    args = parser.parse_args()
    rows = tracked_sizes()
    categories = defaultdict(lambda: {"files": 0, "bytes": 0})
    directories = defaultdict(lambda: {"files": 0, "bytes": 0})
    for row in rows:
        categories[row["category"]]["files"] += 1
        categories[row["category"]]["bytes"] += row["bytes"]
        top = "/".join(Path(row["path"]).parts[:2]) or "."
        directories[top]["files"] += 1
        directories[top]["bytes"] += row["bytes"]
    payload = {
        "schema_version": 1,
        "scope": "tracked working-tree files; history is local refs only when requested",
        "tracked": {"files": len(rows), "bytes": sum(r["bytes"] for r in rows)},
        "categories": {k: categories[k] for k in sorted(categories)},
        "directories": {k: directories[k] for k in sorted(directories)},
        "history_large_blobs": history_objects() if args.history else "not_requested",
    }
    out = args.out if args.out.is_absolute() else ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    md = out.with_suffix(".md")
    lines = ["# 大型产物审计", "", "范围：当前工作树中 Git 已跟踪文件。Git 历史对象仅在使用 `--history` 时扫描本地 refs；不代表远端完整历史。", "", f"总计：{len(rows)} 个文件，{human(sum(r['bytes'] for r in rows))}", "", "## 按类别", "", "| 类别 | 文件数 | 大小 |", "| --- | ---: | ---: |"]
    for key in sorted(categories):
        value = categories[key]
        lines.append(f"| `{key}` | {value['files']} | {human(value['bytes'])} |")
    lines += ["", "## 按顶层目录", "", "| 目录 | 文件数 | 大小 |", "| --- | ---: | ---: |"]
    for key in sorted(directories):
        value = directories[key]
        lines.append(f"| `{key}` | {value['files']} | {human(value['bytes'])} |")
    if isinstance(payload["history_large_blobs"], list):
        lines += ["", "## 本地 refs 中的大型历史 blob（≥1 MiB）", "", "| 大小 | 对象 | 路径 |", "| ---: | --- | --- |"]
        for row in payload["history_large_blobs"][:50]:
            lines.append(f"| {human(row['bytes'])} | `{row['oid']}` | `{row['path']}` |")
    md.write_text("\n".join(lines) + "\n")
    print(f"wrote {out.relative_to(ROOT)} and {md.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
