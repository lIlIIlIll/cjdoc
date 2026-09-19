package cjdoc

import std.collection.*
import std.convert.Parsable

internal class NewCliOptions {
    var command = ""
    var project = "."
    var projectExplicit = false
    var output: ?String = None
    var input: ?String = None
    var baselineInput: ?String = None
    var currentInput: ?String = None
    var diffFormat = "text"
    var denyBreakingApi = false
    var denyPotentiallyBreakingApi = false
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
    var repositoryUrl: ?String = None
    var repositoryRevision: ?String = None
    var repositoryRoot: ?String = None
    var apiSurfaceBaseline: ?String = None
    var minSymbolCoverage: ?Int64 = None
    var minParameterCoverage: ?Int64 = None
    var locale = "zh-CN"
    var localeExplicit = false
    var markdownLayout = "site"
    var markdownLayoutExplicit = false
    var docVersion: ?String = None
    var agentFull = false
    var versionSubcommand = ""

    let versionInputs = ArrayList<String>()
    let versionLabels = HashMap<String, String>()
    let versionChannels = HashMap<String, String>()
    let versionStatuses = HashMap<String, String>()
    let versionBasePaths = HashMap<String, String>()
    let versionReleases = HashMap<String, String>()
    let versionDiffs = HashMap<String, String>()
    let versionAssignmentIds = ArrayList<String>()
    var latestVersion: ?String = None
    var servePort: Int64 = 8080
    var servePortExplicit = false
    var serveOpen = false
    var serveOpenExplicit = false
    let dependencySources = ArrayList<DependencySourceInput>()
    let cfgValues = ArrayList<CfgValue>()
}
internal func newUsage(): String {
    "usage:\n" +
    "  cjdoc generate [--project <dir>] [--format json|markdown|html|api-surface|coverage|symbol-index]... [--output <dir>|--stdout]\n" +
    "                 [--audience external|package|all] [--lint-profile off|standard|strict] [--jobs 1..64]\n" +
    "                 [--cfg NAME=VALUE] [--include-path-dependencies] [--include-cached-dependencies]\n" +
    "                 [--dependency-source NAME=PATH] [--cjpm-cache <dir>]\n" +
    "                 [--cache-dir <dir>|--no-cache] [--force-owned]\n" +
    "                 [--locale zh-CN|en] [--markdown-layout site|single]\n" +
    "                 [--doc-version SAFE_ID]\n" +
    "                 [--agent-full]\n" +
    "  cjdoc check [--project <dir>] [--deny-warnings] [--lint-profile off|standard|strict]\n" +
    "              [--api-surface-baseline <file>] [--min-symbol-coverage 0..100] [--min-parameter-coverage 0..100]\n" +
    "  cjdoc diff OLD NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]\n" +
    "  cjdoc diff --baseline OLD --current NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]\n" +
    "  cjdoc render --input <docs.json> [--format json|markdown|html|api-surface|coverage|symbol-index]... [--output <dir>|--stdout] [--force-owned]\n" +
    "               [--locale zh-CN|en] [--markdown-layout site|single]\n" +
    "  cjdoc versions compose --version ID=HTML_DIR... [--diff ID=API_DIFF_JSON] --output DIR [--latest ID]\\n" +
    "  cjdoc schema list|doc-ir|doc-ir-v6|doc-ir-v7|doc-ir-v8|doc-ir-v9|doc-ir-v10|diagnostics|cfg-matrix|search-index|symbol-index|navigation-index|api-surface|api-surface-v1|api-diff|documentation-coverage-v1|documentation-coverage|doctest-results|versions\n" +
    "  cjdoc serve [--project <dir>] [--port 1..65535] [--open] [generation options]\n"
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
        value != "api-surface" && value != "coverage" && value != "symbol-index") {
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

private func requireNonEmptyCliValue(args: Array<String>, index: Int64, option: String): String {
    let value = requireCliValue(args, index, option)
    if (value.trimAscii().isEmpty()) {
        throw IllegalArgumentException("${option} requires a value")
    }
    value
}

private func parsePathAndTextOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
        case "--project" =>
            options.project = requireCliValue(args, index, "--project")
            options.projectExplicit = true
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
            Some(index + 2)
        case "--no-cache" =>
            options.cacheDirectory = None
            options.noCache = true
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
        case "--locale" =>
            options.locale = requireCliValue(args, index, "--locale")
            options.localeExplicit = true
            Some(index + 2)
        case "--markdown-layout" =>
            options.markdownLayout = requireCliValue(args, index, "--markdown-layout")
            options.markdownLayoutExplicit = true
            Some(index + 2)
        case _ => None<Int64>
    }
}

