package cjdoc

import cjdoc.render as public_render
import std.collection.*
import std.convert.Parsable
import std.fs.*

// One project-root `cjdoc.toml` feeds both the documented per-table policies
// and the common CLI defaults. The file is validated as a whole so a misspelled
// table or key fails before generation, even when a CLI flag overrides the value
// that could not be read. Tables that already have an owning reader keep their
// own key-level rules and error text; this scanner only checks that the table
// itself exists and that its key names are spelled as that reader expects.
internal let PROJECT_CONFIG_MAX_BYTES: Int64 = 256 * 1024
private let PROJECT_CONFIG_LIST_MAX_VALUES: Int64 = 256

internal class ProjectOutputPolicy {
    let formats = ArrayList<String>()
    var directory: ?String = None
    var agentFull: ?Bool = None
    var htmlFontSans: ?String = None
    var htmlFontMono: ?String = None
}

internal class ProjectAnalysisPolicy {
    var audience: ?String = None
    var jobs: ?Int64 = None
    var lintProfile: ?String = None
    var includePathDependencies: ?Bool = None
    var includeCachedDependencies: ?Bool = None
    var cjpmCache: ?String = None
    var cacheDirectory: ?String = None
    var noCache: ?Bool = None
    let cfg = ArrayList<CfgValue>()
    let dependencySources = ArrayList<DependencySourceInput>()
}

internal class ProjectCliConfig {
    let output = ProjectOutputPolicy()
    let analysis = ProjectAnalysisPolicy()
    var semanticMode: ?String = None
}

private func projectConfigFailure(detail: String): IllegalArgumentException {
    IllegalArgumentException("cjdoc.toml: " + detail)
}

private func projectConfigValues(allowed: Array<String>): String {
    let joined = StringBuilder()
    var first = true
    for (candidate in allowed) {
        if (!first) { joined.append(", ") }
        joined.append(candidate)
        first = false
    }
    joined.toString()
}

private func projectConfigScalar(code: String, equals: Int64): String {
    code[equals + 1..].trimAscii()
}

private func projectConfigString(code: String, equals: Int64, setting: String): String {
    let decoded = tomlAssignmentString(code, equals)
    if (decoded.invalid || decoded.value.isNone()) {
        throw projectConfigFailure(setting + " requires a quoted string")
    }
    decoded.value.getOrThrow()
}

private func projectConfigNonEmptyString(code: String, equals: Int64, setting: String): String {
    let value = projectConfigString(code, equals, setting)
    if (value.trimAscii().isEmpty()) {
        throw projectConfigFailure(setting + " requires a non-empty value")
    }
    value
}

private func projectConfigBoolean(code: String, equals: Int64, setting: String): Bool {
    let value = projectConfigScalar(code, equals)
    if (value == "true") { return true }
    if (value == "false") { return false }
    throw projectConfigFailure(setting + " must be true or false")
}

private func projectConfigInteger(code: String, equals: Int64, setting: String,
    minimum: Int64, maximum: Int64): Int64 {
    let value = projectConfigScalar(code, equals)
    if (value.isEmpty()) { throw projectConfigFailure(setting + " requires an integer") }
    for (byte in value.toArray()) {
        if (byte < b'0' || byte > b'9') { throw projectConfigFailure(setting + " requires an integer") }
    }
    let parsed = try {
        Int64.parse(value)
    } catch (_: Exception) {
        throw projectConfigFailure(setting + " is out of range")
    }
    if (parsed < minimum || parsed > maximum) {
        throw projectConfigFailure(setting + " must be in " + minimum.toString() + ".." +
            maximum.toString())
    }
    parsed
}

private func projectConfigEnum(code: String, equals: Int64, setting: String,
    allowed: Array<String>): String {
    let value = projectConfigString(code, equals, setting)
    for (candidate in allowed) {
        if (candidate == value) { return value }
    }
    throw projectConfigFailure(setting + " must be " + projectConfigValues(allowed))
}

