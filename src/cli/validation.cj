protected package cjdoc.cli

import cjdoc.render as public_render
import cjdoc.stdlib_docs.{hasBuiltInStandardLibraryDocsBase,
    isValidStandardLibraryDocsBaseUrl, isValidStandardLibraryDocsVersion}
import std.collection.ArrayList

private func validateHtmlFontOptions(options: NewCliOptions): Unit {
    for ((value, option) in [(options.htmlFontSans, "--html-font-sans"),
        (options.htmlFontMono, "--html-font-mono")]) {
        let list = match (value) {
            case Some(list) => list
            case None => continue
        }
        if (options.command != "generate" && options.command != "render" && options.command != "serve") {
            throw IllegalArgumentException("${option} is only valid for generate, render, or serve")
        }
        if (options.command != "serve" && !options.formats.contains("html")) {
            throw IllegalArgumentException("${option} requires --format html")
        }
        if (!public_render.isValidHtmlFontFamilyList(list)) {
            throw IllegalArgumentException("invalid ${option} value")
        }
    }
}

private func validateDiffOptions(options: NewCliOptions): Unit {
    if (options.diffFormat != "text" && options.diffFormat != "json") {
        throw IllegalArgumentException("diff --format must be text or json")
    }
    let hasBaseline = options.baselineInput.isSome()
    let hasCurrent = options.currentInput.isSome()
    if (hasBaseline != hasCurrent) {
        throw IllegalArgumentException("diff requires both baseline and current inputs")
    }
    if (!hasBaseline) { throw IllegalArgumentException("diff requires OLD NEW or --baseline/--current") }
    if (options.maxDocIrMiB.isSome() || options.output.isSome() || options.stdout || options.projectExplicit || options.input.isSome() ||
        options.apiSurfaceBaseline.isSome() || options.minSymbolCoverage.isSome() ||
        options.minParameterCoverage.isSome() || options.denyWarnings || options.forceOwned ||
        options.jobsExplicit || options.audienceExplicit || options.lintProfileExplicit ||
        options.includePathDependencies || options.includeCachedDependencies ||
        options.cacheDirectory.isSome() || options.noCache || options.cjpmCacheRoot.isSome() ||
        options.repositoryUrl.isSome() || options.repositoryRevision.isSome() || options.repositoryRoot.isSome() ||
        !options.dependencySources.isEmpty() || !options.cfgValues.isEmpty() ||
        options.docVersion.isSome() || options.standardLibraryDocsVersion.isSome() ||
        options.standardLibraryDocsBaseUrl.isSome() || options.agentFull ||
        options.htmlFontSans.isSome() || options.htmlFontMono.isSome() ||
        options.servePortExplicit || options.serveOpenExplicit || options.checkExamples ||
        !options.formats.isEmpty() ||
        options.semanticExplicit || options.cjcExplicit ||
        options.chirWorkerExecutable.isSome() || !options.chirImportPaths.isEmpty() ||
        options.cacheExplicit || options.cjpmCacheExplicit || options.agentFullExplicit ||
        options.includePathDependenciesExplicit || options.includeCachedDependenciesExplicit ||
        // diff's --format selects its own encoding, not documentation output.
        options.localeExplicit || options.allLanguages || !options.requiredLanguages.isEmpty() ||
        options.versionSubcommand != "" || !options.versionInputs.isEmpty() ||
        !options.versionLabels.isEmpty() || !options.versionChannels.isEmpty() ||
        !options.versionStatuses.isEmpty() || !options.versionBasePaths.isEmpty() ||
        !options.versionReleases.isEmpty() || !options.versionDiffs.isEmpty() ||
        !options.versionAssignmentIds.isEmpty() || options.latestVersion.isSome()) {
        throw IllegalArgumentException("diff accepts only input paths, --format, and API deny flags")
    }
}

