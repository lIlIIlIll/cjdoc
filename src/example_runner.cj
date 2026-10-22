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

// Keep these standalone: std.ast rejects foreign blocks in cjdoc's self-documentation pass.
@When[os == "Windows"]
@CallingConv[CDECL]
foreign func CreateJobObjectW(attributes: CPointer<Unit>,
    name: CPointer<UInt16>): CPointer<Unit>

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func SetInformationJobObject(job: CPointer<Unit>, infoClass: Int32,
    limits: VArray<Int64, $18>, length: UInt32): Int32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func OpenProcess(access: UInt32, inheritHandle: Int32,
    processId: UInt32): CPointer<Unit>

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func AssignProcessToJobObject(job: CPointer<Unit>,
    process: CPointer<Unit>): Int32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func CloseHandle(handle: CPointer<Unit>): Int32

// Run-mode limits. A `run` example is documentation, not a test suite: it must never
// turn `cjdoc check --check-examples` into an unbounded job, and its pinned output has
// to stay small enough to fit into a diagnostic.
private let MAX_EXAMPLE_RUN_MILLISECONDS: Int64 = 10000
private let MAX_EXAMPLE_RUN_OUTPUT_BYTES: Int64 = 65536
private let MAX_EXAMPLE_RUN_MEMORY_MB: Int64 = 2048
private let MAX_EXAMPLE_RUN_MEMORY_BYTES: Int64 = MAX_EXAMPLE_RUN_MEMORY_MB * 1024 * 1024
private let EXAMPLE_RUN_CHUNK_BYTES: Int64 = 8192
private let EXAMPLE_RUN_POLL_MILLISECONDS: Int64 = 50
internal func memoryBoundedCommand(command: String, arguments: Array<String>,
    memoryMb: Int64): (String, Array<String>) {
    if (memoryMb < 0) {
        throw IllegalArgumentException("memory limit must not be negative")
    }
    if (memoryMb == 0) { return (command, arguments) }
    let limit = memoryMb * 1024 * 1024
    for (candidate in ["/usr/bin/prlimit", "/bin/prlimit"]) {
        if (!exists(Path(candidate))) { continue }
        let wrapped = ArrayList<String>()
        wrapped.add("--as=" + limit.toString())
        wrapped.add("--")
        // Pin the child's OWN heap below the address-space cap. The child otherwise
        // inherits the ambient `cjHeapSize`, and when a caller raises that (to
        // document a large repository) the runtime is configured for a heap it can
        // never reserve under this `--as` cap: it fails with "allocate create page
        // failed! Out of Memory!" at the first allocation. A quarter of the cap
        // leaves room for the mapping overhead and equals the previous effective
        // value (2048MB cap, 512MB heap) when nothing is overridden.
        wrapped.add("/usr/bin/env")
        wrapped.add("cjHeapSize=" + (memoryMb / 4).toString() + "MB")
        wrapped.add(command)
        wrapped.add(all: arguments)
        return (candidate, wrapped.toArray())
    }
    // Running without an enforceable bound is not a safe fallback.
    throw IllegalStateException("address-space memory limit is unavailable on this platform")
}

// Shared by the watchdog and every wait so there is exactly one budget for the whole
// example run, taken from the MONOTONIC clock: a corrected system clock must not
// extend the limit or kill a healthy example early.
private func exampleRemainingMilliseconds(started: MonoTime, timeoutMilliseconds: Int64): Int64 {
    let left = timeoutMilliseconds - (MonoTime.now() - started).toMilliseconds()
    if (left < 0) { 0 } else { left }
}

private func exampleExpired(started: MonoTime, timeoutMilliseconds: Int64): Bool {
    exampleRemainingMilliseconds(started, timeoutMilliseconds) <= 0
}
// Deliberately distinct from the generated source (`__cjdoc_example.cj`) and the
// compile-only archive (`__cjdoc_example.a`) that share this temporary directory, so
// the artifact lookup cannot mistake either of them for the executable.
private let EXAMPLE_RUN_OUTPUT_BASE = "__cjdoc_run"
private let EXAMPLE_RUN_SUPERVISOR_ARGUMENT = "--cjdoc-run-example-supervisor"

