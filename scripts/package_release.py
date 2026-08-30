#!/usr/bin/env python3
"""Create byte-reproducible cjdoc release archives with an internal manifest."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import tomllib
import zipfile


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def resolve_binary(value: Path) -> Path:
    candidate = value.resolve()
    if candidate.is_file():
        return candidate
    executable = Path(f"{candidate}.exe")
    if executable.is_file():
        return executable
    raise ValueError(f"cjdoc binary does not exist: {candidate}")


def verify_binary_version(binary: Path, version: str) -> None:
    result = subprocess.run([str(binary), "--version"], text=True, capture_output=True, check=False)
    if result.returncode != 0 or result.stdout.strip() != f"cjdoc {version}":
        raise ValueError("binary --version does not match cjpm.toml")


def collect_payload(repo: Path, binary: Path, windows: bool, version: str) -> dict[str, tuple[bytes, int]]:
    executable_name = "cjdoc.exe" if windows else "cjdoc"
    payload: dict[str, tuple[bytes, int]] = {
        executable_name: (binary.read_bytes(), 0o755),
        "README.md": ((repo / "README.md").read_bytes(), 0o644),
        "LICENSE": ((repo / "LICENSE").read_bytes(), 0o644),
    }
    schema_root = repo / "docs/schema"
    schemas = sorted(schema_root.glob("*.json"))
    if not schemas:
        raise ValueError("no JSON schemas found")
    for schema in schemas:
        payload[f"docs/schema/{schema.name}"] = (schema.read_bytes(), 0o644)
    manifest = {
        "schemaVersion": "cjdoc.release-package/1",
        "version": version,
        "files": {
            name: {"sha256": sha256_bytes(content), "size": len(content)}
            for name, (content, _) in sorted(payload.items())
        },
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    payload["release-manifest.json"] = (manifest_bytes, 0o644)
    return payload


def write_zip(path: Path, root_name: str, payload: dict[str, tuple[bytes, int]]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, (content, mode) in sorted(payload.items()):
            info = zipfile.ZipInfo(f"{root_name}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (mode & 0xFFFF) << 16
            archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def write_tar_gz(path: Path, root_name: str, payload: dict[str, tuple[bytes, int]]) -> None:
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, (content, mode) in sorted(payload.items()):
                    info = tarfile.TarInfo(f"{root_name}/{name}")
                    info.size = len(content)
                    info.mode = mode
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    archive.addfile(info, io.BytesIO(content))


def build_archive(repo: Path, binary: Path, platform_name: str, output: Path) -> Path:
    manifest = tomllib.loads((repo / "cjpm.toml").read_text(encoding="utf-8"))
    version = manifest.get("package", {}).get("version")
    if not isinstance(version, str) or not version:
        raise ValueError("cjpm.toml package version is missing")
    windows = platform_name.startswith("windows-")
    extension = ".zip" if windows else ".tar.gz"
    output.mkdir(parents=True, exist_ok=True)
    asset = output / f"cjdoc-{version}-{platform_name}{extension}"
    root_name = f"cjdoc-{version}"
    payload = collect_payload(repo, binary, windows, version)
    with tempfile.NamedTemporaryFile(dir=output, prefix=f".{asset.name}.", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        if windows:
            write_zip(temporary, root_name, payload)
        else:
            write_tar_gz(temporary, root_name, payload)
        temporary.replace(asset)
    finally:
        temporary.unlink(missing_ok=True)
    checksum = asset.with_name(f"{asset.name}.sha256")
    checksum.write_text(f"{sha256_file(asset)}  {asset.name}\n", encoding="ascii", newline="\n")
    return asset


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=repo / "target/release/bin/main")
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--output", type=Path, default=repo / "target/release-package")
    args = parser.parse_args()
    try:
        binary = resolve_binary(args.binary)
        manifest = tomllib.loads((repo / "cjpm.toml").read_text(encoding="utf-8"))
        version = manifest.get("package", {}).get("version")
        if not isinstance(version, str):
            raise ValueError("cjpm.toml package version is missing")
        verify_binary_version(binary, version)
        asset = build_archive(repo, binary, args.platform, args.output.resolve())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        parser.error(str(error))
    print(json.dumps({
        "asset": str(asset),
        "sha256": sha256_file(asset),
        "checksum": str(asset.with_name(f"{asset.name}.sha256")),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
