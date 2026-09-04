package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import cjdoc.schema_data.*
import std.collection.*
import std.env.*
import std.fs.*

private func selectedSourceCacheDirectory(options: NewCliOptions): ?String {
    if (options.noCache) { return None }
    match (options.cacheDirectory) {
        case Some(path) => Some(path)
        case None => Some(Path(options.project).join("target").join("cjdoc").join("cache")
            .join("source-v4").toString())
    }
}

private func orderedFormats(options: NewCliOptions): Array<String> {
    let result = ArrayList<String>()
    if (options.formats.contains("json")) { result.add("json") }
    if (options.formats.contains("markdown")) { result.add("markdown") }
    if (options.formats.contains("html")) { result.add("html") }
    if (options.formats.contains("api-surface")) { result.add("api-surface") }
    if (options.formats.contains("coverage")) { result.add("coverage") }
    result.toArray()
}

private func renderArtifacts(documentation: public_model.DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", markdownLayout!: String = "site"):
    Array<public_render.RenderArtifact> {
    public_render.renderDocumentationFormatsWithOptions(documentation, formats,
        locale: locale, markdownLayout: markdownLayout)
}

internal func renderArtifactsWithCommandFallback(documentation: public_model.DocumentationSet,
    formats: Array<String>, generationRequest: ?GenerationRequest,
    locale!: String = "zh-CN", markdownLayout!: String = "site",
    injectResourceLimitForTest!: Bool = false):
        (public_model.DocumentationSet, Array<public_render.RenderArtifact>) {
    try {
        if (injectResourceLimitForTest) {
            throw public_render.RenderResourceLimitException("injected renderer resource limit")
        }
        (documentation, renderArtifacts(documentation, formats, locale: locale,
            markdownLayout: markdownLayout))
    } catch (error: public_render.RenderResourceLimitException) {
        match (generationRequest) {
            case Some(request) =>
                let fallback = boundGeneratedDocumentation(documentation, request, force: true)
                (fallback, renderArtifacts(fallback, formats, locale: locale,
                    markdownLayout: markdownLayout))
            case None => throw error
        }
    }
}

private func printPublicDiagnostics(documentation: public_model.DocumentationSet): Unit {
    for (diagnostic in documentation.diagnostics) {
        eprintln("${diagnostic.severity}[${diagnostic.code}]: ${diagnostic.message}")
        match (diagnostic.source) {
            case Some(source) => eprintln(" --> ${source.path}:${source.start.line}:${source.start.column}")
            case None => ()
        }
    }
}

private func publicExitCode(documentation: public_model.DocumentationSet, denyWarnings: Bool): Int64 {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error" || (denyWarnings && diagnostic.severity == "warning")) { return 1 }
    }
    0
}

private func coveragePercent(documented: Int64, total: Int64): Int64 {
    if (total == 0) { 100 } else { documented * 100 / total }
}

private func contractGateExitCode(documentation: public_model.DocumentationSet,
    options: NewCliOptions): Int64 {
    var failed = false
    if (options.minSymbolCoverage.isSome() || options.minParameterCoverage.isSome()) {
        let (symbols, documentedSymbols, parameters, documentedParameters) =
            public_render.documentationCoverageCounts(documentation)
        let symbolPercent = coveragePercent(documentedSymbols, symbols)
        let parameterPercent = coveragePercent(documentedParameters, parameters)
        eprintln("documentation coverage: symbols ${documentedSymbols}/${symbols} (${symbolPercent}%), " +
            "parameters ${documentedParameters}/${parameters} (${parameterPercent}%)")
        if (options.minSymbolCoverage.isSome() &&
            symbolPercent < options.minSymbolCoverage.getOrThrow()) {
            eprintln("error: symbol documentation coverage ${symbolPercent}% is below " +
                "${options.minSymbolCoverage.getOrThrow()}%")
            failed = true
        }
        if (options.minParameterCoverage.isSome() &&
            parameterPercent < options.minParameterCoverage.getOrThrow()) {
            eprintln("error: parameter documentation coverage ${parameterPercent}% is below " +
                "${options.minParameterCoverage.getOrThrow()}%")
            failed = true
        }
    }
    match (options.apiSurfaceBaseline) {
        case Some(path) =>
            let actual = public_render.renderDocumentationFormats(documentation,
                ["api-surface"])[0].content
            let expected = readTextBounded(Path(path), 64 * 1024 * 1024)
            if (actual != expected) {
                eprintln("error: API surface differs from baseline '${path}'")
                failed = true
            }
        case None => ()
    }
    if (failed) { 1 } else { 0 }
}

