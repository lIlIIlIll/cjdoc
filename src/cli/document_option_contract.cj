protected package cjdoc.cli

private let GENERATE: UInt8 = 1
private let CHECK: UInt8 = 2
private let RENDER: UInt8 = 4
private let DIFF: UInt8 = 8
private let SERVE: UInt8 = 16
private let PROJECT = GENERATE | CHECK | SERVE
private let SITE = GENERATE | RENDER | SERVE
private let PUBLICATION = GENERATE | RENDER
private let DEPENDENCY_DOCS = GENERATE | CHECK

// A token's applicability is independent of its value or any project default.
// Keep the spelling, help and command scope together; parsers validate values.
private let documentOptionContract: Array<(String, UInt8, String)> = [
    ("--project", PROJECT, " <dir>  Project root (default: current directory)"),
    ("--port", SERVE, " <0..65535>  Loopback port (default: 8080; 0 selects a free port)"),
    ("--open", SERVE, "  Open a browser after the first build"),
    ("--input", RENDER, " <docs.json>  Captured Doc IR (required)"),
    ("--baseline", DIFF, " <file>  Previous API surface snapshot"),
    ("--current", DIFF, " <file>  Current API surface snapshot"),
    ("--format", SITE | DIFF, " <name>  Output format"),
    ("--output", SITE, " <dir>  Output directory (default: target/doc)"),
    ("--stdout", PUBLICATION, "  Write one JSON-producing format to standard output"),
    ("--force-owned", SITE, "  Replace files in an output directory cjdoc owns"),
    ("--doc-version", PUBLICATION, " <version>  Version label for an HTML site"),
    ("--stdlib-doc-version", GENERATE, " <version>  Standard-library documentation release to link"),
    ("--stdlib-doc-base-url", GENERATE, " <https-url>  Alternate standard-library docs root ending in /libs/std"),
    ("--semantic", PROJECT, " <source|chir>  Semantic backend (default: chir)"),
    ("--cjc", PROJECT, " <executable>  Compiler for CHIR (default: cjc)"),
    ("--chir-worker", PROJECT, " <executable>  CHIR worker (default: the installed sibling)"),
    ("--chir-import-path", PROJECT, " <dir>  Extra CHIR import path; repeatable"),
    ("--highlight-adapter", PROJECT, " <abs path>  External highlighting adapter (with --highlight-node)"),
    ("--highlight-node", PROJECT, " <abs path>  Node executable (with --highlight-adapter)"),
    ("--audience", PROJECT, " <external|package|all>  Declaration audience (default: external)"),
    ("--lint-profile", PROJECT, " <off|standard|strict>  Documentation rules (default: standard)"),
    ("--jobs", PROJECT, " <1..64>  Parallel source scans (default: 1)"),
    ("--check-examples", PROJECT, "  Compile and run @example blocks"),
    ("--deny-warnings", PROJECT, "  Fail when a warning is reported"),
    ("--cfg", PROJECT, " <NAME=VALUE>  Conditional compilation value; repeatable"),
    ("--include-path-dependencies", PROJECT, "  Include path dependencies as documented modules"),
    ("--no-include-path-dependencies", PROJECT, "  Do not include path dependencies"),
    ("--include-cached-dependencies", PROJECT, "  Include cached dependencies as documented modules"),
    ("--no-include-cached-dependencies", PROJECT, "  Do not include cached dependencies"),
    ("--dependency-source", PROJECT, " <NAME=PATH>  Explicit dependency source; repeatable"),
    ("--cjpm-cache", PROJECT, " <dir>  Dependency cache root (requires --include-cached-dependencies)"),
    ("--cache-dir", PROJECT, " <dir>  Source cache directory (default: target/cjdoc/cache/source-v11)"),
    ("--no-cache", PROJECT, "  Do not read or write the source cache"),
    ("--cache", PROJECT, "  Re-enable the source cache at its default location"),
    ("--build-context", DEPENDENCY_DOCS, " <record.json>  Captured build context"),
    ("--doc-source", DEPENDENCY_DOCS, " <catalog-or-dir>  External documentation; repeatable"),
    ("--doc-inventory-pin", DEPENDENCY_DOCS, " <PATH=SHA256>  Pin for a local inventory; repeatable"),
    ("--link-language", DEPENDENCY_DOCS, " <lang>  Language used inside links"),
    ("--link-language-fallback", DEPENDENCY_DOCS, "  Allow falling back to another language"),
    ("--link-compatible", DEPENDENCY_DOCS, "  Keep links compatible across versions"),
    ("--repository-url", GENERATE | SERVE, " <url>  Repository URL for source links (with --repository-revision)"),
    ("--repository-revision", GENERATE | SERVE, " <revision>  Source revision (with --repository-url)"),
    ("--repository-root", GENERATE | SERVE, " <dir>  Repository-relative root of the project"),
    ("--api-surface-baseline", PROJECT, " <file>  Strict API baseline; any change fails"),
    ("--min-symbol-coverage", PROJECT, " <0..100>  Additional symbol coverage gate"),
    ("--min-parameter-coverage", PROJECT, " <0..100>  Additional parameter coverage gate"),
    ("--deny-breaking-api", DIFF, "  Fail when a breaking change is found"),
    ("--deny-potentially-breaking-api", DIFF, "  Fail when a potentially breaking change is found"),
    ("--max-doc-ir-mib", SITE | CHECK, " <1..64>  Doc IR size budget"),
    ("--locale", SITE, " <zh-CN|en>  Interface language"),
    ("--all-languages", PUBLICATION, "  Emit one Markdown or HTML site per language"),
    ("--require-language", PROJECT, " <zh-CN|en>  Require a language to be complete; repeatable"),
    ("--agent-full", SITE, "  Include the agent documentation tree"),
    ("--no-agent-full", SITE, "  Do not include the agent documentation tree"),
    ("--validation-report", PUBLICATION, " <report.json>  Attach a validation report to the HTML site"),
    ("--api-diff-report", PUBLICATION, " <report.json>  Attach an API diff report to the HTML site"),
    ("--html-font-sans", SITE, " <families>  Sans-serif font stack written into the HTML site"),
    ("--html-font-mono", SITE, " <families>  Monospace font stack written into the HTML site")
]

private func documentCommandMask(command: String): UInt8 {
    match (command) {
        case "generate" => GENERATE
        case "check" => CHECK
        case "render" => RENDER
        case "diff" => DIFF
        case "serve" => SERVE
        case _ => 0
    }
}

internal func validateDocumentOptionScope(command: String, token: String): Unit {
    let commandMask = documentCommandMask(command)
    for ((name, scope, _) in documentOptionContract) {
        if (name != token) { continue }
        if ((commandMask & scope) == 0) {
            throw IllegalArgumentException("${name} is not valid for ${command}")
        }
        return
    }
    throw IllegalArgumentException("unknown option '${token}'")
}

internal func documentOptionHelp(command: String): String {
    let commandMask = documentCommandMask(command)
    let help = StringBuilder()
    for ((name, scope, description) in documentOptionContract) {
        if ((commandMask & scope) == 0) { continue }
        help.append("  ")
        help.append(name)
        if (name == "--format") {
            if (command == "diff") {
                help.append(" <text|json>  Report format (default: text)")
            } else {
                help.append(" <name>  json, markdown, html, api-surface, coverage, symbol-index; repeatable")
            }
        } else {
            help.append(description)
        }
        help.append("\n")
    }
    help.toString()
}
