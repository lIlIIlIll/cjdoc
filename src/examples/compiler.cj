protected package cjdoc.examples

import cjdoc.binding.DocumentationSet
import cjdoc.documentation.DocumentationQualityConfig
import cjdoc.process.executeWithBoundedOutput
import std.collection.*
import std.env.*
import std.fs.*

private let MAX_EXAMPLE_COMPILER_OUTPUT_BYTES: Int64 = 8192

private func exampleFailureSeverity(config: DocumentationQualityConfig): ?String {
    match (config.ruleSeverity("example-not-compiling")) {
        case Some(value) => if (value == "off") { None } else { Some(value) }
        case None => Some("error")
    }
}

internal func decodedCompilerOutput(bytes: Array<Byte>): String {
    try { String.fromUtf8(bytes) } catch (_: Exception) { "<compiler output was not valid UTF-8>" }
}

internal func boundedCompilerOutput(value: String): String {
    let text = value.trimAscii()
    if (text.toArray().size <= MAX_EXAMPLE_COMPILER_OUTPUT_BYTES) { return text }
    let out = StringBuilder()
    var used: Int64 = 0
    for (line in text.split("\n")) {
        let separator = if (used == 0) { 0 } else { 1 }
        let cost = separator + line.toArray().size
        if (used + cost > MAX_EXAMPLE_COMPILER_OUTPUT_BYTES) { break }
        if (separator > 0) { out.append("\n") }
        out.append(line)
        used += cost
    }
    out.append("\n... compiler output truncated")
    out.toString()
}

// Path substitution keeps gate diagnostics deterministic and attributable: the
// generated file name marks a failure inside the example, and the temporary
// directory name is random on every run.
internal func normalizeExampleOutput(value: String, generated: Path,
    temporary: Path): String {
    boundedCompilerOutput(value.replace(generated.toString(), "<generated-example>")
        .replace(temporary.toString(), "<temporary>"))
}

internal func exampleFailureDetail(outputText: String, exitCode: Int64): String {
    if (outputText.isEmpty()) { "compiler exited with status ${exitCode}" } else { outputText }
}

internal func compilerOutput(stdout: Array<Byte>, stderr: Array<Byte>, generated: Path,
    temporary: Path): String {
    let standardOutput = decodedCompilerOutput(stdout)
    let errorOutput = decodedCompilerOutput(stderr)
    let combined = if (standardOutput.isEmpty()) { errorOutput } else if (errorOutput.isEmpty()) {
        standardOutput
    } else { standardOutput + "\n" + errorOutput }
    normalizeExampleOutput(combined, generated, temporary)
}

// A `must-fail` pin is only satisfied by a failure the compiler attributed to the
// generated example file. A rejected compiler option or an uncompilable package also
// exits non-zero, but names no source file, so it must not be credited to the pin.
private func judgeFailedCompile(documentation: DocumentationSet,
    target: ExampleCompilationTarget, outputText: String, exitCode: Int64,
    failureSeverity: ?String): Unit {
    let label = exampleLabel(target.symbol, target.title)
    let detail = exampleFailureDetail(outputText, exitCode)
    if (target.expectsFailure) {
        if (!outputText.contains("<generated-example>")) {
            // The context failure keeps its own code; the pin is additionally refused,
            // because an uncompilable package would otherwise satisfy `must-fail`.
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
                "declaring package could not be compiled for @example '${label}': ${detail}")
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3070",
                "@example '${label}' pinned to fail did not fail inside the example: ${detail}")
        } else {
            match (target.failureContains) {
                case Some(fragment) => if (!outputText.contains(fragment)) {
                    addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3070",
                        "@example '${label}' failed without the pinned message '${fragment}'")
                }
                case None => ()
            }
        }
        return
    }
    let attributed = outputText.contains("<generated-example>")
    let code = if (attributed) { "CJDOC3030" } else { "CJDOC3031" }
    let prefix = if (attributed) {
        "@example '${label}' failed to compile"
    } else {
        "declaring package could not be compiled for @example '${label}'"
    }
    let severity = if (attributed) { failureSeverity } else { Some("error") }
    match (severity) {
        case Some(value) => addExampleDiagnostic(documentation, target.symbol, value, code,
            "${prefix}: ${detail}")
        case None => ()
    }
}

