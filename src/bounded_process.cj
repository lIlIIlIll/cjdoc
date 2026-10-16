package cjdoc

import std.collection.*
import std.fs.*
import std.io.{InputStream}
import std.math.*
import std.process.*
import std.sync.*
import std.time.*
@When[os != "Windows"]
import std.posix.{killpg, SIGKILL}

@When[os == "Windows"]
import std.env.{getProcessId}

// STS 1.2 can stall concurrent redirected launch() calls before the
// supervisor PID is read. Protect stream setup only; child execution and
// output draining remain concurrent.
private let BOUNDED_PROCESS_LAUNCH_MUTEX = ReentrantMutex()

private let BOUNDED_PROCESS_TIMEOUT_MILLISECONDS: Int64 = 120000
private let BOUNDED_PROCESS_OUTPUT_BYTES: Int64 = 8192
private let BOUNDED_PROCESS_CHUNK_BYTES: Int64 = 8192
private let BOUNDED_PROCESS_POLL_MILLISECONDS: Int64 = 50

// The supervisor prints its group line immediately after starting the child, so a
// handshake that already timed out can still recover the group within this window.
private let BOUNDED_PROCESS_HANDSHAKE_RECOVERY_MILLISECONDS: Int64 = 500

// Retain only the diagnostic prefix, but drain the complete stream so a noisy child
// cannot block on a full pipe before it exits.
private func readBoundedProcessStream(stream: InputStream,
    limit: Int64): (Array<Byte>, Int64) {
    let retained = ArrayList<Byte>()
    let buffer = Array<Byte>(BOUNDED_PROCESS_CHUNK_BYTES, repeat: 0)
    var kept: Int64 = 0
    var total: Int64 = 0
    var count = stream.read(buffer)
    while (count > 0) {
        if (kept < limit) {
            let keep = min(count, limit - kept)
            for (index in 0..keep) { retained.add(buffer[index]) }
            kept += keep
        }
        total += count
        count = stream.read(buffer)
    }
    (retained.toArray(), total)
}