// Paths in the project configuration are project-root relative; the invocation
// directory never changes what they select.
internal func projectConfigPath(projectRoot: String, value: String): String {
    if (Path(value).isAbsolute()) { return value }
    Path(projectRoot).join(value).toString()
}

private func projectConfigPathSetting(code: String, equals: Int64, setting: String,
    projectRoot: String): String {
    projectConfigPath(projectRoot, projectConfigNonEmptyString(code, equals, setting))
}

// Only the tables this scanner owns decide CLI defaults. `[i18n]`, `[lint]`,
// `[coverage]`, `[highlight]`, `[limits]`, metadata and source registrations
// keep their existing readers, including their own unknown-key diagnostics.
private func projectConfigOwnsKeys(kind: String): Bool {
    kind == "docs" || kind == "docs.pages" || kind == "docs.pages.sections" ||
        kind == "docs.packages" || kind == "docs.packages.package" ||
        kind == "external-docs" || kind == "output" || kind == "analysis" ||
        kind == "semantic"
}

private func projectConfigKeyAllowed(kind: String, key: String): Bool {
    if (kind == "analysis" || kind == "output" || kind == "semantic") { return true }
    if (key.isEmpty()) { return false }
    match (kind) {
        case "docs" => key == "index" || key == "index-source"
        case "docs.pages" => key == "source" || key == "path" || key == "route" ||
            key == "title" || key == "id" || key == "language" || key == "kind" ||
            key == "package"
        case "docs.packages.package" => key == "source" || key == "path" || key == "overview"
        case "external-docs" => key == "index" || key == "base-url" || key == "version"
        // Package names and stable section identifiers are the keys themselves.
        case "docs.packages" | "docs.pages.sections" => true
        case _ => true
    }
}

// Decode only the first key component: a quoted dot stays part of the name.
private func projectConfigRootKey(key: String): String {
    let text = key.trimAscii()
    if (text.startsWith("\"") || text.startsWith("'")) {
        let decoded = decodeTomlString(text, 0)
        if (decoded.invalid) { return "" }
        if (decoded.value.isSome()) { return decoded.value.getOrThrow() }
        return ""
    }
    text.split(".", 2)[0].trimAscii()
}

private class ProjectPendingArray {
    let kind: String
    let key: String
    let values = ArrayList<String>()
    let state = TomlStringArrayState()

    init(kind: String, key: String) {
        this.kind = kind
        this.key = key
    }
}

private class ProjectConfigScanner {
    let config = ProjectCliConfig()
    let seen = HashSet<String>()
    let parser = TomlLineScanner()
    var kind = "root"
    var identity = ""
    var pageCount: Int64 = 0
    var groupCount: Int64 = 0
    var tagCount: Int64 = 0
    var repositoryCount: Int64 = 0
    var currentPage: ?String = None
    var currentGroup: ?String = None
    var currentTag: ?String = None
    var pending: ?ProjectPendingArray = None
    // Consumer-owned tables may spell an array across lines; those values are
    // their reader's business, so the scanner only skips to the closing line.
    var skippingArrayValue = false

    private func instance(prefix: String, count: Int64): String {
        prefix + "#" + count.toString()
    }

