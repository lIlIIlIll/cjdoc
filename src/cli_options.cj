package cjdoc

import std.collection.*
import std.convert.Parsable
import cjdoc.model as public_model
import cjdoc.render as public_render

internal class NewCliOptions {
    var command = ""
    var maxDocIrMiB: ?Int64 = None
    var semanticMode = "chir"
    var semanticExplicit = false
    var cjcExecutable = "cjc"
    var cjcExplicit = false
    var chirWorkerExecutable: ?String = None
    var highlightAdapter: ?String = None
    var highlightNode: ?String = None
    var buildContext: ?String = None
    let documentSources = ArrayList<String>()
    let documentInventoryPins = ArrayList<DocumentInventoryPin>()
    var linkLanguage = ""
    var linkLanguageFallback = false
    var linkCompatible = false
    let chirImportPaths = ArrayList<String>()
    var project = "."
    var projectExplicit = false
    var output: ?String = None
    var input: ?String = None
    var baselineInput: ?String = None
    var currentInput: ?String = None
    var diffFormat = "text"
    var denyBreakingApi = false
    var denyPotentiallyBreakingApi = false
    var formatsExplicit = false
    let formats = ArrayList<String>()
    var stdout = false
    var denyWarnings = false
    var checkExamples = false
    var validationReport: ?String = None
    var apiDiffReport: ?String = None
    var forceOwned = false
    var jobs: Int64 = 1
    var jobsExplicit = false
    var audience = "external"
    var audienceExplicit = false
    var lintProfile = "standard"
    var lintProfileExplicit = false
    var schemaName = ""
    var includePathDependencies = false
    var includePathDependenciesExplicit = false
    var includeCachedDependencies = false
    var includeCachedDependenciesExplicit = false
    var cacheDirectory: ?String = None
    var cacheExplicit = false
    var noCache = false
    var cjpmCacheRoot: ?String = None
    var cjpmCacheExplicit = false
    var repositoryUrl: ?String = None
    var repositoryRevision: ?String = None
    var repositoryRoot: ?String = None
    var apiSurfaceBaseline: ?String = None
    var minSymbolCoverage: ?Int64 = None
    var minParameterCoverage: ?Int64 = None
    var locale = "zh-CN"
    var localeExplicit = false
    var allLanguages = false
    let requiredLanguages = ArrayList<String>()
    var docVersion: ?String = None
    var standardLibraryDocsVersion: ?String = None
    var standardLibraryDocsBaseUrl: ?String = None
    var agentFull = false
    var agentFullExplicit = false
    var htmlFontSans: ?String = None
    var htmlFontMono: ?String = None
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
    var servePortExplicit = false
    var serveOpen = false
    var serveOpenExplicit = false
    let dependencySources = ArrayList<DependencySourceInput>()
    let cfgValues = ArrayList<CfgValue>()
}
internal func newUsage(): String {
    "usage:\n" +
    "  cjdoc generate [--project <dir>] [--format json|markdown|html|api-surface|coverage|symbol-index]... [--output <dir>|--stdout] [--doc-version <version>] [--stdlib-doc-version <version>] [--stdlib-doc-base-url <https-url>]\n" +
    "                 [--semantic source|chir] [--cjc <executable>] [--chir-import-path <dir>]...\n" +
    "                 [--chir-worker <executable>]\n" +
    "                 [--highlight-adapter <absolute path> --highlight-node <absolute path>]\n" +
    "                 [--audience external|package|all] [--lint-profile off|standard|strict] [--jobs 1..64]\n" +
    "                 [--check-examples]\n" +
    "                 [--cfg NAME=VALUE] [--include-path-dependencies] [--include-cached-dependencies]\n" +
    "                 [--dependency-source NAME=PATH] [--cjpm-cache <dir>]\n" +
    "                 [--build-context <record.json>] [--doc-source <catalog-or-dir>]...\n" +
    "                 [--doc-inventory-pin PATH=SHA256]...\n" +
    "                 [--link-language <lang>] [--link-language-fallback] [--link-compatible]\n" +
    "                 [--cache-dir <dir>|--no-cache] [--force-owned] [--max-doc-ir-mib 1..64]\n" +
    "                 [--locale zh-CN|en|--all-languages] [--require-language zh-CN|en]...\n" +
    "                 [--agent-full] [--validation-report <report.json>] [--api-diff-report <report.json>]\n" +
    "                 [--html-font-sans <families>] [--html-font-mono <families>]\n" +
    "  cjdoc check [--project <dir>] [--semantic source|chir] [--cjc <executable>] [--chir-import-path <dir>]...\n" +
    "              [--chir-worker <executable>]\n" +
    "              [--highlight-adapter <absolute path> --highlight-node <absolute path>]\n" +
    "              [--deny-warnings] [--lint-profile off|standard|strict] [--check-examples] [--max-doc-ir-mib 1..64]\n" +
    "              [--api-surface-baseline <file>] [--min-symbol-coverage 0..100] [--min-parameter-coverage 0..100]\n" +
    "              [--build-context <record.json>] [--doc-source <catalog-or-dir>]...\n" +
    "              [--doc-inventory-pin PATH=SHA256]...\n" +
    "              [--link-language <lang>] [--link-language-fallback] [--link-compatible]\n" +
    "  cjdoc diff OLD NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]\n" +
    "  cjdoc diff --baseline OLD --current NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]\n" +
    "  cjdoc render --input <docs.json> [--format json|markdown|html|api-surface|coverage|symbol-index]... [--output <dir>|--stdout] [--force-owned] [--doc-version <version>]\n" +
    "               [--locale zh-CN|en|--all-languages] [--max-doc-ir-mib 1..64]\n" +
    "               [--agent-full] [--validation-report <report.json>] [--api-diff-report <report.json>]\n" +
    "               [--html-font-sans <families>] [--html-font-mono <families>]\n" +
    "  cjdoc serve [--project <dir>] [--port <port>] [--open] [--agent-full] [--max-doc-ir-mib 1..64]\n" +
    "              [--html-font-sans <families>] [--html-font-mono <families>]\n" +
    "  cjdoc versions compose --version ID=PATH... [--label ID=TEXT] [--channel ID=TEXT] [--status ID=TEXT]\n" +
    "                        [--base-path ID=PATH] [--release ID=TEXT] [--diff ID=PATH] [--latest ID] --output <dir> [--force-owned]\n" +
    "  cjdoc query --snapshot <docs.json|agent/manifest.json|versions.json>... --request <request.json|->\n" +
    "  cjdoc mcp --snapshot <docs.json|agent/manifest.json|versions.json>...\n" +
    "  cjdoc schema <name> (use 'cjdoc schema list' for available schemas)\n" +
    "  cjdoc <command> --help (options for one command)\n"
}

