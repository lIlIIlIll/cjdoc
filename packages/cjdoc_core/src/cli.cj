package cjdoc_core

import std.fs.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.runtime.getProcessorCount
import std.sort.*

class CliOptions {
    var project = "."
    var format = "json"
    var output: ?String = None
    var lintMissingParameters = false
    var publicOnly = false
    var sourceUrlTemplate: ?String = None
    var includePathDependencies = false
    let dependencySources = ArrayList<DependencySourceInput>()
    let dependencySourceUrls = ArrayList<CliNamedValue>()
    let dependencyRevisions = ArrayList<CliNamedValue>()
    let dependencySourceLinks = ArrayList<DependencySourceLink>()
    let cfgValues = ArrayList<CfgValue>()
    let cfgMatrixProfiles = ArrayList<NamedCfgProfile>()
    var jobs: Int64 = 0
    var cacheDirectory: ?String = None
    var noCache = false
    var includeCachedDependencies = false
    var cjpmCacheRoot: ?String = None
    var stdout = false
    var diagnosticFormat = "text"
    var diagnosticOutput: ?String = None
    var coverage = false
    var lintMissingSymbols = false
    var denyWarnings = false
    var help = false
    var version = false
}

class CliNamedValue {
    let name: String
    let value: String

    init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

private func usage(): String {
    return "usage: cjdoc [--config <path>] [--project <dir>] [--format json|markdown|html] [--output <path>|--stdout] [--diagnostic-format text|json|sarif] [--diagnostic-output <path>] [--cache-dir <path>|--no-cache] [--source-url-template <url>] [--dependency-source-url <name>=<url>] [--dependency-revision <name>=<revision>] [--include-path-dependencies] [--include-cached-dependencies] [--cjpm-cache <path>] [--dependency-source <name>=<path>] [--cfg <name>=<value> | --cfg-matrix-profile <label>:<name>=<value>[,<name>=<value>...]] [--jobs <auto|1..64>] [--public-only] [--lint-missing-params] [--lint-missing-symbols] [--coverage] [--deny-warnings]"
}

private func unquoteConfigValue(raw: String): String {
    let value = raw.trimAscii()
    if ((value.startsWith("\"") && value.endsWith("\"")) ||
        (value.startsWith("'") && value.endsWith("'"))) {
        if (value.size < 2) { throw IllegalArgumentException("invalid quoted config value") }
        return value[1..value.size - 1]
    }
    value
}

private func appendBooleanConfig(args: ArrayList<String>, option: String, value: String): Unit {
    if (value == "true") {
        args.add(option)
    } else if (value != "false") {
        throw IllegalArgumentException("config option '${option}' requires true or false")
    }
}

private func loadConfigArguments(path: String): ArrayList<String> {
    let content = try {
        String.fromUtf8(File.readFrom(path))
    } catch (error: Exception) {
        throw IllegalArgumentException("failed to read config '${path}': ${error.message}")
    }
    let args = ArrayList<String>()
    for (line in content.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) { continue }
        let equals = trimmed.indexOf("=")
        if (equals.isNone()) { throw IllegalArgumentException("invalid config line '${trimmed}'") }
        let at = equals.getOrThrow()
        let name = trimmed[..at].trimAscii()
        let value = unquoteConfigValue(trimmed[at + 1..])
        match (name) {
            case "project" | "format" | "output" | "cache-dir" | "cjpm-cache" |
                "jobs" | "diagnostic-format" | "diagnostic-output" | "source-url-template" |
                "cfg" | "cfg-matrix-profile" | "dependency-source" |
                "dependency-source-url" | "dependency-revision" =>
                args.add("--${name}")
                args.add(value)
            case "stdout" | "no-cache" | "public-only" | "lint-missing-params" |
                "lint-missing-symbols" | "coverage" | "deny-warnings" |
                "include-path-dependencies" | "include-cached-dependencies" =>
                appendBooleanConfig(args, "--${name}", value)
            case _ => throw IllegalArgumentException("unknown config option '${name}'")
        }
    }
    args
}

