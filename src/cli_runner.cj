package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import cjdoc.schema_data.*
import std.collection.*
import std.env.*
import std.fs.*

internal func selectedSourceCacheDirectory(options: NewCliOptions): ?String {
    if (options.noCache) { return None }
    match (options.cacheDirectory) {
        case Some(path) => Some(path)
        case None => Some(Path(options.project).join("target").join("cjdoc").join("cache")
            .join("source-v4").toString())
    }
}

internal func orderedFormats(options: NewCliOptions): Array<String> {
    let result = ArrayList<String>()
    if (options.formats.contains("json")) { result.add("json") }
    if (options.formats.contains("markdown")) { result.add("markdown") }
    if (options.formats.contains("html")) { result.add("html") }
    if (options.formats.contains("api-surface")) { result.add("api-surface") }
    if (options.formats.contains("coverage")) { result.add("coverage") }
    if (options.formats.contains("symbol-index")) { result.add("symbol-index") }
    result.toArray()
}

private func renderArtifacts(documentation: public_model.DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", markdownLayout!: String = "site", docVersion!: ?String = None):
    Array<public_render.RenderArtifact> {
    public_render.renderDocumentationFormatsWithOptions(documentation, formats,
        locale: locale, markdownLayout: markdownLayout, docVersion: docVersion)
}

internal func renderArtifactsWithCommandFallback(documentation: public_model.DocumentationSet,
    formats: Array<String>, generationRequest: ?GenerationRequest,
    locale!: String = "zh-CN", markdownLayout!: String = "site",
    docVersion!: ?String = None, injectResourceLimitForTest!: Bool = false):
        (public_model.DocumentationSet, Array<public_render.RenderArtifact>) {
    try {
        if (injectResourceLimitForTest) {
            throw public_render.RenderResourceLimitException("injected renderer resource limit")
        }
        (documentation, renderArtifacts(documentation, formats, locale: locale,
            markdownLayout: markdownLayout, docVersion: docVersion))
    } catch (error: public_render.RenderResourceLimitException) {
        match (generationRequest) {
            case Some(request) =>
                let fallback = boundGeneratedDocumentation(documentation, request, force: true)
                (fallback, renderArtifacts(fallback, formats, locale: locale,
                    markdownLayout: markdownLayout, docVersion: docVersion))
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

private func coverageMetric(counts: public_render.DocumentationCoverageCounts, metric: String): (Int64, Int64) {
    match (metric) {
        case "symbols" => (counts.symbols, counts.documentedSymbols)
        case "parameters" => (counts.parameters, counts.documentedParameters)
        case "returns" => (counts.returns, counts.documentedReturns)
        case "throws" => (counts.throwsDocs, counts.documentedThrows)
        case "examples" => (counts.examples, counts.documentedExamples)
        case "deprecated" => (counts.deprecated, counts.documentedDeprecated)
        case "semantic-links" => (counts.semanticLinks, counts.resolvedSemanticLinks)
        case _ => (0, 0)
    }
}

private func checkCoverageThreshold(scope: String, metric: String,
    counts: public_render.DocumentationCoverageCounts, threshold: Int64): Bool {
    let (total, documented) = coverageMetric(counts, metric)
    let percent = coveragePercent(documented, total)
    if (percent < threshold) {
        eprintln("error: ${scope} ${metric} coverage ${percent}% is below ${threshold}%")
        return false
    }
    true
}

private func hasCoverageThresholds(config: DocumentationQualityConfig): Bool {
    !config.packageOverrides.isEmpty() || config.coverage.symbols.isSome() ||
        config.coverage.parameters.isSome() || config.coverage.returns.isSome() ||
        config.coverage.throwsDocs.isSome() || config.coverage.examples.isSome() ||
        config.coverage.deprecated.isSome() || config.coverage.semanticLinks.isSome()
}

private func configuredCoverageGate(documentation: public_model.DocumentationSet,
    projectRoot: String): Bool {
    let config = loadDocumentationQualityConfig(projectRoot)
    if (!hasCoverageThresholds(config)) { return true }
    let report = public_render.documentationCoverageReport(documentation)
    let metrics = ["symbols", "parameters", "returns", "throws", "examples", "deprecated", "semantic-links"]
    var passed = true
    for (metric in metrics) {
        match (config.coverage.value(metric)) {
            case Some(threshold) => passed = checkCoverageThreshold("global", metric, report.metrics, threshold) && passed
            case None => ()
        }
    }
    for (override in config.packageOverrides) {
        for (group in report.packages where group.name == override.packageName) {
            for (metric in metrics) {
                match (config.packageThreshold(group.name, metric)) {
                    case Some(threshold) =>
                        passed = checkCoverageThreshold("package ${group.name}", metric, group.metrics, threshold) && passed
                    case None => ()
                }
            }
        }
    }
    passed
}
private func apiSurfaceBaselineGate(documentation: public_model.DocumentationSet, path: String): Bool {
    let baseline = readApiContractSnapshot(path)
    let current = public_render.apiContractSnapshotForDocumentation(documentation)
    let report = compareApiContracts(baseline, current)
    for (entry in report.entries) {
        if (entry.classification != "unchanged") {
            let id = match (entry.newId) {
                case Some(value) => value
                case None => match (entry.oldId) { case Some(value) => value case None => "<unknown>" }
            }
            eprintln("error: API surface " + entry.classification + " at " + entry.kind + " " + id)
            return false
        }
    }
    true
}

private func contractGateExitCode(documentation: public_model.DocumentationSet,
    options: NewCliOptions): Int64 {
    var failed = false
    if (options.command != "render" && !configuredCoverageGate(documentation, options.project)) { failed = true }
    if (options.minSymbolCoverage.isSome() || options.minParameterCoverage.isSome()) {
        let (symbols, documentedSymbols, parameters, documentedParameters) =
            public_render.documentationCoverageCounts(documentation)
        let symbolPercent = coveragePercent(documentedSymbols, symbols)
        let parameterPercent = coveragePercent(documentedParameters, parameters)
        eprintln("documentation coverage: symbols " + documentedSymbols.toString() + "/" + symbols.toString() +
            " (" + symbolPercent.toString() + "%), parameters " + documentedParameters.toString() + "/" +
            parameters.toString() + " (" + parameterPercent.toString() + "%)")
        if (options.minSymbolCoverage.isSome() && symbolPercent < options.minSymbolCoverage.getOrThrow()) {
            eprintln("error: symbol documentation coverage is below the configured threshold")
            failed = true
        }
        if (options.minParameterCoverage.isSome() && parameterPercent < options.minParameterCoverage.getOrThrow()) {
            eprintln("error: parameter documentation coverage is below the configured threshold")
            failed = true
        }
    }
    match (options.apiSurfaceBaseline) {
        case Some(path) =>
            if (!apiSurfaceBaselineGate(documentation, path)) { failed = true }
        case None => ()
    }
    if (failed) { 1 } else { 0 }
}
internal func schemaTextForCli(name: String): String {
    match (name) {
        case "list" => "doc-ir\ndoc-ir-v6\ndoc-ir-v7\ndoc-ir-v8\ndoc-ir-v9\ndoc-ir-v10\ndiagnostics\ncfg-matrix\nsearch-index\nsymbol-index\nnavigation-index\napi-surface\napi-surface-v1\napi-diff\ndocumentation-coverage-v1\ndocumentation-coverage\ndoctest-results\nversions\n"
        case "doc-ir" => DOC_IR_SCHEMA
        case "doc-ir-v6" => DOC_IR_V6_SCHEMA
        case "doc-ir-v7" => DOC_IR_V7_SCHEMA
        case "doc-ir-v8" => DOC_IR_V8_SCHEMA
        case "doc-ir-v9" => DOC_IR_V9_SCHEMA
        case "doc-ir-v10" => DOC_IR_V10_SCHEMA
        case "diagnostics" => DIAGNOSTICS_SCHEMA
        case "cfg-matrix" => CFG_MATRIX_SCHEMA
        case "search-index" => SEARCH_INDEX_SCHEMA
        case "symbol-index" => SYMBOL_INDEX_SCHEMA
        case "navigation-index" => NAVIGATION_INDEX_SCHEMA
        case "api-surface" => API_SURFACE_SCHEMA
        case "api-surface-v1" => API_SURFACE_V1_SCHEMA
        case "api-diff" => API_DIFF_SCHEMA
        case "documentation-coverage-v1" => DOCUMENTATION_COVERAGE_V1_SCHEMA
        case "documentation-coverage" => DOCUMENTATION_COVERAGE_SCHEMA
        case "versions" => VERSIONS_SCHEMA
        case "doctest-results" => DOCTEST_RESULTS_SCHEMA
        case _ => throw IllegalArgumentException("unknown schema " + name)
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


private func repositoryForOptions(options: NewCliOptions): ?public_model.RepositoryInfo {
    match ((options.repositoryUrl, options.repositoryRevision)) {
        case (Some(url), Some(revision)) => Some(public_model.RepositoryInfo(url, revision))
        case _ => None
    }
}

private func repositoryRootForOptions(options: NewCliOptions, repository: ?public_model.RepositoryInfo): ?String {
    if (repository.isNone()) { return None }
    match (options.repositoryRoot) {
        case Some(path) => Some(path)
        case None => Some(options.project)
    }
}

private func doctestFailureSeverity(doctestConfig: DoctestConfig,
    qualityConfig: DocumentationQualityConfig): String {
    match (qualityConfig.ruleSeverity("example-not-compiling")) {
        case Some(value) => value
        case None => if (doctestConfig.mode == "deny") { "error" }
            else { qualityConfig.severity("example-not-compiling") }
    }
}

internal func executeDocumentCommand(options: NewCliOptions, lockedOutput: ?String,
    selectedCache: ?String, outputLock: ?OutputLockHandle, writeOnFailure!: Bool = true): Int64 {
    let commandLine = getCommandLine()
    let astPreflightExecutable: ?String = if (commandLine.isEmpty()) { None }
        else { Some(commandLine[0]) }
    let generationRequest: ?GenerationRequest = if (options.command == "render") {
        None
    } else {
        let repository = repositoryForOptions(options)
        Some(GenerationRequest(options.project, jobs: options.jobs,
            audience: options.audience, lintProfile: options.lintProfile,
            repository: repository, repositoryRoot: repositoryRootForOptions(options, repository),
            includePathDependencies: options.includePathDependencies,
            includeCachedDependencies: options.includeCachedDependencies,
            dependencySources: options.dependencySources.toArray(),
            cfgValues: options.cfgValues.toArray(),
            cacheDirectory: selectedCache,
            astPreflightExecutable: astPreflightExecutable,
            cjpmCacheRoot: options.cjpmCacheRoot))
    }
    var sourceOrigins: Array<SourceFileOrigin> = []
    var documentation = match (generationRequest) {
        case Some(request) =>
            let generated = generateDocumentationWithSource(request, defaultSemanticProvider())
            sourceOrigins = generated.internalDocumentation.sourceFileOrigins.toArray()
            generated.publicDocumentation
        case None => decodeValidatedDocIr(readDocIrInput(Path(options.input.getOrThrow())))
    }
    let qualityConfig = if (generationRequest.isSome()) {
        loadDocumentationQualityConfig(options.project)
    } else {
        DocumentationQualityConfig()
    }
    let doctestConfig = if (generationRequest.isSome()) {
        loadDoctestConfig(options.project)
    } else {
        DoctestConfig()
    }
    var doctestReport: ?DoctestReport = None
    if (generationRequest.isSome() && doctestConfig.mode != "off") {
        if (options.stdout) {
            throw IllegalArgumentException("--stdout cannot be combined with enabled doctests")
        }
        let report = runDoctests(documentation, doctestConfig,
            Path(options.project).join("target").join("cjdoc"),
            projectRoot: Path(options.project), sourceOrigins: sourceOrigins,
            cfgValues: options.cfgValues.toArray())
        doctestReport = Some(report)
        eprintln(doctestReportSummary(report))
        if (doctestReportHasFailure(report)) {
            let severity = doctestFailureSeverity(doctestConfig, qualityConfig)
            if (severity != "off") {
                eprintln(severity + "[CJDOC3010]: doctest execution reported failures")
            }
        }
    }
    var artifacts: Array<public_render.RenderArtifact> = []
    if (options.command != "check") {
        let (renderedDocumentation, renderedArtifacts) = renderArtifactsWithCommandFallback(documentation,
            orderedFormats(options), generationRequest, locale: options.locale,
            markdownLayout: options.markdownLayout, docVersion: options.docVersion)
        documentation = renderedDocumentation
        let artifactList = ArrayList<public_render.RenderArtifact>()
        if (generationRequest.isSome()) {
            artifactList.add(all: appendConceptualArtifacts(options.project, documentation,
                orderedFormats(options), renderedArtifacts))
        } else {
            artifactList.add(all: renderedArtifacts)
        }
        if (options.formats.contains("html")) {
            let agentConceptualPages: Array<public_render.AgentConceptualPage> = if (generationRequest.isSome()) {
                conceptualAgentPages(options.project, documentation)
            } else {
                []
            }
            artifactList.add(all: public_render.renderAgentReadableArtifacts(documentation,
                conceptualPages: agentConceptualPages,
                includeFull: options.agentFull, version: options.docVersion))
        }
        match (options.docVersion) {
            case Some(version) => appendDocumentVersionArtifact(artifactList, version, documentation.project.name)
            case None => ()
        }
        match (doctestReport) {
            case Some(report) =>
                artifactList.add(public_render.RenderArtifact(
                    "doctest/results.json", "application/json", encodeDoctestReport(report)))
            case None => ()
        }
        artifacts = artifactList.toArray()
    }
    printPublicDiagnostics(documentation)
    let diagnosticsExit = publicExitCode(documentation, options.denyWarnings)
    let contractExit = contractGateExitCode(documentation, options)
    let doctestExit = match (doctestReport) {
        case Some(report) =>
            if (doctestFailureSeverity(doctestConfig, qualityConfig) == "error" &&
                doctestReportHasFailure(report)) { 1 } else { 0 }
        case None => 0
    }
    if (options.command != "check" &&
        (writeOnFailure || (diagnosticsExit == 0 && contractExit == 0 && doctestExit == 0))) {
        if (options.stdout) {
            getStdOut().write(artifacts[0].content.toArray())
        } else {
            let output = lockedOutput.getOrThrow()
            writeOwnedArtifactsWithLockHeld(output, artifacts, outputLock.getOrThrow(),
                forceOwned: options.forceOwned)
        }
    }
    if (diagnosticsExit != 0 || contractExit != 0 || doctestExit != 0) { 1 } else { 0 }
}

private func runApiDiff(options: NewCliOptions): Int64 {
    let baseline = readApiContractSnapshot(options.baselineInput.getOrThrow())
    let current = readApiContractSnapshot(options.currentInput.getOrThrow())
    let report = compareApiContracts(baseline, current)
    if (options.diffFormat == "json") {
        getStdOut().write(public_render.encodeApiDiffReport(report).toArray())
    } else {
        print(renderApiDiffText(report))
    }
    apiDiffExitCode(report, options.denyBreakingApi, options.denyPotentiallyBreakingApi)
}

internal func selectedOutputDirectory(options: NewCliOptions): String {
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
        if (options.command == "diff") { return runApiDiff(options) }
        if (options.command == "versions") { return runVersionsCompose(options) }
        if (options.command == "serve") { return runServeCommand(options) }
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
