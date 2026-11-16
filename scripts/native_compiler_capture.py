#!/usr/bin/env python3
"""Capture source-bound native compiler evidence for a provider stage.

The Windows provider stage is the only place this repository runs the pinned SDK's
own LLVM backend on real input, and a crash there is otherwise visible only as a
truncated stage log. This module is the *collector*: it never builds, retries or
reinterprets the stage.

    capture = NativeCompilerCapture.prepare(evidence_dir, child_environment)
    # The stage may run only when `capture.active`; child_environment now names the
    # owned diagnostics directory and invocation log.
    capture.observe(line)   # every stream line, before the log drops its middle
    record = capture.finish(exit_code, evidence_dir / "provider.log")

`observe` is the frontend channel. `cjpm` announces each package's `cjc.exe`
command and the compiler prints its own quoted `cjc-frontend.exe` lines, but the
retained stage log keeps only a head and a tail, so a command from the middle of a
long build would be lost. `observe` keeps just those lines in memory: one line
capped at `COMMAND_LINE_LIMIT`, the channel at `COMMAND_TOTAL_LIMIT`, and it is
thread-safe and never raises. `finish` reports them from that channel, not from
whatever survived in the log.

`finish` always keeps the original outcome in `stageExitCode`; it never rewrites a
failure into success. The record is `recorded` when the SDK binary identity
(before and after), the provider invocation, the diagnostics inventory and the
retained frontend commands are present, and -- for a real compiler failure -- a
privacy-audited bytecode payload. Anything else is `unavailable` with a fixed
`reason` and never a machine path, so a missing capture fails an evidence gate
without turning the stage green.

Bytecode is published only when the stage actually failed inside `llc` and the
selected module survives a deep audit: the SDK's own `opt.exe -S` streams the
bitcode to private text, and any absolute-path, UNC or home-directory token in it
withholds the payload -- as do private addresses, credentials and mail addresses.
The disassembler's own `ModuleID` comment is excluded because it names the audit's
input file, not anything the module stores. A GitHub-hosted runner's conventional
roots (`D:/a/<repo>`, `C:/Users/runneradmin`) are masked and counted only when
`GITHUB_ACTIONS` and `CI` both say the run is on a runner; a runner temp root in
embedded metadata is still a rejection. The bitcode is never rewritten, so a
published file is the compiler's exact output, and evidence already on disk is
never replaced.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import threading
from pathlib import Path

try:
    from .sts_compile_override import PRODUCT_REASON
except ImportError:
    from sts_compile_override import PRODUCT_REASON

SCHEMA = "cjdoc.native-compiler-capture/1"
DIAGNOSTICS_ENV = "CJDOC_STS_COMPILER_DIAGNOSTICS"
INVOCATION_ENV = "CJDOC_STS_INVOCATION_LOG"
PRODUCT_PHASE = "product-run"

# The SDK files whose identity binds this evidence to one compiler. Sizes are
# recorded next to the digests because a truncated download keeps a plausible
# prefix; the pair is what a receipt can be compared against.
SDK_BINARIES = (
    "bin/cjc.exe",
    "bin/cjc-frontend.exe",
    "tools/bin/cjpm.exe",
    "third_party/llvm/bin/opt.exe",
    "third_party/llvm/bin/llc.exe",
    "third_party/llvm/bin/libLLVM-15.dll",
    "third_party/llvm/bin/libLLVM-Foundation-15.dll",
)
OPT_BINARY = "third_party/llvm/bin/opt.exe"

SDK_BINARY_LIMIT = 256 * 1024 * 1024
# A privacy/upload bound, not a performance budget: one failing module is far
# below it, and a larger file is withheld rather than published.
PAYLOAD_LIMIT = 128 * 1024 * 1024
LLVM_TEXT_LIMIT = 64 * 1024 * 1024
INVOCATION_LIMIT = 4 * 1024 * 1024
INVOCATION_RECORD_LIMIT = 8
IR_ENTRY_LIMIT = 4096
DISK_HEADROOM = 512 * 1024 * 1024
STAGE_LOG_TAIL = 2 * 1024 * 1024
COMMAND_LINE_LIMIT = 64 * 1024
COMMAND_TOTAL_LIMIT = 4 * 1024 * 1024
COMMAND_ARGV_LIMIT = 256
AUDIT_TIMEOUT_SECONDS = 300

NAME = re.compile(r"^[A-Za-z0-9_.-]{1,128}\Z")
DETAIL = re.compile(r"^[A-Za-z0-9_.-]{1,64}(?:/[A-Za-z0-9_.-]{1,64}){0,7}\Z")
HEX64 = re.compile(r"^[0-9a-f]{64}\Z")
# `cjpm` announces each package it compiles with the command line it runs, e.g.
# `Compiling package `cjdoc.render`: cjc.exe -p ... --output-dir=...`, and the
# compiler prints its own quoted `cjc-frontend.exe ...` command lines.
_COMPILING = re.compile(
    r"^[ \t]*Compiling (?:build script of )?(?:package )?`(?P<package>[^`\n]{1,128})`:"
    r"[ \t]*(?P<command>.*cjc(?P<frontend>-frontend)?(?:\.exe)?.*)$")
_FRONTEND_COMMAND = re.compile(r'"[^"\n]{0,1024}cjc-frontend(?:\.exe)?"')
# `cjpm run` ends with this line when the SDK's bundled `llc` dies; the failing
# module is the `.opt.bc` immediately named on it.
_LLC_FAILURE = re.compile(
    r"([A-Za-z0-9_.-]{1,128})\.opt\.bc[\"']?[^\n]*?command failed with exit code (\d{1,10})")
_MODULE_ID = "; ModuleID = "
_COMPILER_TEMP = re.compile(r"cangjie-tmp-[A-Za-z0-9]+")
_WINDOWS_ABSOLUTE = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\[A-Za-z0-9._$-]+[\\/])[^\s\"'<>]*")
_POSIX_ABSOLUTE = re.compile(r"(?<![:/\w>])/[^\s\"'<>]*")

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


def _directory(value: object) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        path = Path(value)
        if path.is_dir():
            return path
    except OSError:
        return None
    return None


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


def _inventory(sdk_root: Path) -> dict[str, dict]:
    """Digest the SDK binaries this evidence is bound to, relative-name keyed."""
    try:
        return {relative: _copy_verified(sdk_root / relative, None, SDK_BINARY_LIMIT, relative)
                for relative in SDK_BINARIES}
    except _Unavailable as problem:
        raise _Unavailable("sdk-inventory-incomplete", problem.detail) from None


def _read_tail(path: Path, limit: int) -> str:
    """Read a bounded tail of a stage log that is itself already bounded."""
    handle, info, _before = _open_regular(path, limit, "stage-log-missing")
    offset = max(0, info.st_size - limit)
    try:
        handle.seek(offset)
        raw = handle.read()
    except OSError:
        raise _Unavailable("stage-log-missing") from None
    finally:
        handle.close()
    return (raw.partition(b"\n")[2] if offset else raw).decode("utf-8", "replace")


def _normalize(text: str, replacements: tuple[tuple[str, str], ...]) -> str:
    """Replace this run's machine roots with stable labels, then collapse paths."""
    for literal, label in replacements:
        if literal in text:
            text = text.replace(literal, label)
    text = _COMPILER_TEMP.sub("<compiler-temp>", text)
    # A basename can itself be a user or host identifier, so the collapsed form
    # keeps no name at all.
    text = _WINDOWS_ABSOLUTE.sub("<path>", text)
    return _POSIX_ABSOLUTE.sub("<path>", text)