private func expandConfigArguments(args: Array<String>): ?Array<String> {
    var configPath: ?String = None
    var index: Int64 = 0
    while (index < args.size) {
        if (args[index] == "--config") {
            if (index + 1 >= args.size) { throw IllegalArgumentException("--config requires a value") }
            if (configPath.isSome()) { throw IllegalArgumentException("--config may be specified only once") }
            configPath = Some(args[index + 1])
            index += 2
        } else {
            index++
        }
    }
    if (configPath.isNone()) { return None }
    let expanded = loadConfigArguments(configPath.getOrThrow())
    index = 0
    while (index < args.size) {
        if (args[index] == "--config") {
            index += 2
        } else {
            expanded.add(args[index])
            index++
        }
    }
    Some(expanded.toArray())
}

private func namedValue(values: ArrayList<CliNamedValue>, name: String): ?String {
    for (entry in values) {
        if (entry.name == name) { return Some(entry.value) }
    }
    None
}

private func addNamedValue(values: ArrayList<CliNamedValue>, argument: String,
    optionName: String): Unit {
    let parts = argument.split("=", 2, removeEmpty: false)
    if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("${optionName} requires <name>=<value>")
    }
    let name = parts[0].trimAscii()
    if (namedValue(values, name).isSome()) {
        throw IllegalArgumentException("${optionName} may be specified only once for '${name}'")
    }
    values.add(CliNamedValue(name, parts[1].trimAscii()))
}

private func addCfgMatrixProfile(profiles: ArrayList<NamedCfgProfile>, argument: String): Unit {
    let separator = argument.indexOf(":")
    if (separator.isNone()) {
        throw IllegalArgumentException(
            "--cfg-matrix-profile requires <label>:<name>=<value>[,<name>=<value>...]")
    }
    let at = separator.getOrThrow()
    let name = argument[..at].trimAscii()
    if (!isCfgProfileNameValid(name)) {
        throw IllegalArgumentException("cfg matrix profile label must use letters, digits, '_' or '-'")
    }
    for (profile in profiles) {
        if (profile.name == name) {
            throw IllegalArgumentException("cfg matrix profile '${name}' may be specified only once")
        }
    }
    let assignments = argument[at + 1..]
    if (assignments.trimAscii().isEmpty()) {
        throw IllegalArgumentException("cfg matrix profile '${name}' requires at least one cfg value")
    }
    let values = ArrayList<CfgValue>()
    for (assignment in assignments.split(",", removeEmpty: false)) {
        let parts = assignment.split("=", 2, removeEmpty: false)
        if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
            throw IllegalArgumentException("cfg matrix profile '${name}' contains an invalid <name>=<value>")
        }
        let cfgName = parts[0].trimAscii()
        for (value in values) {
            if (value.name == cfgName) {
                throw IllegalArgumentException(
                    "cfg matrix profile '${name}' contains duplicate cfg key '${cfgName}'")
            }
        }
        values.add(CfgValue(cfgName, parts[1].trimAscii()))
    }
    profiles.add(NamedCfgProfile(name, values.toArray()))
}

private func validateDependencySourceLinks(options: CliOptions): Unit {
    if ((!options.dependencySourceUrls.isEmpty() || !options.dependencyRevisions.isEmpty()) &&
        options.format != "html") {
        throw IllegalArgumentException("dependency source links require --format html")
    }
    for (revision in options.dependencyRevisions) {
        if (namedValue(options.dependencySourceUrls, revision.name).isNone()) {
            throw IllegalArgumentException("--dependency-revision for '${revision.name}' requires --dependency-source-url")
        }
    }
    for (entry in options.dependencySourceUrls) {
        if (!dependencySourceUrlTemplateValid(entry.value)) {
            throw IllegalArgumentException("dependency source URL template must use http/https, include {path}, and contain only supported placeholders")
        }
        let revision = namedValue(options.dependencyRevisions, entry.name)
        if (entry.value.contains("{revision}") && revision.isNone()) {
            throw IllegalArgumentException("dependency source URL for '${entry.name}' uses {revision} but no revision was supplied")
        }
        if (!entry.value.contains("{revision}") && revision.isSome()) {
            throw IllegalArgumentException("--dependency-revision for '${entry.name}' requires a {revision} placeholder")
        }
        options.dependencySourceLinks.add(DependencySourceLink(entry.name, entry.value, revision: revision))
    }
}

