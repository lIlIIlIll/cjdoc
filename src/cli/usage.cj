protected package cjdoc.cli

protected func newUsage(): String {
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
func commandUsage(command: String): ?String {
    match (command) {
        case "generate" =>
            Some("usage: cjdoc generate [options]\n" +
                "Reads the project at --project and writes documentation.\n\n" +
                documentOptionHelp(command) +
                "\nProject defaults come from cjdoc.toml; explicit flags override them.\n")
        case "check" =>
            Some("usage: cjdoc check [options]\n" +
                "Reads the project and reports diagnostics and gates; writes no site.\n\n" +
                documentOptionHelp(command) +
                "\ncheck applies [lint], [coverage] and [highlight]; [output] does not apply.\n")
        case "render" =>
            Some("usage: cjdoc render --input <docs.json> [options]\n" +
                "Re-renders a captured Doc IR file without reading project configuration.\n\n" +
                documentOptionHelp(command))
        case "diff" =>
            Some("usage: cjdoc diff OLD NEW [options]\n" +
                "       cjdoc diff --baseline OLD --current NEW [options]\n\n" +
                documentOptionHelp(command))
        case "serve" =>
            Some("usage: cjdoc serve [options]\n" +
                "Generates the project, serves HTML, and rebuilds when inputs change.\n\n" +
                documentOptionHelp(command) +
                "\nHTML is always served. Status: http://127.0.0.1:<bound-port>/__cjdoc/status.json.\n")
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

// Help is answered before configuration is read: it needs no project, starts no
// worker, and works even when the project's cjdoc.toml is invalid.
protected func runCommandHelp(args: Array<String>): ?Int64 {
    if (args.size < 2) { return None }
    let last = args[args.size - 1]
    if (last != "--help" && last != "-h") { return None }
    // Accept `cjdoc serve --help` and the nested `cjdoc versions compose --help`.
    var name = ""
    var index: Int64 = 0
    while (index < args.size - 1) {
        let token = args[index]
        if (token.startsWith("-")) { return None }
        name = if (name.isEmpty()) { token } else { name + " " + token }
        index++
    }
    match (commandUsage(name)) {
        case Some(text) => print(text); Some(0)
        case None => None<Int64>
    }
}