    private func header(inner: String, array: Bool): (String, String) {
        if (inner == "docs") {
            if (array) { throw projectConfigFailure("[[docs]] must be a single table") }
            return ("docs", "")
        }
        if (inner == "docs.pages") {
            if (!array) { throw projectConfigFailure("[[docs.pages]] must be an array of tables") }
            pageCount++
            currentPage = Some(instance("docs.pages", pageCount))
            return ("docs.pages", currentPage.getOrThrow())
        }
        if (inner == "docs.pages.sections") {
            if (array) { throw projectConfigFailure("[docs.pages.sections] must be a single table") }
            let page = match (currentPage) {
                case Some(value) => value
                case None => throw projectConfigFailure(
                    "[docs.pages.sections] requires a preceding [[docs.pages]] entry")
            }
            return ("docs.pages.sections", page)
        }
        if (inner == "docs.packages") {
            if (array) { throw projectConfigFailure("[[docs.packages]] must be a single table") }
            return ("docs.packages", "")
        }
        if (inner.startsWith("docs.packages.")) {
            let name = inner.removePrefix("docs.packages.")
            if (array || name.trimAscii().isEmpty()) {
                throw projectConfigFailure("[docs.packages.<name>] requires a package name")
            }
            return ("docs.packages.package", name)
        }
        if (inner.startsWith("docs.") || inner.startsWith("docs[")) {
            throw projectConfigFailure("unknown table '[" + inner + "]'")
        }
        if (inner == "metadata") {
            if (array) { throw projectConfigFailure("[[metadata]] must be a single table") }
            return ("metadata", "")
        }
        if (inner == "metadata.groups") {
            if (!array) { throw projectConfigFailure("[[metadata.groups]] must be an array of tables") }
            groupCount++
            currentGroup = Some(instance("metadata.groups", groupCount))
            return ("metadata.groups", currentGroup.getOrThrow())
        }
        if (inner == "metadata.groups.titles") {
            let group = match (currentGroup) {
                case Some(value) => value
                case None => throw projectConfigFailure(
                    "orphan [metadata.groups.titles] table")
            }
            return ("metadata.groups.titles", group)
        }
        if (inner == "metadata.tags") {
            if (!array) { throw projectConfigFailure("[[metadata.tags]] must be an array of tables") }
            tagCount++
            currentTag = Some(instance("metadata.tags", tagCount))
            return ("metadata.tags", currentTag.getOrThrow())
        }
        if (inner == "metadata.tags.titles") {
            let tag = match (currentTag) {
                case Some(value) => value
                case None => throw projectConfigFailure("orphan [metadata.tags.titles] table")
            }
            return ("metadata.tags.titles", tag)
        }
        if (inner.startsWith("metadata")) {
            throw projectConfigFailure("unknown table '[" + inner + "]'")
        }
        if (inner == "i18n" || inner == "lint" || inner == "highlight" ||
            inner == "coverage" || inner == "coverage.translation") {
            if (array) { throw projectConfigFailure("[[" + inner + "]] must be a single table") }
            return (inner, "")
        }
        if (inner.startsWith("coverage.package.")) {
            let name = inner.removePrefix("coverage.package.")
            if (array || name.trimAscii().isEmpty()) {
                throw projectConfigFailure("[coverage.package.<name>] requires a package name")
            }
            return ("coverage.package", name)
        }
        if (inner.startsWith("coverage")) {
            throw projectConfigFailure("unknown table '[" + inner + "]'")
        }
        if (inner == "limits") {
            if (array) { throw projectConfigFailure("[[limits]] must be a single table") }
            return ("limits", "")
        }
        if (inner.startsWith("limits")) {
            throw projectConfigFailure("[limits] must be a single table without subtables")
        }
        if (inner == "source.repositories") {
            if (!array) {
                throw projectConfigFailure("source.repositories must be an array of tables")
            }
            repositoryCount++
            return ("source.repositories", instance("source.repositories", repositoryCount))
        }
        if (inner == "source" || inner.startsWith("source.") || inner == "sources") {
            throw projectConfigFailure("configure source repositories with [[source.repositories]]")
        }
        if (inner.startsWith("external-docs")) {
            if (array) { throw projectConfigFailure("[external-docs.<name>] must be a single table") }
            if (!inner.startsWith("external-docs.")) {
                throw projectConfigFailure("[external-docs] requires a name: [external-docs.<name>]")
            }
            let name = inner.removePrefix("external-docs.")
            if (name.trimAscii().isEmpty()) {
                throw projectConfigFailure("[external-docs.<name>] requires a name")
            }
            return ("external-docs", name)
        }
        if (inner == "output" || inner == "analysis" || inner == "semantic") {
            if (array) { throw projectConfigFailure("[[" + inner + "]] must be a single table") }
            return (inner, "")
        }
        if (inner == "doctest" || inner.startsWith("doctest.")) {
            throw projectConfigFailure(
                "[doctest] is no longer supported; use --check-examples and @example {run}")
        }
        throw projectConfigFailure("unknown table '[" + inner + "]'")
    }