def _split_arguments(text: str) -> list[str]:
    """Split an argument list on unquoted whitespace.

    Separators are literals: a logged Windows path keeps its backslashes, and a
    quote that closes an argument is never consumed as an escape.
    """
    tokens: list[str] = []
    current: list[str] = []
    quote = ""
    for character in text:
        if quote:
            if character == quote:
                quote = ""
            else:
                current.append(character)
        elif character in "\"'":
            quote = character
        elif character.isspace():
            if current:
                tokens.append("".join(current))
                current = []
        else:
            current.append(character)
    if current:
        tokens.append("".join(current))
    return tokens


def _split_option(tokens: list[str]) -> tuple[list[str], list[str]]:
    """Separate the diagnostics tail from the product options actually applied."""
    if "--save-temps" not in tokens:
        return tokens, []
    index = tokens.index("--save-temps")
    start = index - 1 if index > 0 and tokens[index - 1] == "-V" else index
    return tokens[:start], tokens[start:]


def _scan_ir(directory: Path) -> tuple[int, int]:
    """Count the owned diagnostics directory's files and bytes, flat only."""
    try:
        root = directory.lstat()
    except OSError:
        raise _Unavailable("ir-directory-missing") from None
    if not stat.S_ISDIR(root.st_mode):
        raise _Unavailable("ir-unsafe")
    files = 0
    total = 0
    try:
        with os.scandir(directory) as scan:
            entries = sorted(scan, key=lambda item: item.name)
    except OSError:
        raise _Unavailable("ir-unsafe") from None
    for entry in entries:
        # `--save-temps` writes a flat directory. A subdirectory, a link or a
        # device is not a layout this receipt can enumerate honestly.
        if entry.is_symlink():
            raise _Unavailable("ir-unsafe", entry.name)
        info = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise _Unavailable("ir-unsafe", entry.name)
        files += 1
        total += info.st_size
        if files > IR_ENTRY_LIMIT:
            raise _Unavailable("ir-overlimit")
    return files, total


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


