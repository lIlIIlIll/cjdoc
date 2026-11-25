protected package cjdoc.examples

import cjdoc.binding.DocumentationSet
import cjdoc.source.cfg.{CfgProfile, appendCompilerCfgArguments, compilerWhenSelection}
import cjdoc.source.lexing.{sourceLexerTokens, IndexedSourceBuffer}
import std.ast.*
import std.collection.*
import std.fs.*

private func nextExampleToken(tokens: Tokens, start: Int64): Int64 {
    var index = start
    while (index < tokens.size && (tokens[index].kind == NL || tokens[index].kind == COMMENT)) {
        index++
    }
    index
}

private func previousAnnotationToken(tokens: Tokens, start: Int64): Int64 {
    var index = start
    while (index >= 0 && (tokens[index].kind == NL || tokens[index].kind == COMMENT)) {
        index--
    }
    index
}

private func whenAnnotationBeforeMain(source: String, tokens: Tokens,
    mainIndex: Int64, profile: CfgProfile): Bool {
    let sourceIndex = IndexedSourceBuffer(source)
    var cursor = previousAnnotationToken(tokens, mainIndex - 1)
    while (cursor >= 0) {
        if (tokens[cursor].kind != RSQUARE) { break }
        var squareDepth: Int64 = 1
        var opening = cursor - 1
        while (opening >= 0 && squareDepth > 0) {
            if (tokens[opening].kind == RSQUARE) { squareDepth++ }
            if (tokens[opening].kind == LSQUARE) { squareDepth-- }
            opening--
        }
        if (squareDepth != 0) { break }
        let annotationName = opening
        let at = annotationName - 1
        if (annotationName < 0 || at < 0 || tokens[annotationName].kind != IDENTIFIER ||
            tokens[at].kind != AT) { break }
        if (tokens[annotationName].value != "When") {
            cursor = previousAnnotationToken(tokens, at)
            continue
        }
        let start = sourceIndex.byteOffsetFromLexerPosition(
            Int64(tokens[at].pos.line), Int64(tokens[at].pos.column))
        let close = sourceIndex.byteOffsetFromLexerPosition(
            Int64(tokens[cursor].pos.line), Int64(tokens[cursor].pos.column))
        if (start < 0 || close < start) { break }
        let annotation = source[start..close + tokens[cursor].value.size]
        match (compilerWhenSelection(annotation, profile)) {
            case Some(selected) => if (!selected) { return false }
            case None => return false
        }
        cursor = previousAnnotationToken(tokens, at - 1)
    }
    true
}

private func existingMainNameRange(source: String,
    profile: CfgProfile): ?(Int64, Int64) {
    let tokens = sourceLexerTokens(source)
    let sourceIndex = IndexedSourceBuffer(source)
    var index: Int64 = 0
    var declarationDepth: Int64 = 0
    while (index < tokens.size) {
        let kind = tokens[index].kind
        if (kind == LCURL) { declarationDepth++ }
        if (kind == RCURL && declarationDepth > 0) { declarationDepth-- }
        let isMainName = kind == MAIN || (kind == IDENTIFIER && tokens[index].value == "main")
        if (declarationDepth != 0 || !isMainName) {
            index++
            continue
        }
        let opening = nextExampleToken(tokens, index + 1)
        if (opening >= tokens.size || tokens[opening].kind != LPAREN) {
            index++
            continue
        }
        if (!whenAnnotationBeforeMain(source, tokens, index, profile)) {
            index++
            continue
        }
        let start = sourceIndex.byteOffsetFromLexerPosition(
            Int64(tokens[index].pos.line), Int64(tokens[index].pos.column))
        if (start < 0) { return None }
        return Some((start, start + tokens[index].value.size))
    }
    None
}

private func renameExistingMain(source: String,
    profile: CfgProfile): (String, Bool) {
    match (existingMainNameRange(source, profile)) {
        case Some((start, end)) =>
            (source[..start] + "func __cjdoc_preserved_main" + source[end..], true)
        case None => (source, false)
    }
}

