"""Source provenance and deterministic downloads for the real showcase build."""
from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import stat
import subprocess
import zipfile

from showcase_contract.site import ContractError, canonical_json, relative_path
from showcase_inputs import source_inputs


def tool_version(command: list[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, check=True, capture_output=True, text=True)
    version = (result.stdout + result.stderr).strip()
    if not version:
        raise ContractError("tool returned an empty version: " + command[0])
    return version


def checked_input(source: Path, name: str) -> Path:
    path = source / relative_path(name)
    for item in (path, *path.parents):
        if item == source:
            break
        if item.is_symlink():
            raise ContractError("symlink in maintained example source: " + name)
    if not path.is_file():
        raise ContractError("missing maintained example source: " + name)
    return path


def maintained_examples() -> list[str]:
    return [name for name in source_inputs() if name.startswith("examples/pocketkit/")]


def copy_sources(repo: Path, source: Path) -> None:
    """Do not follow links or include untracked logs/secrets from the worktree."""
    for name in maintained_examples():
        path = checked_input(repo, name)
        destination = source / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)


def source_files(source: Path) -> dict[str, Path]:
    """Only maintained inputs and generated, fixed dependency indices belong here."""
    names = maintained_examples()
    names += [f"examples/pocketkit/{version}/docs/support-symbol-index.json" for version in ("demo-v1", "demo-v2")]
    return {name: checked_input(source, name) for name in sorted(names)}


def source_archive(source: Path, site: Path, provenance: dict) -> dict:
    files = source_files(source)
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}
    metadata = {"schemaVersion": "cjdoc.showcase-source/1", **provenance,
                "license": "MIT", "files": hashes,
                "reproduce": "python3 examples/pocketkit/reproduce.py --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both"}
    downloads = site / "downloads"
    downloads.mkdir(exist_ok=True)
    (downloads / "source-manifest.json").write_bytes(canonical_json(metadata))
    payloads = {name: path.read_bytes() for name, path in files.items()}
    payloads["source.json"] = canonical_json(metadata)
    destination = downloads / "pocketkit-source.zip"
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payloads.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    return {"path": "downloads/pocketkit-source.zip",
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            "manifest": "downloads/source-manifest.json", "files": len(payloads)}
