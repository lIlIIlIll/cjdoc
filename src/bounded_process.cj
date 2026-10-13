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
private func boundedProcessGroup(process: SubProcess): Int64 {
    let buffer = Array<Byte>(1, repeat: 0)
    var pid: Int64 = 0
    var count: Int64 = 0
    while (process.stdOutPipe.read(buffer) == 1) {
        if (buffer[0] == b'\n' && pid > 0) { return pid }
        if (buffer[0] < b'0' || buffer[0] > b'9' || count >= 10) { break }
        pid = pid * 10 + Int64(buffer[0] - b'0')
        count++
    }
    throw IllegalStateException("process supervisor did not provide an isolated process group")
}

@When[os == "Windows"]
private func boundedProcessGroup(process: SubProcess): Int64 {
    let _ = process
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

internal func executeWithBoundedOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None,
    timeoutMilliseconds!: Int64 = BOUNDED_PROCESS_TIMEOUT_MILLISECONDS,
    standardInput!: Array<Byte> = [], outputLimit!: Int64 = BOUNDED_PROCESS_OUTPUT_BYTES): (Int64, Array<Byte>, Array<Byte>) {
    let process = launchBoundedProcess(command, arguments, workingDirectory, standardInput.size)
    let job = try { createExampleProcessJob(process) } catch (error: Exception) {
        try { process.terminate(force: true) } catch (_: Exception) {}
        throw error
    }
    let group = try { boundedProcessGroup(process) } catch (error: Exception) {
        terminateBoundedProcessTree(process, 0, job)
        throw error
    }
    let state = AtomicInt64(0)
    let watchdog = spawn {
        var waited: Int64 = 0
        while (waited < timeoutMilliseconds && state.load() == 0) {
            sleep(Duration.millisecond * BOUNDED_PROCESS_POLL_MILLISECONDS)
            waited += BOUNDED_PROCESS_POLL_MILLISECONDS
        }
        if (state.compareAndSwap(0, 2)) { terminateBoundedProcessTree(process, group, job) }
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
    let deadline = Duration.millisecond * timeoutMilliseconds
    let output = try {
        standardOutput.get(deadline)
    } catch (_: Exception) {
        (Array<Byte>(), 0)
    }
    let error = try {
        standardError.get(deadline)
    } catch (_: Exception) {
        (Array<Byte>(), 0)
    }
    let exitCode = process.wait()
    let completed = state.compareAndSwap(0, 1)
    if (completed) { let _ = closeExampleProcessJob(job) }
    watchdog.get()
    (if (completed) { exitCode } else { 124 }, output[0], error[0])
}
