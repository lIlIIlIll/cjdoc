package cjdoc

import std.collection.*
import std.fs.*
import std.io.{InputStream}
import std.math.*
import std.process.*
import std.sync.*
import std.time.*

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

// The run-mode shape is a parameterless `main`, which is how Cangjie requires it to be
// declared: `func main()` is a hard error. `syntheticExampleSource()` keeps the
// statement-only compile probe, so the two builders share only the prologue. An
// example body that references `args` therefore cannot compile.
internal func exampleProgramSource(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget): String {
    let out = StringBuilder()
    if (!unit.packageName.isEmpty()) { out.append("package ${unit.packageName}\n\n") }
    for (spelling in unit.imports) { out.append(spelling); out.append("\n") }
    if (!unit.imports.isEmpty()) { out.append("\n") }
    out.append("main(): Unit {\n")
    for (line in target.code.split("\n")) {
        out.append("    "); out.append(line); out.append("\n")
    }
    out.append("}\n")
    out.toString()
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

// `state` is the single arbiter of the outcome: 0 running, 1 finished normally,
// 2 terminated by the watchdog. The exit code of a force-killed child is not portable,
// so it is never inspected. The watchdog lingers at most one poll interval past the end
// of the run, which keeps the serial gate schedule free of stray threads.
private func executeExampleProgram(executable: Path): ExampleProcessResult {
    let process = launch(executable.toString(), [], stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    let state = AtomicInt64(0)
    let watchdog = spawn {
        var waited: Int64 = 0
        while (waited < MAX_EXAMPLE_RUN_MILLISECONDS && state.load() == 0) {
            sleep(Duration.millisecond * EXAMPLE_RUN_POLL_MILLISECONDS)
            waited += EXAMPLE_RUN_POLL_MILLISECONDS
        }
        if (state.compareAndSwap(0, 2)) { process.terminate(force: true) }
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
    temporary: Path): ?Path {
    let label = exampleLabel(target.symbol, target.title)
    try {
        let sourcePaths = stageExampleSources(unit, temporary)
        if (sourcePaths.isEmpty()) {
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3038",
                "@example '${label}' could not stage its source context")
            return None
        }
        File.writeTo(generated, exampleProgramSource(unit, target).toArray())
        let (exitCode, stdout, stderr) = executeWithOutput("cjc",
            exampleCompilerArguments(unit, target, generated,
                temporary.join(EXAMPLE_RUN_OUTPUT_BASE), sourcePaths: sourcePaths,
                staticExecutable: true),
            workingDirectory: Some(temporary))
        if (exitCode != 0) {
            // A missing linker is an environment gap, so this is CJDOC3038 rather than
            // a CJDOC3030 blamed on the documentation.
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3038",
                "@example '${label}' could not be built as an executable: ${exampleFailureDetail(compilerOutput(stdout, stderr, generated, temporary), exitCode)}")
            return None
        }
        match (findExampleExecutable(temporary)) {
            case Some(executable) => executable
            case None =>
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3038",
                    "@example '${label}' could not be built as an executable: cjc produced no ${EXAMPLE_RUN_OUTPUT_BASE} artifact")
                None
        }
    } catch (error: Exception) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3038",
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
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3037",
            "@example '${label}' exceeded the ${MAX_EXAMPLE_RUN_MILLISECONDS}ms run limit and was terminated")
        return
    }
    if (result.standardOutputBytes > MAX_EXAMPLE_RUN_OUTPUT_BYTES ||
        result.standardErrorBytes > MAX_EXAMPLE_RUN_OUTPUT_BYTES) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3039",
            "@example '${label}' produced ${result.standardOutputBytes}/${result.standardErrorBytes} bytes, above the ${MAX_EXAMPLE_RUN_OUTPUT_BYTES}-byte run output limit")
        return
    }
    // An uncaught exception report goes to stderr and embeds absolute temporary paths,
    // so it is normalised and bounded before being quoted.
    let standardError = normalizeExampleOutput(decodedCompilerOutput(result.standardError),
        generated, temporary)
    if (result.exitCode != 0) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3035",
            "@example '${label}' failed at runtime (exit code ${result.exitCode}): ${standardError}")
        return
    }
    match (target.expectedOutput) {
        case Some(expected) =>
            let actual = normalizeExampleRunOutput(decodedCompilerOutput(result.standardOutput))
            if (actual != expected) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3036",
                    "@example '${label}' output mismatch: expected ${boundedCompilerOutput(expected)}, got ${boundedCompilerOutput(actual)}")
            }
        case None => ()
    }
}

// Reached only after a successful compile, so a `must-fail` example never runs and a
// passing compile is a precondition of `run`.
internal func runExampleTarget(documentation: DocumentationSet, unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget, generated: Path, temporary: Path): Unit {
    let label = exampleLabel(target.symbol, target.title)
    match (buildExampleExecutable(documentation, unit, target, generated, temporary)) {
        case Some(executable) =>
            try {
                reportExampleRunOutcome(documentation, target, label,
                    executeExampleProgram(executable), generated, temporary)
            } catch (error: Exception) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3038",
                    "@example '${label}' could not be executed: ${error.message}")
            }
        case None => ()
    }
}
