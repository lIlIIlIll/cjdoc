package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import cjdoc.schema_data.*
import std.collection.*
import std.env.*
import std.fs.*
import cjdoc_chir_protocol.CJDOC_PRODUCT_VERSION

internal func selectedSourceCacheDirectory(options: NewCliOptions): ?String {
    if (options.noCache) { return None }
    match (options.cacheDirectory) {
        case Some(path) => Some(path)
        case None => Some(Path(options.project).join("target").join("cjdoc").join("cache")
            .join("source-v11").toString())
    }
}

internal func orderedFormats(options: NewCliOptions): Array<String> {
    let result = ArrayList<String>()
    if (options.formats.contains("html")) { result.add("html") }
    if (options.formats.contains("json")) { result.add("json") }
    if (options.formats.contains("markdown")) { result.add("markdown") }
    if (options.formats.contains("api-surface")) { result.add("api-surface") }
    if (options.formats.contains("coverage")) { result.add("coverage") }
    if (options.formats.contains("symbol-index")) { result.add("symbol-index") }
    result.toArray()
}

private func renderArtifacts(documentation: public_model.DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", docVersion!: ?String = None,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<public_render.DocumentationReportAttachment> = [],
    htmlFonts!: public_render.HtmlFontOptions = public_render.HtmlFontOptions()):
    Array<public_render.RenderArtifact> {
    public_render.renderDocumentationFormatsWithOptions(documentation, formats,
        locale: locale, docVersion: docVersion, allLanguages: allLanguages,
        agentFull: agentFull, reports: reports, htmlFonts: htmlFonts)
}


/**
 * The one renderer-resource fallback for directory output.
 *
 * Only `RenderResourceLimitException` may downgrade generated documentation,
 * and only when a generation request exists. The spool is destroyed and
 * recreated strictly before the bounded documentation replaces the input, so
 * the retry starts from an empty inventory. The retry happens exactly once;
 * disk, lock, and output-validation failures are never converted here.
 */
internal func renderArtifactsIntoWithCommandFallback(spool: OutputArtifactSpool,
    documentation: public_model.DocumentationSet, formats: Array<String>,
    generationRequest: ?GenerationRequest,
    locale!: String = "zh-CN",
    docVersion!: ?String = None, injectResourceLimitForTest!: Bool = false,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<public_render.DocumentationReportAttachment> = [],
    htmlFonts!: public_render.HtmlFontOptions = public_render.HtmlFontOptions()):
        public_model.DocumentationSet {
    try {
        if (injectResourceLimitForTest) {
            throw public_render.RenderResourceLimitException("injected renderer resource limit")
        }
        public_render.renderDocumentationInto(spool, documentation, formats, locale: locale,
            docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull,
            reports: reports, htmlFonts: htmlFonts)
        documentation
    } catch (error: public_render.RenderResourceLimitException) {
        match (generationRequest) {
            case Some(request) =>
                spool.reset()
                let fallback = boundGeneratedDocumentation(documentation, request, force: true)
                public_render.renderDocumentationInto(spool, fallback, formats, locale: locale,
                    docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull,
                    reports: reports, htmlFonts: htmlFonts)
                fallback
            case None => throw error
        }
    }
}

