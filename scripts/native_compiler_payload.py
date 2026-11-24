"""Stream verified capture files and publish only privacy-audited compiler payloads."""

from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
from pathlib import Path

OPT_BINARY = "third_party/llvm/bin/opt.exe"
# A privacy/upload bound, not a performance budget: one failing module is far
# below it, and a larger file is withheld rather than published.
PAYLOAD_LIMIT = 128 * 1024 * 1024
LLVM_TEXT_LIMIT = 64 * 1024 * 1024
AUDIT_TIMEOUT_SECONDS = 300
DETAIL = re.compile(r"^[A-Za-z0-9_.-]{1,64}(?:/[A-Za-z0-9_.-]{1,64}){0,7}\Z")
_MODULE_ID = "; ModuleID = "

# Fixed hazard labels: the audit reports which class was found, never the token.
# The list is a set of *identifying token shapes*, not a claim that the bitcode is
# anonymous: a human name inside a source string would survive it.
_HAZARDS = (
    ("windows-absolute-path", re.compile(r"(?<![A-Za-z])[A-Za-z]:[\\/]")),
    ("unc-or-device-path", re.compile(r"\\\\[^\\\s]{1,64}[\\/]")),
    ("home-directory-path", re.compile(
        r"[\\/](?:Users|home|root|people)[\\/]", re.IGNORECASE)),
    ("scratch-directory-path", re.compile(
        r"[\\/](?:tmp|var|mnt|workspace|builds|_temp|AppData)[\\/]", re.IGNORECASE)),
    ("cjdoc-scratch-name", re.compile(r"cjdoc-native-compiler-|cangjie-tmp-")),
    ("private-address", re.compile(
        r"(?<![\d.])(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
        r"|127\.\d{1,3}\.\d{1,3}\.\d{1,3}"
        r"|169\.254\.\d{1,3}\.\d{1,3}"
        r"|192\.168\.\d{1,3}\.\d{1,3}"
        r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?![\d.])")),
    ("credential-token", re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}"
        r"|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{20,}"
        r"|-----BEGIN [A-Z ]*PRIVATE KEY-----)")),
    ("email-address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
)
# LLVM text writes a Windows separator as `\\`, so a path's separators appear
# doubled. Halving each run restores the shape the hazard patterns describe
# without changing whether a token is absolute.
_ESCAPED_SEPARATOR = re.compile(r"\\{2,}")

# A GitHub-hosted runner's own layout is public convention, not this machine's
# identity: the account there belongs to the runner image, not the operator. These
# roots are masked before the hazard scan and counted, never quoted.
_CI_ROOTS = (
    # `D:/a/_temp` is deliberately NOT masked: a temp root inside embedded
    # metadata identifies the machine that produced it, even on a runner.
    (re.compile(r"[A-Za-z]:[\\/]{1,2}a[\\/]{1,2}(?!_temp\b)[A-Za-z0-9_.-]{1,100}",
                re.IGNORECASE), "<github-ci>"),
    (re.compile(r"[A-Za-z]:[\\/]{1,2}Users[\\/]{1,2}runner(?:admin)?\b", re.IGNORECASE),
     "<github-runner>"),
    # The runner image also answers to its 8.3 short name in compiler temp paths.
    (re.compile(r"[A-Za-z]:[\\/]{1,2}Users[\\/]{1,2}RUNNER~\d", re.IGNORECASE),
     "<github-runner>"),
    (re.compile(r"[\\/]{1,2}home[\\/]{1,2}runner\b", re.IGNORECASE), "<github-runner>"),
    (re.compile(r"[\\/]{1,2}Users[\\/]{1,2}runner(?:admin)?\b", re.IGNORECASE),
     "<github-runner>"),
    (re.compile(r"cangjie-tmp-[A-Za-z0-9]{1,32}"), "<compiler-temp>"),
)


class _Unavailable(Exception):
    """An expected capture problem, reported as a fixed reason code."""

    def __init__(self, reason: str, detail: str = "") -> None:
        self.reason = reason
        self.detail = detail
        super().__init__(reason)


def _safe_detail(value: str) -> str | None:
    return value if DETAIL.match(value) else None