// Cangjie entry points use a bare main(); func main() is invalid. Staging
// renames an active source entry point to preserve its original signature, so
// the generated wrapper can always own the executable entry point.
internal func exampleProgramSource(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget): String {
    let out = StringBuilder()
    if (!unit.packageName.isEmpty()) { out.append("package ${unit.packageName}\n\n") }
    for (spelling in target.imports) { out.append(spelling); out.append("\n") }
    if (!target.imports.isEmpty()) { out.append("\n") }
    appendExampleSupervisorSupport(out)
    out.append("main(): Unit {\n")
    out.append("    __cjdoc_runExampleSupervisor()\n")
    for (line in target.code.split("\n")) {
        out.append("    "); out.append(line); out.append("\n")
    }
    out.append("}\n")
    out.toString()
}

private func appendExampleSupervisorSupport(out: StringBuilder): Unit {
    out.append("""
        import std.env as __cjdoc_env
        import std.io as __cjdoc_io
        import std.process as __cjdoc_process
        @When[os != "Windows"]
        import std.posix as __cjdoc_posix

        private let __cjdoc_example_supervisor_argument = "${EXAMPLE_RUN_SUPERVISOR_ARGUMENT}"

        @When[os == "Windows"]
        private func __cjdoc_waitForExampleSupervisorRelease(): Unit {
            let releaseSignal = Array<Byte>(1, repeat: 0)
            if (__cjdoc_process.Process.current.stdIn.read(releaseSignal) != 1) {
                throw IllegalStateException("run-example supervisor was not released")
            }
        }

        @When[os != "Windows"]
        private func __cjdoc_waitForExampleSupervisorRelease(): Unit { () }

        private func __cjdoc_forwardExampleStream(stream: __cjdoc_io.InputStream,
            destination: __cjdoc_io.OutputStream): Unit {
            let buffer = Array<Byte>(8192, repeat: 0)
            var count = stream.read(buffer)
            while (count > 0) {
                let forwarded = Array<Byte>(count, repeat: 0)
                for (index in 0..count) { forwarded[index] = buffer[index] }
                destination.write(forwarded)
                destination.flush()
                count = stream.read(buffer)
            }
        }

        @When[os != "Windows"]
        private func __cjdoc_isolateExampleProcessGroup(): Unit {
            if (__cjdoc_posix.setpgid(0, 0) != 0) {
                throw IllegalStateException("could not isolate run-example process group")
            }
        }

        @When[os == "Windows"]
        private func __cjdoc_isolateExampleProcessGroup(): Unit { () }

        private func __cjdoc_runExampleSupervisor(): Unit {
            let commandLine = __cjdoc_env.getCommandLine()
            if (commandLine.size < 3 ||
                commandLine[1] != __cjdoc_example_supervisor_argument) { return }
            __cjdoc_waitForExampleSupervisorRelease()
            __cjdoc_isolateExampleProcessGroup()
            let example = __cjdoc_process.launch(commandLine[2], [],
                stdIn: __cjdoc_process.ProcessRedirect.Discard,
                stdOut: __cjdoc_process.ProcessRedirect.Pipe,
                stdErr: __cjdoc_process.ProcessRedirect.Pipe)
            let standardOutput = spawn { => __cjdoc_forwardExampleStream(
                example.stdOutPipe, __cjdoc_process.Process.current.stdOut) }
            let standardError = spawn { => __cjdoc_forwardExampleStream(
                example.stdErrPipe, __cjdoc_process.Process.current.stdErr) }
            standardOutput.get()
            standardError.get()
            __cjdoc_process.Process.current.exit(example.wait())
        }
        """)
}