func parseCli(args: Array<String>): CliOptions {
    if (let Some(expanded) <- expandConfigArguments(args)) { return parseCli(expanded) }
    let options = CliOptions()
    var index: Int64 = 0
    while (index < args.size) {
        match (args[index]) {
            case "--project" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--project requires a value") }
                options.project = args[index + 1]
                index += 2
            case "--format" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--format requires a value") }
                options.format = args[index + 1]
                index += 2
            case "--output" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--output requires a value") }
                options.output = args[index + 1]
                index += 2
            case "--stdout" =>
                options.stdout = true
                index++
            case "--diagnostic-format" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--diagnostic-format requires a value")
                }
                options.diagnosticFormat = args[index + 1]
                index += 2
            case "--diagnostic-output" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--diagnostic-output requires a value")
                }
                options.diagnosticOutput = Some(args[index + 1])
                index += 2
            case "--lint-missing-params" =>
                options.lintMissingParameters = true
                index++
            case "--lint-missing-symbols" =>
                options.lintMissingSymbols = true
                index++
            case "--coverage" =>
                options.coverage = true
                index++
            case "--deny-warnings" =>
                options.denyWarnings = true
                index++
            case "--public-only" =>
                options.publicOnly = true
                index++
            case "--source-url-template" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--source-url-template requires a value")
                }
                options.sourceUrlTemplate = Some(args[index + 1])
                index += 2
            case "--dependency-source-url" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--dependency-source-url requires <name>=<url>")
                }
                addNamedValue(options.dependencySourceUrls, args[index + 1], "--dependency-source-url")
                index += 2
            case "--dependency-revision" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--dependency-revision requires <name>=<revision>")
                }
                addNamedValue(options.dependencyRevisions, args[index + 1], "--dependency-revision")
                index += 2
            case "--include-path-dependencies" =>
                options.includePathDependencies = true
                index++
            case "--include-cached-dependencies" =>
                options.includeCachedDependencies = true
                index++
            case "--cjpm-cache" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--cjpm-cache requires a value")
                }
                options.cjpmCacheRoot = Some(args[index + 1])
                index += 2
            case "--dependency-source" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException("--dependency-source requires <name>=<path>")
                }
                let parts = args[index + 1].split("=", 2, removeEmpty: false)
                if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--dependency-source requires <name>=<path>")
                }
                options.dependencySources.add(DependencySourceInput(parts[0].trimAscii(), parts[1].trimAscii()))
                index += 2
            case "--cfg" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--cfg requires <name>=<value>") }
                let parts = args[index + 1].split("=", 2, removeEmpty: false)
                if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--cfg requires <name>=<value>")
                }
                options.cfgValues.add(CfgValue(parts[0].trimAscii(), parts[1].trimAscii()))
                index += 2
            case "--cfg-matrix-profile" =>
                if (index + 1 >= args.size) {
                    throw IllegalArgumentException(
                        "--cfg-matrix-profile requires <label>:<name>=<value>[,<name>=<value>...]")
                }
                addCfgMatrixProfile(options.cfgMatrixProfiles, args[index + 1])
                index += 2
            case "--jobs" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--jobs requires a value") }
                let jobs = if (args[index + 1] == "auto") { 0 } else { try {
                    Int64.parse(args[index + 1])
                } catch (_: Exception) {
                    throw IllegalArgumentException("--jobs must be auto or an integer from 1 to 64")
                } }
                if (jobs < 0 || jobs > 64) {
                    throw IllegalArgumentException("--jobs must be auto or an integer from 1 to 64")
                }
                options.jobs = jobs
                index += 2
            case "--cache-dir" =>
                if (index + 1 >= args.size || args[index + 1].trimAscii().isEmpty()) {
                    throw IllegalArgumentException("--cache-dir requires a value")
                }
                options.cacheDirectory = Some(args[index + 1])
                options.noCache = false
                index += 2
            case "--no-cache" =>
                options.noCache = true
                options.cacheDirectory = None
                index++
            case "-h" | "--help" =>
                options.help = true
                index++
            case "--version" =>
                options.version = true
                index++
            case unknown => throw IllegalArgumentException("unknown argument '${unknown}'")
        }
    }
    if (options.format != "json" && options.format != "markdown" && options.format != "html") {
        throw IllegalArgumentException("unsupported format '${options.format}'")
    }
    if (!options.cfgMatrixProfiles.isEmpty() && options.format != "json") {
        throw IllegalArgumentException("--cfg-matrix-profile currently requires --format json")
    }
    if (!options.cfgMatrixProfiles.isEmpty() && !options.cfgValues.isEmpty()) {
        throw IllegalArgumentException("--cfg and --cfg-matrix-profile are mutually exclusive")
    }
    if (options.stdout && (options.output.isSome() || options.format == "html")) {
        throw IllegalArgumentException("--stdout supports json/markdown and is mutually exclusive with --output")
    }
    if (options.stdout && (options.coverage || (options.diagnosticFormat == "text" &&
        options.diagnosticOutput.isNone()))) {
        throw IllegalArgumentException("--stdout requires diagnostics to use --diagnostic-output and cannot be combined with --coverage")
    }
    if (options.diagnosticFormat != "text" && options.diagnosticFormat != "json" &&
        options.diagnosticFormat != "sarif") {
        throw IllegalArgumentException("--diagnostic-format must be text, json, or sarif")
    }
    if (options.diagnosticFormat != "text" && options.diagnosticOutput.isNone()) {
        throw IllegalArgumentException("JSON/SARIF diagnostics require --diagnostic-output")
    }
    if (let Some(template) <- options.sourceUrlTemplate) {
        if (options.format != "html") {
            throw IllegalArgumentException("--source-url-template requires --format html")
        }
        if (!sourceUrlTemplateValid(template)) {
            throw IllegalArgumentException("source URL template must use http/https, include {path}, and contain only supported placeholders")
        }
    }
    validateDependencySourceLinks(options)
    if (options.cjpmCacheRoot.isSome() && !options.includeCachedDependencies) {
        throw IllegalArgumentException("--cjpm-cache requires --include-cached-dependencies")
    }
    return options
}

