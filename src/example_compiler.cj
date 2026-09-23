package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.process.*

// Example checking is opt-in because documentation snippets are often partial
// expressions rather than complete programs. These limits keep a malformed
// comment from turning a documentation check into an unbounded compiler job.
private let MAX_EXAMPLE_COUNT: Int64 = 256
private let MAX_EXAMPLE_CODE_BYTES: Int64 = 1024 * 1024
private let MAX_EXAMPLE_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
private let MAX_EXAMPLE_SOURCE_BYTES: Int64 = 128 * 1024 * 1024
private let MAX_EXAMPLE_COMPILER_OUTPUT_BYTES: Int64 = 8192

private class ExampleFence {
    let marker: String
    let length: Int64
    let language: String

    init(marker: String, length: Int64, language: String) {
        this.marker = marker
        this.length = length
        this.language = language
    }
}

private class ExampleExtraction {
    let cangjieBlocks = ArrayList<String>()
    let outputBlocks = ArrayList<String>()
}

private class ExampleSourceContext {
    let origin: SourceFileOrigin
    let packageName: String
    let imports = ArrayList<String>()

    init(origin: SourceFileOrigin, packageName: String, imports: Array<String>) {
        this.origin = origin
        this.packageName = packageName
        this.imports.add(all: imports)
    }
}

// One judged `@example`. `pinned` records that the author wrote a directive block,
// which turns every infrastructure skip into a visible CJDOC3034: a pin must never be
// satisfied by a check that silently did not happen.
internal class ExampleCompilationTarget {
    let symbol: SymbolDoc
    let title: String
    let code: String
    let pinned: Bool
    let expectsFailure: Bool
    let failureContains: ?String
    let compilerOptions: Array<String>
    let execute: Bool
    let expectedOutput: ?String

    init(symbol: SymbolDoc, title: String, code: String, pinned!: Bool = false,
        expectsFailure!: Bool = false, failureContains!: ?String = None,
        compilerOptions!: Array<String> = [], execute!: Bool = false,
        expectedOutput!: ?String = None) {
        this.symbol = symbol
        this.title = title
        this.code = code
        this.pinned = pinned
        this.expectsFailure = expectsFailure
        this.failureContains = failureContains
        this.compilerOptions = compilerOptions
        this.execute = execute
        this.expectedOutput = expectedOutput
    }
}

internal class ExampleCompilationUnit {
    let actualRoot: String
    let packageName: String
    let sourceOrigins = ArrayList<SourceFileOrigin>()
    let imports = ArrayList<String>()
    let targets = ArrayList<ExampleCompilationTarget>()
    var sourceBytes: Int64 = 0
    var sourceLimitExceeded = false

    init(actualRoot: String, packageName: String) {
        this.actualRoot = actualRoot
        this.packageName = packageName
    }

    func addSource(origin: SourceFileOrigin): Unit {
        for (existing in sourceOrigins) {
            if (existing.actualPath == origin.actualPath) { return }
        }
        let size = origin.capturedSource.toArray().size
        if (size > MAX_EXAMPLE_SOURCE_FILE_BYTES) {
            sourceLimitExceeded = true
            return
        }
        if (sourceBytes > MAX_EXAMPLE_SOURCE_BYTES - size) {
            sourceLimitExceeded = true
            return
        }
        sourceOrigins.add(origin)
        sourceBytes += size
    }

    func addImport(value: String): Unit {
        if (!value.isEmpty() && !imports.contains(value)) { imports.add(value) }
    }
}

private class ExampleCollectionState {
    let contexts: ArrayList<ExampleSourceContext>
    let units = ArrayList<ExampleCompilationUnit>()
    var count: Int64 = 0
    var limitReported = false

    init(contexts: ArrayList<ExampleSourceContext>) { this.contexts = contexts }
}