// Keeps the first `limit` bytes but drains to EOF, so an example that prints more than
// the cap cannot deadlock on a full pipe; the second result is the true byte count.
private func readBoundedExampleStream(stream: InputStream,
    limit: Int64): (Array<Byte>, Int64) {
    let retained = ArrayList<Byte>()
    let buffer = Array<Byte>(EXAMPLE_RUN_CHUNK_BYTES, repeat: 0)
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

private class ExampleProcessResult {
    let exitCode: Int64
    let standardOutput: Array<Byte>
    let standardError: Array<Byte>
    let standardOutputBytes: Int64
    let standardErrorBytes: Int64
    let timedOut: Bool

    init(exitCode: Int64, standardOutput: Array<Byte>, standardError: Array<Byte>,
        standardOutputBytes: Int64, standardErrorBytes: Int64, timedOut: Bool) {
        this.exitCode = exitCode
        this.standardOutput = standardOutput
        this.standardError = standardError
        this.standardOutputBytes = standardOutputBytes
        this.standardErrorBytes = standardErrorBytes
        this.timedOut = timedOut
    }
}

// State is the single arbiter of the outcome: 0 running, 1 finished normally,
// 2 terminated by the watchdog. On Windows, closing the job handle also terminates
// descendants that outlive their immediate parent.
private func terminateExampleProcessDirectly(process: SubProcess): Unit {
    try { process.terminate(force: true) } catch (_: Exception) { () }
}

@When[os == "Windows"]
private func exampleSupervisorInputRedirect(): ProcessRedirect { ProcessRedirect.Pipe }

@When[os != "Windows"]
private func exampleSupervisorInputRedirect(): ProcessRedirect { ProcessRedirect.Discard }

@When[os == "Windows"]
internal func createExampleProcessJob(process: SubProcess,
    memoryBytes!: Int64 = 0): CPointer<Unit> {
    unsafe {
        let job = CreateJobObjectW(CPointer<Unit>(), CPointer<UInt16>())
        if (job.isNull()) {
            throw IllegalStateException("could not create run-example process job")
        }
        // JobObjectExtendedLimitInformation is 18 64-bit words on Windows x64;
        // LimitFlags is word 2 and JobMemoryLimit is word 15.
        if (memoryBytes < 0) {
            throw IllegalArgumentException("memory limit must not be negative")
        }
        let limitFlags: Int64 = if (memoryBytes > 0) { 0x2200 } else { 0x2000 }
        var extendedLimits: VArray<Int64, $18> =
            [0, 0, limitFlags, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        if (memoryBytes > 0) { extendedLimits[15] = memoryBytes }
        if (SetInformationJobObject(job, 9, inout extendedLimits, 144) == 0) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not configure run-example process job")
        }
        let processHandle = OpenProcess(0x0101, 0, UInt32(process.pid))
        if (processHandle.isNull()) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not open run-example supervisor process")
        }
        let assigned = AssignProcessToJobObject(job, processHandle) != 0
        let _ = CloseHandle(processHandle)
        if (!assigned) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not assign run-example supervisor to process job")
        }
        job
    }
}

@When[os != "Windows"]
internal func createExampleProcessJob(process: SubProcess,
    memoryBytes!: Int64 = 0): CPointer<Unit> {
    let _ = process
    let _ = memoryBytes
    CPointer<Unit>()
}

@When[os == "Windows"]
private func releaseExampleSupervisor(process: SubProcess): Unit {
    let releaseSignal = Array<Byte>(1, repeat: 0)
    process.stdInPipe.write(releaseSignal)
    process.stdInPipe.flush()
}

@When[os != "Windows"]
private func releaseExampleSupervisor(process: SubProcess): Unit {
    let _ = process
}

@When[os == "Windows"]
internal func closeExampleProcessJob(job: CPointer<Unit>): Bool {
    if (job.isNull()) { return false }
    unsafe { CloseHandle(job) != 0 }
}

@When[os != "Windows"]
internal func closeExampleProcessJob(job: CPointer<Unit>): Bool {
    let _ = job
    false
}

