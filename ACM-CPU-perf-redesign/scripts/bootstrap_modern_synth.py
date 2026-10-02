#!/usr/bin/env python3
"""Install the pinned official OSS CAD Suite under build/tools, without sudo."""
import argparse
import hashlib
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def install(directory):
    lock = json.loads((ROOT / "scripts/modern_synthesis.lock.json").read_text())
    directory = directory.resolve()
    packages = directory / "packages"
    packages.mkdir(parents=True, exist_ok=True)
    archive = packages / lock["archive"]
    if not archive.exists():
        temporary = archive.with_suffix(archive.suffix + ".partial")
        subprocess.run(["curl", "-fL", "--retry", "2", "--max-time", "900", lock["url"],
                        "-o", str(temporary)], check=True)
        temporary.replace(archive)
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != lock["sha256"] or archive.stat().st_size != lock["size_bytes"]:
        raise RuntimeError(f"Archive does not match the pinned publisher digest: {archive}")
    stamp = directory / "oss-cad-suite/.verified-release.json"
    if not stamp.exists() or json.loads(stamp.read_text()) != lock:
        # Never truncate binaries/libraries that an existing process may have
        # mapped. A distinct tools directory is required for replacing a build.
        destination = directory / "oss-cad-suite"
        if destination.exists():
            raise RuntimeError("Existing unverified/different OSS CAD installation; select a new --tools-dir")
        with tempfile.TemporaryDirectory(prefix=".oss-cad-extract-", dir=directory) as staging:
            with tarfile.open(archive, "r|gz") as contents:
                for entry in contents:
                    if entry.name != "oss-cad-suite" and not entry.name.startswith("oss-cad-suite/"):
                        raise RuntimeError(f"Unexpected archive path: {entry.name}")
                    contents.extract(entry, staging, filter="data")
            staged = Path(staging) / "oss-cad-suite"
            (staged / ".verified-release.json").write_text(json.dumps(lock, indent=2) + "\n")
            staged.rename(destination)
    yosys = directory / "oss-cad-suite/bin/yosys"
    version = subprocess.check_output([str(yosys), "-V"], text=True).strip()
    if version != lock["yosys_version"]:
        raise RuntimeError(f"Unexpected extracted Yosys version: {version}")
    print(f"Verified {version}\nInstalled under {yosys.parent.parent}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, default=ROOT / "build/tools")
    args = parser.parse_args()
    install(args.tools_dir)


if __name__ == "__main__":
    main()