private func validateSharedOptionScopes(options: NewCliOptions): Unit {
    if ((options.validationReport.isSome() || options.apiDiffReport.isSome()) &&
        options.command != "generate" && options.command != "render") {
        throw IllegalArgumentException("captured report attachments are only valid for generate and render")
    }
    if ((options.buildContext.isSome() || !options.documentSources.isEmpty() || !options.documentInventoryPins.isEmpty() || !options.linkLanguage.isEmpty() ||
        options.linkLanguageFallback || options.linkCompatible) && options.command != "generate" && options.command != "check") {
        throw IllegalArgumentException("dependency documentation options are only valid for generate and check")
    }
    if (options.highlightAdapter.isSome() || options.highlightNode.isSome()) {
        if (options.command != "generate" && options.command != "check") {
            throw IllegalArgumentException("highlight host options are only valid for generate and check")
        }
        if (options.highlightAdapter.isNone() || options.highlightNode.isNone()) {
            throw IllegalArgumentException("--highlight-adapter and --highlight-node must be supplied together")
        }
    }
}

private func validateCommandOptionValues(options: NewCliOptions): Unit {
    if (options.denyBreakingApi || options.denyPotentiallyBreakingApi) {
        throw IllegalArgumentException("API deny flags are only valid for diff")
    }
    if (options.jobs < 1 || options.jobs > 64) { throw IllegalArgumentException("--jobs must be in 1..64") }
    if (options.audience != "external" && options.audience != "package" && options.audience != "all") {
        throw IllegalArgumentException("--audience must be external, package, or all")
    }
    if (options.lintProfile != "off" && options.lintProfile != "standard" && options.lintProfile != "strict") {
        throw IllegalArgumentException("--lint-profile must be off, standard, or strict")
    }
    if (options.semanticMode != "source" && options.semanticMode != "chir") {
        throw IllegalArgumentException("--semantic must be source or chir")
    }
    if (options.command != "generate" && options.command != "check" &&
        options.command != "serve" &&
        (options.semanticExplicit || options.cjcExplicit ||
            options.chirWorkerExecutable.isSome() || !options.chirImportPaths.isEmpty())) {
        throw IllegalArgumentException(
            "semantic options are only valid for generate, check, and serve")
    }
    if (options.semanticMode == "source" &&
        (options.cjcExplicit || options.chirWorkerExecutable.isSome() ||
            !options.chirImportPaths.isEmpty())) {
        throw IllegalArgumentException(
            "--cjc, --chir-worker, and --chir-import-path require --semantic chir")
    }
    for (threshold in [options.minSymbolCoverage, options.minParameterCoverage]) {
        if (threshold.isSome() && (threshold.getOrThrow() < 0 || threshold.getOrThrow() > 100)) {
            throw IllegalArgumentException("coverage thresholds must be in 0..100")
        }
    }
    if (options.locale != "zh-CN" && options.locale != "en") {
        throw IllegalArgumentException("--locale must be zh-CN or en")
    }
    if (options.allLanguages && (options.localeExplicit || options.stdout ||
        (options.command != "generate" && options.command != "render"))) {
        throw IllegalArgumentException("--all-languages supports generate/render directory output with site Markdown and conflicts with --locale")
    }
}

