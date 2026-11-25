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
                "  --input <docs.json>                   captured cjdoc.doc-ir/19 document (required)\n" +
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