private func outputPath(options: CliOptions): String {
    return match (options.output) {
        case Some(path) => path
        case None =>
            if (options.format == "html") {
                Path(options.project).join("target").join("doc").join("html").toString()
            } else {
                let fileName = if (!options.cfgMatrixProfiles.isEmpty()) {
                    "docs.matrix.json"
                } else if (options.format == "markdown") {
                    "docs.md"
                } else {
                    "docs.json"
                }
                Path(options.project).join("target").join("doc").join(fileName).toString()
            }
    }
}

private func printDiagnostics(documentation: DocumentationSet): Unit {
    for (diagnostic in documentation.diagnostics) {
        println("${diagnostic.severity}[${diagnostic.code}]: ${diagnostic.message}")
        if (let Some(source) <- diagnostic.source) {
            println(" --> ${source.path}:${source.startLine}:${source.startColumn}")
        }
    }
}

private func renderDiagnosticsText(documentation: DocumentationSet): String {
    let builder = StringBuilder()
    for (diagnostic in documentation.diagnostics) {
        builder.append("${diagnostic.severity}[${diagnostic.code}]: ${diagnostic.message}\n")
        if (let Some(source) <- diagnostic.source) {
            builder.append(" --> ${source.path}:${source.startLine}:${source.startColumn}\n")
        }
    }
    builder.toString()
}

private func hasWarningDiagnostics(documentation: DocumentationSet): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "warning") { return true }
    }
    false
}

private func writeAtomically(path: String, content: String): Unit {
    let destination = Path(path)
    if (exists(destination)) {
        try {
            if (String.fromUtf8(File.readFrom(destination)) == content) { return }
        } catch (_: Exception) {
            // Fall through to the atomic replacement and surface write errors.
        }
    }
    let parent = destination.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    let temporary = path + ".tmp"
    File.writeTo(temporary, content.toArray())
    rename(temporary, to: path, overwrite: true)
}

