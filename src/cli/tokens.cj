protected package cjdoc.cli

import cjdoc.filesystem.hostPathIsAbsolute
import cjdoc.dependency.{validateDependencySourceName, validateInventoryPin}
import cjdoc.manifest.docIrLimitBytes
import std.collection.*
import std.convert.Parsable
import cjdoc.model as public_model

internal func splitNamedValue(value: String, option: String): (String, String) {
    let parts = value.split("=", 2)
    if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("${option} requires NAME=VALUE")
    }
    (parts[0].trimAscii(), parts[1].trimAscii())
}

protected func cliErrorText(message: String, includeUsage: Bool): String {
    if (includeUsage) { "error: ${message}\n${newUsage()}" } else { "error: ${message}" }
}

internal func isCliDocumentationFormat(value: String): Bool {
    value == "json" || value == "markdown" || value == "html" ||
        value == "api-surface" || value == "coverage" || value == "symbol-index"
}

private func addFormat(options: NewCliOptions, value: String): Unit {
    if (!isCliDocumentationFormat(value)) {
        throw IllegalArgumentException("unsupported format '${value}'")
    }
    if (!options.formats.contains(value)) { options.formats.add(value) }
}

private func requireCliValue(args: Array<String>, index: Int64, option: String): String {
    if (index + 1 >= args.size) {
        throw IllegalArgumentException("${option} requires a value")
    }
    args[index + 1]
}

internal func requireNonEmptyCliValue(args: Array<String>, index: Int64, option: String): String {
    let value = requireCliValue(args, index, option)
    if (value.trimAscii().isEmpty()) {
        throw IllegalArgumentException("${option} requires a value")
    }
    value
}

private func requireHighlightHostPath(args: Array<String>, index: Int64, option: String): String {
    let value = requireNonEmptyCliValue(args, index, option)
    // Paths are argv values, never shell command strings.
    for (byte in value.toArray()) {
        if (byte < 32 || byte == 127 || byte == b';' || byte == b'|' || byte == b'&' ||
            byte == b'$' || byte == b'`' || byte == b'<' || byte == b'>' ||
            byte == b'"' || byte == b'\'' || byte == b'(' || byte == b')' ||
            byte == b'*' || byte == b'?' || byte == b'[' || byte == b']' ||
            byte == b'{' || byte == b'}' || byte == b'!' || byte == b'#' || byte == b'~') {
            throw IllegalArgumentException("${option} requires a path without shell metacharacters")
        }
    }
    if (!hostPathIsAbsolute(value)) {
        throw IllegalArgumentException("${option} requires an absolute path")
    }
    value
}


