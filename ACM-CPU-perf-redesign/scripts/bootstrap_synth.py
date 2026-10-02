#!/usr/bin/env python3
"""Install pinned Linux x86-64 synthesis tools under build/tools, without sudo."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from bootstrap_modern_synth import install as install_modern

ROOT = Path(__file__).resolve().parents[1]


def download(record, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
        temporary = path.with_suffix(path.suffix + ".download")
        print(f"Downloading {record['url']}", flush=True)
        urllib.request.urlretrieve(record["url"], temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != record["sha256"]:
            temporary.unlink()
            raise RuntimeError(f"Checksum mismatch for {path.name}")
        temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, default=ROOT / "build/tools")
    args = parser.parse_args()
    directory = args.tools_dir.resolve()
    lock = json.loads((ROOT / "scripts/synthesis.lock.json").read_text())
    install_modern(directory)
    packages = []
    for package in lock["ubuntu_packages"]:
        path = directory / "packages" / package["file"]
        download(package, path)
        packages.append(path)
    support = directory / "synth-support"
    stamp = support / ".verified-packages.json"
    if not stamp.exists() or json.loads(stamp.read_text()) != lock["ubuntu_packages"]:
        if support.exists():
            raise RuntimeError("Existing unverified/different support tools; select a new --tools-dir")
        with tempfile.TemporaryDirectory(prefix=".synth-support-", dir=directory) as staging:
            staged = Path(staging) / "tools"
            for path in packages:
                subprocess.run(["dpkg-deb", "-x", str(path), str(staged)], check=True)
            (staged / ".verified-packages.json").write_text(json.dumps(lock["ubuntu_packages"], indent=2) + "\n")
            staged.rename(support)
    archive = directory / "sv2v-Linux.zip"
    download(lock["sv2v"], archive)
    if not (directory / "sv2v-Linux/sv2v").is_file():
        with zipfile.ZipFile(archive) as zip_file:
            zip_file.extractall(directory)
    (directory / "sv2v-Linux/sv2v").chmod(0o755)
    libs = directory / "asap7-libs"
    upstream = lock["asap7"]
    for library in upstream["files"]:
        record = dict(library, url=("https://raw.githubusercontent.com/The-OpenROAD-Project/"
                                   f"asap7sc7p5t_28/{upstream['commit']}/LIB/NLDM/{library['file']}"))
        path = libs / library["file"]
        download(record, path)
        subprocess.run([str(support / "usr/lib/7zip/7z"), "x", "-y", f"-o{libs}", str(path)],
                       check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["python3", str(ROOT / "scripts/merge_liberty.py"), str(libs)], check=True)
    print(f"Pinned tools and ASAP7 RVT TT libraries ready in {directory}")


if __name__ == "__main__":
    main()
