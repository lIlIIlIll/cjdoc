package cjdoc

import std.collection.*
import std.fs.*
import std.io.{InputStream}
import std.math.*
import std.process.*
import std.sync.*
import std.time.*

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

internal func executeWithBoundedOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None): (Int64, Array<Byte>, Array<Byte>) {
    let process = launch(command, arguments, workingDirectory: workingDirectory,
        stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe)
    let state = AtomicInt64(0)
    let watchdog = spawn {
        var waited: Int64 = 0
        while (waited < BOUNDED_PROCESS_TIMEOUT_MILLISECONDS && state.load() == 0) {
            sleep(Duration.millisecond * BOUNDED_PROCESS_POLL_MILLISECONDS)
            waited += BOUNDED_PROCESS_POLL_MILLISECONDS
        }
        if (state.compareAndSwap(0, 2)) { process.terminate(force: true) }
    }
    let standardOutput = spawn { => readBoundedProcessStream(process.stdOutPipe,
        BOUNDED_PROCESS_OUTPUT_BYTES) }
    let standardError = spawn { => readBoundedProcessStream(process.stdErrPipe,
        BOUNDED_PROCESS_OUTPUT_BYTES) }
    let output = standardOutput.get()
    let error = standardError.get()
    let exitCode = process.wait()
    let completed = state.compareAndSwap(0, 1)
    watchdog.get()
    if (!completed && state.load() == 2) {
        return (exitCode, output[0], error[0])
    }
    (exitCode, output[0], error[0])
}
