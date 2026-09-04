from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tarfile
import zipfile

try:
    from .archive_limits import archive_magic
    from .release_archive_reader import (
        ArchiveMember,
        read_archive,
        read_member_stream,
        safe_member_name,
        sha256_bytes,
    )
    from .release_package_contracts import (
        COMMIT,
        REPOSITORY_PAYLOAD,
        SCHEMA_PAYLOAD,
        SEMVER,
        SHA256,
    )
    from .safe_output_root import lexical_absolute, verify_directory_chain
    from .strict_json import strict_loads
except ImportError:  # Direct module execution.
    from archive_limits import archive_magic
    from release_archive_reader import (
        ArchiveMember,
        read_archive,
        read_member_stream,
        safe_member_name,
        sha256_bytes,
    )
    from release_package_contracts import (
        COMMIT,
        REPOSITORY_PAYLOAD,
        SCHEMA_PAYLOAD,
        SEMVER,
        SHA256,
    )
    from safe_output_root import lexical_absolute, verify_directory_chain
    from strict_json import strict_loads

def committed_file(repo: Path, source_commit: str, relative: str) -> bytes:
    tree = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "-z", source_commit, "--", relative],
        capture_output=True, check=False,
    )
    entry = tree.stdout.rstrip(b"\0")
    if tree.returncode != 0 or not entry or b"\0" in entry:
        raise ValueError(f"release source commit omits package payload: {relative}")
    metadata, separator, name = entry.partition(b"\t")
    fields = metadata.split()
    if separator != b"\t" or name.decode("utf-8", "strict") != relative or \
            len(fields) != 3 or fields[0] not in (b"100644", b"100755") or fields[1] != b"blob":
        raise ValueError(f"release source payload is not a regular committed file: {relative}")
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{source_commit}:{relative}"],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"cannot read release source payload: {relative}")
    return result.stdout


def verify_repository_payload(members: dict[str, ArchiveMember], repo: Path,
                              source_commit: str) -> None:
    repo = lexical_absolute(repo)
    try:
        verify_directory_chain(repo)
    except ValueError as error:
        raise ValueError("release repository must be a canonical regular directory") from error
    if not repo.is_dir():
        raise ValueError("release repository must be a canonical regular directory")
    for archive_name, repository_name in REPOSITORY_PAYLOAD.items():
        member = members.get(archive_name)
        if member is None:
            raise ValueError(f"release package omits repository payload: {archive_name}")
        expected = committed_file(repo, source_commit, repository_name)
        if member.size != len(expected) or member.sha256 != sha256_bytes(expected):
            raise ValueError(
                f"release package payload does not match source commit: {archive_name}"
            )


def inspect_archive(path: Path, platform_name: str, version: str,
                    sdk_version: str, sdk_sha256: str,
                    source_commit: str) -> tuple[dict[str, object], dict[str, ArchiveMember], str]:
    path = lexical_absolute(path)
    if not SEMVER.fullmatch(version):
        raise ValueError("release package version must be a stable three-part SemVer")
    if not SHA256.fullmatch(sdk_sha256):
        raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
    if not COMMIT.fullmatch(source_commit):
        raise ValueError("source commit must be lowercase 40-hex")
    extension = ".zip" if platform_name.startswith("windows-") else ".tar.gz"
    expected_archive = f"cjdoc-{version}-{platform_name}{extension}"
    if path.name != expected_archive:
        raise ValueError(f"release archive name must be {expected_archive}")
    expected_format = "zip" if platform_name.startswith("windows-") else "gzip-tar"
    members = read_archive(path, expected_format=expected_format)
    if not members:
        raise ValueError("release archive is empty")
    expected_root = f"cjdoc-{version}"
    roots = {PurePosixPath(name).parts[0] for name in members}
    if roots != {expected_root}:
        raise ValueError(f"release archive root mismatch: {sorted(roots)}")
    relative_members = {
        PurePosixPath(name).relative_to(expected_root).as_posix(): member
        for name, member in members.items()
    }
    manifest_member = relative_members.get("release-manifest.json")
    if manifest_member is None:
        raise ValueError("release archive omits release-manifest.json")
    if manifest_member.content is None:
        raise ValueError("release manifest was not captured during bounded inspection")
    try:
        manifest = strict_loads(
            manifest_member.content, description="release manifest"
        )
    except ValueError as error:
        raise ValueError(f"release manifest is invalid: {error}") from error
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion", "version", "platform", "sourceCommit", "runtime", "files"
    } or manifest.get("schemaVersion") != "cjdoc.release-package/2":
        raise ValueError("unknown release package manifest schema")
    if manifest.get("version") != version or manifest.get("platform") != platform_name:
        raise ValueError("release package identity does not match its declared target")
    if manifest.get("sourceCommit") != source_commit:
        raise ValueError("release package source commit does not match")
    runtime = manifest.get("runtime")
    if not isinstance(runtime, dict) or set(runtime) != {
        "requiresCangjieSdk", "sdkVersion", "sdkArchiveSha256"
    } or runtime.get("requiresCangjieSdk") is not True or \
            runtime.get("sdkVersion") != sdk_version or runtime.get("sdkArchiveSha256") != sdk_sha256:
        raise ValueError("release package SDK requirement does not match")
    files = manifest.get("files")
    if not isinstance(files, dict):
        raise ValueError("release package manifest files must be an object")
    actual_payload = set(relative_members) - {"release-manifest.json"}
    if set(files) != actual_payload:
        raise ValueError(
            "release package member set mismatch: missing=" +
            ",".join(sorted(set(files) - actual_payload)) +
            " unexpected=" + ",".join(sorted(actual_payload - set(files)))
        )
    for name, metadata in files.items():
        if not isinstance(metadata, dict) or set(metadata) != {"sha256", "size"} or \
                not isinstance(metadata.get("sha256"), str) or \
                not SHA256.fullmatch(metadata["sha256"]) or \
                type(metadata.get("size")) is not int or metadata["size"] < 0:
            raise ValueError(f"invalid release manifest metadata: {name}")
        member = relative_members[name]
        if metadata.get("size") != member.size or \
                metadata.get("sha256") != member.sha256:
            raise ValueError(f"release package payload hash/size mismatch: {name}")
    executable_name = "cjdoc.exe" if platform_name.startswith("windows-") else "cjdoc"
    expected_payload = {
        executable_name,
        "README.md",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "licenses/markdown-MIT.txt",
        "licenses/yjson-Apache-2.0.txt",
    } | SCHEMA_PAYLOAD
    if actual_payload != expected_payload:
        raise ValueError(
            "release package payload set mismatch: missing=" +
            ",".join(sorted(expected_payload - actual_payload)) +
            " unexpected=" + ",".join(sorted(actual_payload - expected_payload))
        )
    expected_modes = {
        name: (0o755 if name == executable_name else 0o644)
        for name in relative_members
    }
    for name, member in relative_members.items():
        expected_mode = expected_modes[name]
        if member.mode != expected_mode:
            raise ValueError(
                f"release package member mode mismatch: {name} "
                f"must be {expected_mode:04o}, got {member.mode:04o}"
            )
    return manifest, relative_members, executable_name


