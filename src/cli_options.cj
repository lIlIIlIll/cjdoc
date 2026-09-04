package cjdoc

import std.collection.*
import std.convert.Parsable

internal class NewCliOptions {
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

internal func newUsage(): String {
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
        case "--api-surface-baseline" =>
            options.apiSurfaceBaseline = Some(
                requireNonEmptyCliValue(args, index, "--api-surface-baseline"))
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
            addFormat(options, requireCliValue(args, index, "--format"))
            Some(index + 2)
        case "--dependency-source" =>
            let (name, path) = splitNamedValue(
                requireCliValue(args, index, "--dependency-source"), "--dependency-source")
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
        case "--force-owned" => options.forceOwned = true; Some(index + 1)
        case "--include-path-dependencies" => options.includePathDependencies = true; Some(index + 1)
        case "--include-cached-dependencies" => options.includeCachedDependencies = true; Some(index + 1)
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

private func validateCliOptions(options: NewCliOptions): Unit {
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
}

private func parseSchemaCommand(args: Array<String>): NewCliOptions {
    if (args.size != 2) { throw IllegalArgumentException("schema requires exactly one schema name") }
    let options = NewCliOptions()
    options.command = "schema"
    options.schemaName = args[1]
    if (options.schemaName != "list" && options.schemaName != "doc-ir" &&
        options.schemaName != "doc-ir-v6" && options.schemaName != "doc-ir-v7" &&
        options.schemaName != "doc-ir-v8" && options.schemaName != "diagnostics" &&
        options.schemaName != "cfg-matrix" && options.schemaName != "search-index" &&
        options.schemaName != "api-surface" && options.schemaName != "documentation-coverage") {
        throw IllegalArgumentException("unknown schema '${options.schemaName}'")
    }
    options
}

private func parseDocumentOptions(args: Array<String>): NewCliOptions {
    let options = NewCliOptions()
    options.command = args[0]
    var index: Int64 = 1
    while (index < args.size) {
        index = parseCliOption(options, args, index)
    }
    validateCliOptions(options)
    options
}

internal func parseNewCli(args: Array<String>): NewCliOptions {
    if (args.isEmpty()) { throw IllegalArgumentException("missing command") }
    if (args[0] == "schema") { return parseSchemaCommand(args) }
    if (args[0] != "generate" && args[0] != "check" && args[0] != "render") {
        throw IllegalArgumentException("unknown command '${args[0]}'")
    }
    parseDocumentOptions(args)
}