    private func mark(key: String): Unit {
        if (!seen.add(kind + "#" + identity + "|" + key)) {
            throw projectConfigFailure("duplicate setting '" + key + "' in [" + kind + "]")
        }
    }

    private func assignOutput(code: String, equals: Int64, key: String,
        projectRoot: String): Unit {
        let setting = "[output]." + key
        match (key) {
            case "formats" =>
                throw projectConfigFailure(setting + " must be written as an array literal")
            case "directory" =>
                config.output.directory = Some(
                    projectConfigPathSetting(code, equals, setting, projectRoot))
            case "agent-full" =>
                config.output.agentFull = Some(projectConfigBoolean(code, equals, setting))
            case "html-font-sans" =>
                let value = projectConfigString(code, equals, setting)
                if (!public_render.isValidHtmlFontFamilyList(value)) {
                    throw projectConfigFailure(setting + " is not a valid font family list")
                }
                config.output.htmlFontSans = Some(value)
            case "html-font-mono" =>
                let value = projectConfigString(code, equals, setting)
                if (!public_render.isValidHtmlFontFamilyList(value)) {
                    throw projectConfigFailure(setting + " is not a valid font family list")
                }
                config.output.htmlFontMono = Some(value)
            case _ => throw projectConfigFailure("unknown [output] setting '" + key + "'")
        }
    }

    private func assignAnalysis(code: String, equals: Int64, key: String,
        projectRoot: String): Unit {
        let setting = "[analysis]." + key
        match (key) {
            case "cfg" | "dependency-sources" =>
                throw projectConfigFailure(setting + " must be written as an array literal")
            case "audience" =>
                config.analysis.audience = Some(projectConfigEnum(code, equals, setting,
                    ["external", "package", "all"]))
            case "jobs" =>
                config.analysis.jobs = Some(projectConfigInteger(code, equals, setting, 1, 64))
            case "lint-profile" =>
                config.analysis.lintProfile = Some(projectConfigEnum(code, equals, setting,
                    ["off", "standard", "strict"]))
            case "include-path-dependencies" =>
                config.analysis.includePathDependencies = Some(
                    projectConfigBoolean(code, equals, setting))
            case "include-cached-dependencies" =>
                config.analysis.includeCachedDependencies = Some(
                    projectConfigBoolean(code, equals, setting))
            case "cjpm-cache" =>
                config.analysis.cjpmCache = Some(
                    projectConfigPathSetting(code, equals, setting, projectRoot))
            case "cache-dir" =>
                config.analysis.cacheDirectory = Some(
                    projectConfigPathSetting(code, equals, setting, projectRoot))
            case "no-cache" =>
                config.analysis.noCache = Some(projectConfigBoolean(code, equals, setting))
            case _ => throw projectConfigFailure("unknown [analysis] setting '" + key + "'")
        }
    }

    private func assignSemantic(code: String, equals: Int64, key: String): Unit {
        if (key != "mode") {
            throw projectConfigFailure("unknown [semantic] setting '" + key + "'")
        }
        config.semanticMode = Some(projectConfigEnum(code, equals, "[semantic].mode",
            ["source", "chir"]))
    }

    private func assignOwned(code: String, equals: Int64, key: String,
        projectRoot: String): Unit {
        if (!projectConfigKeyAllowed(kind, key)) {
            throw projectConfigFailure("unknown [" + kind + "] setting '" + key + "'")
        }
        match (kind) {
            case "output" => assignOutput(code, equals, key, projectRoot)
            case "analysis" => assignAnalysis(code, equals, key, projectRoot)
            case "semantic" => assignSemantic(code, equals, key)
            case _ => ()
        }
    }