private func compileExampleTarget(documentation: DocumentationSet,
    unit: ExampleCompilationUnit, target: ExampleCompilationTarget,
    preparation: ExampleDependencyPreparation,
    failureSeverity: ?String): Unit {
    let label = exampleLabel(target.symbol, target.title)
    let packageArtifacts = preparation.artifacts
    if (unit.sourceLimitExceeded || unit.sourceOrigins.isEmpty()) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
            "cannot prepare the source context for @example '${label}'")
        if (target.pinned) {
            reportPinnedExampleSkipped(documentation, target.symbol, label,
                "the declaring package sources could not be prepared")
        }
        return
    }
    if (!preparation.failure.isEmpty()) {
        judgeFailedCompile(documentation, target, preparation.failure, 1,
            failureSeverity)
        return
    }
    let temporary = try {
        Directory.createTemp(getTempDirectory())
    } catch (_: Exception) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
            "cannot create a temporary directory for @example '${label}'")
        if (target.pinned) {
            reportPinnedExampleSkipped(documentation, target.symbol, label,
                "no temporary directory could be created")
        }
        return
    }
    let generated = temporary.join("__cjdoc_example.cj")
    try {
        let (sourcePaths, _) = stageExampleSources(unit, temporary)
        if (sourcePaths.isEmpty()) {
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
                "cannot stage the source context for @example '${label}'")
            if (target.pinned) {
                reportPinnedExampleSkipped(documentation, target.symbol, label,
                    "the declaring package sources could not be staged")
            }
        } else {
            let output = temporary.join("__cjdoc_example.a")
            File.writeTo(generated, syntheticExampleSource(unit, target).toArray())
            let (exitCode, stdout, stderr) = executeWithBoundedOutput("cjc",
                exampleCompilerArguments(documentation, unit, target, generated, output,
                    sourcePaths: sourcePaths, staticExecutable: false,
                    packageArtifacts: packageArtifacts),
                workingDirectory: Some(temporary))
            if (exitCode != 0) {
                judgeFailedCompile(documentation, target,
                    compilerOutput(stdout, stderr, generated, temporary), exitCode,
                    failureSeverity)
            } else if (target.expectsFailure) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3070",
                    "@example '${label}' is pinned to fail but compiled successfully")
            } else if (target.execute) {
                runExampleTarget(documentation, unit, target, generated, temporary,
                    packageArtifacts)
            }
        }
    } catch (error: Exception) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
            "could not start cjc for @example '${label}': ${error.message}")
        if (target.pinned) {
            reportPinnedExampleSkipped(documentation, target.symbol, label, "cjc could not be started")
        }
    } finally {
        try { let _ = removeIfExists(temporary, recursive: true) } catch (_: Exception) {}
    }
}

// Validated flags contain no whitespace, so separators preserve argv boundaries.
private func exampleCompilerOptionsKey(options: Array<String>): String {
    let key = StringBuilder()
    for (option in options) { key.append(option); key.append("\n") }
    key.toString()
}

private func compileExampleUnit(documentation: DocumentationSet,
    unit: ExampleCompilationUnit, failureSeverity: ?String): Unit {
    let (required, requirementFailure) = requiredExamplePackages(documentation, unit)
    let preparations = HashMap<String, ExampleDependencyPreparation>()
    try {
        for (target in unit.targets) {
            let key = exampleCompilerOptionsKey(target.compilerOptions)
            let preparation = match (preparations.get(key)) {
                case Some(value) => value
                case None =>
                    let value = prepareExampleDependencies(documentation, required,
                        requirementFailure, target.compilerOptions)
                    preparations[key] = value
                    value
            }
            compileExampleTarget(documentation, unit, target, preparation,
                failureSeverity)
        }
    } finally {
        for ((_, preparation) in preparations) { releaseExampleDependencies(preparation) }
    }
}

protected func compileDocumentationExamples(documentation: DocumentationSet,
    audience: String, qualityConfig: DocumentationQualityConfig): Unit {
    let failureSeverity = exampleFailureSeverity(qualityConfig)
    for (unit in collectExampleUnits(documentation, audience)) {
        compileExampleUnit(documentation, unit, failureSeverity)
    }
}
