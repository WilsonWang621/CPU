#!/usr/bin/env python3
"""Create and verify a deterministic large-output experiment archive."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tarfile
import tempfile
from pathlib import Path


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def entries(root: Path):
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"symlink is not allowed: {path}")
        if path.is_file():
            result.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": sha(path)})
    return result


def safe_extract(archive: Path, destination: Path):
    with tarfile.open(archive, "r:gz") as stream:
        for member in stream.getmembers():
            target = (destination / member.name).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise ValueError(f"unsafe archive member: {member.name}")
        stream.extractall(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    source = args.input_dir.resolve()
    output = args.output_dir.resolve()
    if not source.is_dir():
        raise SystemExit(f"input directory does not exist: {source}")
    output.mkdir(parents=True, exist_ok=True)
    files = entries(source)
    manifest = {"schema_version": 1, "experiment_id": args.experiment_id, "root": str(args.input_dir), "files": files}
    archive = output / f"{args.experiment_id}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="pararisc-archive-") as temp:
        staging = Path(temp) / "payload"
        shutil.copytree(source, staging)
        (staging / "ARCHIVE-MANIFEST.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        with archive.open("wb") as raw:
            import gzip
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as tar:
                    for path in sorted(staging.rglob("*")):
                        info = tar.gettarinfo(path, arcname=str(path.relative_to(staging)))
                        info.mtime = 0; info.uid = 0; info.gid = 0; info.uname = ""; info.gname = ""
                        if path.is_file():
                            with path.open("rb") as stream:
                                tar.addfile(info, stream)
                        else:
                            tar.addfile(info)
    manifest["archive_sha256"] = sha(archive)
    manifest_path = output / f"{args.experiment_id}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    with tempfile.TemporaryDirectory(prefix="pararisc-restore-") as temp:
        restored = Path(temp)
        safe_extract(archive, restored)
        for item in files:
            restored_file = restored / item["path"]
            if not restored_file.is_file() or restored_file.stat().st_size != item["bytes"] or sha(restored_file) != item["sha256"]:
                raise SystemExit(f"restore verification failed: {item['path']}")
    print(f"archive={archive} sha256={manifest['archive_sha256']} files={len(files)} restore=verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
