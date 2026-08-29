package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.convert.Parsable
import std.fs.*
import std.sort.*

private class NewCliOptions {
    var command = ""
    var project = "."
    var output: ?String = None
    var input: ?String = None
    let formats = ArrayList<String>()
    var stdout = false
    var denyWarnings = false
    var jobs: Int64 = 1
    var audience = "external"
    var lintProfile = "standard"
    var schemaName = ""
    var includePathDependencies = false
    var includeCachedDependencies = false
    let dependencySources = ArrayList<DependencySourceInput>()
    let cfgValues = ArrayList<CfgValue>()
}

private func newUsage(): String {
    "usage:\n" +
    "  cjdoc generate [--project <dir>] [--format json|markdown|html]... [--output <dir>|--stdout]\n" +
    "                 [--audience external|package|all] [--lint-profile off|standard|strict] [--jobs 1..64]\n" +
    "                 [--cfg NAME=VALUE] [--include-path-dependencies] [--include-cached-dependencies]\n" +
    "                 [--dependency-source NAME=PATH]\n" +
    "  cjdoc check [--project <dir>] [--deny-warnings] [--lint-profile off|standard|strict]\n" +
    "  cjdoc render --input <docs.json> [--format json|markdown|html]... [--output <dir>|--stdout]\n" +
    "  cjdoc schema list|doc-ir|diagnostics|cfg-matrix|search-index\n"
}

private func splitNamedValue(value: String, option: String): (String, String) {
    let parts = value.split("=")
    if (parts.size != 2 || parts[0].trimAscii().isEmpty() || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("${option} requires NAME=VALUE")
    }
    (parts[0].trimAscii(), parts[1].trimAscii())
}

private func addFormat(options: NewCliOptions, value: String): Unit {
    if (value != "json" && value != "markdown" && value != "html") {
        throw IllegalArgumentException("unsupported format '${value}'")
    }
    if (!options.formats.contains(value)) { options.formats.add(value) }
}

private func parseNewCli(args: Array<String>): NewCliOptions {
    let options = NewCliOptions()
    if (args.isEmpty()) { throw IllegalArgumentException("missing command") }
    options.command = args[0]
    if (options.command == "schema") {
        if (args.size != 2) { throw IllegalArgumentException("schema requires exactly one schema name") }
        options.schemaName = args[1]
        return options
    }
    if (options.command != "generate" && options.command != "check" && options.command != "render") {
        throw IllegalArgumentException("unknown command '${options.command}'")
    }
    var index: Int64 = 1
    while (index < args.size) {
        match (args[index]) {
            case "--project" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--project requires a value") }
                options.project = args[index + 1]; index += 2
            case "--input" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--input requires a value") }
                options.input = Some(args[index + 1]); index += 2
            case "--output" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--output requires a value") }
                options.output = Some(args[index + 1]); index += 2
            case "--format" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--format requires a value") }
                addFormat(options, args[index + 1]); index += 2
            case "--stdout" => options.stdout = true; index++
            case "--deny-warnings" => options.denyWarnings = true; index++
            case "--include-path-dependencies" => options.includePathDependencies = true; index++
            case "--include-cached-dependencies" => options.includeCachedDependencies = true; index++
            case "--dependency-source" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--dependency-source requires a value") }
                let (name, path) = splitNamedValue(args[index + 1], "--dependency-source")
                options.dependencySources.add(DependencySourceInput(name, path)); index += 2
            case "--cfg" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--cfg requires a value") }
                let (name, value) = splitNamedValue(args[index + 1], "--cfg")
                options.cfgValues.add(CfgValue(name, value)); index += 2
            case "--jobs" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--jobs requires a value") }
                options.jobs = Int64.parse(args[index + 1]); index += 2
            case "--audience" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--audience requires a value") }
                options.audience = args[index + 1]; index += 2
            case "--lint-profile" =>
                if (index + 1 >= args.size) { throw IllegalArgumentException("--lint-profile requires a value") }
                options.lintProfile = args[index + 1]; index += 2
            case _ => throw IllegalArgumentException("unknown option '${args[index]}'")
        }
    }
    if (options.jobs < 1 || options.jobs > 64) { throw IllegalArgumentException("--jobs must be in 1..64") }
    if (options.audience != "external" && options.audience != "package" && options.audience != "all") {
        throw IllegalArgumentException("--audience must be external, package, or all")
    }
    if (options.lintProfile != "off" && options.lintProfile != "standard" && options.lintProfile != "strict") {
        throw IllegalArgumentException("--lint-profile must be off, standard, or strict")
    }
    if (options.command == "render" && options.input.isNone()) {
        throw IllegalArgumentException("render requires --input")
    }
    if (options.command != "render" && options.input.isSome()) {
        throw IllegalArgumentException("--input is only valid for render")
    }
    if (options.command == "check" && (!options.formats.isEmpty() || options.output.isSome() || options.stdout)) {
        throw IllegalArgumentException("check does not accept render output options")
    }
    if (options.stdout && options.output.isSome()) {
        throw IllegalArgumentException("--stdout and --output are mutually exclusive")
    }
    if (options.formats.isEmpty() && options.command != "check") { options.formats.add("json") }
    if (options.stdout && (options.formats.size != 1 || options.formats[0] != "json")) {
        throw IllegalArgumentException("--stdout requires exactly one json format")
    }
    options
}

