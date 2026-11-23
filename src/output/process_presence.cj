protected package cjdoc.output

import cjdoc.digest.Sha256Digest
@When[os == "Linux"]
import std.env.*

@When[os == "Linux"]
import std.fs.*

// A writer can disappear between the moment it records a lock owner and the
// recovery attempt that follows, for example when it is killed while its spool
// is being populated. std.process reports that disappearance as the same opaque
// ProcessException it raises for allocation, permission and query failures, so
// recovery cannot treat that exception as evidence.
//
// Linux exposes a narrower query that answers exactly the question recovery
// needs: does this PID still name a process? clock_getcpuclockid returns the
// POSIX error number directly instead of setting a shared errno, so no
// intervening library call can change the answer before it is interpreted.
//
// An explicit ESRCH proves absence only in the caller's process domain. The
// owner must also carry this kernel boot and PID namespace identity; otherwise
// a live writer in another namespace could be mistaken for a missing PID.
// Standalone declarations keep std.ast self-documentation support.
@When[os == "Linux"]
foreign func clock_getcpuclockid(processId: Int32, clockId: CPointer<Int32>): Int32

@When[os == "Linux"]
foreign func readlink(path: CString, buffer: CPointer<UInt8>, size: UIntNative): IntNative

@When[os == "Linux"]
private func linuxProcessBootId(): String {
    let file = File("/proc/sys/kernel/random/boot_id", OpenMode.Read)
    let buffer = Array<Byte>(64, repeat: 0)
    let count = try { file.read(buffer) } finally { file.close() }
    if (count != 37 || buffer[36] != b'\n') {
        throw IllegalStateException("process boot identity is unavailable")
    }
    for (index in 0..36) {
        let separator = index == 8 || index == 13 || index == 18 || index == 23
        let valid = if (separator) { buffer[index] == b'-' } else {
            (buffer[index] >= b'0' && buffer[index] <= b'9') ||
                (buffer[index] >= b'a' && buffer[index] <= b'f')
        }
        if (!valid) { throw IllegalStateException("invalid process boot identity") }
    }
    String.fromUtf8(buffer[0..36])
}

@When[os == "Linux"]
private func linuxPidNamespace(): String {
    let buffer = Array<Byte>(64, repeat: 0)
    let count = unsafe {
        let path = LibC.mallocCString("/proc/self/ns/pid")
        try {
            let handle = acquireArrayRawData(buffer)
            try { Int64(readlink(path, handle.pointer, UIntNative(buffer.size))) } finally {
                releaseArrayRawData(handle)
            }
        } finally { LibC.free(path) }
    }
    if (count < 7 || count >= buffer.size) {
        throw IllegalStateException("process namespace identity is unavailable")
    }
    let identity = String.fromUtf8(buffer[0..count])
    if (!identity.startsWith("pid:[") || !identity.endsWith("]")) {
        throw IllegalStateException("invalid process namespace identity")
    }
    for (index in 5..identity.size - 1) {
        if (identity[index] < b'0' || identity[index] > b'9') {
            throw IllegalStateException("invalid process namespace identity")
        }
    }
    identity
}

@When[os == "Linux"]
private func linuxProcViewMatchesCurrentPid(): Bool {
    // std.process reads procfs, but the kernel query uses the active PID
    // namespace. A single NStgid value proves that the procfs view agrees.
    let file = File("/proc/self/status", OpenMode.Read)
    let buffer = Array<Byte>(4096, repeat: 0)
    let count = try { file.read(buffer) } finally { file.close() }
    let expected = "\nNStgid:\t${getProcessId()}\n"
    if (count < expected.size) { return false }
    for (start in 0..count - expected.size + 1) {
        var matches = true
        for (offset in 0..expected.size) {
            if (buffer[start + offset] != expected[offset]) {
                matches = false
                break
            }
        }
        if (matches) { return true }
    }
    false
}

// These OS identities are invariant during this process's lifetime. Their
// digest binds liveness observations without publishing host identifiers.
@When[os == "Linux"]
internal func outputProcessDomainSha256(): ?String {
    try {
        if (!linuxProcViewMatchesCurrentPid()) { return None }
        let boot = linuxProcessBootId()
        let namespace = linuxPidNamespace()
        Some(Sha256Digest.digest("cjdoc.process-domain/2\n${boot}\n${namespace}"))
    } catch (_: Exception) { None }
}

@When[os != "Linux"]
internal func outputProcessDomainSha256(): ?String { None }

@When[os == "Linux"]
internal func outputProcessDomainMatches(captured: ?String): Bool {
    match (captured) {
        case Some(expected) => outputProcessDomainSha256() == Some(expected)
        case None => false
    }
}

@When[os != "Linux"]
internal func outputProcessDomainMatches(captured: ?String): Bool {
    // No new absence proof is used on other targets; retain their existing
    // successful std.process observation, but never accept a Linux domain.
    captured.isNone()
}

// This answers only for the current PID namespace. Callers must establish the
// owner's matching domain before using Dead to authorize lock reclamation.
@When[os == "Linux"]
internal func processPresenceState(pid: Int64): OutputProcessState {
    if (pid <= 0 || pid > Int64(Int32.Max)) {
        // The kernel cannot be asked about this value, so absence is unproven.
        return OutputProcessState.Unknown
    }
    var clockId: Int32 = 0
    let status = unsafe { clock_getcpuclockid(Int32(pid), inout clockId) }
    // ESRCH is 3 in the Linux UAPI.
    let noSuchProcess: Int32 = 3
    if (status == noSuchProcess) {
        OutputProcessState.Dead
    } else {
        OutputProcessState.Unknown
    }
}

@When[os != "Linux"]
internal func processPresenceState(pid: Int64): OutputProcessState {
    // Other targets keep the previous fail-closed rule rather than guessing that
    // a failed process query means the owner is gone.
    let _ = pid
    OutputProcessState.Unknown
}
