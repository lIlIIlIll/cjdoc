"""Deterministic offline payloads and safe, byte-checked extraction for tests.

The download lives at downloads/showcase-offline.zip and excludes only itself
from its contents. All other published files (including other downloads and
reports) are required. A stale/incomplete archive cannot supply file:// evidence.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys
import tempfile
import zipfile

from .site import ContractError, Site, canonical_json, relative_path

ARCHIVE = "downloads/showcase-offline.zip"
MAX_UNCOMPRESSED_BYTES = 512 * 1024 * 1024


def payload_inventory(site: Site) -> dict[str, str]:
    return {name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in sorted(site.files.items()) if name != ARCHIVE}


def payload_digest(site: Site) -> str:
    return hashlib.sha256(canonical_json(payload_inventory(site))).hexdigest()


def create_archive(root: Path) -> Path:
    site = Site(root)
    destination = site.root / ARCHIVE
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.exists() and not destination.is_file():
        raise ContractError("offline destination must be a regular file")
    fd, temporary = tempfile.mkstemp(prefix="cjdoc-offline-", suffix=".zip", dir=site.root.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, path in sorted(site.files.items()):
                if name == ARCHIVE:
                    continue
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return destination


# macOS exposes `/var` and `/tmp` as system aliases of `/private/...`, so every
# `tempfile` location contains a symlink component. These are documented system
# aliases, not attacker-controlled links, so they are normalized away before the
# symlink check. Kept in step with `scripts/safe_output_root.py`.
_DARWIN_SYSTEM_ALIASES = {
    Path("/var"): Path("/private/var"),
    Path("/tmp"): Path("/private/tmp"),
}


def _normalized_destination(destination: Path) -> Path:
    """Return an absolute destination with darwin system aliases normalized."""
    candidate = Path(os.path.abspath(os.fspath(destination)))
    if sys.platform == "darwin":
        for alias, canonical in _DARWIN_SYSTEM_ALIASES.items():
            try:
                relative = candidate.relative_to(alias)
            except ValueError:
                continue
            try:
                if alias.is_symlink() and alias.resolve(strict=True) == canonical:
                    return canonical / relative
            except OSError:
                pass
    return candidate


def extract_archive(archive_path: Path, destination: Path, expected: Site) -> Site:
    """Extract to a new directory; reject extras, missing files and unsafe paths.

    The expected tree is inventoried before extraction. The extraction directory
    cannot be inside the final site and is never reused between runs. The caller
    owns the containing TemporaryDirectory and cleans up partial extractions.
    """
    if destination.exists() or destination.is_symlink():
        raise ContractError("offline extraction requires a fresh directory")
    # A symlink component would make the extraction path untrustworthy, but the
    # macOS system aliases above are legitimate, so normalize those first.
    destination = _normalized_destination(destination)
    if any(parent.is_symlink() for parent in destination.parents):
        raise ContractError("symlink in offline extraction destination")
    resolved = destination.resolve()
    if resolved.is_relative_to(expected.root) or expected.root.is_relative_to(resolved):
        raise ContractError("offline extraction and published site must be separate")
    if archive_path.is_symlink() or not archive_path.is_file():
        raise ContractError("offline archive must be a regular file")
    inventory = payload_inventory(expected)
    try:
        with zipfile.ZipFile(archive_path) as archive:
            members = archive.infolist()
            names = []
            total_size = 0
            for item in members:
                name = relative_path(item.filename)
                mode = item.external_attr >> 16
                if item.is_dir() or item.flag_bits & 1 or stat.S_ISLNK(mode):
                    raise ContractError("offline archive contains a directory, symlink or encrypted file")
                if stat.S_IFMT(mode) not in (0, stat.S_IFREG):
                    raise ContractError("offline archive contains a special file")
                names.append(name)
                total_size += item.file_size
            if total_size > MAX_UNCOMPRESSED_BYTES:
                raise ContractError("offline archive exceeds the extraction budget")
            if len(names) != len(set(names)) or len(names) != len({n.casefold() for n in names}):
                raise ContractError("offline archive has duplicate or case-colliding paths")
            if set(names) != inventory.keys():
                raise ContractError("offline archive inventory differs from the final site payload")
            destination.mkdir(parents=True)
            for item in members:
                data = archive.read(item)
                if hashlib.sha256(data).hexdigest() != inventory[item.filename]:
                    raise ContractError(f"offline bytes differ from the final site: {item.filename}")
                target = destination / item.filename
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise ContractError(f"invalid offline archive: {error}") from error
    return Site(destination)
