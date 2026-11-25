protected package cjdoc.cli

import cjdoc.render as public_render
import cjdoc.stdlib_docs.{hasBuiltInStandardLibraryDocsBase,
    isValidStandardLibraryDocsBaseUrl, isValidStandardLibraryDocsVersion}

private func validateHtmlFontOptions(options: NewCliOptions): Unit {
    for ((value, option) in [(options.htmlFontSans, "--html-font-sans"),
        (options.htmlFontMono, "--html-font-mono")]) {
        let list = match (value) {
            case Some(list) => list
            case None => continue
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
}

private func validateHighlightPair(options: NewCliOptions): Unit {
    if (options.highlightAdapter.isSome() != options.highlightNode.isSome()) {
        throw IllegalArgumentException("--highlight-adapter and --highlight-node must be supplied together")
    }
}

private func validateCommandOptionValues(options: NewCliOptions): Unit {
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
    if (options.allLanguages && (options.localeExplicit || options.stdout)) {
        throw IllegalArgumentException("--all-languages requires site Markdown or HTML directory output and conflicts with --locale")
    }
}

private func validateRenderCommandOptions(options: NewCliOptions): Unit {
    if (options.command == "render" && options.input.isNone()) {
        throw IllegalArgumentException("render requires --input")
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
    if (options.docVersion.isSome() && !options.formats.contains("html")) {
        throw IllegalArgumentException("--doc-version requires --format html")
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
    if (options.agentFull && options.command != "serve" && !options.formats.contains("html")) {
        throw IllegalArgumentException("--agent-full requires --format html")
    }
    validateHtmlFontOptions(options)
    if ((options.validationReport.isSome() || options.apiDiffReport.isSome()) &&
        (!options.formats.contains("html") || options.stdout)) {
        throw IllegalArgumentException("captured report attachments require HTML directory output")
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
    if (options.cjpmCacheRoot.isSome() && !options.includeCachedDependencies) {
        throw IllegalArgumentException("--cjpm-cache requires --include-cached-dependencies")
    }
}

internal func validateCliOptions(options: NewCliOptions): Unit {
    validateHighlightPair(options)
    if (options.command == "diff") { validateDiffOptions(options); return }
    validateCommandOptionValues(options)
    validateRenderCommandOptions(options)
    validateRenderOutputOptions(options)
    validateRepositoryAndCacheOptions(options)
}