internal func schemaTextForCli(name: String): String {
    match (name) {
        case "list" => "doc-ir\ndoc-ir-v6\ndoc-ir-v7\ndoc-ir-v8\ndiagnostics\ncfg-matrix\nsearch-index\napi-surface\ndocumentation-coverage\n"
        case "doc-ir" => DOC_IR_SCHEMA
        case "doc-ir-v6" => DOC_IR_V6_SCHEMA
        case "doc-ir-v7" => DOC_IR_V7_SCHEMA
        case "doc-ir-v8" => DOC_IR_V8_SCHEMA
        case "diagnostics" => DIAGNOSTICS_SCHEMA
        case "cfg-matrix" => CFG_MATRIX_SCHEMA
        case "search-index" => SEARCH_INDEX_SCHEMA
        case "api-surface" => API_SURFACE_SCHEMA
        case "documentation-coverage" => DOCUMENTATION_COVERAGE_SCHEMA
        case _ => throw IllegalArgumentException("unknown schema '${name}'")
    }
}

private func runSchema(name: String): Int64 {
    print(schemaTextForCli(name))
    0
}

private func readDocIrInput(path: Path): String {
    let limit: Int64 = 64 * 1024 * 1024
    readTextBounded(path, limit)
}

private func executeDocumentCommand(options: NewCliOptions, lockedOutput: ?String,
    selectedCache: ?String, outputLock: ?OutputLockHandle): Int64 {
    let commandLine = getCommandLine()
    let astPreflightExecutable: ?String = if (commandLine.isEmpty()) { None }
        else { Some(commandLine[0]) }
    let generationRequest: ?GenerationRequest = if (options.command == "render") {
        None
    } else {
        Some(GenerationRequest(options.project, jobs: options.jobs,
            audience: options.audience, lintProfile: options.lintProfile,
            includePathDependencies: options.includePathDependencies,
            includeCachedDependencies: options.includeCachedDependencies,
            dependencySources: options.dependencySources.toArray(),
            cfgValues: options.cfgValues.toArray(),
            cacheDirectory: selectedCache,
            astPreflightExecutable: astPreflightExecutable,
            cjpmCacheRoot: options.cjpmCacheRoot))
    }
    var documentation = match (generationRequest) {
        case Some(request) => DocumentationEngine().generate(request)
        case None => decodeValidatedDocIr(readDocIrInput(Path(options.input.getOrThrow())))
    }
    var artifacts: Array<public_render.RenderArtifact> = []
    if (options.command != "check") {
        let (renderedDocumentation, renderedArtifacts) = renderArtifactsWithCommandFallback(documentation,
            orderedFormats(options), generationRequest, locale: options.locale,
            markdownLayout: options.markdownLayout)
        documentation = renderedDocumentation
        artifacts = renderedArtifacts
    }
    printPublicDiagnostics(documentation)
    let diagnosticsExit = publicExitCode(documentation, options.denyWarnings)
    let contractExit = contractGateExitCode(documentation, options)
    if (options.command != "check") {
        if (options.stdout) {
            getStdOut().write(artifacts[0].content.toArray())
        } else {
            let output = lockedOutput.getOrThrow()
            writeOwnedArtifactsWithLockHeld(output, artifacts, outputLock.getOrThrow(),
                forceOwned: options.forceOwned)
        }
    }
    if (diagnosticsExit != 0 || contractExit != 0) { 1 } else { 0 }
}

private func selectedOutputDirectory(options: NewCliOptions): String {
    match (options.output) {
        case Some(path) => path
        case None => if (options.command == "render") { "target/doc" }
            else { Path(options.project).join("target").join("doc").toString() }
    }
}

internal func completeLockedOutputCommand(output: String,
    action: (OutputLockHandle) -> Int64, announceSuccess: () -> Unit): Int64 {
    let result = withOutputLockResultGuard(output, action)
    announceSuccess()
    result
}

func runCli(args: Array<String>): Int64 {
    if (args.size == 1 && (args[0] == "--help" || args[0] == "-h")) { print(newUsage()); return 0 }
    if (args.size == 1 && args[0] == "--version") { println("cjdoc 0.7.2"); return 0 }
    let options = try {
        parseNewCli(args)
    } catch (error: Exception) {
        eprintln(cliErrorText(error.message, true))
        return 2
    }
    try {
        if (options.command == "schema") { return runSchema(options.schemaName) }
        if (options.command == "check" || options.stdout) {
            let requestedCache: ?String = if (options.command == "render") { None }
                else { selectedSourceCacheDirectory(options) }
            let (_, selectedCache) = prepareOutputAndCacheDirectories(
                selectedOutputDirectory(options), requestedCache)
            return executeDocumentCommand(options, None<String>,
                selectedCache, None<OutputLockHandle>)
        }
        let requestedOutput = selectedOutputDirectory(options)
        let requestedCache: ?String = if (options.command == "render") { None }
            else { selectedSourceCacheDirectory(options) }
        let (output, selectedCache) = prepareOutputAndCacheDirectories(requestedOutput, requestedCache)
        completeLockedOutputCommand(output, { lock =>
            executeDocumentCommand(options, Some(output), selectedCache, Some(lock))
        }, { => println("generated ${selectedOutputDirectory(options)}") })
    } catch (error: Exception) {
        eprintln(cliErrorText(error.message, false))
        2
    }
}