    private func assignArray(values: Array<String>, created: ProjectPendingArray,
        projectRoot: String): Unit {
        if (created.kind == "output" && created.key == "formats") {
            if (values.size == 0) {
                throw projectConfigFailure("[output].formats must list at least one format")
            }
            let seenFormats = HashSet<String>()
            for (value in values) {
                if (!isCliDocumentationFormat(value)) {
                    throw projectConfigFailure("[output].formats does not support '" + value + "'")
                }
                if (!seenFormats.add(value)) {
                    throw projectConfigFailure("[output].formats repeats '" + value + "'")
                }
                config.output.formats.add(value)
            }
            return
        }
        if (created.kind == "analysis" && created.key == "cfg") {
            for (value in values) {
                let (name, cfgValue) = splitNamedValue(value, "[analysis].cfg")
                config.analysis.cfg.add(CfgValue(name, cfgValue))
            }
            return
        }
        if (created.kind == "analysis" && created.key == "dependency-sources") {
            for (value in values) {
                let (name, path) = splitNamedValue(value, "[analysis].dependency-sources")
                if (path.trimAscii().isEmpty()) {
                    throw projectConfigFailure(
                        "[analysis].dependency-sources requires NAME=PATH")
                }
                let input = try {
                    DependencySourceInput(name, projectConfigPath(projectRoot, path))
                } catch (error: IllegalArgumentException) {
                    throw projectConfigFailure(
                        "[analysis].dependency-sources: " + error.message)
                }
                for (existing in config.analysis.dependencySources) {
                    if (existing.name == input.name) {
                        throw projectConfigFailure(
                            "[analysis].dependency-sources repeats '" + input.name + "'")
                    }
                }
                config.analysis.dependencySources.add(input)
            }
            return
        }
    }

    private func collectArray(created: ProjectPendingArray, value: String,
        projectRoot: String): Bool {
        let (complete, exceeded, invalid) = collectTomlStrings(value, created.values,
            PROJECT_CONFIG_LIST_MAX_VALUES, created.state)
        let setting = "[" + created.kind + "]." + created.key
        if (invalid) {
            throw projectConfigFailure(setting + " must be an array of quoted strings")
        }
        if (exceeded) { throw projectConfigFailure(setting + " exceeds 256 entries") }
        if (!complete) { return false }
        assignArray(created.values.toArray(), created, projectRoot)
        true
    }

    private func isOwnedArrayKey(key: String): Bool {
        (kind == "output" && key == "formats") ||
            (kind == "analysis" && (key == "cfg" || key == "dependency-sources"))
    }