private func parsePathAndTextOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--validation-report" =>
            options.validationReport = Some(requireNonEmptyCliValue(args, index, "--validation-report"))
            Some(index + 2)
        case "--api-diff-report" =>
            options.apiDiffReport = Some(requireNonEmptyCliValue(args, index, "--api-diff-report"))
            Some(index + 2)
        case "--build-context" =>
            options.buildContext = Some(requireNonEmptyCliValue(args, index, "--build-context"))
            Some(index + 2)
        case "--doc-source" =>
            options.documentSources.add(requireNonEmptyCliValue(args, index, "--doc-source"))
            Some(index + 2)
        case "--doc-inventory-pin" =>
            let value = requireNonEmptyCliValue(args, index, "--doc-inventory-pin")
            let separator = value.lastIndexOf("=").getOrThrow({ => IllegalArgumentException("inventory pin requires PATH=SHA256") })
            let path = value[..separator]
            let digest = value[separator + 1..]
            validateInventoryPin(path, digest)
            options.documentInventoryPins.add((path, digest))
            Some(index + 2)
        case "--link-language" =>
            options.linkLanguage = public_model.documentationLanguage(requireNonEmptyCliValue(args, index, "--link-language"))
            Some(index + 2)
        case "--highlight-adapter" =>
            options.highlightAdapter = Some(requireHighlightHostPath(args, index, "--highlight-adapter"))
            Some(index + 2)
        case "--highlight-node" =>
            options.highlightNode = Some(requireHighlightHostPath(args, index, "--highlight-node"))
            Some(index + 2)
        case "--cjc" =>
            options.cjcExecutable = requireNonEmptyCliValue(args, index, "--cjc")
            options.cjcExplicit = true
            Some(index + 2)
        case "--chir-worker" =>
            options.chirWorkerExecutable = Some(
                requireNonEmptyCliValue(args, index, "--chir-worker"))
            Some(index + 2)
        case "--project" =>
            options.project = requireCliValue(args, index, "--project")
            Some(index + 2)
        case "--input" =>
            options.input = Some(requireCliValue(args, index, "--input"))
            Some(index + 2)
        case "--baseline" =>
            options.baselineInput = Some(requireNonEmptyCliValue(args, index, "--baseline"))
            Some(index + 2)
        case "--current" =>
            options.currentInput = Some(requireNonEmptyCliValue(args, index, "--current"))
            Some(index + 2)
        case "--output" =>
            options.output = Some(requireCliValue(args, index, "--output"))
            Some(index + 2)
        case "--cache-dir" =>
            options.cacheDirectory = Some(requireNonEmptyCliValue(args, index, "--cache-dir"))
            options.noCache = false
            options.cacheExplicit = true
            Some(index + 2)
        case "--no-cache" =>
            options.cacheDirectory = None
            options.noCache = true
            options.cacheExplicit = true
            Some(index + 1)
        case "--cache" =>
            // Re-enable the source cache with its default location after a
            // project set [analysis].no-cache = true.
            options.cacheDirectory = None
            options.noCache = false
            options.cacheExplicit = true
            Some(index + 1)
        case "--cjpm-cache" =>
            options.cjpmCacheRoot = Some(requireNonEmptyCliValue(args, index, "--cjpm-cache"))
            Some(index + 2)
        case "--repository-url" =>
            options.repositoryUrl = Some(requireNonEmptyCliValue(args, index, "--repository-url"))
            Some(index + 2)
        case "--repository-revision" =>
            options.repositoryRevision = Some(requireNonEmptyCliValue(args, index, "--repository-revision"))
            Some(index + 2)
        case "--repository-root" =>
            options.repositoryRoot = Some(requireNonEmptyCliValue(args, index, "--repository-root"))
            Some(index + 2)
        case "--api-surface-baseline" =>
            options.apiSurfaceBaseline = Some(requireNonEmptyCliValue(args, index, "--api-surface-baseline"))
            Some(index + 2)
        case "--doc-version" =>
            options.docVersion = Some(requireNonEmptyCliValue(args, index, "--doc-version"))
            Some(index + 2)
        case "--stdlib-doc-version" =>
            options.standardLibraryDocsVersion = Some(requireNonEmptyCliValue(args, index, "--stdlib-doc-version"))
            Some(index + 2)
        case "--stdlib-doc-base-url" =>
            options.standardLibraryDocsBaseUrl = Some(requireNonEmptyCliValue(args, index, "--stdlib-doc-base-url"))
            Some(index + 2)
        case "--locale" =>
            options.locale = requireCliValue(args, index, "--locale")
            options.localeExplicit = true
            Some(index + 2)
        case "--all-languages" =>
            options.allLanguages = true
            Some(index + 1)
        case "--require-language" =>
            options.requiredLanguages.add(public_model.documentationLanguage(requireCliValue(args, index, "--require-language")))
            Some(index + 2)
        case _ => None<Int64>
    }
}

private func parseCollectionOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--chir-import-path" =>
            options.chirImportPaths.add(requireNonEmptyCliValue(args, index, "--chir-import-path"))
            Some(index + 2)
        case "--format" =>
            let value = requireCliValue(args, index, "--format")
            if (options.command == "diff") {
                options.diffFormat = value
            } else {
                addFormat(options, value)
            }
            Some(index + 2)
        case "--dependency-source" =>
            let (name, path) = splitNamedValue(requireCliValue(args, index, "--dependency-source"), "--dependency-source")
            validateDependencySourceName(name)
            options.dependencySources.add((name, path))
            Some(index + 2)
        case "--cfg" =>
            let (name, value) = splitNamedValue(requireCliValue(args, index, "--cfg"), "--cfg")
            options.cfgValues.add((name, value))
            Some(index + 2)
        case _ => None<Int64>
    }
}