private func orderedFormats(options: NewCliOptions): Array<String> {
    let result = ArrayList<String>()
    if (options.formats.contains("json")) { result.add("json") }
    if (options.formats.contains("markdown")) { result.add("markdown") }
    if (options.formats.contains("html")) { result.add("html") }
    result.toArray()
}

private func renderArtifacts(documentation: public_model.DocumentationSet,
    formats: Array<String>): Array<public_render.RenderArtifact> {
    let result = ArrayList<public_render.RenderArtifact>()
    for (format in formats) {
        result.add(all: public_render.rendererFor(format).render(documentation))
    }
    result.toArray()
}

private func writeOutputAtomically(path: Path, content: String): Unit {
    let parent = path.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    if (exists(path)) {
        try { if (String.fromUtf8(File.readFrom(path)) == content) { return } }
        catch (_: Exception) {}
    }
    let temporary = Path(path.toString() + ".tmp")
    File.writeTo(temporary, content.toArray())
    rename(temporary, to: path, overwrite: true)
}

private func ownershipManifest(paths: Array<String>): String {
    sort(paths)
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"cjdoc.output/1\",\n  \"files\": [")
    var index: Int64 = 0
    while (index < paths.size) {
        if (index > 0) { out.append(",") }
        out.append("\n    ${public_render.escapeJsonString(paths[index])}")
        index++
    }
    if (!paths.isEmpty()) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func writeOwnedArtifacts(outputDirectory: String,
    artifacts: Array<public_render.RenderArtifact>): Unit {
    let root = Path(outputDirectory)
    let manifest = root.join(".cjdoc-output.json")
    if (exists(root) && !exists(manifest) && !Directory.readFrom(root).isEmpty()) {
        throw IllegalArgumentException("refusing to write into non-empty unowned output directory '${outputDirectory}'")
    }
    if (!exists(root)) { Directory.create(root, recursive: true) }
    let paths = ArrayList<String>()
    for (artifact in artifacts) {
        writeOutputAtomically(root.join(artifact.path), artifact.content)
        paths.add(artifact.path)
    }
    writeOutputAtomically(manifest, ownershipManifest(paths.toArray()))
}

private func printPublicDiagnostics(documentation: public_model.DocumentationSet): Unit {
    for (diagnostic in documentation.diagnostics) {
        eprintln("${diagnostic.severity}[${diagnostic.code}]: ${diagnostic.message}")
        match (diagnostic.source) {
            case Some(source) => eprintln(" --> ${source.path}:${source.start.line}:${source.start.column}")
            case None => ()
        }
    }
}

private func publicExitCode(documentation: public_model.DocumentationSet, denyWarnings: Bool): Int64 {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error" || (denyWarnings && diagnostic.severity == "warning")) { return 1 }
    }
    0
}

private func runSchema(name: String): Int64 {
    match (name) {
        case "list" => println("doc-ir\ndiagnostics\ncfg-matrix\nsearch-index")
        case "doc-ir" => print(DOC_IR_SCHEMA)
        case "diagnostics" => print(DIAGNOSTICS_SCHEMA)
        case "cfg-matrix" => print(CFG_MATRIX_SCHEMA)
        case "search-index" => print(SEARCH_INDEX_SCHEMA)
        case _ => throw IllegalArgumentException("unknown schema '${name}'")
    }
    0
}

func runCli(args: Array<String>): Int64 {
    if (args.size == 1 && (args[0] == "--help" || args[0] == "-h")) { print(newUsage()); return 0 }
    if (args.size == 1 && args[0] == "--version") { println("cjdoc 0.4.0"); return 0 }
    try {
        let options = parseNewCli(args)
        if (options.command == "schema") { return runSchema(options.schemaName) }
        let documentation = if (options.command == "render") {
            let input = options.input.getOrThrow()
            let bytes = File.readFrom(Path(input))
            if (bytes.size > 64 * 1024 * 1024) {
                throw IllegalArgumentException("Doc IR input exceeds 64 MiB")
            }
            public_render.decodeDocIr(String.fromUtf8(bytes))
        } else {
            DocumentationEngine().generate(GenerationRequest(options.project, jobs: options.jobs,
                audience: options.audience, lintProfile: options.lintProfile,
                includePathDependencies: options.includePathDependencies,
                includeCachedDependencies: options.includeCachedDependencies,
                dependencySources: options.dependencySources.toArray(),
                cfgValues: options.cfgValues.toArray()))
        }
        printPublicDiagnostics(documentation)
        if (options.command != "check") {
            let artifacts = renderArtifacts(documentation, orderedFormats(options))
            if (options.stdout) {
                print(artifacts[0].content)
            } else {
                let output = match (options.output) {
                    case Some(path) => path
                    case None => if (options.command == "render") { "target/doc" }
                        else { Path(options.project).join("target").join("doc").toString() }
                }
                writeOwnedArtifacts(output, artifacts)
                println("generated ${output}")
            }
        }
        publicExitCode(documentation, options.denyWarnings)
    } catch (error: Exception) {
        eprintln("error: ${error.message}")
        eprintln(newUsage())
        2
    }
}
