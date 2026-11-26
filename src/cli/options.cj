protected package cjdoc.cli

import std.collection.*

protected class NewCliOptions {
    protected var command = ""
    protected var maxDocIrMiB: ?Int64 = None
    protected var semanticMode = "chir"
    var semanticExplicit = false
    protected var cjcExecutable = "cjc"
    var cjcExplicit = false
    protected var chirWorkerExecutable: ?String = None
    protected var highlightAdapter: ?String = None
    protected var highlightNode: ?String = None
    protected var buildContext: ?String = None
    protected let documentSources = ArrayList<String>()
    protected let documentInventoryPins = ArrayList<(String, String)>()
    protected var linkLanguage = ""
    protected var linkLanguageFallback = false
    protected var linkCompatible = false
    protected let chirImportPaths = ArrayList<String>()
    protected var project = "."
    protected var output: ?String = None
    protected var input: ?String = None
    protected var baselineInput: ?String = None
    protected var currentInput: ?String = None
    protected var diffFormat = "text"
    protected var denyBreakingApi = false
    protected var denyPotentiallyBreakingApi = false
    protected let formats = ArrayList<String>()
    protected var stdout = false
    protected var denyWarnings = false
    protected var checkExamples = false
    var validationReport: ?String = None
    var apiDiffReport: ?String = None
    protected var forceOwned = false
    protected var jobs: Int64 = 1
    var jobsExplicit = false
    protected var audience = "external"
    var audienceExplicit = false
    protected var lintProfile = "standard"
    var lintProfileExplicit = false
    protected var schemaName = ""
    protected var includePathDependencies = false
    var includePathDependenciesExplicit = false
    protected var includeCachedDependencies = false
    var includeCachedDependenciesExplicit = false
    protected var cacheDirectory: ?String = None
    var cacheExplicit = false
    protected var noCache = false
    protected var cjpmCacheRoot: ?String = None
    protected var repositoryUrl: ?String = None
    protected var repositoryRevision: ?String = None
    protected var repositoryRoot: ?String = None
    protected var apiSurfaceBaseline: ?String = None
    protected var minSymbolCoverage: ?Int64 = None
    protected var minParameterCoverage: ?Int64 = None
    protected var locale = "zh-CN"
    var localeExplicit = false
    protected var allLanguages = false
    protected let requiredLanguages = ArrayList<String>()
    protected var docVersion: ?String = None
    protected var standardLibraryDocsVersion: ?String = None
    protected var standardLibraryDocsBaseUrl: ?String = None
    protected var agentFull = false
    var agentFullExplicit = false
    protected var htmlFontSans: ?String = None
    protected var htmlFontMono: ?String = None
    var versionSubcommand = ""
    // Serve re-resolves project configuration from the original command line on
    // every rebuild instead of reusing already-merged values.
    var serveArgs: Array<String> = []

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
    var serveOpen = false
    protected let dependencySources = ArrayList<(String, String)>()
    protected let cfgValues = ArrayList<(String, String)>()
}

private func parseSchemaCommand(args: Array<String>): NewCliOptions {
    if (args.size != 2) { throw IllegalArgumentException("schema requires exactly one schema name") }
    if (args[1].startsWith("-")) {
        throw IllegalArgumentException("${args[1]} is not valid for schema")
    }
    let options = NewCliOptions()
    options.command = "schema"
    options.schemaName = args[1]
    options
}

private func parseDocumentOptions(args: Array<String>): NewCliOptions {
    let options = NewCliOptions()
    options.command = args[0]
    if (args[0] == "serve") { options.serveArgs = args }
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
    // Configuration is resolved once, after the CLI is known but before the
    // cross-option checks, so invalid project values fail even when overridden.
    applyProjectCliConfig(options)
    validateCliOptions(options)
    options
}

// Serve re-resolves its configuration from the original command line on every
// rebuild, so [analysis]/[semantic] edits and removals take effect while CLI
// overrides keep winning.
internal func reparseServeCommand(original: Array<String>): NewCliOptions {
    parseNewCli(original)
}

protected func parseNewCli(args: Array<String>): NewCliOptions {
    if (args.isEmpty()) { throw IllegalArgumentException("missing command") }
    if (args[0] == "schema") { return parseSchemaCommand(args) }
    if (args[0] == "versions") { return parseVersionsCommand(args) }
    if (args[0] != "generate" && args[0] != "check" && args[0] != "render" &&
        args[0] != "diff" && args[0] != "serve") {
        throw IllegalArgumentException("unknown command '${args[0]}'")
    }
    parseDocumentOptions(args)
}