def _open_regular(path: Path, limit: int, reason: str, detail: str = "",
                  oversize_reason: str | None = None):
    """Open a regular file without following a symlink, or raise `_Unavailable`."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise _Unavailable(reason, detail)
        descriptor = os.open(path, flags)
    except OSError:
        raise _Unavailable(reason, detail) from None
    handle = os.fdopen(descriptor, "rb")
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or (
            before.st_dev, before.st_ino, before.st_size) != (
            info.st_dev, info.st_ino, info.st_size):
        handle.close()
        raise _Unavailable(reason, detail)
    if info.st_size > limit:
        handle.close()
        raise _Unavailable(oversize_reason or reason, detail)
    return handle, info, before


def _copy_verified(source: Path, sink, limit: int, detail: str) -> dict:
    """Stream one file into `sink` (or nowhere) and digest exactly the bytes read.

    The source is opened once, and the name must still resolve to that same inode
    afterwards: the digest describes one observed snapshot, not a re-read.
    """
    handle, info, before = _open_regular(source, limit, "payload-unreadable", detail,
                                         "payload-oversize")
    digest = hashlib.sha256()
    total = 0
    try:
        while block := handle.read(1024 * 1024):
            total += len(block)
            if total > limit:
                raise _Unavailable("payload-oversize", detail)
            digest.update(block)
            if sink is not None:
                sink.write(block)
        try:
            after = source.stat(follow_symlinks=False)
            after_descriptor = os.fstat(handle.fileno())
        except OSError:
            raise _Unavailable("unstable-file", detail) from None
    except OSError:
        raise _Unavailable("payload-unreadable", detail) from None
    finally:
        handle.close()
    # Windows can give path and descriptor timestamps different semantics.
    # Compare each API with itself; retain both identity and timestamp guards.
    if total != info.st_size or not stat.S_ISREG(after.st_mode) or (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
            before.st_dev, before.st_ino, before.st_size,
            before.st_mtime_ns, before.st_ctime_ns) or (
            after_descriptor.st_dev, after_descriptor.st_ino, after_descriptor.st_size,
            after_descriptor.st_mtime_ns, after_descriptor.st_ctime_ns) != (
            info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns):
        raise _Unavailable("unstable-file", detail)
    return {"sha256": digest.hexdigest(), "size": total}


def _mask_ci_roots(text: str) -> tuple[str, int]:
    """Blank convention-only CI roots and report how many were seen."""
    occurrences = 0
    for pattern, label in _CI_ROOTS:
        text, count = pattern.subn(label, text)
        occurrences += count
    return text, occurrences


def _scan_llvm_text(path: Path, detail: str, mask_ci: bool) -> tuple[list[str], int, int, bool]:
    """Stream one rendered module and report hazard labels, not its contents.

    Classification runs on a view where doubled separators are single ones, so an
    escaped Windows path is judged by the same rules as a raw one. Nothing derived
    from that view is published.
    """
    handle, _info, _before = _open_regular(path, LLVM_TEXT_LIMIT, "privacy-audit-unreadable",
                                          detail, "privacy-audit-overlimit")
    labels: list[str] = []
    occurrences = 0
    seen = 0
    module_id = False
    try:
        for raw in handle:
            seen += len(raw)
            if seen > LLVM_TEXT_LIMIT:
                raise _Unavailable("privacy-audit-overlimit", detail)
            line = raw.decode("utf-8", "replace")
            if line.startswith(_MODULE_ID):
                # `opt -S` names its own input file here; that comment describes
                # the audit command, not anything the module stores.
                module_id = True
                continue
            if mask_ci:
                line, count = _mask_ci_roots(line)
                occurrences += count
            plain = _ESCAPED_SEPARATOR.sub(r"\\", line)
            for label, pattern in _HAZARDS:
                if label not in labels and pattern.search(plain):
                    labels.append(label)
    except OSError:
        raise _Unavailable("privacy-audit-unreadable", detail) from None
    finally:
        handle.close()
    return labels, occurrences, seen, module_id


def _retain_audited_payload(root: Path, sdk_root: Path, evidence_dir: Path,
                            prefix: str, module: str, source: Path, *, mask_ci: bool) -> dict:
    """Audit the module in private and publish the exact bytes if it is safe."""
    detail = f"{module}.opt.bc"
    audit_dir = root / "audit"
    try:
        audit_dir.mkdir(exist_ok=True)
        with (audit_dir / detail).open("xb") as sink:
            observed = _copy_verified(source, sink, PAYLOAD_LIMIT, detail)
    except OSError:
        raise _Unavailable("payload-unreadable", detail) from None
    text_file = audit_dir / f"{module}.ll"
    try:
        completed = subprocess.run(
            [str(sdk_root / OPT_BINARY), "-S", "-o", str(text_file),
             str(audit_dir / detail)],
            cwd=str(audit_dir), stdin=subprocess.DEVNULL, capture_output=True,
            check=False, timeout=AUDIT_TIMEOUT_SECONDS)
        if completed.returncode != 0:
            raise _Unavailable("privacy-audit-unavailable", detail)
        labels, occurrences, seen, module_id = _scan_llvm_text(
            text_file, detail, mask_ci)
    except (OSError, subprocess.TimeoutExpired):
        raise _Unavailable("privacy-audit-unavailable", detail) from None
    finally:
        # The rendered text is a private working file; only labels leave.
        text_file.unlink(missing_ok=True)
    if labels:
        raise _Unavailable("privacy-audit-rejected", labels[0])
    relative_dir = f"{prefix}.native-compiler"
    directory = evidence_dir / relative_dir
    target = directory / detail
    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL
             | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0))
    try:
        directory.mkdir(exist_ok=False)
        descriptor = os.open(target, flags, 0o600)
    except FileExistsError:
        # Nothing this run created may be removed or replaced.
        raise _Unavailable("evidence-exists", detail) from None
    except OSError:
        raise _Unavailable("evidence-write-failed", detail) from None
    try:
        with os.fdopen(descriptor, "wb") as sink:
            written = _copy_verified(audit_dir / detail, sink, PAYLOAD_LIMIT, detail)
        if written != observed:
            raise _Unavailable("payload-unstable", detail)
    except BaseException:
        # Only the file this call created is removed.
        target.unlink(missing_ok=True)
        try:
            directory.rmdir()
        except OSError:
            pass
        raise
    return {
        "file": f"{relative_dir}/{detail}",
        "sha256": observed["sha256"],
        "size": observed["size"],
        "module": module,
        # The published file is the compiler's exact output.
        "rewritten": False,
        "audit": {
            "scope": "llvm-ir-text",
            "tool": "opt -S",
            "verdict": "no-identifying-tokens",
            "llvmTextBytes": seen,
            "moduleIdExcluded": module_id,
            # Counts only: a permitted CI root is described, never quoted.
            "ciRootOccurrences": occurrences,
            "ciRoots": ["<github-ci>", "<github-runner>"] if mask_ci else [],
        },
    }