private func isManagedHtmlPath(path: String): Bool {
    if (path == "index.html" || path == "search-index.json" || path == "search.js" ||
        path == "style.css") { return true }
    if (path.startsWith("packages/package-") && path.endsWith(".html")) { return !path.contains("..") }
    if (path.startsWith("symbols/symbol-") && path.endsWith(".html")) { return !path.contains("..") }
    false
}

private func removeManagedDirectoryIfEmpty(path: Path): Unit {
    if (exists(path) && Directory.readFrom(path).isEmpty()) { let _ = removeIfExists(path) }
}

private func siteContainsPath(site: HtmlSite, path: String): Bool {
    for (file in site.files) {
        if (file.path == path) { return true }
    }
    false
}

private func writeHtmlSite(path: String, site: HtmlSite): Unit {
    let root = Path(path)
    if (!exists(root)) { Directory.create(root, recursive: true) }
    let manifest = root.join(".cjdoc-files")
    if (exists(manifest)) {
        let previous = String.fromUtf8(File.readFrom(manifest))
        for (entry in previous.split("\n")) {
            if (isManagedHtmlPath(entry) && !siteContainsPath(site, entry)) {
                let _ = removeIfExists(root.join(entry))
            }
        }
        removeManagedDirectoryIfEmpty(root.join("packages"))
        removeManagedDirectoryIfEmpty(root.join("symbols"))
    }
    let nextManifest = StringBuilder()
    for (file in site.files) {
        writeAtomically(root.join(file.path).toString(), file.content)
        nextManifest.append(file.path)
        nextManifest.append("\n")
    }
    writeAtomically(manifest.toString(), nextManifest.toString())
}

private func selectedSourceCacheDirectory(options: CliOptions): ?String {
    if (options.noCache) { return None }
    Some(match (options.cacheDirectory) {
        case Some(path) => path
        case None => Path(options.project).join("target").join("cjdoc").join("cache")
            .join("source-v2").toString()
    })
}

private func generateCliDocumentation(options: CliOptions, cfgValues: Array<CfgValue>,
    jobs: Int64, astPreflightExecutable: ?String): DocumentationSet {
    let documentation = generateDocumentation(options.project,
        includePathDependencies: options.includePathDependencies,
        dependencySources: options.dependencySources.toArray(),
        cfgValues: cfgValues, jobs: jobs,
        cacheDirectory: selectedSourceCacheDirectory(options),
        astPreflightExecutable: astPreflightExecutable,
        includeCachedDependencies: options.includeCachedDependencies,
        cjpmCacheRoot: options.cjpmCacheRoot)
    if (options.format == "markdown" || options.format == "html") {
        validateDocumentationMarkdown(documentation)
    }
    if (options.publicOnly) { retainPublicApi(documentation) }
    lintDocumentation(documentation, options.lintMissingParameters,
        missingSymbolDocs: options.lintMissingSymbols)
    documentation
}

private func emitDiagnostics(options: CliOptions, documentation: DocumentationSet): Bool {
    match (options.diagnosticOutput) {
        case Some(diagnosticPath) => try {
            let content = if (options.diagnosticFormat == "json") {
                renderDiagnosticsJson(documentation)
            } else if (options.diagnosticFormat == "sarif") {
                renderDiagnosticsSarif(documentation)
            } else {
                renderDiagnosticsText(documentation)
            }
            writeAtomically(diagnosticPath, content)
            true
        } catch (error: Exception) {
            println("error[CJDOC1010]: failed to write diagnostics '${diagnosticPath}': ${error.message}")
            false
        }
        case None =>
            printDiagnostics(documentation)
            true
    }
}

private func appendProfileDiagnostics(target: DocumentationSet, profileName: String,
    documentation: DocumentationSet): Unit {
    for (diagnostic in documentation.diagnostics) {
        target.diagnostics.add(Diagnostic(diagnostic.severity, diagnostic.code,
            "[cfg profile '${profileName}'] ${diagnostic.message}",
            source: diagnostic.source, symbolId: diagnostic.symbolId))
    }
}

