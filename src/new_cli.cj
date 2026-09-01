package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import cjdoc.schema_data.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*

private class NewCliOptions {
    var command = ""
    var project = "."
    var projectExplicit = false
    var output: ?String = None
    var input: ?String = None
    let formats = ArrayList<String>()
    var stdout = false
    var denyWarnings = false
    var forceOwned = false
    var jobs: Int64 = 1
    var jobsExplicit = false
    var audience = "external"
    var audienceExplicit = false
    var lintProfile = "standard"
    var lintProfileExplicit = false
    var schemaName = ""
    var includePathDependencies = false
    var includeCachedDependencies = false
    var cacheDirectory: ?String = None
    var noCache = false
    var cjpmCacheRoot: ?String = None
    var apiSurfaceBaseline: ?String = None
    var minSymbolCoverage: ?Int64 = None
    var minParameterCoverage: ?Int64 = None
    var locale = "zh-CN"
    var localeExplicit = false
    var markdownLayout = "site"
    var markdownLayoutExplicit = false
    let dependencySources = ArrayList<DependencySourceInput>()
    let cfgValues = ArrayList<CfgValue>()
}

private func newUsage(): String {
    "usage:\n" +
    "  cjdoc generate [--project <dir>] [--format json|markdown|html|api-surface|coverage]... [--output <dir>|--stdout]\n" +
    "                 [--audience external|package|all] [--lint-profile off|standard|strict] [--jobs 1..64]\n" +
    "                 [--cfg NAME=VALUE] [--include-path-dependencies] [--include-cached-dependencies]\n" +
    "                 [--dependency-source NAME=PATH] [--cjpm-cache <dir>]\n" +
    "                 [--cache-dir <dir>|--no-cache] [--force-owned]\n" +
    "                 [--locale zh-CN|en] [--markdown-layout site|single]\n" +
    "  cjdoc check [--project <dir>] [--deny-warnings] [--lint-profile off|standard|strict]\n" +
    "              [--api-surface-baseline <file>] [--min-symbol-coverage 0..100] [--min-parameter-coverage 0..100]\n" +
    "  cjdoc render --input <docs.json> [--format json|markdown|html|api-surface|coverage]... [--output <dir>|--stdout] [--force-owned]\n" +
    "               [--locale zh-CN|en] [--markdown-layout site|single]\n" +
    "  cjdoc schema list|doc-ir|doc-ir-v6|doc-ir-v7|doc-ir-v8|diagnostics|cfg-matrix|search-index|api-surface|documentation-coverage\n"
}

internal func splitNamedValue(value: String, option: String): (String, String) {
    let parts = value.split("=", 2)
    if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("${option} requires NAME=VALUE")
    }
    (parts[0].trimAscii(), parts[1].trimAscii())
}

internal func cliErrorText(message: String, includeUsage: Bool): String {
    if (includeUsage) { "error: ${message}\n${newUsage()}" } else { "error: ${message}" }
}

private func addFormat(options: NewCliOptions, value: String): Unit {
    if (value != "json" && value != "markdown" && value != "html" &&
        value != "api-surface" && value != "coverage") {
        throw IllegalArgumentException("unsupported format '${value}'")
    }
    if (!options.formats.contains(value)) { options.formats.add(value) }
}

