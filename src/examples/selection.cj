protected package cjdoc.examples

import cjdoc.binding.{DocumentationSet, SymbolDoc, renderableSymbolIds}
import cjdoc.source.normalizeSourceNewlines
import cjdoc.source.frontend.sourceImportTextsFromSource
import cjdoc.source.model.SourceFileOrigin
import cjdoc.source.Diagnostic
import cjdoc.documentation.comments.DocTag
import std.collection.*

// Example checking is opt-in because documentation snippets are often partial
// expressions rather than complete programs. These limits keep a malformed
// comment from turning a documentation check into an unbounded compiler job.
private let MAX_EXAMPLE_COUNT: Int64 = 256
private let MAX_EXAMPLE_CODE_BYTES: Int64 = 1024 * 1024

// Source budgets shared by example selection and imported-package staging: one
// compilation unit, whatever it imports, must fit these caps before any compiler runs.
internal let MAX_EXAMPLE_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
internal let MAX_EXAMPLE_SOURCE_BYTES: Int64 = 128 * 1024 * 1024

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

// One judged `@example`. `pinned` records that the author wrote a directive block,
// which turns every infrastructure skip into a visible CJDOC3070: a pin must never be
// satisfied by a check that silently did not happen.
internal class ExampleCompilationTarget {
    let symbol: SymbolDoc
    let title: String
    let code: String
    let pinned: Bool
    let expectsFailure: Bool
    let failureContains: ?String
    let compilerOptions: Array<String>
    let imports: Array<String>
    let execute: Bool
    let expectedOutput: ?String

    init(symbol: SymbolDoc, title: String, code: String, pinned!: Bool = false,
        expectsFailure!: Bool = false, failureContains!: ?String = None,
        compilerOptions!: Array<String> = [], imports!: Array<String> = [],
        execute!: Bool = false, expectedOutput!: ?String = None) {
        this.symbol = symbol
        this.title = title
        this.code = code
        this.pinned = pinned
        this.expectsFailure = expectsFailure
        this.failureContains = failureContains
        this.compilerOptions = compilerOptions
        this.imports = imports
        this.execute = execute
        this.expectedOutput = expectedOutput
    }
}

internal class ExampleCompilationUnit {
    let actualRoot: String
    let moduleId: String
    let packageName: String
    let sourceOrigins = ArrayList<SourceFileOrigin>()
    let targets = ArrayList<ExampleCompilationTarget>()
    var sourceBytes: Int64 = 0
    var sourceLimitExceeded = false

    init(actualRoot: String, moduleId: String, packageName: String) {
        this.actualRoot = actualRoot
        this.moduleId = moduleId
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
}

private class ExampleSourceContext {
    let origin: SourceFileOrigin
    let packageName: String

    init(origin: SourceFileOrigin, packageName: String) {
        this.origin = origin
        this.packageName = packageName
    }
}

private class ExampleCollectionState {
    let contexts: ArrayList<ExampleSourceContext>
    let units = ArrayList<ExampleCompilationUnit>()
    let importsByFile = HashMap<String, Array<String>>()
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
    Some(ExampleSourceContext(origin, origin.packageName))
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
    moduleId: String, packageName: String): ?ExampleCompilationUnit {
    for (unit in units) {
        if (unit.actualRoot == actualRoot && unit.moduleId == moduleId &&
            unit.packageName == packageName) { return Some(unit) }
    }
    None
}

private func attachExampleSources(unit: ExampleCompilationUnit,
    contexts: ArrayList<ExampleSourceContext>, targetOrigin: SourceFileOrigin): Unit {
    for (context in contexts) {
        if (context.origin.actualRoot != unit.actualRoot) { continue }
        if (!context.packageName.isEmpty() && context.packageName != unit.packageName) { continue }
        unit.addSource(context.origin)
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

internal func reportPinnedExampleSkipped(documentation: DocumentationSet, symbol: SymbolDoc,
    label: String, reason: String): Unit {
    addExampleDiagnostic(documentation, symbol, "error", "CJDOC3070",
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
    let imports = try {
        match (state.importsByFile.get(origin.actualPath)) {
            case Some(value) => value
            case None =>
                let value = sourceImportTextsFromSource(origin.logicalPath, origin.capturedSource, true).toArray()
                state.importsByFile[origin.actualPath] = value
                value
        }
    } catch (_: Exception) {
        addExampleDiagnostic(documentation, symbol, "error", "CJDOC3031",
            "cannot capture conditional imports for @example '${label}'")
        if (pinned) {
            reportPinnedExampleSkipped(documentation, symbol, label, "the declaring imports could not be captured")
        }
        return
    }
    let packageName = examplePackageName(symbol, state.contexts, origin)
    let unit = match (findExampleUnit(state.units, origin.actualRoot, origin.moduleId, packageName)) {
        case Some(value) => value
        case None =>
            let value = ExampleCompilationUnit(origin.actualRoot, origin.moduleId, packageName)
            state.units.add(value)
            attachExampleSources(value, state.contexts, origin)
            value
    }
    unit.targets.add(ExampleCompilationTarget(symbol, tag.subject, code, pinned: pinned,
        expectsFailure: directives.expectsFailure, failureContains: directives.failureContains,
        compilerOptions: compilerOptions, imports: imports,
        execute: directives.execute, expectedOutput: expectedOutput))
    state.count++
}

private func collectExampleTargets(documentation: DocumentationSet,
    state: ExampleCollectionState, audience: String): Unit {
    let renderableIds = renderableSymbolIds(documentation, audience)
    for (symbol in documentation.symbols) {
        if (!renderableIds.contains(symbol.id)) { continue }
        match (symbol.documentation) {
            case Some(comment) =>
                if (comment.languageItems.isEmpty()) {
                    for (tag in comment.examples) { collectExampleForTag(documentation, state, symbol, tag) }
                } else {
                    for (item in comment.languageItems) {
                        if (item.tag.name == "example" && item.state != "invalid" && item.state != "conflict") {
                            collectExampleForTag(documentation, state, symbol, item.tag)
                        }
                    }
                }
            case None => ()
        }
    }
}

// The whole selection phase behind one entry: extraction, directive validation and
// source-context attachment stay internal to it, so compilation receives only the
// units it has to compile.
internal func collectExampleUnits(documentation: DocumentationSet,
    audience: String): ArrayList<ExampleCompilationUnit> {
    let state = ExampleCollectionState(collectExampleSourceContexts(documentation))
    collectExampleTargets(documentation, state, audience)
    state.units
}