@When[os != "Windows"]
private func terminateExampleProcessTree(process: SubProcess,
    job: CPointer<Unit>): Unit {
    let _ = job
    if (killpg(Int32(process.pid), SIGKILL) != 0) {
        terminateExampleProcessDirectly(process)
    }
}

@When[os == "Windows"]
private func terminateExampleProcessTree(process: SubProcess,
    job: CPointer<Unit>): Unit {
    if (!closeExampleProcessJob(job)) { terminateExampleProcessDirectly(process) }
}

@When[os == "Windows"]
private func launchExampleSupervisor(executable: Path): SubProcess {
    launch(executable.toString(), [EXAMPLE_RUN_SUPERVISOR_ARGUMENT, executable.toString()],
        stdIn: exampleSupervisorInputRedirect(), stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe)
}

@When[os != "Windows"]
private func launchExampleSupervisor(executable: Path): SubProcess {
    let (command, arguments) = memoryBoundedCommand(executable.toString(),
        [EXAMPLE_RUN_SUPERVISOR_ARGUMENT, executable.toString()], MAX_EXAMPLE_RUN_MEMORY_MB)
    launch(command, arguments, stdIn: exampleSupervisorInputRedirect(),
        stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
}

private func executeExampleProgram(executable: Path): ExampleProcessResult {
    let process = launchExampleSupervisor(executable)
    let job = try {
        createExampleProcessJob(process, memoryBytes: MAX_EXAMPLE_RUN_MEMORY_BYTES)
    } catch (error: Exception) {
        terminateExampleProcessDirectly(process)
        throw error
    }
    try {
        releaseExampleSupervisor(process)
    } catch (error: Exception) {
        if (!closeExampleProcessJob(job)) { terminateExampleProcessDirectly(process) }
        throw error
    }
    let state = AtomicInt64(0)
    // ONE absolute budget for the watchdog and all three waits, so the run limit
    // is the limit for the whole call rather than per stage (separate full waits
    // would allow roughly three times it).
    let started = MonoTime.now()
    let expiredFlag = AtomicBool(false)
    let watchdog = spawn {
        while (state.load() == 0 && !expiredFlag.load()) {
            if (exampleExpired(started, MAX_EXAMPLE_RUN_MILLISECONDS)) {
                // Claiming the timeout state is what keeps cleanup correct: if the
                // reads or the status wait expired first the state is still 0, and
                // without this claim completion would be recorded as normal and the
                // escaped example would keep running while the caller sees a
                // plain exit-code failure rather than a timeout.
                if (state.compareAndSwap(0, 2)) {
                    expiredFlag.store(true)
                    terminateExampleProcessTree(process, job)
                }
                break
            }
            sleep(Duration.millisecond * EXAMPLE_RUN_POLL_MILLISECONDS)
        }
    }
    let standardOutput = spawn { => readBoundedExampleStream(process.stdOutPipe,
        MAX_EXAMPLE_RUN_OUTPUT_BYTES) }
    let standardError = spawn { => readBoundedExampleStream(process.stdErrPipe,
        MAX_EXAMPLE_RUN_OUTPUT_BYTES) }
    // Bound every blocking stage by the run limit, exactly as bounded_process does.
    // Each of these ends at EOF or at the child's own exit, and an example that
    // escapes the example process group survives the group kill while keeping the
    // inherited pipes open or the supervisor waiting: without a deadline the caller
    // (and so the whole test process) blocks past the limit and the suite wedges
    // with no output -- issue #116.
    // Never pass an exhausted budget to `get`: `Future.get(Duration.Zero)` waits with
    // no timeout, and a fresh clock read can land past the deadline even after the
    // check above, so one read of the clock decides whether there is a budget at all.
    func awaitStream(future: Future<(Array<Byte>, Int64)>): (Array<Byte>, Int64) {
        let remainingMs = exampleRemainingMilliseconds(started, MAX_EXAMPLE_RUN_MILLISECONDS)
        if (remainingMs <= 0) { return (Array<Byte>(), -1) }
        try {
            future.get(Duration.millisecond * remainingMs)
        } catch (_: Exception) {
            (Array<Byte>(), -1)
        }
    }
    var readExpired = false
    var (outputBytes, outputTotal) = awaitStream(standardOutput)
    if (outputTotal < 0) {
        readExpired = true
        (outputBytes, outputTotal) = (Array<Byte>(), 0)
    }
    var (errorBytes, errorTotal) = awaitStream(standardError)
    if (errorTotal < 0) {
        readExpired = true
        (errorBytes, errorTotal) = (Array<Byte>(), 0)
    }
    // Expiry is tracked separately from the code: an example that exits 124 by
    // itself is an ordinary exit code and must keep its runtime-failure diagnostic
    // rather than be relabelled as exceeding the run limit.
    var statusExpired = false
    var exitCode: Int64 = 124
    let statusRemainingMs = exampleRemainingMilliseconds(started, MAX_EXAMPLE_RUN_MILLISECONDS)
    if (statusRemainingMs <= 0) {
        statusExpired = true
    } else {
        let statusReader: Future<Int64> = spawn {
            try {
                process.wait()
            } catch (_: Exception) {
                -1
            }
        }
        try {
            exitCode = statusReader.get(Duration.millisecond * statusRemainingMs)
        } catch (_: Exception) {
            statusExpired = true
        }
    }
    // A read or status wait that expired means the call did NOT finish inside the
    // limit, so the tree is terminated and the result is reported as a timeout even
    // if `process.wait()` later returned a normal code. A delayed watchdog alone
    // could otherwise be the only thing that would have claimed the timeout.
    let expiredOverall = readExpired || statusExpired
    var completed = false
    if (!expiredOverall) {
        completed = state.compareAndSwap(0, 1)
    }
    if (!completed) {
        if (state.compareAndSwap(0, 2)) { terminateExampleProcessTree(process, job) }
        expiredFlag.store(true)
    } else {
        let _ = closeExampleProcessJob(job)
    }
    watchdog.get()
    ExampleProcessResult(if (expiredOverall) { 124 } else { exitCode }, outputBytes, errorBytes,
        outputTotal, errorTotal, expiredOverall || state.load() == 2)
}

private func isRunnableExampleFile(path: Path): Bool {
    try { FileInfo(path).isRegular() } catch (_: Exception) { false }
}
@When[os == "Windows"]
private func exampleExecutableOutputPath(temporary: Path): Path {
    temporary.join("${EXAMPLE_RUN_OUTPUT_BASE}.exe")
}

@When[os != "Windows"]
private func exampleExecutableOutputPath(temporary: Path): Path {
    temporary.join(EXAMPLE_RUN_OUTPUT_BASE)
}

// Prefer the Windows executable suffix; other targets may emit their suffix via cjc.
private func findExampleExecutable(temporary: Path): ?Path {
    let suffixed = temporary.join("${EXAMPLE_RUN_OUTPUT_BASE}.exe")
    if (isRunnableExampleFile(suffixed)) { return Some(suffixed) }
    let literal = temporary.join(EXAMPLE_RUN_OUTPUT_BASE)
    if (isRunnableExampleFile(literal)) { return Some(literal) }
    let candidates = ArrayList<Path>()
    for (entry in Directory.readFrom(temporary)) {
        if (entry.name.startsWith("${EXAMPLE_RUN_OUTPUT_BASE}.") &&
            isRunnableExampleFile(entry.path)) {
            candidates.add(entry.path)
        }
    }
    if (candidates.size == 1) { Some(candidates[0]) } else { None }
}

private func buildExampleExecutable(documentation: DocumentationSet,
    unit: ExampleCompilationUnit, target: ExampleCompilationTarget, generated: Path,
    temporary: Path, packageArtifacts: Array<ExamplePackageArtifact>): ?Path {
    let label = exampleLabel(target.symbol, target.title)
    try {
        let (sourcePaths, _) = stageExampleSources(unit, temporary,
            forRun: true, cfgProfile: documentation.cfgProfile)
        if (sourcePaths.isEmpty()) {
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
                "@example '${label}' could not stage its source context")
            return None
        }
        File.writeTo(generated, exampleProgramSource(unit, target).toArray())
        let (exitCode, stdout, stderr) = executeWithBoundedOutput("cjc",
            exampleCompilerArguments(documentation, unit, target, generated,
                exampleExecutableOutputPath(temporary), sourcePaths: sourcePaths,
                staticExecutable: true,
                packageArtifacts: packageArtifacts),
            workingDirectory: Some(temporary))
        if (exitCode != 0) {
            // A missing linker is an environment gap, not a source failure.
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
                "@example '${label}' could not be built as an executable: ${exampleFailureDetail(compilerOutput(stdout, stderr, generated, temporary), exitCode)}")
            return None
        }
        match (findExampleExecutable(temporary)) {
            case Some(executable) => executable
            case None =>
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
                    "@example '${label}' could not be built as an executable: cjc produced no ${EXAMPLE_RUN_OUTPUT_BASE} artifact")
                None
        }
    } catch (error: Exception) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
            "@example '${label}' could not be built as an executable: ${error.message}")
        None
    }
}