private func validateRenderCommandOptions(options: NewCliOptions): Unit {
    if (options.command == "render" && options.input.isNone()) {
        throw IllegalArgumentException("render requires --input")
    }
    if (options.command == "render" && (options.projectExplicit || options.denyWarnings ||
        options.checkExamples || options.includePathDependencies || options.includeCachedDependencies ||
        options.includePathDependenciesExplicit || options.includeCachedDependenciesExplicit ||
        options.cacheExplicit || options.cjpmCacheExplicit ||
        options.cacheDirectory.isSome() || options.noCache || options.cjpmCacheRoot.isSome() ||
        options.apiSurfaceBaseline.isSome() || options.minSymbolCoverage.isSome() ||
        options.minParameterCoverage.isSome() || !options.requiredLanguages.isEmpty() ||
        !options.dependencySources.isEmpty() || !options.cfgValues.isEmpty() ||
        options.jobsExplicit || options.audienceExplicit || options.lintProfileExplicit)) {
        throw IllegalArgumentException(
            "render accepts only --input, render options, and --max-doc-ir-mib")
    }
    if (options.command != "render" && options.input.isSome()) {
        throw IllegalArgumentException("--input is only valid for render")
    }
    if (options.command == "check" && (!options.formats.isEmpty() || options.output.isSome() || options.stdout)) {
        throw IllegalArgumentException("check does not accept render output options")
    }
    if (options.command == "check" && options.localeExplicit) {
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
}

private func validateRenderOutputOptions(options: NewCliOptions): Unit {
    if (options.formats.isEmpty() && options.command != "check") { options.formats.add("json") }
    if (options.docVersion.isSome() && options.command != "generate" && options.command != "render") {
        throw IllegalArgumentException("--doc-version is only valid for generate or render")
    }
    if (options.docVersion.isSome() && !options.formats.contains("html")) {
        throw IllegalArgumentException("--doc-version requires --format html")
    }
    if ((options.standardLibraryDocsVersion.isSome() || options.standardLibraryDocsBaseUrl.isSome()) &&
        options.command != "generate") {
        throw IllegalArgumentException("--stdlib-doc-version and --stdlib-doc-base-url are only valid for generate")
    }
    if (let Some(baseUrl) <- options.standardLibraryDocsBaseUrl) {
        if (!isValidStandardLibraryDocsBaseUrl(baseUrl)) {
            throw IllegalArgumentException("--stdlib-doc-base-url must be HTTPS and end in /libs/std")
        }
    }
    if (let Some(version) <- options.standardLibraryDocsVersion) {
        if (!isValidStandardLibraryDocsVersion(version)) {
            throw IllegalArgumentException("--stdlib-doc-version must be a safe URL path segment")
        }
        if (options.standardLibraryDocsBaseUrl.isNone() && !hasBuiltInStandardLibraryDocsBase(version)) {
            throw IllegalArgumentException("--stdlib-doc-base-url is required for this standard-library documentation version")
        }
    }
    if (options.agentFull && options.command != "generate" && options.command != "render" &&
        options.command != "serve") {
        throw IllegalArgumentException("--agent-full is only valid for generate, render, or serve")
    }
    if (options.agentFull && options.command != "serve" && !options.formats.contains("html")) {
        throw IllegalArgumentException("--agent-full requires --format html")
    }
    validateHtmlFontOptions(options)
    if (options.validationReport.isSome() || options.apiDiffReport.isSome()) {
        if ((options.command != "generate" && options.command != "render") ||
            !options.formats.contains("html") || options.stdout) {
            throw IllegalArgumentException("captured report attachments require generate/render HTML directory output")
        }
    }

    if (options.stdout && (options.formats.size != 1 ||
        (options.formats[0] != "json" && options.formats[0] != "api-surface" &&
            options.formats[0] != "coverage" && options.formats[0] != "symbol-index"))) {
        throw IllegalArgumentException("--stdout requires exactly one JSON-producing format")
    }
}

private func validateRepositoryAndCacheOptions(options: NewCliOptions): Unit {
    let hasRepositoryUrl = options.repositoryUrl.isSome()
    let hasRepositoryRevision = options.repositoryRevision.isSome()
    if (hasRepositoryUrl != hasRepositoryRevision) {
        throw IllegalArgumentException("--repository-url and --repository-revision must be provided together")
    }
    if (options.repositoryRoot.isSome() && !hasRepositoryUrl) {
        throw IllegalArgumentException("--repository-root requires --repository-url and --repository-revision")
    }
    if (options.command != "generate" && options.command != "serve" &&
        (hasRepositoryUrl || hasRepositoryRevision || options.repositoryRoot.isSome())) {
        throw IllegalArgumentException("repository options are only valid for generate")
    }
    if (options.cjpmCacheRoot.isSome() && !options.includeCachedDependencies) {
        throw IllegalArgumentException("--cjpm-cache requires --include-cached-dependencies")
    }
}

internal func validateCliOptions(options: NewCliOptions): Unit {
    validateSharedOptionScopes(options)
    if (options.command == "diff") { validateDiffOptions(options); return }
    validateCommandOptionValues(options)
    validateRenderCommandOptions(options)
    validateRenderOutputOptions(options)
    validateRepositoryAndCacheOptions(options)
}