internal func trimExampleBlankLines(value: String): String {
    let normalized = normalizeSourceNewlines(value)
    let lines = normalized.split("\n")
    var first: Int64 = 0
    while (first < lines.size && lines[first].trimAscii().isEmpty()) { first++ }
    var last = lines.size
    while (last > first && lines[last - 1].trimAscii().isEmpty()) { last-- }
    if (first >= last) { return "" }
    let out = StringBuilder()
    var index = first
    while (index < last) {
        if (index > first) { out.append("\n") }
        out.append(lines[index])
        index++
    }
    out.toString()
}

private func exampleFenceLineValue(line: String): ?String {
    var leadingSpaces: Int64 = 0
    while (leadingSpaces < line.size && line[leadingSpaces] == b' ') { leadingSpaces++ }
    if (leadingSpaces > 3) { return None }
    let remainder = line[leadingSpaces..]
    if (!remainder.isEmpty() && remainder[0] != b'`' && remainder[0] != b'~') {
        return None
    }
    Some(remainder.trimAscii())
}

private func exampleFenceOpening(line: String): ?ExampleFence {
    let value = match (exampleFenceLineValue(line)) {
        case Some(candidate) => candidate
        case None => return None
    }
    if (value.isEmpty()) { return None }
    let marker = if (value[0] == b'`') { "`" } else if (value[0] == b'~') { "~" } else { return None }
    var length: Int64 = 0
    while (length < value.size && value[length] == marker[0]) { length++ }
    if (length < 3) { return None }
    let info = value[length..].trimAscii()
    if (marker == "`" && info.contains("`")) { return None }
    let fields = info.split(" ", 2, removeEmpty: true)
    let language = if (fields.isEmpty()) { "" } else { fields[0] }
    Some(ExampleFence(marker, length, language))
}

private func isExampleFenceClosing(line: String, fence: ExampleFence): Bool {
    let value = match (exampleFenceLineValue(line)) {
        case Some(candidate) => candidate
        case None => return false
    }
    if (!value.startsWith(fence.marker)) { return false }
    var length: Int64 = 0
    while (length < value.size && value[length] == fence.marker[0]) { length++ }
    length >= fence.length && value[length..].trimAscii().isEmpty()
}

// An empty `output` block is a real pin ("this example prints nothing"), so unlike a
// `cangjie` fence it is kept even when it trims down to nothing.
private func appendExtractedBlock(extraction: ExampleExtraction, fence: ExampleFence,
    code: StringBuilder): Unit {
    let content = trimExampleBlankLines(code.toString())
    if (fence.language == "cangjie") {
        if (!content.isEmpty()) { extraction.cangjieBlocks.add(content) }
    } else if (fence.language == "output") {
        extraction.outputBlocks.add(content)
    }
}

private func extractExampleCode(value: String): ExampleExtraction {
    let extraction = ExampleExtraction()
    var activeFence: ?ExampleFence = None
    var code = StringBuilder()
    var hasCode = false
    for (line in normalizeSourceNewlines(value).split("\n")) {
        match (activeFence) {
            case Some(fence) =>
                if (isExampleFenceClosing(line, fence)) {
                    appendExtractedBlock(extraction, fence, code)
                    activeFence = None
                    code = StringBuilder()
                    hasCode = false
                } else {
                    if (hasCode) { code.append("\n") }
                    code.append(line)
                    hasCode = true
                }
            case None =>
                match (exampleFenceOpening(line)) {
                    case Some(fence) =>
                        activeFence = Some(fence)
                        code = StringBuilder()
                    case None => ()
                }
        }
    }
    match (activeFence) {
        case Some(fence) => appendExtractedBlock(extraction, fence, code)
        case None => ()
    }
    extraction
}

private func joinedExampleCode(blocks: ArrayList<String>): String {
    let out = StringBuilder()
    var first = true
    for (block in blocks) {
        if (!first) { out.append("\n") }
        out.append(block)
        first = false
    }
    out.toString()
}

private func readExampleSourceContext(origin: SourceFileOrigin): ?ExampleSourceContext {
    Some(ExampleSourceContext(origin, origin.packageName, origin.imports))
}