def prepare_extraction_target(root: Path, relative: str) -> Path:
    """Create private parent directories and return a new regular-file path."""
    parts = safe_member_name(relative).parts
    current = root
    for part in parts[:-1]:
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            current.mkdir(mode=0o700)
            metadata = current.lstat()
        if current.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"release extraction path is not a safe directory: {relative}")
    target = current / parts[-1]
    try:
        target.lstat()
    except FileNotFoundError:
        return target
    raise ValueError(f"release extraction target already exists: {relative}")


def write_extracted_member(root: Path, relative: str, member: ArchiveMember,
                           stream) -> None:
    target = prepare_extraction_target(root, relative)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(target, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            digest, _ = read_member_stream(
                stream, name=member.name, expected_size=member.size, output=output
            )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if digest != member.sha256:
        target.unlink(missing_ok=True)
        raise ValueError(f"release archive member changed during extraction: {relative}")
    target.chmod(member.mode)


def extract_members(path: Path, expected_format: str, destination: Path,
                    root_name: str, members: dict[str, ArchiveMember]) -> Path:
    """Reopen and stream verified members into a private smoke-test directory."""
    root = destination / root_name
    root.mkdir(mode=0o700)
    expected = {f"{root_name}/{relative}": (relative, member)
                for relative, member in members.items()}
    observed: set[str] = set()
    actual_format = archive_magic(path)
    if actual_format != expected_format:
        raise ValueError("release archive format changed before extraction")
    if actual_format == "zip":
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                normalized = safe_member_name(info.filename).as_posix()
                if normalized not in expected or normalized in observed:
                    raise ValueError("release archive members changed before extraction")
                relative, member = expected[normalized]
                mode = ((info.external_attr >> 16) & 0xFFFF) & 0o7777
                if info.file_size != member.size or mode != member.mode:
                    raise ValueError(f"release archive metadata changed before extraction: {relative}")
                with archive.open(info, "r") as stream:
                    write_extracted_member(root, relative, member, stream)
                observed.add(normalized)
    elif actual_format in ("tar", "gzip-tar"):
        mode = "r:gz" if actual_format == "gzip-tar" else "r:"
        with tarfile.open(path, mode=mode) as archive:
            for info in archive:
                normalized = safe_member_name(info.name).as_posix()
                if normalized not in expected or normalized in observed or not info.isfile():
                    raise ValueError("release archive members changed before extraction")
                relative, member = expected[normalized]
                if info.size != member.size or (info.mode & 0o7777) != member.mode:
                    raise ValueError(f"release archive metadata changed before extraction: {relative}")
                stream = archive.extractfile(info)
                if stream is None:
                    raise ValueError(f"release archive member cannot be read: {relative}")
                with stream:
                    write_extracted_member(root, relative, member, stream)
                observed.add(normalized)
    else:
        raise ValueError("unsupported release archive format during extraction")
    if observed != set(expected):
        raise ValueError("release archive members changed before extraction")
    return root


def _inside(root: Path, candidate: Path) -> bool:
    try:
        return os.path.commonpath((str(root), str(candidate))) == str(root)
    except ValueError:
        return False