internal func stageExampleSources(unit: ExampleCompilationUnit,
    temporary: Path, forRun!: Bool = false,
    cfgProfile!: CfgProfile = CfgProfile()): (Array<String>, Bool) {
    let paths = ArrayList<String>()
    var index: Int64 = 0
    var entryPointPatched = false
    try {
        for (origin in unit.sourceOrigins) {
            let path = temporary.join("__cjdoc_context_${index}.cj")
            let stagedSource = if (forRun && !entryPointPatched) {
                let (rewritten, found) = renameExistingMain(origin.capturedSource, cfgProfile)
                if (found) { entryPointPatched = true }
                rewritten
            } else {
                origin.capturedSource
            }
            File.writeTo(path, stagedSource.toArray())
            paths.add(path.toString())
            index++
        }
        (paths.toArray(), entryPointPatched)
    } catch (_: Exception) {
        ([], false)
    }
}

// The generated file carries the declaring package clause and the captured
// imports, so `cjc` still reports those lines under this file. The body range is
// recorded here, where the layout is decided, so failure attribution can tell an
// error in the example apart from an error in its context.
protected class SyntheticExampleSource {
    let text: String
    let bodyStartLine: Int64
    let bodyEndLine: Int64

    init(text: String, bodyStartLine: Int64, bodyEndLine: Int64) {
        this.text = text
        this.bodyStartLine = bodyStartLine
        this.bodyEndLine = bodyEndLine
    }
}

private func countSourceLines(value: String): Int64 {
    var lines: Int64 = 1
    for (byte in value.toArray()) {
        if (byte == b'\n') { lines++ }
    }
    lines
}

protected func syntheticExampleSource(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget): SyntheticExampleSource {
    syntheticSourceForHeader(exampleHeaderText(unit, target), target.code,
        "func __cjdoc_compile_example(): Unit {\n", "}\n")
}

// Package clause, captured imports and the wrapper signature are the declaring
// package's context even though they live in the generated file.
internal func exampleHeaderText(unit: ExampleCompilationUnit,
    target: ExampleCompilationTarget): String {
    let header = StringBuilder()
    if (!unit.packageName.isEmpty()) { header.append("package ${unit.packageName}\n\n") }
    for (spelling in target.imports) { header.append(spelling); header.append("\n") }
    if (!target.imports.isEmpty()) { header.append("\n") }
    header.toString()
}

protected func syntheticSourceForHeader(headerText: String, code: String,
    opener: String, trailer: String): SyntheticExampleSource {
    let body = StringBuilder()
    var bodyLines: Int64 = 0
    for (line in code.split("\n")) {
        body.append("    "); body.append(line); body.append("\n")
        bodyLines++
    }
    let preamble = headerText + opener
    let headerLines = countSourceLines(preamble) - 1
    let bodyStartLine = headerLines + 1
    SyntheticExampleSource(preamble + body.toString() + trailer, bodyStartLine,
        bodyStartLine + bodyLines - 1)
}

// `staticExecutable` selects `--static --output-type exe` (needed so a run-mode
// example is executable without the SDK runtime on `PATH`, see docs/how-to/check-examples.md).
// `--output-type exe` also drops a `<package>.cjo` into the current working
// directory, so every caller must pass `workingDirectory: Some(temporary)`.
internal func exampleCompilerArguments(documentation: DocumentationSet,
    unit: ExampleCompilationUnit, target: ExampleCompilationTarget, generated: Path,
    output: Path, sourcePaths!: Array<String> = [],
    staticExecutable!: Bool = false,
    packageArtifacts!: Array<ExamplePackageArtifact> = []): Array<String> {
    let args = ArrayList<String>()
    args.add("--diagnostic-format"); args.add("noColor")
    args.add("--error-count-limit"); args.add("8")
    args.add("-Woff"); args.add("all")
    appendCompilerCfgArguments(args, documentation.cfgProfile)
    for (option in target.compilerOptions) { args.add(option) }
    for (artifact in packageArtifacts) {
        args.add("--import-path"); args.add(artifact.artifactRoot.toString())
        args.add("--library-path"); args.add(artifact.artifactRoot.toString())
    }
    if (staticExecutable) {
        args.add("--static")
        args.add("--output-type"); args.add("exe")
        var index = packageArtifacts.size
        while (index > 0) {
            index--
            let packageName = packageArtifacts[index].packageName
            let libraryName = match (packageName.indexOf("::")) {
                case Some(separator) => packageName[separator + 2..] + "@" + packageName[..separator]
                case None => packageName
            }
            args.add("--library"); args.add(libraryName)
        }
    } else {
        args.add("--output-type"); args.add("staticlib")
    }
    args.add("-o"); args.add(output.toString())
    for (path in sourcePaths) { args.add(path) }
    args.add(generated.toString())
    args.toArray()
}
