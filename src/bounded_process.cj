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

private let BOUNDED_PROCESS_TIMEOUT_MILLISECONDS: Int64 = 120000
private let BOUNDED_PROCESS_OUTPUT_BYTES: Int64 = 8192
private let BOUNDED_PROCESS_CHUNK_BYTES: Int64 = 8192
private let BOUNDED_PROCESS_POLL_MILLISECONDS: Int64 = 50

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
    workingDirectory: ?Path, inputBytes: Int64): SubProcess {
    let wrapperArguments = ArrayList<String>()
    wrapperArguments.add("-c")
    // The child blocks until its isolated group has been recorded by the parent.
    // The count is formatted only from the caller byte array's size, never request text.
    // STS pipe streams expose no public close; forwarding exactly this count supplies EOF.
    // Disable inner job control so the stdin forwarder and target remain in that group.
    wrapperArguments.add("set -m; (set +m; IFS= read -r release; count=$1; shift; if [ \"$count\" = 0 ]; then exec \"$@\" </dev/null; else head -c \"$count\" | \"$@\"; fi) <&0 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\"")
    wrapperArguments.add("cjdoc-process-supervisor")
    wrapperArguments.add(inputBytes.toString())
    wrapperArguments.add(command)
    wrapperArguments.add(all: arguments)
    launch("/bin/bash", wrapperArguments.toArray(), workingDirectory: workingDirectory,
        stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
}

@When[os == "Windows"]
private func launchBoundedProcess(command: String, arguments: Array<String>,
    workingDirectory: ?Path, inputBytes: Int64): SubProcess {
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
private func boundedProcessGroup(process: SubProcess, timeoutMilliseconds: Int64): Int64 {
    // The supervisor writes one line naming the isolated group, and this read runs
    // BEFORE the watchdog is started, so it must carry its own deadline: a
    // supervisor that never prints would otherwise block here forever and the outer
    // `timeoutMilliseconds` could never fire. This is the same class of unbounded
    // read as the trailing stream reads below, and issue #116 stalled in exactly
    // the "child launches but never answers" state.
    let reader: Future<Int64> = spawn {
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
    // An exhausted budget must not become `Duration.Zero`, which waits forever.
    let pid = if (timeoutMilliseconds <= 0) {
        0
    } else {
        try {
            reader.get(Duration.millisecond * timeoutMilliseconds)
        } catch (_: Exception) {
            0
        }
    }
    if (pid <= 0) {
        throw IllegalStateException("process supervisor did not provide an isolated process group")
    }
    pid
}

@When[os == "Windows"]
private func boundedProcessGroup(process: SubProcess, timeoutMilliseconds: Int64): Int64 {
    let _ = (process, timeoutMilliseconds)
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

// The deadline helpers are shared by the handshake, the watchdog and every wait so
// there is exactly one budget for the whole call. An exhausted budget must NEVER be
// handed to `get`: `Future.get(Duration.Zero)` waits without any timeout, so
// clamping to zero would turn "already expired" into "wait forever".
private func expired(deadline: DateTime): Bool {
    (deadline - DateTime.now()).toMilliseconds() <= 0
}

private func remainingMilliseconds(deadline: DateTime): Int64 {
    let left = (deadline - DateTime.now()).toMilliseconds()
    if (left < 0) { 0 } else { left }
}

private func remainingDuration(deadline: DateTime): Duration {
    Duration.millisecond * remainingMilliseconds(deadline)
}

internal func executeWithBoundedOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None,
    timeoutMilliseconds!: Int64 = BOUNDED_PROCESS_TIMEOUT_MILLISECONDS,
    standardInput!: Array<Byte> = [], outputLimit!: Int64 = BOUNDED_PROCESS_OUTPUT_BYTES): (Int64, Array<Byte>, Array<Byte>) {
    // ONE absolute deadline for the whole call, established before the handshake.
    // The handshake previously received a full `timeoutMilliseconds` of its own and
    // the reads/status a second full budget, so a slow supervisor could stretch the
    // advertised bound to nearly twice its value.
    let deadline = DateTime.now() + Duration.millisecond * timeoutMilliseconds
    let process = launchBoundedProcess(command, arguments, workingDirectory, standardInput.size)
    let job = try { createExampleProcessJob(process) } catch (error: Exception) {
        try { process.terminate(force: true) } catch (_: Exception) {}
        throw error
    }
    let group = try { boundedProcessGroup(process, remainingMilliseconds(deadline)) } catch (error: Exception) {
        terminateBoundedProcessTree(process, 0, job)
        throw error
    }
    let state = AtomicInt64(0)
    let expiredFlag = AtomicBool(false)
    let watchdog = spawn {
        while (state.load() == 0 && !expiredFlag.load()) {
            if (expired(deadline)) {
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
    var readExpired = false
    let output = if (expired(deadline)) {
        readExpired = true
        (Array<Byte>(), 0)
    } else {
        try {
            standardOutput.get(remainingDuration(deadline))
        } catch (_: Exception) {
            // A read that expires means the call did NOT complete inside the timeout,
            // so record it: otherwise a child that already exited successfully could
            // let the status wait return 0 and the call would report success with
            // truncated output instead of 124.
            readExpired = true
            (Array<Byte>(), 0)
        }
    }
    let error = if (expired(deadline)) {
        readExpired = true
        (Array<Byte>(), 0)
    } else {
        try {
            standardError.get(remainingDuration(deadline))
        } catch (_: Exception) {
            readExpired = true
            (Array<Byte>(), 0)
        }
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
    let exitCode = if (expired(deadline)) {
        124
    } else {
        try {
            statusReader.get(remainingDuration(deadline))
        } catch (_: Exception) {
            124
        }
    }
    // Record completion only when nothing has already claimed the operation and no
    // bounded wait expired. A read or status that expired means the call did NOT
    // finish inside the timeout, so the tree is terminated first: a descendant that
    // escaped the process group could otherwise keep running while the caller is
    // told 124.
    var completed = false
    if (!readExpired && exitCode != 124) {
        completed = state.compareAndSwap(0, 1)
    }
    if (!completed) {
        if (state.compareAndSwap(0, 2)) { terminateBoundedProcessTree(process, group, job) }
        expiredFlag.store(true)
    } else {
        let _ = closeExampleProcessJob(job)
    }
    watchdog.get()
    (if (completed && !readExpired) { exitCode } else { 124 }, output[0], error[0])
}
