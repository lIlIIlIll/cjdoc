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

// Run-mode limits. A `run` example is documentation, not a test suite: it must never
// turn `cjdoc check --check-examples` into an unbounded job, and its pinned output has
// to stay small enough to fit into a diagnostic.
private let MAX_EXAMPLE_RUN_MILLISECONDS: Int64 = 10000
private let MAX_EXAMPLE_RUN_OUTPUT_BYTES: Int64 = 65536
private let EXAMPLE_RUN_CHUNK_BYTES: Int64 = 8192
private let EXAMPLE_RUN_POLL_MILLISECONDS: Int64 = 50
// Deliberately distinct from the generated source (`__cjdoc_example.cj`) and the
// compile-only archive (`__cjdoc_example.a`) that share this temporary directory, so
// the artifact lookup cannot mistake either of them for the executable.
private let EXAMPLE_RUN_OUTPUT_BASE = "__cjdoc_run"
private let EXAMPLE_RUN_SUPERVISOR_ARGUMENT = "--cjdoc-run-example-supervisor"

// Cangjie entry points use a bare `main()`; `func main()` is invalid. When the
// package already declares an entry point, staging replaces its body with a call to
// the generated example function instead of adding a second `main`.
internal func exampleProgramSource(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget, existingMain!: Bool = false): String {
    let out = StringBuilder()
    if (!unit.packageName.isEmpty()) { out.append("package ${unit.packageName}\n\n") }
    for (spelling in target.imports) { out.append(spelling); out.append("\n") }
    if (!target.imports.isEmpty()) { out.append("\n") }
    appendExampleSupervisorSupport(out)
    if (existingMain) {
        out.append("func __cjdoc_example_runner(): Unit {\n")
    } else {
        out.append("main(): Unit {\n")
    }
    out.append("    __cjdoc_runExampleSupervisor()\n")
    for (line in target.code.split("\n")) {
        out.append("    "); out.append(line); out.append("\n")
    }
    out.append("}\n")
    out.toString()
}

private func appendExampleSupervisorSupport(out: StringBuilder): Unit {
    out.append("""
        import std.env.{getCommandLine}
        import std.io.{InputStream, OutputStream}
        import std.process.{launch, Process, ProcessRedirect}
        import std.sync.*
        @When[os != "Windows"]
        import std.posix.{setpgid}

        private let __cjdoc_example_supervisor_argument = "${EXAMPLE_RUN_SUPERVISOR_ARGUMENT}"

        private func __cjdoc_forwardExampleStream(stream: InputStream,
            destination: OutputStream): Unit {
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
            if (setpgid(0, 0) != 0) {
                throw IllegalStateException("could not isolate run-example process group")
            }
        }

        @When[os == "Windows"]
        private func __cjdoc_isolateExampleProcessGroup(): Unit { () }

        private func __cjdoc_runExampleSupervisor(): Unit {
            let commandLine = getCommandLine()
            if (commandLine.size < 3 ||
                commandLine[1] != __cjdoc_example_supervisor_argument) { return }
            __cjdoc_isolateExampleProcessGroup()
            let example = launch(commandLine[2], [],
                stdIn: ProcessRedirect.Discard,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe)
            let standardOutput = spawn { => __cjdoc_forwardExampleStream(
                example.stdOutPipe, Process.current.stdOut) }
            let standardError = spawn { => __cjdoc_forwardExampleStream(
                example.stdErrPipe, Process.current.stdErr) }
            standardOutput.get()
            standardError.get()
            Process.current.exit(example.wait())
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

// state is the single arbiter of the outcome: 0 running, 1 finished normally,
// 2 terminated by the watchdog. The exit code of a force-killed child is not portable,
// so it is never inspected. The supervisor keeps the process-tree root alive while
// inherited output pipes remain open.
private func terminateExampleProcessDirectly(process: SubProcess): Unit {
    try { process.terminate(force: true) } catch (_: Exception) { () }
}

@When[os != "Windows"]
private func terminateExampleProcessTree(process: SubProcess): Unit {
    if (killpg(Int32(process.pid), SIGKILL) != 0) {
        terminateExampleProcessDirectly(process)
    }
}

@When[os == "Windows"]
private func terminateExampleProcessTree(process: SubProcess): Unit {
    try {
        let exitCode = execute("taskkill.exe", ["/F", "/T", "/PID", process.pid.toString()],
            stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.Discard,
            stdErr: ProcessRedirect.Discard)
        if (exitCode != 0) { terminateExampleProcessDirectly(process) }
    } catch (_: Exception) {
        terminateExampleProcessDirectly(process)
    }
}

private func executeExampleProgram(executable: Path): ExampleProcessResult {
    let process = launch(executable.toString(), [EXAMPLE_RUN_SUPERVISOR_ARGUMENT,
        executable.toString()], stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    let state = AtomicInt64(0)
    let watchdog = spawn {
        var waited: Int64 = 0
        while (waited < MAX_EXAMPLE_RUN_MILLISECONDS && state.load() == 0) {
            sleep(Duration.millisecond * EXAMPLE_RUN_POLL_MILLISECONDS)
            waited += EXAMPLE_RUN_POLL_MILLISECONDS
        }
        if (state.compareAndSwap(0, 2)) { terminateExampleProcessTree(process) }
    }
    let standardOutput = spawn { => readBoundedExampleStream(process.stdOutPipe,
        MAX_EXAMPLE_RUN_OUTPUT_BYTES) }
    let standardError = spawn { => readBoundedExampleStream(process.stdErrPipe,
        MAX_EXAMPLE_RUN_OUTPUT_BYTES) }
    let (outputBytes, outputTotal) = standardOutput.get()
    let (errorBytes, errorTotal) = standardError.get()
    let exitCode = process.wait()
    let completed = state.compareAndSwap(0, 1)
    watchdog.get()
    ExampleProcessResult(exitCode, outputBytes, errorBytes, outputTotal, errorTotal,
        !completed && state.load() == 2)
}

private func isRunnableExampleFile(path: Path): Bool {
    try { FileInfo(path).isRegular() } catch (_: Exception) { false }
}

// `-o` is honoured literally on Linux, while some targets append an executable suffix,
// so the artifact is located by listing the directory instead of building a
// platform-conditional name.
private func findExampleExecutable(temporary: Path): ?Path {
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
        let (sourcePaths, existingMain) = stageExampleSources(unit, temporary, forRun: true)
        if (sourcePaths.isEmpty()) {
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3074",
                "@example '${label}' could not stage its source context")
            return None
        }
        File.writeTo(generated, exampleProgramSource(unit, target,
            existingMain: existingMain).toArray())
        let (exitCode, stdout, stderr) = executeWithBoundedOutput("cjc",
            exampleCompilerArguments(documentation, unit, target, generated,
                temporary.join(EXAMPLE_RUN_OUTPUT_BASE), sourcePaths: sourcePaths,
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
                    "@example '${label}' could not be executed: ${error.message}")
            }
        case None => ()
    }
}