private func parseCollectionOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
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
            options.dependencySources.add(DependencySourceInput(name, path))
            Some(index + 2)
        case "--cfg" =>
            let (name, value) = splitNamedValue(requireCliValue(args, index, "--cfg"), "--cfg")
            options.cfgValues.add(CfgValue(name, value))
            Some(index + 2)
        case _ => None<Int64>
    }
}


private func parseNumericOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
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
            options.servePort = Int64.parse(requireCliValue(args, index, "--port"))
            options.servePortExplicit = true
            Some(index + 2)
        case _ => None<Int64>
    }
}

private func parseEnumOption(options: NewCliOptions, args: Array<String>, index: Int64): ?Int64 {
    match (args[index]) {
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
        case "--stdout" => options.stdout = true; Some(index + 1)
        case "--deny-warnings" => options.denyWarnings = true; Some(index + 1)
        case "--deny-breaking-api" => options.denyBreakingApi = true; Some(index + 1)
        case "--deny-potentially-breaking-api" => options.denyPotentiallyBreakingApi = true; Some(index + 1)
        case "--force-owned" => options.forceOwned = true; Some(index + 1)
        case "--include-path-dependencies" => options.includePathDependencies = true; Some(index + 1)
        case "--include-cached-dependencies" => options.includeCachedDependencies = true; Some(index + 1)
        case "--open" => options.serveOpen = true; options.serveOpenExplicit = true; Some(index + 1)
        case "--agent-full" => options.agentFull = true; Some(index + 1)

        case _ => None<Int64>
    }
}

private func parseCliOption(options: NewCliOptions, args: Array<String>, index: Int64): Int64 {
    if (let Some(next) <- parsePathAndTextOption(options, args, index)) { return next }
    if (let Some(next) <- parseCollectionOption(options, args, index)) { return next }
    if (let Some(next) <- parseNumericOption(options, args, index)) { return next }
    if (let Some(next) <- parseEnumOption(options, args, index)) { return next }
    if (let Some(next) <- parseFlagOption(options, args, index)) { return next }
    throw IllegalArgumentException("unknown option '${args[index]}'")
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
    if (options.output.isSome() || options.stdout || options.projectExplicit || options.input.isSome() ||
        options.apiSurfaceBaseline.isSome() || options.minSymbolCoverage.isSome() ||
        options.minParameterCoverage.isSome() || options.denyWarnings || options.forceOwned ||
        options.jobsExplicit || options.audienceExplicit || options.lintProfileExplicit ||
        options.includePathDependencies || options.includeCachedDependencies ||
        options.cacheDirectory.isSome() || options.noCache || options.cjpmCacheRoot.isSome() ||
        options.repositoryUrl.isSome() || options.repositoryRevision.isSome() || options.repositoryRoot.isSome() ||
        !options.dependencySources.isEmpty() || !options.cfgValues.isEmpty() ||
        options.docVersion.isSome() || options.agentFull || options.servePortExplicit ||
        options.serveOpenExplicit) {
        throw IllegalArgumentException("diff accepts only input paths, --format, and API deny flags")
    }
}