// Per-command help is static text: it never reads cjdoc.toml, needs a project,
// or starts a worker. Unknown commands still fail through normal dispatch.
internal func commandUsage(command: String): ?String {
    match (command) {
        case "generate" =>
            Some("usage: cjdoc generate [options]\n" +
                "Reads the project at --project (default the current directory) and writes documentation.\n\n" +
                "  --project <dir>                       project root, default the current directory\n" +
                "  --format <name>                       json (default), markdown, html, api-surface, coverage, symbol-index; repeatable\n" +
                "                                        a CLI list replaces the configured [output].formats list\n" +
                "  --output <dir>                        output directory, default <project>/target/doc\n" +
                "  --stdout                              write one JSON-producing format to standard output\n" +
                "  --force-owned                         replace files in an output directory cjdoc owns\n" +
                "  --doc-version <version>               version label for an HTML site (requires --format html)\n" +
                "  --stdlib-doc-version <version>        standard-library documentation release to link\n" +
                "  --stdlib-doc-base-url <https-url>     alternate standard-library docs root ending in /libs/std\n" +
                "  --semantic <source|chir>              semantic backend, default chir; source needs no worker\n" +
                "  --cjc <executable>                    compiler used by the CHIR backend, default cjc\n" +
                "  --chir-worker <executable>            explicit CHIR worker; default is the installed sibling\n" +
                "  --chir-import-path <dir>              extra CHIR import path, repeatable\n" +
                "  --highlight-adapter <abs path>        external highlighting adapter (with --highlight-node)\n" +
                "  --highlight-node <abs path>           Node executable for the adapter\n" +
                "  --audience <external|package|all>     declaration audience, default external\n" +
                "  --lint-profile <off|standard|strict>  documentation rules, default standard\n" +
                "  --jobs <1..64>                        parallel source scans, default 1\n" +
                "  --check-examples                       compile and run @example blocks\n" +
                "  --deny-warnings                        fail when a warning is reported\n" +
                "  --cfg <NAME=VALUE>                     conditional compilation value, repeatable\n" +
                "  --include-path-dependencies            include path dependencies as documented modules\n" +
                "  --include-cached-dependencies          include cached dependencies as documented modules\n" +
                "  --dependency-source <NAME=PATH>        explicit dependency source, repeatable\n" +
                "  --cjpm-cache <dir>                     cjpm dependency cache root (with --include-cached-dependencies)\n" +
                "  --cache-dir <dir>                      cjdoc source cache, default <project>/target/cjdoc/cache/source-v11\n" +
                "  --no-cache                             do not read or write the source cache\n" +
                "  --cache                                use the default source cache location again\n" +
                "  --build-context <record.json>          captured build context\n" +
                "  --doc-source <catalog-or-dir>          external documentation catalog or directory, repeatable\n" +
                "  --doc-inventory-pin <PATH=SHA256>      pin for one local symbol inventory, repeatable\n" +
                "  --link-language <lang>                 language used inside links\n" +
                "  --link-language-fallback               allow falling back to another language\n" +
                "  --link-compatible                      keep generated links compatible across versions\n" +
                "  --repository-url <url>                 GitHub repository URL for source links\n" +
                "  --repository-revision <revision>       commit used by source links\n" +
                "  --repository-root <dir>                repository-relative root of the project\n" +
                "  --max-doc-ir-mib <1..64>               Doc IR size budget, default from [limits]\n" +
                "  --locale <zh-CN|en>                    interface language; default follows [i18n] default-language\n" +
                "  --all-languages                        emit one site per configured language\n" +
                "  --require-language <zh-CN|en>          require a language to be complete, repeatable\n" +
                "  --agent-full                           include the agent documentation tree\n" +
                "  --validation-report <report.json>      attach a validation report to the site\n" +
                "  --api-diff-report <report.json>        attach an API diff report to the site\n" +
                "  --html-font-sans <families>            sans-serif font stack written into the site\n" +
                "  --html-font-mono <families>            monospace font stack written into the site\n\n" +
                "Project defaults come from cjdoc.toml; explicit flags override them.\n")
        case "check" =>
            Some("usage: cjdoc check [options]\n" +
                "Reads the project and reports diagnostics and gates; writes no site.\n\n" +
                "  --project <dir>                       project root, default the current directory\n" +
                "  --semantic <source|chir>              semantic backend, default chir; source needs no worker\n" +
                "  --cjc <executable>                    compiler used by the CHIR backend, default cjc\n" +
                "  --chir-worker <executable>            explicit CHIR worker; default is the installed sibling\n" +
                "  --chir-import-path <dir>              extra CHIR import path, repeatable\n" +
                "  --highlight-adapter <abs path>        external highlighting adapter (with --highlight-node)\n" +
                "  --highlight-node <abs path>           Node executable for the adapter\n" +
                "  --audience <external|package|all>     declaration audience, default external\n" +
                "  --lint-profile <off|standard|strict>  documentation rules, default standard\n" +
                "  --jobs <1..64>                        parallel source scans, default 1\n" +
                "  --check-examples                       compile and run @example blocks\n" +
                "  --deny-warnings                        fail when a warning is reported\n" +
                "  --cfg <NAME=VALUE>                     conditional compilation value, repeatable\n" +
                "  --include-path-dependencies            include path dependencies as documented modules\n" +
                "  --include-cached-dependencies          include cached dependencies as documented modules\n" +
                "  --dependency-source <NAME=PATH>        explicit dependency source, repeatable\n" +
                "  --cjpm-cache <dir>                     cjpm dependency cache root (with --include-cached-dependencies)\n" +
                "  --cache-dir <dir>                      cjdoc source cache, default <project>/target/cjdoc/cache/source-v11\n" +
                "  --no-cache                             do not read or write the source cache\n" +
                "  --cache                                use the default source cache location again\n" +
                "  --build-context <record.json>          captured build context\n" +
                "  --doc-source <catalog-or-dir>          external documentation catalog or directory, repeatable\n" +
                "  --doc-inventory-pin <PATH=SHA256>      pin for one local symbol inventory, repeatable\n" +
                "  --link-language <lang>                 language used inside links\n" +
                "  --link-language-fallback               allow falling back to another language\n" +
                "  --link-compatible                      keep generated links compatible across versions\n" +
                "  --api-surface-baseline <file>          strict API baseline; any change fails\n" +
                "  --min-symbol-coverage <0..100>         additional symbol coverage gate\n" +
                "  --min-parameter-coverage <0..100>      additional parameter coverage gate\n" +
                "  --max-doc-ir-mib <1..64>               Doc IR size budget, default from [limits]\n\n" +
                "check applies [lint], [coverage] and [highlight]; [output] does not apply.\n")
        case "render" =>
            Some("usage: cjdoc render --input <docs.json> [options]\n" +
                "Re-renders a captured Doc IR file without reading the project configuration.\n\n" +
                "  --input <docs.json>                   captured cjdoc.doc-ir/18 document (required)\n" +
                "  --format <name>                       json, markdown, html, api-surface, coverage, symbol-index; repeatable\n" +
                "  --output <dir>                        output directory, default target/doc\n" +
                "  --stdout                              write one JSON-producing format to standard output\n" +
                "  --force-owned                         replace files in an output directory cjdoc owns\n" +
                "  --doc-version <version>               version label for an HTML site (requires --format html)\n" +
                "  --locale <zh-CN|en>                   interface language, default zh-CN\n" +
                "  --all-languages                        emit one site per recorded language\n" +
                "  --agent-full                           include the agent documentation tree\n" +
                "  --validation-report <report.json>      attach a validation report to the site\n" +
                "  --api-diff-report <report.json>        attach an API diff report to the site\n" +
                "  --html-font-sans <families>            sans-serif font stack written into the site\n" +
                "  --html-font-mono <families>            monospace font stack written into the site\n" +
                "  --max-doc-ir-mib <1..64>               Doc IR size budget, default 64\n")
        case "diff" =>
            Some("usage: cjdoc diff OLD NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]\n" +
                "       cjdoc diff --baseline OLD --current NEW [options]\n\n" +
                "  --baseline <file>                     previous cjdoc.api-surface/3 snapshot\n" +
                "  --current <file>                      current cjdoc.api-surface/3 snapshot\n" +
                "  --format <text|json>                  report format, default text\n" +
                "  --deny-breaking-api                   fail when a breaking change is found\n" +
                "  --deny-potentially-breaking-api       fail when a potentially breaking change is found\n")
        case "serve" =>
            Some("usage: cjdoc serve [options]\n" +
                "Generates the project, serves the HTML site, and rebuilds when inputs change.\n\n" +
                "  --project <dir>                       project root, default the current directory\n" +
                "  --port <port>                         loopback port, default 8080\n" +
                "  --open                                open a browser once the first build finishes\n" +
                "  --format <name>                       formats to generate; html is always served\n" +
                "  --output <dir>                        output directory, default <project>/target/doc\n" +
                "  --semantic <source|chir>              semantic backend, default chir; source needs no worker\n" +
                "  --cjc <executable>                    compiler used by the CHIR backend, default cjc\n" +
                "  --chir-worker <executable>            explicit CHIR worker; default is the installed sibling\n" +
                "  --chir-import-path <dir>              extra CHIR import path, repeatable\n" +
                "  --highlight-adapter <abs path>        external highlighting adapter (with --highlight-node)\n" +
                "  --highlight-node <abs path>           Node executable for the adapter\n" +
                "  --audience <external|package|all>     declaration audience, default external\n" +
                "  --lint-profile <off|standard|strict>  documentation rules, default standard\n" +
                "  --jobs <1..64>                        parallel source scans, default 1\n" +
                "  --check-examples                       compile and run @example blocks\n" +
                "  --deny-warnings                        fail the rebuild when a warning is reported\n" +
                "  --cfg <NAME=VALUE>                     conditional compilation value, repeatable\n" +
                "  --include-path-dependencies            include path dependencies as documented modules\n" +
                "  --include-cached-dependencies          include cached dependencies as documented modules\n" +
                "  --dependency-source <NAME=PATH>        explicit dependency source, repeatable\n" +
                "  --cjpm-cache <dir>                     cjpm dependency cache root (with --include-cached-dependencies)\n" +
                "  --cache-dir <dir>                      cjdoc source cache, default <project>/target/cjdoc/cache/source-v11\n" +
                "  --no-cache                             do not read or write the source cache\n" +
                "  --cache                                use the default source cache location again\n" +
                "  --repository-url <url>                 GitHub repository URL for source links\n" +
                "  --repository-revision <revision>       commit used by source links\n" +
                "  --repository-root <dir>                repository-relative root of the project\n" +
                "  --max-doc-ir-mib <1..64>               Doc IR size budget, default from [limits]\n" +
                "  --locale <zh-CN|en>                    interface language; default follows [i18n] default-language\n" +
                "  --require-language <zh-CN|en>          require a language to be complete, repeatable\n" +
                "  --api-surface-baseline <file>          strict API baseline; any change fails\n" +
                "  --min-symbol-coverage <0..100>         additional symbol coverage gate\n" +
                "  --min-parameter-coverage <0..100>      additional parameter coverage gate\n" +
                "  --agent-full                           include the agent documentation tree\n" +
                "  --html-font-sans <families>            sans-serif font stack written into the site\n" +
                "  --html-font-mono <families>            monospace font stack written into the site\n\n" +
                "Status is available at http://127.0.0.1:<port>/__cjdoc/status.json.\n")
        case "versions" | "versions compose" =>
            Some("usage: cjdoc versions compose --version ID=PATH... --output <dir> [options]\n\n" +
                "  --version <ID=PATH>                   generated site root, repeatable and required\n" +
                "  --output <dir>                        composed site root, required\n" +
                "  --latest <ID>                         default version, default the first --version\n" +
                "  --label <ID=TEXT>                     display label, default the version ID\n" +
                "  --channel <ID=TEXT>                   release channel, default unspecified\n" +
                "  --status <ID=TEXT>                    release status, default published\n" +
                "  --base-path <ID=PATH>                 route prefix, default the version ID\n" +
                "  --release <ID=TEXT>                   release notes text\n" +
                "  --diff <ID=PATH>                      existing API diff to attach\n" +
                "  --force-owned                         replace files in an output directory cjdoc owns\n")
        case "query" =>
            Some("usage: cjdoc query --snapshot <docs.json|agent/manifest.json|versions.json>... --request <request.json|->\n\n" +
                "  --snapshot <path>                     frozen documentation input, 1..64 entries\n" +
                "  --request <path|->                    one JSON request object; - reads standard input\n")
        case "mcp" =>
            Some("usage: cjdoc mcp --snapshot <docs.json|agent/manifest.json|versions.json>...\n\n" +
                "Serves the documentation query tools over stdio JSON-RPC.\n\n" +
                "  --snapshot <path>                     frozen documentation input, 1..64 entries\n")
        case "schema" =>
            Some("usage: cjdoc schema <name>\n       cjdoc schema list\n\n" +
                "Prints one published schema, or the list of available schema names.\n")
        case _ => None<String>
    }
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

private func requireNonEmptyCliValue(args: Array<String>, index: Int64, option: String): String {
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
    if (!highlightHostPathIsAbsolute(value)) {
        throw IllegalArgumentException("${option} requires an absolute path")
    }
    value
}

@When[os != "Windows"]
internal func highlightHostPathIsAbsolute(value: String): Bool { value.startsWith("/") }

@When[os == "Windows"]
internal func highlightHostPathIsAbsolute(value: String): Bool {
    if (value.startsWith("\\\\")) { return true }
    value.size >= 3 && ((value[0] >= b'A' && value[0] <= b'Z') ||
        (value[0] >= b'a' && value[0] <= b'z')) && value[1] == b':' &&
        (value[2] == b'\\' || value[2] == b'/')
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
            options.documentInventoryPins.add(DocumentInventoryPin(value[..separator], value[separator + 1..]))
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
            options.cjpmCacheExplicit = true
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
            options.formatsExplicit = true
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
            options.servePort = Int64.parse(requireCliValue(args, index, "--port"))
            options.servePortExplicit = true
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
        case "--open" => options.serveOpen = true; options.serveOpenExplicit = true; Some(index + 1)
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

private func parseCliOption(options: NewCliOptions, args: Array<String>, index: Int64): Int64 {
    if (let Some(next) <- parsePathAndTextOption(options, args, index)) { return next }
    if (let Some(next) <- parseCollectionOption(options, args, index)) { return next }
    if (let Some(next) <- parseNumericOption(options, args, index)) { return next }
    if (let Some(next) <- parseEnumOption(options, args, index)) { return next }
    if (let Some(next) <- parseFlagOption(options, args, index)) { return next }
    if (let Some(next) <- parseHtmlFontOption(options, args, index)) { return next }
    throw IllegalArgumentException("unknown option '${args[index]}'")
}

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
private func validateCliOptions(options: NewCliOptions): Unit {
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
