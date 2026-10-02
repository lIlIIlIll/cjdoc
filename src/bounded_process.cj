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
    workingDirectory: ?Path): SubProcess {
    let wrapperArguments = ArrayList<String>()
    wrapperArguments.add("-c")
    // The child blocks until its isolated group has been recorded by the parent.
    wrapperArguments.add("set -m; (IFS= read -r release; exec \"$@\" </dev/null) <&0 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\"")
    wrapperArguments.add("cjdoc-process-supervisor")
    wrapperArguments.add(command)
    wrapperArguments.add(all: arguments)
    launch("/bin/bash", wrapperArguments.toArray(), workingDirectory: workingDirectory,
        stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
}

@When[os == "Windows"]
private func launchBoundedProcess(command: String, arguments: Array<String>,
    workingDirectory: ?Path): SubProcess {
    let script = StringBuilder()
    script.append("$ErrorActionPreference='Stop'; if ([Console]::In.Read() -lt 0) { exit 125 }; & '")
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
    timeoutMilliseconds!: Int64 = BOUNDED_PROCESS_TIMEOUT_MILLISECONDS): (Int64, Array<Byte>, Array<Byte>) {
    let process = launchBoundedProcess(command, arguments, workingDirectory)
    let job = try { createExampleProcessJob(process) } catch (error: Exception) {
        try { process.terminate(force: true) } catch (_: Exception) {}
        throw error
    }
    let group = try { boundedProcessGroup(process) } catch (error: Exception) {
        terminateBoundedProcessTree(process, 0, job)
        throw error
    }
    try {
        process.stdInPipe.write("\n".toArray())
        process.stdInPipe.flush()
    } catch (error: Exception) {
        terminateBoundedProcessTree(process, group, job)
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
        BOUNDED_PROCESS_OUTPUT_BYTES) }
    let standardError = spawn { => readBoundedProcessStream(process.stdErrPipe,
        BOUNDED_PROCESS_OUTPUT_BYTES) }
    let output = standardOutput.get()
    let error = standardError.get()
    let exitCode = process.wait()
    let completed = state.compareAndSwap(0, 1)
    if (completed) { let _ = closeExampleProcessJob(job) }
    watchdog.get()
    (if (completed) { exitCode } else { 124 }, output[0], error[0])
}