private func validateCliOptions(options: NewCliOptions): Unit {
    if (options.command == "diff") { validateDiffOptions(options); return }
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
    if (options.docVersion.isSome() && options.command != "generate" && options.command != "render") {
        throw IllegalArgumentException("--doc-version is only valid for generate or render")
    }
    if (options.docVersion.isSome() && !options.formats.contains("html")) {
        throw IllegalArgumentException("--doc-version requires --format html")
    }
    if (options.agentFull && options.command != "generate" && options.command != "render" &&
        options.command != "serve") {
        throw IllegalArgumentException("--agent-full is only valid for generate, render, or serve")
    }
    if (options.agentFull && options.command != "serve" && !options.formats.contains("html")) {
        throw IllegalArgumentException("--agent-full requires --format html")
    }

    if (options.stdout && (options.formats.size != 1 ||
        (options.formats[0] != "json" && options.formats[0] != "api-surface" &&
            options.formats[0] != "coverage" && options.formats[0] != "symbol-index"))) {
        throw IllegalArgumentException("--stdout requires exactly one JSON-producing format")
    }
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
private func parseVersionAssignment(options: NewCliOptions, args: Array<String>, index: Int64,
    option: String, target: HashMap<String, String>, assignmentIds: ArrayList<String>): Int64 {
    let (id, value) = splitNamedValue(requireNonEmptyCliValue(args, index, option), option)
    if (target.contains(id)) { throw IllegalArgumentException("duplicate versions assignment") }
    target[id] = value
    assignmentIds.add(id)
    index + 2
}

private func parseVersionsCommand(args: Array<String>): NewCliOptions {
    if (args.size < 3 || args[1] != "compose") {
        throw IllegalArgumentException("versions requires the compose subcommand")
    }
    let options = NewCliOptions()
    options.command = "versions"
    options.versionSubcommand = "compose"
    var index: Int64 = 2
    while (index < args.size) {
        match (args[index]) {
            case "--version" =>
                let (id, path) = splitNamedValue(requireNonEmptyCliValue(args, index, "--version"), "--version")
                options.versionInputs.add(id + "=" + path)
                index += 2
            case "--label" => index = parseVersionAssignment(options, args, index, "--label", options.versionLabels, options.versionAssignmentIds)
            case "--channel" => index = parseVersionAssignment(options, args, index, "--channel", options.versionChannels, options.versionAssignmentIds)
            case "--status" => index = parseVersionAssignment(options, args, index, "--status", options.versionStatuses, options.versionAssignmentIds)
            case "--base-path" => index = parseVersionAssignment(options, args, index, "--base-path", options.versionBasePaths, options.versionAssignmentIds)
            case "--release" => index = parseVersionAssignment(options, args, index, "--release", options.versionReleases, options.versionAssignmentIds)
            case "--diff" => index = parseVersionAssignment(options, args, index, "--diff", options.versionDiffs, options.versionAssignmentIds)
            case "--latest" =>
                options.latestVersion = Some(requireNonEmptyCliValue(args, index, "--latest"))
                index += 2
            case "--output" =>
                options.output = Some(requireNonEmptyCliValue(args, index, "--output"))
                index += 2
            case "--force-owned" =>
                options.forceOwned = true
                index++
            case _ => throw IllegalArgumentException("unsupported versions compose option")
        }
    }
    if (options.versionInputs.isEmpty()) {
        throw IllegalArgumentException("versions compose requires --version ID=PATH")
    }
    if (options.output.isNone()) {
        throw IllegalArgumentException("versions compose requires --output")
    }
    options
}

private func parseSchemaCommand(args: Array<String>): NewCliOptions {
    if (args.size != 2) { throw IllegalArgumentException("schema requires exactly one schema name") }
    let options = NewCliOptions()
    options.command = "schema"
    options.schemaName = args[1]
    if (options.schemaName != "list" && options.schemaName != "doc-ir" &&
        options.schemaName != "doc-ir-v6" && options.schemaName != "doc-ir-v7" &&
        options.schemaName != "doc-ir-v8" && options.schemaName != "doc-ir-v9" &&
        options.schemaName != "doc-ir-v10" && options.schemaName != "diagnostics" &&
        options.schemaName != "cfg-matrix" && options.schemaName != "search-index" &&
        options.schemaName != "symbol-index" &&
        options.schemaName != "api-surface" && options.schemaName != "api-surface-v1" &&
        options.schemaName != "api-diff" && options.schemaName != "documentation-coverage-v1" &&
        options.schemaName != "documentation-coverage" &&
        options.schemaName != "navigation-index" &&
        options.schemaName != "versions" &&
        options.schemaName != "doctest-results") {
        throw IllegalArgumentException("unknown schema '${options.schemaName}'")
    }
    options
}

private func parseDocumentOptions(args: Array<String>): NewCliOptions {
    let options = NewCliOptions()
    options.command = args[0]
    var index: Int64 = 1
    while (index < args.size) {
        if (options.command == "diff" && !args[index].startsWith("-")) {
            if (options.baselineInput.isNone()) {
                options.baselineInput = Some(args[index])
                index++
                continue
            }
            if (options.currentInput.isNone()) {
                options.currentInput = Some(args[index])
                index++
                continue
            }
        }
        index = parseCliOption(options, args, index)
    }
    validateCliOptions(options)
    options
}

internal func parseNewCli(args: Array<String>): NewCliOptions {
    if (args.isEmpty()) { throw IllegalArgumentException("missing command") }
    if (args[0] == "schema") { return parseSchemaCommand(args) }
    if (args[0] == "versions") { return parseVersionsCommand(args) }
    if (args[0] != "generate" && args[0] != "check" && args[0] != "render" &&
        args[0] != "diff" && args[0] != "serve") {
        throw IllegalArgumentException("unknown command '${args[0]}'")
    }
    parseDocumentOptions(args)
}

