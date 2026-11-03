"""Extract bounded, privacy-safe compiler failure facts from private logs."""
from __future__ import annotations

from pathlib import Path
import re

# These contexts are the only producer identities allowed into retained evidence.
_CONTEXTS = {
    "public-cancel-host": {
        "stage": "public-cancel-host", "tool": "cjc", "wrapper": "cjpm",
        "package": "highlight_host_fixture",
    },
    "provider": {
        "stage": "provider", "tool": "cjc", "wrapper": "cjpm",
        "package": "provider_plugin_fixture",
    },
}

_MAX_LOG_BYTES = 1024 * 1024
_MAX_STREAMS = 2
_FRAME = re.compile(
    r"^\s*#\d{1,3}\s+(?:0x[0-9a-fA-F]{1,16}\s+)?"
    r"(llvm::(?:[A-Za-z_~][A-Za-z0-9_~]*::)*[A-Za-z_~][A-Za-z0-9_~]*)"
    r"(?=[(<\s]|$)"
)
# A namespace-shaped token is not proof that it contains no private metadata.
_KNOWN_LLVM_SYMBOLS = frozenset({
    "llvm::sys::PrintStackTrace",
    "llvm::MachineRegisterInfo::addRegOperandToUseList",
    "llvm::MachineInstr::addOperand",
    "llvm::InstrEmitter::EmitSpecialNode",
    "llvm::ScheduleDAGSDNodes::EmitSchedule",
    "llvm::SelectionDAGISel::CodeGenAndEmitDAG",
    "llvm::SelectionDAGISel::SelectBasicBlock",
    "llvm::SelectionDAGISel::SelectAllBasicBlocks",
    "llvm::SelectionDAGISel::runOnMachineFunction",
    "llvm::createX86ISelDag",
    "llvm::MachineFunctionPass::runOnFunction",
    "llvm::FPPassManager::runOnFunction",
    "llvm::FPPassManager::runOnModule",
    "llvm::legacy::PassManagerImpl::run",
})
_EXCEPTION_CODE = re.compile(
    r"^[ \t]*Exception Code:[ \t]*0x([0-9a-f]{8})\b", re.IGNORECASE | re.MULTILINE)
_EXCEPTION_CODES = {
    "c0000005": "0xC0000005",  # access violation
    "c00000fd": "0xC00000FD",  # stack overflow
    "c000001d": "0xC000001D",  # illegal instruction
    "c0000409": "0xC0000409",  # stack buffer overrun
    "80000003": "0x80000003",  # breakpoint
    "e06d7363": "0xE06D7363",  # MSVC C++ exception
}
_SIGNATURES = (
    ("llvm-crash-report", re.compile(r"PLEASE submit a bug report", re.IGNORECASE),
     "LLVM emitted its crash-report banner."),
    ("llvm-internal-error", re.compile(r"\bLLVM ERROR\s*:", re.IGNORECASE),
     "LLVM reported an internal compiler error."),
    ("llvm-stack-dump", re.compile(r"^[ \t]*Stack dump:", re.IGNORECASE | re.MULTILINE),
     "LLVM emitted a compiler stack dump."),
    ("compiler-backend-error", re.compile(r"\berror in backend\s*:", re.IGNORECASE),
     "The compiler backend reported an error."),
    ("compiler-fatal-diagnostic", re.compile(r"\bfatal error\s*:", re.IGNORECASE),
     "The compiler emitted a fatal diagnostic."),
    ("compiler-exception", re.compile(r"\b(?:unhandled|uncaught) exception\b", re.IGNORECASE),
     "The compiler process reported an exception."),
)


def _read_tail(path: Path) -> bytes | None:
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            size = stream.tell()
            stream.seek(max(0, size - _MAX_LOG_BYTES))
            raw = stream.read(_MAX_LOG_BYTES)
            return raw.partition(b"\n")[2] if size > _MAX_LOG_BYTES else raw
    except OSError:
        return None


def compiler_failure_evidence(context: str, logs: list[tuple[str, Path]]) -> dict | None:
    """Return only fixed classifications and LLVM-owned symbols, never log text."""
    identity = _CONTEXTS.get(context)
    if identity is None or not 1 <= len(logs) <= _MAX_STREAMS:
        return None

    classifications: list[str] = []
    messages: list[str] = []
    exception_codes: list[str] = []
    stack_symbols: list[str] = []
    observed_streams: list[str] = []

    for label, path in logs:
        if label not in {"stdout", "stderr", "stage-log"}:
            continue
        raw = _read_tail(path)
        if raw is None:
            continue
        text = raw.decode("utf-8", errors="replace")
        found = False
        for code, pattern, message in _SIGNATURES:
            if pattern.search(text):
                found = True
                if code not in classifications:
                    classifications.append(code)
                if message not in messages:
                    messages.append(message)
        for match in _EXCEPTION_CODE.finditer(text):
            code = _EXCEPTION_CODES.get(match.group(1).lower())
            if code is not None:
                found = True
                if code not in exception_codes:
                    exception_codes.append(code)
                if "native-exception" not in classifications:
                    classifications.append("native-exception")
                message = "Build output contained a recognized native exception diagnostic."
                if message not in messages:
                    messages.append(message)
        for line in text.splitlines():
            match = _FRAME.match(line)
            if match is None:
                continue
            symbol = match.group(1)
            if symbol not in _KNOWN_LLVM_SYMBOLS:
                continue
            found = True
            if symbol not in stack_symbols:
                stack_symbols.append(symbol)
            if "llvm-stack-frame" not in classifications:
                classifications.append("llvm-stack-frame")
            message = "LLVM stack frames were present in compiler output."
            if message not in messages:
                messages.append(message)
        if found and label not in observed_streams:
            observed_streams.append(label)

    if not classifications:
        return None
    return {
        "schemaVersion": "cjdoc.compiler-failure/1",
        "status": "recorded",
        **identity,
        "classifications": classifications,
        "messages": messages[:8],
        "exceptionCodes": exception_codes[:8],
        "stackSymbols": stack_symbols,
        "observedStreams": observed_streams,
    }