class NativeCompilerCapture:
    """One provider stage's owned diagnostic capture.

    `prepare` activates only with a unique private scratch root, free disk and a
    readable SDK inventory; otherwise it sets `reason` and leaves the child
    environment untouched. `finish` publishes a sanitized receipt and removes the
    owned scratch root, whatever the stage outcome was.
    """

    def __init__(self, evidence_dir: Path) -> None:
        self.evidence_dir = Path(evidence_dir)
        # The directory the compiler writes `--save-temps` output into. Only a
        # successful `prepare` sets it; an inactive capture leaves an empty path
        # that no caller should treat as an owned location.
        self.diagnostics_dir = Path()
        self.active = False
        self._reason = ""
        self._detail = ""
        self._root: Path | None = None
        self._root_identity: tuple[int, int] = (0, 0)
        self._invocation_log: Path | None = None
        self._sdk_root: Path | None = None
        self._sdk_source = ""
        self._sdk_before: dict[str, dict] = {}
        self._replacements: tuple[tuple[str, str], ...] = ()
        self._mask_ci = False
        self._record: dict | None = None
        self._lock = threading.Lock()
        self._observed: list[tuple[str, bool]] = []
        self._observed_bytes = 0
        self._observed_skipped = 0
        self._observed_truncated = False
        self._llc_failure: tuple[str, int] | None = None

    @property
    def reason(self) -> str:
        return self._reason

    @classmethod
    def prepare(cls, evidence_dir: Path,
                child_environment: dict[str, str]) -> NativeCompilerCapture:
        capture = cls(evidence_dir)
        try:
            runner_temp = _directory(child_environment.get("RUNNER_TEMP"))
            if runner_temp is None:
                raise _Unavailable("prepare-runner-temp-missing")
            try:
                if shutil.disk_usage(runner_temp).free < DISK_HEADROOM:
                    raise _Unavailable("prepare-free-space-low")
                root = Path(tempfile.mkdtemp(prefix="cjdoc-native-compiler-",
                                             dir=str(runner_temp)))
                info = root.lstat()
                ir = root / "ir"
                ir.mkdir()
                invocation_log = root / "invocations.jsonl"
            except OSError:
                raise _Unavailable("prepare-temp-unavailable") from None
            if not stat.S_ISDIR(info.st_mode):
                raise _Unavailable("prepare-temp-unavailable")
            capture._root = root
            capture._root_identity = (info.st_dev, info.st_ino)
            sdk_root, source = None, ""
            for variable in ("CANGJIE_HOME", "CANGJIE_SDK_ROOT"):
                sdk_root = _directory(child_environment.get(variable))
                if sdk_root is not None:
                    source = variable
                    break
            if sdk_root is None:
                raise _Unavailable("sdk-root-unresolved")
            capture._sdk_root = sdk_root
            capture._sdk_source = source
            capture._sdk_before = _inventory(sdk_root)
            # The capture owns its own log: a record left by an earlier stage or
            # flow describes a different invocation, and mixing it in would make
            # this receipt claim commands this stage never ran.
            capture._invocation_log = invocation_log
            # Only a GitHub-hosted runner may claim its own conventional roots are
            # public. Anywhere else the same token shapes stay hazards.
            capture._mask_ci = (child_environment.get("GITHUB_ACTIONS") == "true"
                                and child_environment.get("CI") == "true")
            roots = [(sdk_root, "<sdk>"), (root, "<capture-temp>"),
                     (invocation_log, "<invocation-log>"), (evidence_dir, "<evidence>"),
                     (runner_temp, "<runner-temp>")]
            for key, label in (("GITHUB_WORKSPACE", "<workspace>"), ("HOME", "<home>"),
                               ("USERPROFILE", "<home>")):
                directory = _directory(child_environment.get(key))
                if directory is not None:
                    roots.append((directory, label))
            pairs = set()
            for path, label in roots:
                pairs.update({(str(path), label), (path.as_posix(), label),
                              (str(path).replace("/", "\\"), label)})
            capture._replacements = tuple(
                sorted(pairs, key=lambda item: (-len(item[0]), item[1])))
            capture.diagnostics_dir = ir
            # The wrapper only gains these values once everything above succeeded:
            # a half-prepared capture must not change how the stage compiles.
            child_environment[DIAGNOSTICS_ENV] = str(ir)
            child_environment[INVOCATION_ENV] = str(invocation_log)
            capture.active = True
        except _Unavailable as problem:
            capture._reason = problem.reason
            capture._detail = problem.detail
            capture._release()
        except Exception:  # noqa: BLE001 - preparation may never break the stage
            capture._reason = "prepare-temp-unavailable"
            capture._release()
        return capture

    def observe(self, line: bytes) -> None:
        """Retain one compiler command line from the live stage stream.

        Called for every line the stage runner reads, before the retained log drops
        the middle of a long build. Only `cjpm`'s per-package `cjc` lines and
        quoted `cjc-frontend` lines are kept; everything else is dropped here
        rather than stored and classified later.
        """
        if not self.active:
            return
        try:
            raw = line.encode("utf-8", "replace") if isinstance(line, str) else bytes(line)
            raw = raw.rstrip(b"\r\n")
            if not raw:
                return
            if b".opt.bc" in raw and b"command failed with exit code" in raw:
                failure = _LLC_FAILURE.search(raw[:COMMAND_LINE_LIMIT].decode("utf-8", "replace"))
                if failure is not None:
                    with self._lock:
                        self._llc_failure = (failure.group(1), int(failure.group(2)))
            if b"Compiling " not in raw and b"cjc-frontend" not in raw:
                return
            truncated = len(raw) > COMMAND_LINE_LIMIT
            text = raw[:COMMAND_LINE_LIMIT].decode("utf-8", "replace")
            if not _COMPILING.match(text) and not _FRONTEND_COMMAND.search(text):
                return
            with self._lock:
                if self._observed_bytes + len(text) > COMMAND_TOTAL_LIMIT:
                    self._observed_skipped += 1
                    self._observed_truncated = True
                    return
                self._observed_bytes += len(text)
                self._observed.append((text, truncated))
        except Exception:  # noqa: BLE001 - observation may never disturb the stage
            return

    def finish(self, exit_code: int, stage_log: Path) -> dict:
        if self._record is not None:
            # The first observation is the one that saw the stage's own output; a
            # later caller gets the same receipt instead of a re-decision about a
            # scratch root that no longer exists.
            return dict(self._record)
        stage_log = Path(stage_log)
        stem = stage_log.stem
        prefix = stem if NAME.match(stem) and len(stem) <= 64 else "stage"
        record: dict = {
            "schemaVersion": SCHEMA,
            "status": "unavailable",
            "stageExitCode": int(exit_code),
            "reason": self._reason or None,
            "reasonDetail": _safe_detail(self._detail),
            "sdk": None,
            "invocations": None,
            "compileOptions": {"product": None, "diagnostics": [], "observedIn": None},
            "ir": None,
            "frontendCommands": None,
            "compilerFailure": {"observed": False},
            "payload": None,
            "temporaryRemoved": False,
            "evidenceFile": None,
        }
        receipt = self.evidence_dir / f"{prefix}.native-compiler.json"
        # Evidence belongs to one attempt: a receipt that already exists was
        # written by something else, so this capture collects nothing and
        # replaces nothing, not even its own account of the run.
        receipt_exists = os.path.lexists(receipt)
        if self.active and receipt_exists:
            record["reason"] = "evidence-exists"
        elif self.active:
            try:
                self._collect(record, int(exit_code), stage_log, prefix)
            except _Unavailable as problem:
                record["reason"] = problem.reason
                record["reasonDetail"] = _safe_detail(problem.detail)
            except Exception:  # noqa: BLE001 - a collector fault must not mask the stage
                record["reason"] = "capture-internal-error"
                record["reasonDetail"] = None
            else:
                record["status"] = "recorded"
                record["reason"] = None
                record["reasonDetail"] = None
        record["temporaryRemoved"] = self._release()
        if not receipt_exists:
            try:
                record["evidenceFile"] = self._write(receipt, record)
            except _Unavailable as problem:
                # The stage's own result must survive a receipt that cannot be
                # written; the caller sees `unavailable`, not a traceback.
                record["status"] = "unavailable"
                record["reason"] = problem.reason
                record["reasonDetail"] = None
                self._discard_payload(record)
        self._record = record
        return dict(record)

    def _collect(self, record: dict, exit_code: int, stage_log: Path, prefix: str) -> None:
        # Identity first: whatever else turns out to be unavailable, the receipt
        # still names the compiler binaries the stage actually ran.
        after = _inventory(self._sdk_root) if self._sdk_root else {}
        changed = [relative for relative in SDK_BINARIES
                   if after.get(relative) != self._sdk_before.get(relative)]
        record["sdk"] = {
            "resolvedFrom": self._sdk_source,
            "root": "<sdk>",
            # The before snapshot stays primary: those are the bytes the stage
            # actually compiled with.
            "binaries": self._sdk_before,
            "matchesPrepare": not changed,
            **({"changed": changed} if changed else {}),
        }
        files, total = _scan_ir(self.diagnostics_dir)
        record["ir"] = {"files": files, "totalBytes": total}
        record["invocations"], record["compileOptions"] = self._invocations()
        record["frontendCommands"] = self._frontend_commands()
        if changed:
            raise _Unavailable("sdk-inventory-changed", changed[0])
        if exit_code == 0:
            if not self._observed:
                # The compiler's own command lines are the evidence this receipt
                # exists for; none means the stream was never observed.
                raise _Unavailable("frontend-commands-empty")
            if files == 0:
                # A successful stage that recorded no diagnostics means the
                # capture is not wired into the compiler at all.
                raise _Unavailable("ir-empty")
            return
        # Prefer the live stream: the failing line can fall inside the bounded
        # stage log's omitted middle. Keep the log fallback for direct callers.
        failure = self._llc_failure
        source_channel = "stage-stream"
        if failure is None:
            matches = list(_LLC_FAILURE.finditer(_read_tail(stage_log, STAGE_LOG_TAIL)))
            if matches:
                failure = (matches[-1].group(1), int(matches[-1].group(2)))
            source_channel = "stage-log"
        if failure is None or not NAME.match(failure[0]):
            raise _Unavailable("llc-failure-unrecognized")
        module, code = failure
        record["compilerFailure"] = {
            "observed": True,
            "classification": "llc-nonzero-exit",
            "source": source_channel,
            "module": module,
            "llcExitCode": code,
            "exceptionCode": f"0x{code:08X}" if 0 <= code <= 0xFFFFFFFF else None,
        }
        source = self.diagnostics_dir / f"{module}.opt.bc"
        try:
            info = source.lstat()
        except OSError:
            raise _Unavailable(
                "ir-empty" if files == 0 else "llc-failure-module-missing",
                f"{module}.opt.bc") from None
        if not stat.S_ISREG(info.st_mode):
            raise _Unavailable("ir-unsafe", f"{module}.opt.bc")
        record["payload"] = self._retain(prefix, module, source)

    def _invocations(self) -> tuple[dict, dict]:
        if self._invocation_log is None:
            raise _Unavailable("invocation-log-missing")
        handle, _info, _before = _open_regular(self._invocation_log, INVOCATION_LIMIT,
                                              "invocation-log-missing", "",
                                              "invocation-log-oversize")
        try:
            raw = handle.read()
        except OSError:
            raise _Unavailable("invocation-log-missing") from None
        finally:
            handle.close()
        try:
            entries = [json.loads(line) for line in raw.decode("utf-8").splitlines()
                       if line.strip()]
        except ValueError:
            raise _Unavailable("invocation-log-malformed") from None
        records: list[dict] = []
        ignored = 0
        for entry in entries:
            # The provider stage runs one product invocation. A record from any
            # other phase describes a different build and is not this evidence.
            if not isinstance(entry, dict):
                raise _Unavailable("invocation-log-malformed")
            if entry.get("phase") != PRODUCT_PHASE:
                ignored += 1
                continue
            if len(records) >= INVOCATION_RECORD_LIMIT:
                break
            option, argv, exit_code = (entry.get("option"), entry.get("argv"),
                                       entry.get("exitCode"))
            if (entry.get("reason") != PRODUCT_REASON or not isinstance(option, str)
                    or not isinstance(argv, list) or not isinstance(exit_code, int)
                    or isinstance(exit_code, bool)):
                raise _Unavailable("invocation-log-malformed")
            product, diagnostics = _split_option(
                [self._normalize(token) for token in _split_arguments(option)])
            package = entry.get("package")
            records.append({
                "package": package if isinstance(package, str) and NAME.match(package) else "",
                "productOptions": product,
                "diagnosticsOptions": diagnostics,
                "exitCode": exit_code,
                "argv": [self._normalize(token) for token in argv
                         if isinstance(token, str)][:COMMAND_ARGV_LIMIT],
                "policySha256": entry.get("policySha256")
                if isinstance(entry.get("policySha256"), str)
                and HEX64.match(entry["policySha256"]) else None,
                "wrapperSha256": entry.get("wrapperSha256")
                if isinstance(entry.get("wrapperSha256"), str)
                and HEX64.match(entry["wrapperSha256"]) else None,
            })
        if not records:
            raise _Unavailable("invocation-log-malformed")
        compile_options = {"product": records[0]["productOptions"],
                           "diagnostics": records[0]["diagnosticsOptions"],
                           "observedIn": PRODUCT_PHASE,
                           # Retention is only evidence if it wrote into the
                           # directory this capture owns.
                           "diagnosticsDirMatchesCapture": records[0][
                               "diagnosticsOptions"].count(
                                   self._normalize(str(self.diagnostics_dir))) == 1}
        return ({"count": len(records),
                 "truncated": bool(entries) and len(records) >= INVOCATION_RECORD_LIMIT,
                 "ignored": ignored, "records": records}, compile_options)

    def _frontend_commands(self) -> dict:
        entries = []
        for text, truncated in list(self._observed):
            match = _COMPILING.match(text)
            if match is not None:
                package = match.group("package")
                program = "cjc-frontend" if match.group("frontend") else "cjc"
                command = match.group("command").strip()
            else:
                package, program, command = "", "cjc-frontend", text.strip()
            normalized = self._normalize(command)
            entries.append({
                "package": package if NAME.match(package) else "",
                "program": program,
                "argv": _split_arguments(normalized)[:COMMAND_ARGV_LIMIT],
                "commandLine": normalized,
                "lineTruncated": truncated,
            })
        return {"source": "stage-stream", "count": len(entries),
                "truncated": self._observed_truncated,
                "skipped": self._observed_skipped,
                "totalBytes": self._observed_bytes, "entries": entries}

    def _retain(self, prefix: str, module: str, source: Path) -> dict:
        """Audit the module in private and publish the exact bytes if it is safe."""
        if self._root is None or self._sdk_root is None:
            raise _Unavailable("capture-internal-error")
        detail = f"{module}.opt.bc"
        audit_dir = self._root / "audit"
        try:
            audit_dir.mkdir(exist_ok=True)
            with (audit_dir / detail).open("xb") as sink:
                observed = _copy_verified(source, sink, PAYLOAD_LIMIT, detail)
        except OSError:
            raise _Unavailable("payload-unreadable", detail) from None
        text_file = audit_dir / f"{module}.ll"
        try:
            completed = subprocess.run(
                [str(self._sdk_root / OPT_BINARY), "-S", "-o", str(text_file),
                 str(audit_dir / detail)],
                cwd=str(audit_dir), stdin=subprocess.DEVNULL, capture_output=True,
                check=False, timeout=AUDIT_TIMEOUT_SECONDS)
            if completed.returncode != 0:
                raise _Unavailable("privacy-audit-unavailable", detail)
            labels, occurrences, seen, module_id = _scan_llvm_text(
                text_file, detail, self._mask_ci)
        except (OSError, subprocess.TimeoutExpired):
            raise _Unavailable("privacy-audit-unavailable", detail) from None
        finally:
            # The rendered text is a private working file; only labels leave.
            text_file.unlink(missing_ok=True)
        if labels:
            raise _Unavailable("privacy-audit-rejected", labels[0])
        relative_dir = f"{prefix}.native-compiler"
        directory = self.evidence_dir / relative_dir
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
                "ciRoots": ["<github-ci>", "<github-runner>"] if self._mask_ci else [],
            },
        }

    def _discard_payload(self, record: dict) -> None:
        payload = record.get("payload")
        if not isinstance(payload, dict):
            return
        relative = payload.get("file")
        record["payload"] = None
        if not isinstance(relative, str) or not relative:
            return
        target = (self.evidence_dir / relative).resolve()
        try:
            target.relative_to(self.evidence_dir.resolve())
        except ValueError:
            return
        target.unlink(missing_ok=True)
        try:
            target.parent.rmdir()
        except OSError:
            pass

    def _write(self, receipt: Path, record: dict) -> str:
        body = (json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True)
                + "\n").encode("utf-8")
        flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                 | getattr(os, "O_BINARY", 0))
        try:
            self.evidence_dir.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(receipt, flags, 0o600)
        except FileExistsError:
            raise _Unavailable("evidence-exists") from None
        except OSError:
            raise _Unavailable("evidence-write-failed") from None
        try:
            with os.fdopen(descriptor, "wb") as sink:
                sink.write(body)
        except OSError:
            receipt.unlink(missing_ok=True)
            raise _Unavailable("evidence-write-failed") from None
        return receipt.name

    def _release(self) -> bool:
        """Remove only this capture's own unique scratch root."""
        root, self._root = self._root, None
        if root is None:
            return True
        if not os.path.lexists(root):
            return True
        try:
            info = root.lstat()
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or (
                info.st_dev, info.st_ino) != self._root_identity:
            return False
        shutil.rmtree(root, ignore_errors=True)
        return not os.path.lexists(root)

    def _normalize(self, text: str) -> str:
        return _normalize(text, self._replacements)