private func collectExampleSourceContexts(documentation: DocumentationSet): ArrayList<ExampleSourceContext> {
    let contexts = ArrayList<ExampleSourceContext>()
    for (origin in documentation.sourceFileOrigins) {
        match (readExampleSourceContext(origin)) {
            case Some(context) => contexts.add(context)
            case None => ()
        }
    }
    contexts
}

private func sourceOriginForSymbol(documentation: DocumentationSet,
    symbol: SymbolDoc): ?SourceFileOrigin {
    for (origin in documentation.sourceFileOrigins) {
        if (origin.logicalPath == symbol.source.path) { return Some(origin) }
    }
    None
}

private func contextForOrigin(contexts: ArrayList<ExampleSourceContext>,
    origin: SourceFileOrigin): ?ExampleSourceContext {
    for (context in contexts) {
        if (context.origin.actualPath == origin.actualPath) { return Some(context) }
    }
    None
}

private func examplePackageName(symbol: SymbolDoc, contexts: ArrayList<ExampleSourceContext>,
    origin: SourceFileOrigin): String {
    match (contextForOrigin(contexts, origin)) {
        case Some(context) => if (context.packageName.isEmpty()) { symbol.packageName } else { context.packageName }
        case None => symbol.packageName
    }
}

private func findExampleUnit(units: ArrayList<ExampleCompilationUnit>, actualRoot: String,
    packageName: String): ?ExampleCompilationUnit {
    for (unit in units) {
        if (unit.actualRoot == actualRoot && unit.packageName == packageName) { return Some(unit) }
    }
    None
}

private func attachExampleSources(unit: ExampleCompilationUnit,
    contexts: ArrayList<ExampleSourceContext>, targetOrigin: SourceFileOrigin): Unit {
    for (context in contexts) {
        if (context.origin.actualRoot != unit.actualRoot) { continue }
        if (!context.packageName.isEmpty() && context.packageName != unit.packageName) { continue }
        unit.addSource(context.origin)
        for (spelling in context.imports) { unit.addImport(spelling) }
    }
    unit.addSource(targetOrigin)
}

internal func exampleLabel(symbol: SymbolDoc, title: String): String {
    if (!title.isEmpty()) { title } else { symbol.qualifiedName }
}

internal func addExampleDiagnostic(documentation: DocumentationSet, symbol: SymbolDoc,
    severity: String, code: String, message: String): Unit {
    documentation.diagnostics.add(Diagnostic(severity, code, message,
        source: symbol.source, symbolId: symbol.id))
}

private func reportPinnedExampleSkipped(documentation: DocumentationSet, symbol: SymbolDoc,
    label: String, reason: String): Unit {
    addExampleDiagnostic(documentation, symbol, "error", "CJDOC3034",
        "@example '${label}' is pinned but was not checked: ${reason}")
}

private func joinedDirectiveProblems(problems: ArrayList<String>): String {
    let out = StringBuilder()
    var first = true
    for (problem in problems) {
        if (!first) { out.append("; ") }
        out.append(problem)
        first = false
    }
    out.toString()
}

// Grammar and compiler-option allowlist problems merge into one CJDOC3033 so an author
// fixing a directive sees every mistake at once, before anything is spawned.
private func parseTagDirectives(tag: DocTag): (ExampleDirectives, Array<String>) {
    if (tag.directives.isEmpty()) { return (ExampleDirectives(), []) }
    let parsed = parseExampleDirectives(tag.directives)
    let (accepted, problems) = validateExampleFlags(parsed.flags.toArray())
    parsed.problems.add(all: problems)
    (parsed, accepted)
}