private func parseNumericOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--max-doc-ir-mib" =>
            let value = Int64.parse(requireCliValue(args, index, "--max-doc-ir-mib"))
            let _ = docIrLimitBytes(value)
            options.maxDocIrMiB = Some(value)
            Some(index + 2)
        case "--min-symbol-coverage" =>
            options.minSymbolCoverage = Some(
                Int64.parse(requireCliValue(args, index, "--min-symbol-coverage")))
            Some(index + 2)
        case "--min-parameter-coverage" =>
            options.minParameterCoverage = Some(
                Int64.parse(requireCliValue(args, index, "--min-parameter-coverage")))
            Some(index + 2)
        case "--jobs" =>
            options.jobs = Int64.parse(requireCliValue(args, index, "--jobs"))
            options.jobsExplicit = true
            Some(index + 2)
        case "--port" =>
            let port = Int64.tryParse(requireCliValue(args, index, "--port")).getOrDefault({ => -1 })
            if (port < 0 || port > 65535) {
                throw IllegalArgumentException("--port must be an integer in 0..65535")
            }
            options.servePort = port
            Some(index + 2)
        case _ => None<Int64>
    }
}

private func parseEnumOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--semantic" =>
            options.semanticMode = requireCliValue(args, index, "--semantic")
            options.semanticExplicit = true
            Some(index + 2)
        case "--audience" =>
            options.audience = requireCliValue(args, index, "--audience")
            options.audienceExplicit = true
            Some(index + 2)
        case "--lint-profile" =>
            options.lintProfile = requireCliValue(args, index, "--lint-profile")
            options.lintProfileExplicit = true
            Some(index + 2)
        case _ => None<Int64>
    }
}

private func parseFlagOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--link-language-fallback" => options.linkLanguageFallback = true; Some(index + 1)
        case "--link-compatible" => options.linkCompatible = true; Some(index + 1)
        case "--stdout" => options.stdout = true; Some(index + 1)
        case "--deny-warnings" => options.denyWarnings = true; Some(index + 1)
        case "--deny-breaking-api" => options.denyBreakingApi = true; Some(index + 1)
        case "--deny-potentially-breaking-api" => options.denyPotentiallyBreakingApi = true; Some(index + 1)
        case "--check-examples" => options.checkExamples = true; Some(index + 1)
        case "--force-owned" => options.forceOwned = true; Some(index + 1)
        case "--include-path-dependencies" =>
            options.includePathDependencies = true
            options.includePathDependenciesExplicit = true
            Some(index + 1)
        case "--no-include-path-dependencies" =>
            options.includePathDependencies = false
            options.includePathDependenciesExplicit = true
            Some(index + 1)
        case "--include-cached-dependencies" =>
            options.includeCachedDependencies = true
            options.includeCachedDependenciesExplicit = true
            Some(index + 1)
        case "--no-include-cached-dependencies" =>
            options.includeCachedDependencies = false
            options.includeCachedDependenciesExplicit = true
            Some(index + 1)
        case "--open" => options.serveOpen = true; Some(index + 1)
        case "--agent-full" => options.agentFull = true; options.agentFullExplicit = true; Some(index + 1)
        case "--no-agent-full" => options.agentFull = false; options.agentFullExplicit = true; Some(index + 1)

        case _ => None<Int64>
    }
}

private func parseHtmlFontOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--html-font-sans" =>
            options.htmlFontSans = Some(requireCliValue(args, index, "--html-font-sans"))
            Some(index + 2)
        case "--html-font-mono" =>
            options.htmlFontMono = Some(requireCliValue(args, index, "--html-font-mono"))
            Some(index + 2)
        case _ => None<Int64>
    }
}

internal func parseCliOption(options: NewCliOptions, args: Array<String>, index: Int64): Int64 {
    validateDocumentOptionScope(options.command, args[index])
    if (let Some(next) <- parsePathAndTextOption(options, args, index)) { return next }
    if (let Some(next) <- parseCollectionOption(options, args, index)) { return next }
    if (let Some(next) <- parseNumericOption(options, args, index)) { return next }
    if (let Some(next) <- parseEnumOption(options, args, index)) { return next }
    if (let Some(next) <- parseFlagOption(options, args, index)) { return next }
    if (let Some(next) <- parseHtmlFontOption(options, args, index)) { return next }
    throw IllegalArgumentException("unknown option '${args[index]}'")
}