private func parseNewCli(args: Array<String>): NewCliOptions {
    let options = NewCliOptions()
    if (args.isEmpty()) { throw IllegalArgumentException("missing command") }
    options.command = args[0]
    if (options.command == "schema") {
        if (args.size != 2) { throw IllegalArgumentException("schema requires exactly one schema name") }
        options.schemaName = args[1]
        if (options.schemaName != "list" && options.schemaName != "doc-ir" &&
            options.schemaName != "doc-ir-v6" && options.schemaName != "doc-ir-v7" &&
            options.schemaName != "doc-ir-v8" &&
            options.schemaName != "diagnostics" && options.schemaName != "cfg-matrix" &&
            options.schemaName != "search-index" && options.schemaName != "api-surface" &&
            options.schemaName != "documentation-coverage") {
            throw IllegalArgumentException("unknown schema '${options.schemaName}'")
        }
        return options
    }
    if (options.command != "generate" && options.command != "check" && options.command != "render") {
        throw IllegalArgumentException("unknown command '${options.command}'")
    }
    var index: Int64 = 1
    while (index < args.size) {
        match (args[index]) {
            case "--project" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--project requires a value") }
                options.project = args[index + 1]; options.projectExplicit = true; index += 2
            case "--input" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--input requires a value") }
                options.input = Some(args[index + 1]); index += 2
            case "--output" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--output requires a value") }
                options.output = Some(args[index + 1]); index += 2
            case "--format" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--format requires a value") }
                addFormat(options, args[index + 1]); index += 2
            case "--stdout" => options.stdout = true; index++
            case "--deny-warnings" => options.denyWarnings = true; index++
            case "--force-owned" => options.forceOwned = true; index++
            case "--include-path-dependencies" => options.includePathDependencies = true; index++
            case "--include-cached-dependencies" => options.includeCachedDependencies = true; index++
            case "--cache-dir" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--cache-dir requires a value")
                }
                options.cacheDirectory = Some(args[index + 1]); options.noCache = false; index += 2
            case "--no-cache" => options.cacheDirectory = None; options.noCache = true; index++
            case "--cjpm-cache" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--cjpm-cache requires a value")
                }
                options.cjpmCacheRoot = Some(args[index + 1]); index += 2
            case "--api-surface-baseline" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--api-surface-baseline requires a value")
                }
                options.apiSurfaceBaseline = Some(args[index + 1]); index += 2
            case "--min-symbol-coverage" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--min-symbol-coverage requires a value")
                }
                options.minSymbolCoverage = Some(Int64.parse(args[index + 1])); index += 2
            case "--min-parameter-coverage" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--min-parameter-coverage requires a value")
                }
                options.minParameterCoverage = Some(Int64.parse(args[index + 1])); index += 2
            case "--locale" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--locale requires a value") }
                options.locale = args[index + 1]; options.localeExplicit = true; index += 2
            case "--markdown-layout" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--markdown-layout requires a value")
                }
                options.markdownLayout = args[index + 1]
                options.markdownLayoutExplicit = true; index += 2
            case "--dependency-source" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--dependency-source requires a value") }
                let (name, path) = splitNamedValue(args[index + 1], "--dependency-source")
                options.dependencySources.add(DependencySourceInput(name, path)); index += 2
            case "--cfg" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--cfg requires a value") }
                let (name, value) = splitNamedValue(args[index + 1], "--cfg")
                options.cfgValues.add(CfgValue(name, value)); index += 2
            case "--jobs" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--jobs requires a value") }
                options.jobs = Int64.parse(args[index + 1]); options.jobsExplicit = true; index += 2
            case "--audience" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--audience requires a value") }
                options.audience = args[index + 1]; options.audienceExplicit = true; index += 2
            case "--lint-profile" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--lint-profile requires a value") }
                options.lintProfile = args[index + 1]; options.lintProfileExplicit = true; index += 2
            case _ => throw IllegalArgumentException("unknown option '${args[index]}'")
        }
    }
    if (options.jobs < 1 || options.jobs > 64) { throw IllegalArgumentException("--jobs must be in 1..64") }
    if (options.audience != "external" && options.audience != "package" && options.audience != "all") {
        throw IllegalArgumentException("--audience must be external, package, or all")
    }
    if (options.lintProfile != "off" && options.lintProfile != "standard" && options.lintProfile != "strict") {
        throw IllegalArgumentException("--lint-profile must be off, standard, or strict")
    }
    for (threshold in [options.minSymbolCoverage, options.minParameterCoverage]) {
        if (threshold.isSome() && (threshold.getOrThrow() < 0 || threshold.getOrThrow() > 100)) {
            throw IllegalArgumentException("coverage thresholds must be in 0..100")
        }
    }
    if (options.locale != "zh-CN" && options.locale != "en") {
        throw IllegalArgumentException("--locale must be zh-CN or en")
    }
    if (options.markdownLayout != "site" && options.markdownLayout != "single") {
        throw IllegalArgumentException("--markdown-layout must be site or single")
    }
    if (options.markdownLayout == "single" && options.locale != "en") {
        throw IllegalArgumentException("legacy single-page Markdown requires --locale en")
    }
    if (options.command == "render" && options.input.isNone()) {
        throw IllegalArgumentException("render requires --input")
    }
    if (options.command == "render" && (options.projectExplicit || options.denyWarnings ||
        options.includePathDependencies || options.includeCachedDependencies ||
        options.cacheDirectory.isSome() || options.noCache || options.cjpmCacheRoot.isSome() ||
        options.apiSurfaceBaseline.isSome() || options.minSymbolCoverage.isSome() ||
        options.minParameterCoverage.isSome() ||
        !options.dependencySources.isEmpty() || !options.cfgValues.isEmpty() ||
        options.jobsExplicit || options.audienceExplicit || options.lintProfileExplicit)) {
        throw IllegalArgumentException(
            "render accepts only --input, --format, --output, --stdout, and --force-owned")
    }
    if (options.command != "render" && options.input.isSome()) {
        throw IllegalArgumentException("--input is only valid for render")
    }
    if (options.command == "check" && (!options.formats.isEmpty() || options.output.isSome() || options.stdout)) {
        throw IllegalArgumentException("check does not accept render output options")
    }
    if (options.command == "check" && (options.localeExplicit || options.markdownLayoutExplicit)) {
        throw IllegalArgumentException("check does not accept renderer localization options")
    }
    if (options.command == "check" && options.forceOwned) {
        throw IllegalArgumentException("check does not accept --force-owned")
    }
    if (options.stdout && options.output.isSome()) {
        throw IllegalArgumentException("--stdout and --output are mutually exclusive")
    }
    if (options.stdout && options.forceOwned) {
        throw IllegalArgumentException("--stdout does not accept --force-owned")
    }
    if (options.formats.isEmpty() && options.command != "check") { options.formats.add("json") }
    if (options.stdout && (options.formats.size != 1 ||
        (options.formats[0] != "json" && options.formats[0] != "api-surface" &&
            options.formats[0] != "coverage"))) {
        throw IllegalArgumentException("--stdout requires exactly one JSON-producing format")
    }
    if (options.cjpmCacheRoot.isSome() && !options.includeCachedDependencies) {
        throw IllegalArgumentException("--cjpm-cache requires --include-cached-dependencies")
    }
    options
}

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
    if (args.size == 1 && args[0] == "--version") { println("cjdoc 0.7.1"); return 0 }
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