@When[os != "Windows"]
private func launchBoundedProcess(command: String, arguments: Array<String>,
    workingDirectory: ?Path, inputBytes: Int64, environment!: ?Map<String, String> = None): SubProcess {
    let wrapperArguments = ArrayList<String>()
    wrapperArguments.add("-c")
    // The child blocks until its isolated group has been recorded by the parent.
    // The count is formatted only from the caller byte array's size, never request text.
    // STS pipe streams expose no public close; forwarding exactly this count supplies EOF.
    // Disable inner job control so the stdin forwarder and target remain in that group.
    // Once the group exists, disable parent job notifications to keep stderr clean.
    wrapperArguments.add("owner=$PPID; set -m; (set +m; IFS= read -r release; count=$1; shift; if [ \"$count\" = -1 ]; then (while kill -0 \"$owner\" 2>/dev/null; do sleep 0.1; done; kill -KILL 0) </dev/null >/dev/null 2>&1 & exec \"$@\"; elif [ \"$count\" = 0 ]; then exec \"$@\" </dev/null; else head -c \"$count\" | \"$@\"; fi) <&0 & child=$!; set +m; printf '%s\\n' \"$child\"; wait \"$child\"")
    wrapperArguments.add("cjdoc-process-supervisor")
    wrapperArguments.add(inputBytes.toString())
    wrapperArguments.add(command)
    wrapperArguments.add(all: arguments)
    launch("/bin/bash", wrapperArguments.toArray(), workingDirectory: workingDirectory, environment: environment,
        stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
}

@When[os == "Windows"]
private func launchBoundedProcess(command: String, arguments: Array<String>,
    workingDirectory: ?Path, inputBytes: Int64, environment!: ?Map<String, String> = None): SubProcess {
    if (inputBytes < 0) {
        // Preload only this trusted gate; the adapter remains Node's real entry
        // module (including CommonJS require.main and its original argv).
        // Attach this same PID to the job before releasing module initialization.
        // Inherited preloads must not re-gate descendants or worker threads,
        // including workers that deliberately replace their environment.
        let ownerPid = getProcessId()
        let gatedArguments = ArrayList<String>()
        gatedArguments.add(all: ["--import",
            "data:text/javascript,import{readSync}from'node:fs';import{isMainThread}from'node:worker_threads';if(isMainThread&&process.ppid===${ownerPid}){const release=Buffer.alloc(1);if(readSync(0,release,0,1,null)!==1||release[0]!==10)process.exit(125);}const gate=process.execArgv.indexOf(import.meta.url);if(gate>0&&process.execArgv[gate-1]==='--import')process.execArgv.splice(gate-1,2);",
            "--"])
        gatedArguments.add(all: arguments)
        return launch(command, gatedArguments.toArray(),
            workingDirectory: workingDirectory, environment: environment,
            stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    }
    let script = StringBuilder()
    if (inputBytes > 0) {
        script.append("$OutputEncoding = New-Object System.Text.UTF8Encoding $false; [Console]::InputEncoding = $OutputEncoding; ")
    }
    script.append("$ErrorActionPreference='Stop'; if ([Console]::In.ReadLine() -eq $null) { exit 125 }; ")
    if (inputBytes > 0) {
        // The optional payload is one newline-terminated UTF-8 protocol request.
        script.append("[Console]::In.ReadLine() | ")
    }
    script.append("& '")
    script.append(command.replace("'", "''")); script.append("'")
    for (argument in arguments) {
        script.append(" '"); script.append(argument.replace("'", "''")); script.append("'")
    }
    script.append("; exit $LASTEXITCODE")
    launch("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script.toString()],
        workingDirectory: workingDirectory, stdIn: ProcessRedirect.Pipe,
        stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
}

@When[os != "Windows"]
private func boundedProcessGroupWithReader(process: SubProcess, timeoutMilliseconds: Int64,
    job: CPointer<Unit>): Int64 {
    // The supervisor writes one line naming the isolated group, and this read runs
    // BEFORE the watchdog is started, so it must carry its own deadline: a
    // supervisor that never prints would otherwise block here forever and the outer
    // `timeoutMilliseconds` could never fire. This is the same class of unbounded
    // read as the trailing stream reads below, and issue #116 stalled in exactly
    // the "child launches but never answers" state.
    let reader = startProcessGroupReader(process)
    let pid = awaitProcessGroupLine(reader, timeoutMilliseconds)
    if (pid > 0) { return pid }
    // The handshake timed out, but the supervisor has already spawned its isolated
    // group. That group is blocked reading the stdin pipe the caller never released,
    // so killing only the outer Bash would leak it indefinitely. Await the SAME
    // reader for a short grace -- the supervisor prints the line immediately after
    // `child=$!` -- and kill the group it names. Starting a second reader here would
    // race this one for the same bytes and could miss the line entirely.
    let recovered = awaitProcessGroupLine(reader,
        BOUNDED_PROCESS_HANDSHAKE_RECOVERY_MILLISECONDS)
    terminateBoundedProcessTree(process, recovered, job)
    throw IllegalStateException("process supervisor did not provide an isolated process group")
}

// The reader for the one numeric line naming the isolated process group. It is
// started once and awaited more than once: the handshake budget may expire while
// the line is still in flight, and starting a SECOND reader for the recovery would
// race the first one for the same bytes, so the recovery could miss the line and
// report group 0 -- leaking the very group it is trying to kill.
private func startProcessGroupReader(process: SubProcess): Future<Int64> {
    spawn {
        let buffer = Array<Byte>(1, repeat: 0)
        var pid: Int64 = 0
        var count: Int64 = 0
        while (process.stdOutPipe.read(buffer) == 1) {
            if (buffer[0] == b'\n' && pid > 0) { return pid }
            if (buffer[0] < b'0' || buffer[0] > b'9' || count >= 10) { break }
            pid = pid * 10 + Int64(buffer[0] - b'0')
            count++
        }
        0
    }
}

// Await that reader under a budget. An exhausted budget must not become
// `Duration.Zero`, which waits forever.
private func awaitProcessGroupLine(reader: Future<Int64>, timeoutMilliseconds: Int64): Int64 {
    if (timeoutMilliseconds <= 0) { return 0 }
    try {
        reader.get(Duration.millisecond * timeoutMilliseconds)
    } catch (_: Exception) {
        0
    }
}

@When[os == "Windows"]
private func boundedProcessGroupWithReader(process: SubProcess, timeoutMilliseconds: Int64,
    job: CPointer<Unit>): Int64 {
    let _ = (process, timeoutMilliseconds, job)
    0
}

@When[os != "Windows"]
private func terminateBoundedProcessTree(process: SubProcess, group: Int64,
    job: CPointer<Unit>): Unit {
    let _ = job
    if (group > 0) { let _ = killpg(Int32(group), SIGKILL) }
    try { process.terminate(force: true) } catch (_: Exception) {}
}

@When[os == "Windows"]
private func terminateBoundedProcessTree(process: SubProcess, group: Int64,
    job: CPointer<Unit>): Unit {
    let _ = group
    if (!closeExampleProcessJob(job)) {
        try { process.terminate(force: true) } catch (_: Exception) {}
    }
}

// The budget helpers are shared by the handshake, the watchdog and every wait so
// there is exactly one budget for the whole call, and it is derived from the
// MONOTONIC clock: `DateTime.now()` can jump when the system clock is corrected,
// which would either extend an advertised timeout or kill a healthy process early.
// An exhausted budget must NEVER be handed to `get`: `Future.get(Duration.Zero)`
// waits without any timeout, so clamping to zero would turn "already expired" into
// "wait forever".
private func remainingMilliseconds(started: MonoTime, timeoutMilliseconds: Int64): Int64 {
    let left = timeoutMilliseconds - (MonoTime.now() - started).toMilliseconds()
    if (left < 0) { 0 } else { left }
}

private func expired(started: MonoTime, timeoutMilliseconds: Int64): Bool {
    remainingMilliseconds(started, timeoutMilliseconds) <= 0
}

internal func executeWithBoundedOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None,
    timeoutMilliseconds!: Int64 = BOUNDED_PROCESS_TIMEOUT_MILLISECONDS,
    standardInput!: Array<Byte> = [], outputLimit!: Int64 = BOUNDED_PROCESS_OUTPUT_BYTES): (Int64, Array<Byte>, Array<Byte>) {
    // ONE absolute budget for the whole call, established before the handshake.
    // The handshake previously received a full `timeoutMilliseconds` of its own and
    // the reads/status a second full budget, so a slow supervisor could stretch the
    // advertised bound to nearly twice its value.
    let started = MonoTime.now()
    let process = synchronized(BOUNDED_PROCESS_LAUNCH_MUTEX) {
        launchBoundedProcess(command, arguments, workingDirectory, standardInput.size)
    }
    let job = try { createExampleProcessJob(process) } catch (error: Exception) {
        try { process.terminate(force: true) } catch (_: Exception) {}
        throw error
    }
    let group = try { boundedProcessGroupWithReader(process, remainingMilliseconds(started, timeoutMilliseconds), job) }
        catch (error: Exception) {
        terminateBoundedProcessTree(process, 0, job)
        throw error
    }
    let state = AtomicInt64(0)
    let expiredFlag = AtomicBool(false)
    let watchdog = spawn {
        while (state.load() == 0 && !expiredFlag.load()) {
            if (expired(started, timeoutMilliseconds)) {
                // Claiming the timeout state here is what makes the tree cleanup
                // below correct: if a bounded read expired first, the state is still
                // 0, and without this claim completion would later be recorded as
                // normal and the escaped descendant would never be killed.
                if (state.compareAndSwap(0, 2)) {
                    expiredFlag.store(true)
                    terminateBoundedProcessTree(process, group, job)
                }
                break
            }
            sleep(Duration.millisecond * BOUNDED_PROCESS_POLL_MILLISECONDS)
        }
    }
    let standardOutput = spawn { => readBoundedProcessStream(process.stdOutPipe,
        outputLimit) }
    let standardError = spawn { => readBoundedProcessStream(process.stdErrPipe,
        BOUNDED_PROCESS_OUTPUT_BYTES) }
    try {
        process.stdInPipe.write("\n".toArray())
        process.stdInPipe.write(standardInput)
        process.stdInPipe.flush()
    } catch (_: Exception) {
        terminateBoundedProcessTree(process, group, job)
    }
    // The reads must be bounded too, not just the watchdog. `readBoundedProcessStream`
    // ends at EOF, and EOF requires EVERY writer of the inherited pipe to close it.
    // A descendant that escapes the supervisor's process group (for example a
    // `setsid` process, or anything that daemonises) survives the group kill, keeps
    // the pipe open, and would otherwise block the caller for as long as that
    // descendant lives -- measured at 45 s for a 2 s timeout before this bound was
    // added. Bounding the read makes the timeout total, which is what the caller
    // was promised.
    // A fresh clock read can land past the deadline even after `expired` was false,
    // and `Future.get(Duration.Zero)` waits without a timeout, so a nonpositive
    // budget must be treated as expiration rather than passed through. One read of
    // the clock decides it.
    func awaitRead(future: Future<(Array<Byte>, Int64)>): (Array<Byte>, Int64) {
        let remainingMs = remainingMilliseconds(started, timeoutMilliseconds)
        if (remainingMs <= 0) { return (Array<Byte>(), -1) }
        try {
            future.get(Duration.millisecond * remainingMs)
        } catch (_: Exception) {
            (Array<Byte>(), -1)
        }
    }
    var readExpired = false
    var output = awaitRead(standardOutput)
    if (output[1] < 0) {
        readExpired = true
        output = (Array<Byte>(), 0)
    }
    var error = awaitRead(standardError)
    if (error[1] < 0) {
        readExpired = true
        error = (Array<Byte>(), 0)
    }
    // `process.wait()` is the wait on the supervisor (`bash`), whose script ends
    // with `wait "$child"`. When the group kill misses a child that escaped the
    // group, the supervisor itself never exits and this call would block past the
    // timeout -- the same unbounded-wait class as the reads above. Collecting the
    // status in a bounded future makes the timeout total here too: on expiry the
    // caller reports 124 and the supervisor is terminated by the watchdog path.
    let statusReader: Future<Int64> = spawn {
        try {
            process.wait()
        } catch (_: Exception) {
            -1
        }
    }
    // Expiry is tracked separately from the code: a program that legitimately exits
    // 124 must stay an ordinary exit code (and be reported as such), not be turned
    // into a timeout. A status-wait that merely *expired* means the child is still
    // alive at the deadline, which is the timeout condition.
    var statusExpired = false
    var exitCode: Int64 = 124
    if (expired(started, timeoutMilliseconds)) {
        statusExpired = true
    } else {
        let remainingMs = remainingMilliseconds(started, timeoutMilliseconds)
        if (remainingMs <= 0) {
            statusExpired = true
        } else {
            try {
                exitCode = statusReader.get(Duration.millisecond * remainingMs)
            } catch (_: Exception) {
                statusExpired = true
            }
        }
    }
    // Record completion only when nothing has already claimed the operation and no
    // bounded wait expired. A read or a status wait that expired means the call did
    // NOT finish inside the timeout, so the tree is terminated first: a descendant
    // that escaped the process group could otherwise keep running while the caller
    // is told 124. A child that exited 124 by itself is NOT a timeout and keeps its
    // own code.
    let expiredOverall = readExpired || statusExpired
    var completed = false
    if (!expiredOverall) {
        completed = state.compareAndSwap(0, 1)
    }
    if (!completed) {
        if (state.compareAndSwap(0, 2)) { terminateBoundedProcessTree(process, group, job) }
        expiredFlag.store(true)
    } else {
        let _ = closeExampleProcessJob(job)
    }
    watchdog.get()
    (if (completed && !expiredOverall) { exitCode } else { 124 }, output[0], error[0])
}

// Highlight-only JSONL transport. One caller owns it and sends one request at a time.
// Reuses the bounded supervisor's process-group / Windows job cleanup, not a sandbox.
internal class HighlightWorkerProcess {
    private let process: SubProcess
    private let group: Int64
    private let job: CPointer<Unit>
    private let failed: AtomicBool
    private let closed = AtomicBool(false)
    private let stderrReader: Future<Unit>

    init(command: String, arguments: Array<String>, environment: Map<String, String>) {
        let child = synchronized(BOUNDED_PROCESS_LAUNCH_MUTEX) {
            launchBoundedProcess(command, arguments, None<Path>, -1, environment: environment)
        }
        let childJob = try { createExampleProcessJob(child) } catch (error: Exception) {
            try { child.terminate(force: true) } catch (_: Exception) {}
            throw error
        }
        let childGroup = try { boundedProcessGroupWithReader(child, 5000, childJob) }
            catch (error: Exception) { terminateBoundedProcessTree(child, 0, childJob); throw error }
        this.process = child; this.job = childJob; this.group = childGroup
        let failureFlag = AtomicBool(false)
        this.failed = failureFlag
        this.stderrReader = spawn {
            let buffer = Array<Byte>(8192, repeat: 0)
            var total: Int64 = 0
            try {
                var count = child.stdErrPipe.read(buffer)
                while (count > 0) {
                    total += count
                    if (total > 8192) {
                        failureFlag.store(true)
                        // exchange observes failure; close's CAS alone owns the job handle.
                        break
                    }
                    count = child.stdErrPipe.read(buffer)
                }
            } catch (_: Exception) { failureFlag.store(true) }
        }
        try { releaseHighlightWorker(child) } catch (error: Exception) { close(); throw error }
    }

    func exchange(request: String, cancelled: () -> Bool): String {
        let started = MonoTime.now()
        let ready = AtomicBool(false)
        let response = spawn {
            try {
            process.stdInPipe.write(request.toArray())
            process.stdInPipe.flush()
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(8192, repeat: 0)
            var count = process.stdOutPipe.read(buffer)
            while (count > 0) {
                if (count > EXTERNAL_HIGHLIGHT_OUTPUT_BYTES + 1 - bytes.size) {
                    throw IllegalArgumentException("highlight output limit")
                }
                var complete = false
                for (index in 0..count) {
                    if (buffer[index] == b'\n') {
                        if (index != count - 1) { throw IllegalArgumentException("extra highlight response") }
                        complete = true
                    }
                    bytes.add(buffer[index])
                }
                if (complete) { return String.fromUtf8(bytes.toArray()) }
                count = process.stdOutPipe.read(buffer)
            }
            throw IllegalStateException("highlight worker EOF")
            } finally { ready.store(true) }
        }
        try {
            while (true) {
                if (cancelled() || failed.load() || expired(started, 5000)) {
                    throw IllegalStateException("highlight worker cancelled, failed or timed out")
                }
                if (ready.load()) { return response.get() }
                sleep(Duration.millisecond * 10)
            }
            throw IllegalStateException("highlight worker stopped")
        } catch (error: Exception) { close(); throw error }
    }

    func close(): Unit {
        if (!closed.compareAndSwap(false, true)) { return }
        terminateBoundedProcessTree(process, group, job)
        let waiter = spawn { => process.wait() }
        try { let _ = waiter.get(Duration.second) } catch (_: Exception) {}
        try { stderrReader.get(Duration.second) } catch (_: Exception) {}
    }
}

private func releaseHighlightWorker(process: SubProcess): Unit {
    process.stdInPipe.write("\n".toArray()); process.stdInPipe.flush()
}