private func collectExampleForTag(documentation: DocumentationSet, state: ExampleCollectionState,
    symbol: SymbolDoc, tag: DocTag): Unit {
    let label = exampleLabel(symbol, tag.subject)
    let pinned = !tag.directives.isEmpty()
    let (directives, compilerOptions) = parseTagDirectives(tag)
    if (!directives.problems.isEmpty()) {
        addExampleDiagnostic(documentation, symbol, "error", "CJDOC3033",
            "@example '${label}' has invalid directives: ${joinedDirectiveProblems(directives.problems)} (accepted: must-pass, must-fail, run, error=\"…\", flags=\"…\")")
        return
    }
    let extraction = extractExampleCode(tag.description)
    if (extraction.cangjieBlocks.isEmpty()) {
        addExampleDiagnostic(documentation, symbol, "warning", "CJDOC3032",
            "@example '${label}' has no cangjie fenced code block")
        if (pinned) {
            reportPinnedExampleSkipped(documentation, symbol, label,
                "the example has no cangjie fenced code block")
        }
        return
    }
    let expectedOutput = match (extraction.outputBlocks.size) {
        case 0 => Option<String>.None
        case 1 => Some(extraction.outputBlocks[0])
        case _ =>
            addExampleDiagnostic(documentation, symbol, "error", "CJDOC3033",
                "@example '${label}' has more than one output block")
            return
    }
    if (expectedOutput.isSome() && !directives.execute) {
        addExampleDiagnostic(documentation, symbol, "error", "CJDOC3033",
            "@example '${label}' pins output without run")
        return
    }
    if (state.count >= MAX_EXAMPLE_COUNT) {
        if (!state.limitReported) {
            addExampleDiagnostic(documentation, symbol, "error", "CJDOC3031",
                "example compilation stopped after ${MAX_EXAMPLE_COUNT} examples")
            state.limitReported = true
        }
        if (pinned) {
            reportPinnedExampleSkipped(documentation, symbol, label,
                "the ${MAX_EXAMPLE_COUNT}-example check limit was reached")
        }
        return
    }
    let code = joinedExampleCode(extraction.cangjieBlocks)
    if (code.toArray().size > MAX_EXAMPLE_CODE_BYTES) {
        addExampleDiagnostic(documentation, symbol, "error", "CJDOC3031",
            "@example '${label}' exceeds the ${MAX_EXAMPLE_CODE_BYTES}-byte code limit")
        if (pinned) {
            reportPinnedExampleSkipped(documentation, symbol, label,
                "the example code exceeds the ${MAX_EXAMPLE_CODE_BYTES}-byte limit")
        }
        return
    }
    let origin = match (sourceOriginForSymbol(documentation, symbol)) {
        case Some(value) => value
        case None =>
            addExampleDiagnostic(documentation, symbol, "error", "CJDOC3031",
                "cannot find the source context for @example '${label}'")
            if (pinned) {
                reportPinnedExampleSkipped(documentation, symbol, label,
                    "the declaring source file could not be found")
            }
            return
    }
    let packageName = examplePackageName(symbol, state.contexts, origin)
    let unit = match (findExampleUnit(state.units, origin.actualRoot, packageName)) {
        case Some(value) => value
        case None =>
            let value = ExampleCompilationUnit(origin.actualRoot, packageName)
            state.units.add(value)
            attachExampleSources(value, state.contexts, origin)
            value
    }
    unit.targets.add(ExampleCompilationTarget(symbol, tag.subject, code, pinned: pinned,
        expectsFailure: directives.expectsFailure, failureContains: directives.failureContains,
        compilerOptions: compilerOptions, execute: directives.execute,
        expectedOutput: expectedOutput))
    state.count++
}

private func collectExampleTargets(documentation: DocumentationSet,
    state: ExampleCollectionState): Unit {
    for (symbol in documentation.symbols) {
        match (symbol.documentation) {
            case Some(comment) =>
                for (tag in comment.examples) { collectExampleForTag(documentation, state, symbol, tag) }
            case None => ()
        }
    }
}

internal func stageExampleSources(unit: ExampleCompilationUnit,
    temporary: Path): Array<String> {
    let paths = ArrayList<String>()
    var index: Int64 = 0
    try {
        for (origin in unit.sourceOrigins) {
            let path = temporary.join("__cjdoc_context_${index}.cj")
            File.writeTo(path, origin.capturedSource.toArray())
            paths.add(path.toString())
            index++
        }
        paths.toArray()
    } catch (_: Exception) {
        []
    }
}