    func scan(text: String, projectRoot: String): Unit {
        for (rawLine in text.split("\n")) {
            match (pending) {
                case Some(created) =>
                    let visible = match (parser.code(rawLine)) {
                        case Some(value) => value
                        case None => throw projectConfigFailure(
                            "array values in cjdoc.toml must use single-line strings")
                    }
                    if (collectArray(created, visible, projectRoot)) { pending = None }
                    continue
                case None => ()
            }
            if (skippingArrayValue) {
                match (parser.code(rawLine)) {
                    case Some(value) =>
                        if (value.trimAscii().endsWith("]")) { skippingArrayValue = false }
                    case None => ()
                }
                continue
            }
            let code = match (parser.code(rawLine)) {
                case Some(value) => value
                case None =>
                    if (kind == "root" || projectConfigOwnsKeys(kind)) {
                        throw projectConfigFailure(
                            "settings in [" + kind + "] must use single-line strings")
                    }
                    continue
            }
            if (code.isEmpty()) { continue }
            if (code.startsWith("[")) {
                let (array, inner) = projectConfigTableHeader(code)
                let (nextKind, nextIdentity) = header(inner, array)
                kind = nextKind
                identity = nextIdentity
                continue
            }
            let equals = tomlAssignmentEquals(code)
            if (equals.isNone()) {
                if (projectConfigOwnsKeys(kind)) {
                    throw projectConfigFailure("expected a key/value assignment in [" + kind + "]")
                }
                continue
            }
            let position = equals.getOrThrow()
            let key = code[..position].trimAscii()
            if (kind == "root") {
                // Every setting belongs to a table; a stray key is a typo. The
                // two reserved roots keep their documented actionable message.
                let root = projectConfigRootKey(key)
                if (root == "limits") {
                    throw projectConfigFailure(
                        "configure Doc IR limits with [limits]; dotted keys and inline tables are unsupported")
                }
                if (root == "source") {
                    throw projectConfigFailure(
                        "configure source repositories with [[source.repositories]]")
                }
                if (root == "metadata") {
                    throw projectConfigFailure(
                        "metadata definitions must use the supported metadata tables")
                }
                throw projectConfigFailure("unknown top-level setting '" + key + "'")
            }
            if (!projectConfigOwnsKeys(kind)) {
                if (projectConfigScalar(code, position).startsWith("[") &&
                    !projectConfigScalar(code, position).endsWith("]")) {
                    skippingArrayValue = true
                }
                continue
            }
            mark(key)
            if (isOwnedArrayKey(key) && projectConfigScalar(code, position).startsWith("[")) {
                let created = ProjectPendingArray(kind, key)
                if (!collectArray(created, projectConfigScalar(code, position), projectRoot)) {
                    pending = Some(created)
                }
                continue
            }
            assignOwned(code, position, key, projectRoot)
        }
    }

    func finish(): ProjectCliConfig {
        match (pending) {
            case Some(created) => throw projectConfigFailure("[" + created.kind + "]." +
                created.key + " array is not terminated")
            case None => ()
        }
        match ((config.analysis.cacheDirectory, config.analysis.noCache)) {
            case (Some(_), Some(true)) =>
                throw projectConfigFailure(
                    "[analysis] cache-dir and no-cache are mutually exclusive")
            case _ => ()
        }
        config
    }
}

private func projectConfigTableHeader(code: String): (Bool, String) {
    let trimmed = code.trimAscii()
    if (trimmed.startsWith("[[") && trimmed.endsWith("]]") && trimmed.size >= 4) {
        return (true, trimmed[2..trimmed.size - 2].trimAscii())
    }
    if (trimmed.startsWith("[") && trimmed.endsWith("]") && trimmed.size >= 2) {
        return (false, trimmed[1..trimmed.size - 1].trimAscii())
    }
    if (trimmed.startsWith("[[")) {
        throw projectConfigFailure("malformed table header '" + trimmed + "'")
    }
    let inner = if (trimmed.startsWith("[")) { trimmed[1..] } else { trimmed }
    throw projectConfigFailure("malformed table header '" + inner + "'")
}

internal func loadProjectCliConfig(projectRoot: String): ProjectCliConfig {
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return ProjectCliConfig() }
    let text = try {
        readTextBounded(path, PROJECT_CONFIG_MAX_BYTES)
    } catch (_: Exception) {
        throw projectConfigFailure("configuration is unavailable or exceeds 256 KiB")
    }
    let scanner = ProjectConfigScanner()
    scanner.scan(text, projectRoot)
    scanner.finish()
}