private func runCfgMatrix(options: CliOptions, jobs: Int64,
    astPreflightExecutable: ?String): Int64 {
    let profiles = ArrayList<NamedCfgProfile>()
    profiles.add(all: options.cfgMatrixProfiles)
    sort(profiles, lessThan: { left, right => left.name < right.name }, stable: true)
    let entries = ArrayList<CfgMatrixDocumentation>()
    let diagnostics = DocumentationSet("cfg-matrix")
    var hasErrors = false
    var hasWarnings = false
    var hasFatal = false
    for (profile in profiles) {
        let documentation = generateCliDocumentation(options, profile.profile.values.toArray(),
            jobs, astPreflightExecutable)
        entries.add(CfgMatrixDocumentation(profile.name, documentation))
        appendProfileDiagnostics(diagnostics, profile.name, documentation)
        if (hasErrorDiagnostics(documentation)) { hasErrors = true }
        if (hasWarningDiagnostics(documentation)) { hasWarnings = true }
        if (hasFatalDiagnostics(documentation)) { hasFatal = true }
        if (options.coverage) {
            let coverage = documentationCoverage(documentation)
            println("coverage[${profile.name}]: symbols ${coverage.documentedPublicSymbols}/${coverage.publicSymbols} (${coverage.symbolPercent()}%), parameters ${coverage.documentedPublicParameters}/${coverage.publicParameters} (${coverage.parameterPercent()}%)")
        }
    }
    if (!emitDiagnostics(options, diagnostics)) { return 1 }
    if (hasFatal) { return 1 }
    let path = outputPath(options)
    let content = renderCfgMatrixJson(entries.toArray())
    try {
        if (options.stdout) { print(content) } else { writeAtomically(path, content) }
    } catch (error: Exception) {
        println("error[CJDOC1010]: failed to write '${path}': ${error.message}")
        return 1
    }
    if (!options.stdout) { println("generated ${path}") }
    return if (hasErrors || (options.denyWarnings && hasWarnings)) { 1 } else { 0 }
}

public func runCli(args: Array<String>): Int64 {
    let options = try {
        parseCli(args)
    } catch (error: IllegalArgumentException) {
        println("error: ${error.message}")
        println(usage())
        return 2
    }
    if (options.help) {
        println(usage())
        return 0
    }
    if (options.version) {
        println("cjdoc 0.3.0")
        return 0
    }
    let commandLine = getCommandLine()
    let astPreflightExecutable: ?String = if (commandLine.isEmpty()) {
        None
    } else {
        Some(commandLine[0])
    }
    let jobs = if (options.jobs == 0) {
        let processors = getProcessorCount()
        if (processors < 1) { 1 } else if (processors > 8) { 8 } else { processors }
    } else {
        options.jobs
    }
    if (!options.cfgMatrixProfiles.isEmpty()) {
        return runCfgMatrix(options, jobs, astPreflightExecutable)
    }
    let documentation = generateCliDocumentation(options, options.cfgValues.toArray(),
        jobs, astPreflightExecutable)
    if (!emitDiagnostics(options, documentation)) { return 1 }
    if (options.coverage) {
        let coverage = documentationCoverage(documentation)
        println("coverage: symbols ${coverage.documentedPublicSymbols}/${coverage.publicSymbols} (${coverage.symbolPercent()}%), parameters ${coverage.documentedPublicParameters}/${coverage.publicParameters} (${coverage.parameterPercent()}%)")
    }
    if (hasFatalDiagnostics(documentation)) { return 1 }
    let path = outputPath(options)
    try {
        if (options.format == "html") {
            writeHtmlSite(path, renderDocumentationHtml(documentation,
                sourceUrlTemplate: options.sourceUrlTemplate,
                dependencySourceLinks: options.dependencySourceLinks.toArray()))
        } else {
            let content = if (options.format == "markdown") {
                renderDocumentationMarkdown(documentation)
            } else {
                renderDocumentationJson(documentation)
            }
            if (options.stdout) { print(content) } else { writeAtomically(path, content) }
        }
    } catch (error: Exception) {
        println("error[CJDOC1010]: failed to write '${path}': ${error.message}")
        return 1
    }
    if (!options.stdout) { println("generated ${path}") }
    return if (hasErrorDiagnostics(documentation) ||
        (options.denyWarnings && hasWarningDiagnostics(documentation))) { 1 } else { 0 }
}