private func syntheticExampleSource(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget): String {
    let out = StringBuilder()
    if (!unit.packageName.isEmpty()) { out.append("package ${unit.packageName}\n\n") }
    for (spelling in unit.imports) { out.append(spelling); out.append("\n") }
    if (!unit.imports.isEmpty()) { out.append("\n") }
    out.append("func __cjdoc_compile_example(): Unit {\n")
    for (line in target.code.split("\n")) {
        out.append("    "); out.append(line); out.append("\n")
    }
    out.append("}\n")
    out.toString()
}

// `staticExecutable` selects `--static --output-type exe` (needed so a run-mode
// example is executable without the SDK runtime on `PATH`, see docs/usage.md).
// `--output-type exe` also drops a `<package>.cjo` into the current working
// directory, so every caller must pass `workingDirectory: Some(temporary)`.
internal func exampleCompilerArguments(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget, generated: Path, output: Path,
    sourcePaths!: Array<String> = [], staticExecutable!: Bool = false): Array<String> {
    let args = ArrayList<String>()
    args.add("--diagnostic-format"); args.add("noColor")
    args.add("--error-count-limit"); args.add("8")
    args.add("-Woff"); args.add("all")
    for (option in target.compilerOptions) { args.add(option) }
    if (staticExecutable) {
        args.add("--static")
        args.add("--output-type"); args.add("exe")
    } else {
        args.add("--output-type"); args.add("staticlib")
    }
    args.add("-o"); args.add(output.toString())
    for (path in sourcePaths) { args.add(path) }
    args.add(generated.toString())
    args.toArray()
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
    target: ExampleCompilationTarget, label: String, outputText: String, exitCode: Int64): Unit {
    let detail = exampleFailureDetail(outputText, exitCode)
    if (target.expectsFailure) {
        if (!outputText.contains("<generated-example>")) {
            // The context failure keeps its own code; the pin is additionally refused,
            // because an uncompilable package would otherwise satisfy `must-fail`.
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
                "declaring package could not be compiled for @example '${label}': ${detail}")
            addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3034",
                "@example '${label}' pinned to fail did not fail inside the example: ${detail}")
        } else {
            match (target.failureContains) {
                case Some(fragment) => if (!outputText.contains(fragment)) {
                    addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3034",
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
    addExampleDiagnostic(documentation, target.symbol, "error", code, "${prefix}: ${detail}")
}

private func compileExampleTarget(documentation: DocumentationSet,
    unit: ExampleCompilationUnit, target: ExampleCompilationTarget): Unit {
    let label = exampleLabel(target.symbol, target.title)
    if (unit.sourceLimitExceeded || unit.sourceOrigins.isEmpty()) {
        addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3031",
            "cannot prepare the source context for @example '${label}'")
        if (target.pinned) {
            reportPinnedExampleSkipped(documentation, target.symbol, label,
                "the declaring package sources could not be prepared")
        }
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
        let sourcePaths = stageExampleSources(unit, temporary)
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
            let (exitCode, stdout, stderr) = executeWithOutput("cjc",
                exampleCompilerArguments(unit, target, generated, output,
                    sourcePaths: sourcePaths, staticExecutable: false),
                workingDirectory: Some(temporary))
            if (exitCode != 0) {
                judgeFailedCompile(documentation, target, label,
                    compilerOutput(stdout, stderr, generated, temporary), exitCode)
            } else if (target.expectsFailure) {
                addExampleDiagnostic(documentation, target.symbol, "error", "CJDOC3034",
                    "@example '${label}' is pinned to fail but compiled successfully")
            } else if (target.execute) {
                runExampleTarget(documentation, unit, target, generated, temporary)
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

internal func compileDocumentationExamples(documentation: DocumentationSet): Unit {
    let state = ExampleCollectionState(collectExampleSourceContexts(documentation))
    collectExampleTargets(documentation, state)
    for (unit in state.units) {
        sortStrings(unit.imports)
        for (target in unit.targets) { compileExampleTarget(documentation, unit, target) }
    }
}