internal func renderArtifactsWithCommandFallback(documentation: public_model.DocumentationSet,
    formats: Array<String>, generationRequest: ?GenerationRequest,
    locale!: String = "zh-CN",
    docVersion!: ?String = None, injectResourceLimitForTest!: Bool = false,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<public_render.DocumentationReportAttachment> = [],
    htmlFonts!: public_render.HtmlFontOptions = public_render.HtmlFontOptions()):
        (public_model.DocumentationSet, Array<public_render.RenderArtifact>) {
    try {
        if (injectResourceLimitForTest) {
            throw public_render.RenderResourceLimitException("injected renderer resource limit")
        }
        (documentation, renderArtifacts(documentation, formats, locale: locale,
            docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull, reports: reports,
            htmlFonts: htmlFonts))
    } catch (error: public_render.RenderResourceLimitException) {
        match (generationRequest) {
            case Some(request) =>
                let fallback = boundGeneratedDocumentation(documentation, request, force: true)
                (fallback, renderArtifacts(fallback, formats, locale: locale,
                    docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull, reports: reports,
                    htmlFonts: htmlFonts))
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
        var matched = false
        for (group in report.packages where group.name == override.packageName) {
            matched = true
            for (metric in metrics) {
                match (config.packageThreshold(group.name, metric)) {
                    case Some(threshold) =>
                        passed = checkCoverageThreshold("package ${group.name}", metric, group.metrics, threshold) && passed
                    case None => ()
                }
            }
        }
        if (!matched) {
            eprintln("error: package coverage override '${override.packageName}' does not match any selected package")
            passed = false
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
        case "list" => "doc-ir\ndoc-ir-v18\ndiagnostics\ncfg-matrix\nsearch-index\n" +
            "search-index-v11\nsymbol-index\nnavigation-index\napi-surface\napi-surface-v3\n" +
            "api-diff\napi-diff-v2\ndocumentation-coverage\ndocumentation-quality\n" +
            "versions\nversions-v2\ntranslation-coverage\nsite-manifest\nnavigation-index-v1\n" +
            "navigation-index-v2\nagent-full-index\ndeclaration\npage\nmachine-manifest\nquery-request\nquery-result\n" +
            "search-contract\nsource-provenance\n"
        case "doc-ir" => DOC_IR_SCHEMA
        case "doc-ir-v18" => DOC_IR_V18_SCHEMA
        case "source-provenance" => sourceProvenanceReceiptSchema()
        case "diagnostics" => DIAGNOSTICS_SCHEMA
        case "cfg-matrix" => CFG_MATRIX_SCHEMA
        case "search-index" => SEARCH_INDEX_SCHEMA
        case "search-index-v11" => SEARCH_INDEX_SCHEMA
        case "symbol-index" => SYMBOL_INDEX_SCHEMA
        case "navigation-index" | "navigation-index-v2" => NAVIGATION_INDEX_V2_SCHEMA
        case "navigation-index-v1" => NAVIGATION_INDEX_SCHEMA
        case "agent-full-index" | "declaration" | "page" | "machine-manifest" =>
            documentationArtifactSchema(name)
        case "query-request" => DOCUMENTATION_QUERY_REQUEST_SCHEMA
        case "query-result" => documentationQueryOutputSchema()
        // The search contract is not a JSON Schema; it is the published rule
        // table both executors read, exported for consumers and diff tests.
        case "search-contract" => documentationSearchContract()
        case "api-surface" => API_SURFACE_SCHEMA
        case "api-surface-v3" => API_SURFACE_SCHEMA
        case "api-diff" => API_DIFF_SCHEMA
        case "api-diff-v2" => API_DIFF_SCHEMA
        case "documentation-coverage" => DOCUMENTATION_COVERAGE_SCHEMA
        case "documentation-quality" => DOCUMENTATION_QUALITY_SCHEMA
        case "versions" => VERSIONS_SCHEMA
        case "versions-v2" => VERSIONS_SCHEMA
        case "translation-coverage" => TRANSLATION_COVERAGE_SCHEMA
        case "site-manifest" => SITE_MANIFEST_SCHEMA
        case _ => throw IllegalArgumentException("unknown schema '${name}'")
    }
}

private func runSchema(name: String): Int64 {
    print(schemaTextForCli(name))
    0
}

private func readDocIrInput(path: Path, limit: Int64): String {
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



 internal func executeDocumentCommand(options: NewCliOptions, lockedOutput: ?String,
    selectedCache: ?String, outputLock: ?OutputLockHandle, writeOnFailure!: Bool = true): Int64 {
    // The source parser worker and the installed CHIR companion are both
    // located from the real executable, never from argv[0], PATH, or the cwd.
    let astPreflightExecutable = currentCjdocExecutablePath()
    let chirOptions: ?ChirOptions = if (options.semanticMode == "chir") {
        Some(ChirOptions(compilerExecutable: options.cjcExecutable,
            importPaths: options.chirImportPaths.toArray(),
            workerExecutable: selectedCliChirWorker(options, astPreflightExecutable)))
    } else {
        None
    }
    let generationRequest: ?GenerationRequest = if (options.command == "render") {
        None
    } else {
        let repository = repositoryForOptions(options)
        Some(GenerationRequest(options.project, repository: repository,
            repositoryRoot: repositoryRootForOptions(options, repository), jobs: options.jobs,
            audience: options.audience, lintProfile: options.lintProfile,
            checkExamples: options.checkExamples,
            includePathDependencies: options.includePathDependencies,
            includeCachedDependencies: options.includeCachedDependencies,
            dependencySources: options.dependencySources.toArray(),
            cfgValues: options.cfgValues.toArray(),
            cacheDirectory: selectedCache,
            astPreflightExecutable: astPreflightExecutable,
            chir: chirOptions,
            cjpmCacheRoot: options.cjpmCacheRoot,
            highlightAdapter: options.highlightAdapter, highlightNode: options.highlightNode,
            requiredLanguages: options.requiredLanguages.toArray(), buildContext: options.buildContext,
            documentSources: options.documentSources.toArray(), linkLanguage: options.linkLanguage,
            linkLanguageFallback: options.linkLanguageFallback, linkCompatible: options.linkCompatible,
            documentInventoryPins: options.documentInventoryPins.toArray(),
            documentationRevision: options.docVersion.getOrDefault({ => "" }),
            standardLibraryDocsVersion: options.standardLibraryDocsVersion,
            standardLibraryDocsBaseUrl: options.standardLibraryDocsBaseUrl,
            maxDocIrMiB: options.maxDocIrMiB))
    }
    let renderLocale = selectedCliRenderLocale(options)
    var documentation = match (generationRequest) {
        case Some(request) =>
            let semanticProvider: SemanticProvider = match (request.chir) {
                case Some(chir) => AutoChirSemanticProvider(chir)
                case None => defaultSemanticProvider()
            }
            generateDocumentationWithSource(request, semanticProvider).publicDocumentation
        case None =>
            let limit = docIrLimitBytes(options.maxDocIrMiB.getOrDefault({ => 64 }))
            public_render.decodeDocIr(readDocIrInput(Path(options.input.getOrThrow()), limit),
                maxDocumentBytes: limit)
    }
    // Every directory case renders once, straight into the lock-scoped spool.
    // A spool is created only after the documentation value exists so a failed
    // generation never leaves transaction state behind.
    var spool: ?OutputArtifactSpool = None
    if (options.command != "check" && !options.stdout) {
        let created = OutputArtifactSpool(outputLock.getOrThrow())
        spool = Some(created)
        documentation = renderArtifactsIntoWithCommandFallback(created, documentation,
            orderedFormats(options), generationRequest, locale: renderLocale,
            docVersion: options.docVersion, allLanguages: options.allLanguages,
            agentFull: options.agentFull, reports: capturedCliReports(options),
            htmlFonts: public_render.HtmlFontOptions(sans: options.htmlFontSans,
                mono: options.htmlFontMono))
        match (options.docVersion) {
            case Some(version) =>
                appendDocumentVersionArtifactInto(created, version, documentation.project.name)
            case None => ()
        }
    }
    let artifacts = if (options.command != "check" && options.stdout) {
        let (renderedDocumentation, rendered) = renderArtifactsWithCommandFallback(documentation,
            orderedFormats(options), generationRequest, locale: renderLocale,
            docVersion: options.docVersion, allLanguages: options.allLanguages,
            agentFull: options.agentFull, reports: capturedCliReports(options),
            htmlFonts: public_render.HtmlFontOptions(sans: options.htmlFontSans, mono: options.htmlFontMono))
        documentation = renderedDocumentation
        rendered
    } else { Array<public_render.RenderArtifact>() }
    printPublicDiagnostics(documentation)
    let diagnosticsExit = publicExitCode(documentation, options.denyWarnings)
    let contractExit = contractGateExitCode(documentation, options)
    if (options.command != "check" &&
        (writeOnFailure || (diagnosticsExit == 0 && contractExit == 0))) {
        if (options.stdout) {
            getStdOut().write(artifacts[0].content.toArray())
        } else {
            let output = lockedOutput.getOrThrow()
            writeOwnedSpoolWithLockHeld(output, spool.getOrThrow(), outputLock.getOrThrow(),
                forceOwned: options.forceOwned)
        }
    } else {
        // A rejected serve rebuild must not publish, and its spool must vanish
        // so the next attempt starts from an empty inventory.
        match (spool) {
            case Some(created) => created.discard()
            case None => ()
        }
    }
    if (diagnosticsExit != 0 || contractExit != 0) { 1 } else { 0 }
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

// Help is answered before configuration is read: it needs no project, starts no
// worker, and works even when the project's cjdoc.toml is invalid.
private func runCommandHelp(args: Array<String>): ?Int64 {
    if (args.size < 2) { return None }
    let last = args[args.size - 1]
    if (last != "--help" && last != "-h") { return None }
    // Accept `cjdoc serve --help` and the nested `cjdoc versions compose --help`.
    var name = ""
    var index: Int64 = 0
    while (index < args.size - 1) {
        let token = args[index]
        if (token.startsWith("-")) { return None }
        name = if (name.isEmpty()) { token } else { name + " " + token }
        index++
    }
    match (commandUsage(name)) {
        case Some(text) => print(text); Some(0)
        case None => None<Int64>
    }
}

func runCli(args: Array<String>): Int64 {
    if (args.size == 1 && (args[0] == "--help" || args[0] == "-h")) { print(newUsage()); return 0 }
    if (args.size == 1 && args[0] == "--version") { println("cjdoc " + CJDOC_PRODUCT_VERSION); return 0 }
    if (let Some(exitCode) <- runCommandHelp(args)) { return exitCode }
    if (!args.isEmpty() && (args[0] == "query" || args[0] == "mcp")) {
        return runDocumentationReadCli(args)
    }
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