// Merge the project defaults into the parsed command once, before the final
// cross-option validation. Explicit CLI values always win, and every configured
// value has already been validated even when it is overridden.
internal func applyProjectCliConfig(options: NewCliOptions): Unit {
    if (options.command != "generate" && options.command != "check" &&
        options.command != "serve") {
        return
    }
    let config = loadProjectCliConfig(options.project)
    let analysis = config.analysis
    // `[output]` describes produced sites. check writes none, and --stdout is an
    // explicit one-format choice that would otherwise inherit a site format list.
    if (options.command != "check" && !options.stdout) {
        // A CLI --format list replaces the configured list instead of extending it.
        if (!config.output.formats.isEmpty() && options.formats.isEmpty()) {
            for (format in config.output.formats) { options.formats.add(format) }
        }
        if (options.output.isNone()) {
            match (config.output.directory) {
                case Some(value) => options.output = Some(value)
                case None => ()
            }
        }
        // HTML-only settings are defaults for an HTML site. When the resolved
        // formats are JSON-only they would only fail validation, so they are
        // not inherited; the configured values were already validated above.
        let htmlSite = options.command == "serve" || options.formats.contains("html")
        if (htmlSite) {
            if (!options.agentFullExplicit) {
                match (config.output.agentFull) {
                    case Some(value) => options.agentFull = value
                    case None => ()
                }
            }
            if (options.htmlFontSans.isNone()) {
                match (config.output.htmlFontSans) {
                    case Some(value) => options.htmlFontSans = Some(value)
                    case None => ()
                }
            }
            if (options.htmlFontMono.isNone()) {
                match (config.output.htmlFontMono) {
                    case Some(value) => options.htmlFontMono = Some(value)
                    case None => ()
                }
            }
        }
    }
    if (!options.audienceExplicit) {
        match (analysis.audience) {
            case Some(value) => options.audience = value
            case None => ()
        }
    }
    if (!options.jobsExplicit) {
        match (analysis.jobs) {
            case Some(value) => options.jobs = value
            case None => ()
        }
    }
    if (!options.lintProfileExplicit) {
        match (analysis.lintProfile) {
            case Some(value) => options.lintProfile = value
            case None => ()
        }
    }
    if (!options.semanticExplicit) {
        match (config.semanticMode) {
            case Some(value) => options.semanticMode = value
            case None => ()
        }
    }
    if (!options.includePathDependenciesExplicit) {
        match (analysis.includePathDependencies) {
            case Some(value) => options.includePathDependencies = value
            case None => ()
        }
    }
    if (!options.includeCachedDependenciesExplicit) {
        match (analysis.includeCachedDependencies) {
            case Some(value) => options.includeCachedDependencies = value
            case None => ()
        }
    }
    // A configured cache root only accompanies cache reading. --no-include-cached-
    // dependencies therefore drops it instead of inheriting an unusable pair.
    if (options.cjpmCacheRoot.isNone() && options.includeCachedDependencies) {
        match (analysis.cjpmCache) {
            case Some(value) => options.cjpmCacheRoot = Some(value)
            case None => ()
        }
    }
    // --cache-dir or --no-cache already decided the cache for this command.
    if (options.cacheDirectory.isNone() && !options.noCache && !options.cacheExplicit) {
        match (analysis.cacheDirectory) {
            case Some(value) => options.cacheDirectory = Some(value)
            case None => ()
        }
        if (options.cacheDirectory.isNone() && analysis.noCache.getOrDefault({ => false })) {
            options.noCache = true
        }
    }
    if (!analysis.cfg.isEmpty()) {
        let overridden = HashSet<String>()
        for (value in options.cfgValues) { let _ = overridden.add(value.name) }
        for (value in analysis.cfg) {
            if (!overridden.contains(value.name)) { options.cfgValues.add(value) }
        }
    }
    if (!analysis.dependencySources.isEmpty()) {
        let overridden = HashSet<String>()
        for (value in options.dependencySources) { let _ = overridden.add(value.name) }
        for (value in analysis.dependencySources) {
            if (!overridden.contains(value.name)) { options.dependencySources.add(value) }
        }
    }
}

// `--locale` selects interface labels; without it the configured publication
// default language wins over the built-in zh-CN.
internal func selectedCliRenderLocale(options: NewCliOptions): String {
    if (options.localeExplicit) { return options.locale }
    if (options.command != "generate" && options.command != "serve") { return options.locale }
    match (loadDocumentationLanguages(options.project)) {
        case Some(value) => value.defaultLanguage
        case None => options.locale
    }
}