// `println` contributes exactly one trailing newline, so both sides drop leading and
// trailing blank lines before being compared.
private func normalizeExampleRunOutput(value: String): String {
    trimExampleBlankLines(normalizeSourceNewlines(value))
}

private func reportExampleRunOutcome(documentation: DocumentationSet,
    target: ExampleCompilationTarget, label: String, result: ExampleProcessResult,
    generated: Path, temporary: Path): Unit {
    if (result.timedOut) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3073",
            "@example '${label}' exceeded the ${MAX_EXAMPLE_RUN_MILLISECONDS}ms run limit and was terminated")
        return
    }
    if (result.standardOutputBytes > MAX_EXAMPLE_RUN_OUTPUT_BYTES ||
        result.standardErrorBytes > MAX_EXAMPLE_RUN_OUTPUT_BYTES) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3075",
            "@example '${label}' produced ${result.standardOutputBytes}/${result.standardErrorBytes} bytes, above the ${MAX_EXAMPLE_RUN_OUTPUT_BYTES}-byte run output limit")
        return
    }
    // An uncaught exception report goes to stderr and embeds absolute temporary paths,
    // so it is normalised and bounded before being quoted.
    let standardError = normalizeExampleOutput(decodedCompilerOutput(result.standardError),
        generated, temporary)
    if (result.exitCode != 0) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3071",
            "@example '${label}' failed at runtime (exit code ${result.exitCode}): ${standardError}")
        return
    }
    match (target.expectedOutput) {
        case Some(expected) =>
            let actual = normalizeExampleRunOutput(decodedCompilerOutput(result.standardOutput))
            if (actual != expected) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3072",
                    "@example '${label}' output mismatch: expected ${boundedCompilerOutput(expected)}, got ${boundedCompilerOutput(actual)}")
            }
        case None => ()
    }
}

// Reached only after a successful compile, so a `must-fail` example never runs and a
// passing compile is a precondition of `run`.
internal func runExampleTarget(documentation: DocumentationSet, unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget, generated: Path, temporary: Path,
    packageArtifacts: Array<ExamplePackageArtifact>): Unit {
    let label = exampleLabel(target.symbol, target.title)
    match (buildExampleExecutable(documentation, unit, target, generated, temporary,
        packageArtifacts)) {
        case Some(executable) =>
            try {
                reportExampleRunOutcome(documentation, target, label,
                    executeExampleProgram(executable), generated, temporary)
            } catch (error: Exception) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
                    "@example '${label}' could not be executed (artifact extension '${executable.extensionName}'): ${error.message}")
            }
        case None => ()
    }
}
