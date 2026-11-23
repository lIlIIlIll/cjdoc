package cjdoc

import cjdoc.semantic.SemanticProvider
import cjdoc.cli.{NewCliOptions, capturedCliReports, cliErrorText, currentCjdocExecutablePath, newUsage,
    orderedFormats, parseNewCli, passesCliCoverageGates, runCommandHelp, runDocumentationReadCli,
    runSchema, runServeCommand, runVersionsCompose, selectedCliChirWorker, selectedCliRenderLocale, selectedOutputDirectory,
    selectedSourceCacheDirectory}
import cjdoc.manifest.docIrLimitBytes
import cjdoc.filesystem.readTextBounded
import cjdoc.output.{OutputPublication, prepareOutputAndCacheDirectories, withOutputPublication}
import cjdoc.versions.appendDocumentVersionArtifactInto
import cjdoc.model as public_model
import cjdoc.render as public_render
import cjdoc.render.foundation.RenderArtifactStore
import std.collection.*
import std.env.*
import std.fs.*
import cjdoc_chir_protocol.CJDOC_PRODUCT_VERSION

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
internal func renderArtifactsIntoWithCommandFallback(store: RenderArtifactStore,
    restartDraft: () -> Unit, documentation: public_model.DocumentationSet, formats: Array<String>,
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
        public_render.renderDocumentationInto(store, documentation, formats, locale: locale,
            docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull,
            reports: reports, htmlFonts: htmlFonts)
        documentation
    } catch (error: public_render.RenderResourceLimitException) {
        match (generationRequest) {
            case Some(request) =>
                restartDraft()
                let fallback = boundGeneratedDocumentation(documentation, request, force: true)
                public_render.renderDocumentationInto(store, fallback, formats, locale: locale,
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
    var failed = !passesCliCoverageGates(documentation, options)
    match (options.apiSurfaceBaseline) {
        case Some(path) =>
            if (!apiSurfaceBaselineGate(documentation, path)) { failed = true }
        case None => ()
    }
    if (failed) { 1 } else { 0 }
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



internal func executeDocumentCommand(options: NewCliOptions, selectedCache: ?String,
    publication: ?OutputPublication): Int64 {
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
            dependencySources: Array<DependencySourceInput>(options.dependencySources.size, { index =>
                let (name, path) = options.dependencySources[index]
                DependencySourceInput(name, path)
            }),
            cfgValues: Array<CfgValue>(options.cfgValues.size, { index =>
                let (name, value) = options.cfgValues[index]
                CfgValue(name, value)
            }),
            cacheDirectory: selectedCache,
            astPreflightExecutable: astPreflightExecutable,
            chir: chirOptions,
            cjpmCacheRoot: options.cjpmCacheRoot,
            highlightAdapter: options.highlightAdapter, highlightNode: options.highlightNode,
            requiredLanguages: options.requiredLanguages.toArray(), buildContext: options.buildContext,
            documentSources: options.documentSources.toArray(), linkLanguage: options.linkLanguage,
            linkLanguageFallback: options.linkLanguageFallback, linkCompatible: options.linkCompatible,
            documentInventoryPins: Array<DocumentInventoryPin>(options.documentInventoryPins.size, { index =>
                let (path, digest) = options.documentInventoryPins[index]
                DocumentInventoryPin(path, digest)
            }),
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
            public_render.decodeDocIr(readTextBounded(Path(options.input.getOrThrow()), limit),
                maxDocumentBytes: limit)
    }
    if (options.command != "check" && !options.stdout) {
        let output = publication.getOrThrow()
        let store = output.begin()
        documentation = renderArtifactsIntoWithCommandFallback(store, { => output.restart() },
            documentation, orderedFormats(options), generationRequest, locale: renderLocale,
            docVersion: options.docVersion, allLanguages: options.allLanguages,
            agentFull: options.agentFull, reports: capturedCliReports(options),
            htmlFonts: public_render.HtmlFontOptions(sans: options.htmlFontSans,
                mono: options.htmlFontMono))
        match (options.docVersion) {
            case Some(version) =>
                appendDocumentVersionArtifactInto(store, version, documentation.project.name)
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
    if (options.command != "check" && options.stdout) {
        getStdOut().write(artifacts[0].content.toArray())
    }
    if (diagnosticsExit != 0 || contractExit != 0) { 1 } else { 0 }
}

internal func runServeRebuild(options: NewCliOptions, output: String, cache: ?String,
    writeOnFailure: Bool): Int64 {
    withOutputPublication(output, options.forceOwned, { publication =>
        executeDocumentCommand(options, cache, Some(publication))
    }, writeOnFailure: writeOnFailure)
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

func runCli(args: Array<String>): Int64 {
    if (args.size == 1 && (args[0] == "--help" || args[0] == "-h")) { print(newUsage()); return 0 }
    if (args.size == 1 && args[0] == "--version") { println("cjdoc " + CJDOC_PRODUCT_VERSION); return 0 }
    if (let Some(exitCode) <- runCommandHelp(args)) { return exitCode }
    if (!args.isEmpty() && (args[0] == "query" || args[0] == "mcp")) {
        return runDocumentationReadCli(args, { paths =>
            let session = DocumentationQuerySession(paths)
            { request: String => session.execute(request) }
        }, documentationQueryExitCode)
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
        if (options.command == "serve") { return runServeCommand(options, runServeRebuild) }
        if (options.command == "check" || options.stdout) {
            let requestedCache: ?String = if (options.command == "render") { None }
                else { selectedSourceCacheDirectory(options) }
            let (_, selectedCache) = prepareOutputAndCacheDirectories(
                selectedOutputDirectory(options), requestedCache)
            return executeDocumentCommand(options, selectedCache, None<OutputPublication>)
        }
        let requestedOutput = selectedOutputDirectory(options)
        let requestedCache: ?String = if (options.command == "render") { None }
            else { selectedSourceCacheDirectory(options) }
        let (output, selectedCache) = prepareOutputAndCacheDirectories(requestedOutput, requestedCache)
        withOutputPublication(output, options.forceOwned, { publication =>
            executeDocumentCommand(options, selectedCache, Some(publication))
        }, afterRelease: { => println("generated ${selectedOutputDirectory(options)}") })
    } catch (error: Exception) {
        eprintln(cliErrorText(error.message, false))
        2
    }
}
