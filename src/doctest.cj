package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.core.*
import std.fs.*
import std.io.*
import std.process.*
import std.time.*
import std.unicode.*

internal let DOCTEST_SCHEMA_VERSION = "cjdoc.doctest/1"
internal let DOCTEST_MAX_RESULTS: Int64 = 100000
internal let DOCTEST_MAX_OUTPUT_BYTES: Int64 = 8 * 1024 * 1024
internal let DOCTEST_PIPE_CHUNK_BYTES: Int64 = 64 * 1024

internal class DoctestSnippet {
    public let id: String
    public let symbolId: String
    public let packageName: String
    public let qualifiedName: String
    public let title: String
    public let language: String
    public let code: String

    init(id: String, symbolId: String, packageName: String, qualifiedName: String, title: String,
        language: String, code: String) {
        this.id = id
        this.symbolId = symbolId
        this.packageName = packageName
        this.qualifiedName = qualifiedName
        this.title = title
        this.language = language
        this.code = code
    }
}

internal class DoctestCaseResult {
    public let id: String
    public let symbolId: String
    public let qualifiedName: String
    public let title: String
    public let language: String
    public let status: String
    public let exitCode: ?Int64
    public let durationMs: Int64
    public let stdout: String
    public let stderr: String
    public let message: String

    init(snippet: DoctestSnippet, status: String, exitCode!: ?Int64 = None,
        durationMs!: Int64 = 0, stdout!: String = "", stderr!: String = "",
        message!: String = "") {
        this.id = snippet.id
        this.symbolId = snippet.symbolId
        this.qualifiedName = snippet.qualifiedName
        this.title = snippet.title
        this.language = snippet.language
        this.status = status
        this.exitCode = exitCode
        this.durationMs = durationMs
        this.stdout = stdout
        this.stderr = stderr
        this.message = message
    }
}

internal class DoctestReport {
    public let mode: String
    public let timeoutMs: Int64
    public let memoryMb: Int64
    public let jobs: Int64
    private let resultsStorage: ArrayList<DoctestCaseResult>

    init(config: DoctestConfig, results: Array<DoctestCaseResult>) {
        this.mode = config.mode
        this.timeoutMs = config.timeoutMs
        this.memoryMb = config.memoryMb
        this.jobs = config.jobs
        this.resultsStorage = ArrayList<DoctestCaseResult>(results)
    }

    public prop results: ReadOnlyList<DoctestCaseResult> { get() { resultsStorage } }
}

private class DoctestFence {
    public let marker: Byte
    public let length: Int64
    public let language: String

    init(marker: Byte, length: Int64, language: String) {
        this.marker = marker
        this.length = length
        this.language = language
    }
}

private class DoctestProcessResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let outputLimit: Bool

    init(exitCode: Int64, stdout: String, stderr: String, timedOut: Bool,
        outputLimit: Bool) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
        this.outputLimit = outputLimit
    }
}
private class DoctestPackageContext {
    public let packageName: String
    public let moduleId: String
    public let dependencyIds: Array<String>
    public let artifactRoot: Path

    init(packageName: String, moduleId: String, dependencyIds: Array<String>, artifactRoot: Path) {
        this.packageName = packageName
        this.moduleId = moduleId
        this.dependencyIds = dependencyIds
        this.artifactRoot = artifactRoot
    }
}

private class DoctestProjectContext {
    private let packagesStorage: ArrayList<DoctestPackageContext>

    init(packages: Array<DoctestPackageContext>) {
        this.packagesStorage = ArrayList<DoctestPackageContext>(packages)
    }

    func packageFor(name: String): ?DoctestPackageContext {
        for (packageContext in packagesStorage) {
            if (packageContext.packageName == name) { return Some(packageContext) }
        }
        None
    }

    func appendLibraryPaths(arguments: ArrayList<String>): Unit {
        for (packageContext in packagesStorage) {
            arguments.add("--import-path")
            arguments.add(packageContext.artifactRoot.toString())
            arguments.add("--library-path")
            arguments.add(packageContext.artifactRoot.toString())
        }
    }

    private func appendModuleLibraries(moduleId: String, visited: HashSet<String>,
        arguments: ArrayList<String>): Unit {
        if (!visited.add(moduleId)) { return }
        var moduleContext: ?DoctestPackageContext = None
        for (packageContext in packagesStorage) {
            if (packageContext.moduleId == moduleId) {
                moduleContext = Some(packageContext)
                break
            }
        }
        match (moduleContext) {
            case None => return
            case Some(packageContext) =>
                for (dependencyId in packageContext.dependencyIds) {
                    appendModuleLibraries(dependencyId, visited, arguments)
                }
        }
        for (packageContext in packagesStorage where packageContext.moduleId == moduleId) {
            arguments.add("--library")
            arguments.add(packageContext.packageName)
        }
    }
    func appendLibraries(arguments: ArrayList<String>, selected: DoctestPackageContext): Unit {
        // Static linkers resolve references from left to right: the selected
        // package must precede every library it calls.
        arguments.add("--library")
        arguments.add(selected.packageName)
        let visited = HashSet<String>()
        let _ = visited.add(selected.moduleId)
        // Packages in one module can still import one another; compilation
        // order is dependency-aware, so preserve it for static linking too.
        for (packageContext in packagesStorage where packageContext.moduleId == selected.moduleId &&
            packageContext.packageName != selected.packageName) {
            arguments.add("--library")
            arguments.add(packageContext.packageName)
        }
        for (dependencyId in selected.dependencyIds) {
            appendModuleLibraries(dependencyId, visited, arguments)
        }
    }
}


private func readProcessPipe(stream: InputStream, maxBytes: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(DOCTEST_PIPE_CHUNK_BYTES, repeat: 0)
    var total: Int64 = 0
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) { break }
        if (count > buffer.size || count > maxBytes - total) {
            throw IllegalArgumentException("doctest process output exceeds the configured limit")
        }
        for (index in 0..count) { output.add(buffer[index]) }
        total += count
    }
    output.toArray()
}

private func processText(bytes: Array<Byte>): String {
    try { String.fromUtf8(bytes) } catch (_: Exception) { "<non-UTF-8 output>" }
}

private func runBoundedProcess(command: String, arguments: Array<String>, workingDirectory: Path,
    timeoutMs: Int64, maxOutputBytes: Int64): DoctestProcessResult {
    let process = launch(command, arguments, workingDirectory: Some(workingDirectory),
        stdOut: Pipe, stdErr: Pipe)
    let stdoutFuture: Future<Array<Byte>> = spawn {
        readProcessPipe(process.stdOutPipe, maxOutputBytes)
    }
    let stderrFuture: Future<Array<Byte>> = spawn {
        readProcessPipe(process.stdErrPipe, maxOutputBytes)
    }
    var timedOut = false
    var outputLimit = false
    var exitCode: Int64 = -1
    try {
        exitCode = process.wait(timeout: Some(Duration.millisecond * timeoutMs))
    } catch (_: Exception) {
        timedOut = true
        process.terminate(force: true)
        try { let _ = process.wait() } catch (_: Exception) { () }
    }
    var stdout = Array<Byte>()
    var stderr = Array<Byte>()
    try { stdout = stdoutFuture.get(Duration.millisecond * timeoutMs) } catch (_: Exception) {
        outputLimit = true
        stdoutFuture.cancel()
    }
    try { stderr = stderrFuture.get(Duration.millisecond * timeoutMs) } catch (_: Exception) {
        outputLimit = true
        stderrFuture.cancel()
    }
    DoctestProcessResult(exitCode, processText(stdout), processText(stderr), timedOut, outputLimit)
}

private func leadingSpaces(line: String): Int64 {
    var count: Int64 = 0
    while (count < line.size && line[count] == b' ') { count++ }
    count
}

private func fenceOpening(line: String): ?DoctestFence {
    let spaces = leadingSpaces(line)
    if (spaces > 3 || spaces >= line.size) { return None }
    let marker = line[spaces]
    if (marker != b'`' && marker != b'~') { return None }
    var length: Int64 = 0
    while (spaces + length < line.size && line[spaces + length] == marker) { length++ }
    if (length < 3) { return None }
    let info = line[spaces + length..].trimAscii()
    if (info.isEmpty() || info.contains("`") || info.contains("~")) { return None }
    let language = info.split(" ")[0].toLower()
    if (language != "cj" && language != "cangjie") {
        return None
    }
    // cangjie is an accepted Markdown alias, but cj is the frozen
    // doctest-results wire value. Keep the parser permissive and the output
    // canonical so every emitted result validates against the schema.
    Some(DoctestFence(marker, length, "cj"))
}

private func fenceClosing(line: String, fence: DoctestFence): Bool {
    let spaces = leadingSpaces(line)
    if (spaces > 3 || spaces >= line.size) { return false }
    var length: Int64 = 0
    while (spaces + length < line.size && line[spaces + length] == fence.marker) { length++ }
    length >= fence.length && line[spaces + length..].trimAscii().isEmpty()
}

private func snippetCode(lines: ArrayList<String>): String {
    let out = StringBuilder()
    for (line in lines) {
        if (out.toString().size > 0) { out.append("\n") }
        out.append(line)
    }
    out.toString()
}

private func extractSnippets(symbol: public_model.SymbolDoc, tag: public_model.DocTag, exampleIndex: Int64): Array<DoctestSnippet> {
    let snippets = ArrayList<DoctestSnippet>()
    var fence: ?DoctestFence = None
    let body = ArrayList<String>()
    var blockIndex: Int64 = 0
    for (line in tag.description.split("\n")) {
        match (fence) {
            case Some(active) =>
                if (fenceClosing(line, active)) {
                    let code = snippetCode(body)
                    snippets.add(DoctestSnippet(
                        symbol.id + ":example:" + exampleIndex.toString() + ":" + blockIndex.toString(),
                        symbol.id, symbol.packageName, symbol.qualifiedName, tag.subject, active.language, code))
                    blockIndex++
                    body.clear()
                    fence = None
                } else {
                    body.add(line)
                }
            case None =>
                match (fenceOpening(line)) {
                    case Some(opening) => fence = Some(opening)
                    case None => ()
                }
        }
    }
    match (fence) {
        case Some(active) =>
            let code = snippetCode(body)
            snippets.add(DoctestSnippet(
                symbol.id + ":example:" + exampleIndex.toString() + ":" + blockIndex.toString(),
                symbol.id, symbol.packageName, symbol.qualifiedName, tag.subject, active.language, code))
        case None => ()
    }
    snippets.toArray()
}

private func collectSnippets(documentation: public_model.DocumentationSet): Array<DoctestSnippet> {
    let snippets = ArrayList<DoctestSnippet>()
    for (symbol in documentation.declarations) {
        match (symbol.documentation) {
            case Some(comment) =>
                var exampleIndex: Int64 = 0
                for (tag in comment.tags) {
                    if (tag.name != "example") { continue }
                    let found = extractSnippets(symbol, tag, exampleIndex)
                    if (found.isEmpty()) {
                        snippets.add(DoctestSnippet(
                            symbol.id + ":example:" + exampleIndex.toString() + ":skipped",
                            symbol.id, symbol.packageName, symbol.qualifiedName, tag.subject, "cj", ""))
                    } else {
                        snippets.add(all: found)
                    }
                    if (snippets.size > DOCTEST_MAX_RESULTS) {
                        throw IllegalArgumentException("doctest result limit exceeded")
                    }
                }
            case None => ()
        }
    }
    snippets.toArray()
}

private func containsDoctestEntryPoint(code: String): Bool {
    for (line in code.split("\n")) {
        let candidate = line.trimAscii()
        if (candidate.startsWith("main(") || candidate.startsWith("func main(") ||
            candidate.startsWith("public func main(") || candidate.startsWith("private func main(")) {
            return true
        }
    }
    false
}

private func doctestProgram(code: String, projectPackageName!: ?String = None): String {
    let trimmed = code.trimAscii()
    if (trimmed.startsWith("package ") || containsDoctestEntryPoint(trimmed)) {
        trimmed + "\n"
    } else {
        var body = trimmed
        let imports = StringBuilder()
        while (body.startsWith("import ")) {
            let end = match (body.indexOf("\n")) {
                case Some(index) => index
                case None => body.size
            }
            imports.append(body[..end])
            imports.append("\n")
            body = if (end < body.size) { body[end + 1..].trimAscii() } else { "" }
        }
        let projectImport = match (projectPackageName) {
            case Some(name) => "import " + name + ".*\n\n"
            case None => ""
        }
        "package cjdoc_doctest\n" + projectImport + imports.toString() +
            "\nmain() {\n" + body + "\n}\n"
    }
}

private func skippedResult(snippet: DoctestSnippet, message: String): DoctestCaseResult {
    DoctestCaseResult(snippet, "skipped", message: message)
}

private func memoryBoundedCommand(command: String, arguments: Array<String>, memoryMb: Int64): (String, Array<String>) {
    let limit = memoryMb * 1024 * 1024
    for (candidate in ["/usr/bin/prlimit", "/bin/prlimit"]) {
        if (!exists(Path(candidate))) { continue }
        let wrapped = ArrayList<String>()
        wrapped.add("--as=" + limit.toString())
        wrapped.add("--")
        wrapped.add(command)
        wrapped.add(all: arguments)
        return (candidate, wrapped.toArray())
    }
    // Running without an enforceable bound is not a safe fallback. In
    // particular, macOS and Windows do not provide Linux's prlimit paths;
    // report the unavailable limiter and let the command fail closed instead
    // of executing unbounded user code.
    throw IllegalStateException("doctest memory limit is unavailable on this platform")
}
private func doctestOriginForLogicalPath(origins: Array<SourceFileOrigin>, logicalPath: String): ?SourceFileOrigin {
    var found: ?SourceFileOrigin = None
    for (origin in origins where origin.logicalPath == logicalPath) {
        if (found.isSome()) { return None }
        found = Some(origin)
    }
    found
}

private func discoveredPackageSourceRoot(module: public_model.ModuleDoc,
    packageDoc: public_model.PackageDoc, origins: Array<SourceFileOrigin>): ?String {
    if (packageDoc.sourceFiles.isEmpty()) { return None }
    var actualRoot: ?String = None
    var packageRoot: ?String = None
    for (logicalPath in packageDoc.sourceFiles) {
        let origin = match (doctestOriginForLogicalPath(origins, logicalPath)) {
            case Some(value) => value
            case None => return None
        }
        if (origin.logicalPrefix != module.sourcePrefix ||
            !hostPathIsWithin(origin.actualRoot, origin.actualPath)) { return None }
        let relative = match (relativePathFromResolved(origin.actualRoot, origin.actualPath)) {
            case Some(value) => value
            case None => return None
        }
        let expected = if (module.sourcePrefix.isEmpty()) { relative }
            else { module.sourcePrefix + "/" + relative }
        if (expected != logicalPath) { return None }
        match (actualRoot) {
            case Some(value) => if (value != origin.actualRoot) { return None }
            case None => actualRoot = Some(origin.actualRoot)
        }
        let candidate = try {
            canonicalize(Path(origin.actualPath).parent.toString()).toString()
        } catch (_: Exception) { return None }
        match (packageRoot) {
            case None => packageRoot = Some(candidate)
            case Some(value) =>
                var common = value
                if (hostPathIsWithin(common, candidate)) {
                    ()
                } else if (hostPathIsWithin(candidate, common)) {
                    common = candidate
                } else {
                    var found = false
                    while (true) {
                        let parent = Path(common).parent.normalize().toString()
                        if (parent == common) { break }
                        common = parent
                        if (hostPathIsWithin(common, candidate)) {
                            found = true
                            break
                        }
                    }
                    if (!found) { return None }
                }
                packageRoot = Some(common)
        }
    }
    packageRoot
}

private func packageSourceRoot(documentation: public_model.DocumentationSet,
    packageDoc: public_model.PackageDoc, projectRoot: Path,
    sourceOrigins: Array<SourceFileOrigin>): Path {
    var module: ?public_model.ModuleDoc = None
    for (candidate in documentation.modules) {
        if (candidate.id == packageDoc.moduleId) { module = Some(candidate); break }
    }
    let resolvedModule = match (module) {
        case Some(value) => value
        case None => throw IllegalStateException("doctest package module is unavailable")
    }
    if (!sourceOrigins.isEmpty()) {
        let discovered = match (discoveredPackageSourceRoot(resolvedModule, packageDoc, sourceOrigins)) {
            case Some(value) => value
            case None => throw IllegalStateException(
                "doctest package root is unavailable from source discovery: " + packageDoc.name)
        }
        return try { Path(canonicalize(discovered).toString()) } catch (_: Exception) {
            throw IllegalStateException("doctest package root is unavailable")
        }
    }
    let modulePath = if (resolvedModule.sourcePrefix.isEmpty()) {
        projectRoot
    } else {
        projectRoot.join(resolvedModule.sourcePrefix)
    }
    let moduleRoot = try {
        canonicalize(modulePath.toString()).toString()
    } catch (_: Exception) {
        throw IllegalStateException("doctest package root is unavailable")
    }
    let manifest = try {
        readTextBounded(Path(moduleRoot).join("cjpm.toml"), 256 * 1024)
    } catch (_: Exception) { "" }
    let packageView = parseCjpmPackageNameChecked(manifest)
    match (resolvedPackageSourceRoot(moduleRoot, packageView.sourceDirectory)) {
        case Some(sourceRoot) => Path(sourceRoot)
        case None => throw IllegalStateException(
            "doctest package source directory is unavailable: " + packageDoc.name)
    }
}

private func orderedDoctestModules(documentation: public_model.DocumentationSet): Array<public_model.ModuleDoc> {
    let ordered = ArrayList<public_model.ModuleDoc>()
    let compiled = HashSet<String>()
    while (ordered.size < documentation.modules.size) {
        var progressed = false
        for (module in documentation.modules where !compiled.contains(module.id)) {
            var ready = true
            for (dependencyId in module.dependencyIds) {
                var known = false
                for (candidate in documentation.modules) {
                    if (candidate.id == dependencyId) { known = true; break }
                }
                if (known && !compiled.contains(dependencyId)) { ready = false; break }
            }
            if (!ready) { continue }
            ordered.add(module)
            let _ = compiled.add(module.id)
            progressed = true
        }
        if (!progressed) {
            throw IllegalStateException("doctest module dependency graph contains a cycle")
        }
    }
    ordered.toArray()
}

private func compileProjectPackage(packageDoc: public_model.PackageDoc,
    module: public_model.ModuleDoc, sourceRoot: Path, config: DoctestConfig,
    workRoot: Path, cfgValues: Array<CfgValue>, packageIndex: Int64,
    previousPackages: ArrayList<DoctestPackageContext>): DoctestPackageContext {
    let artifactRoot = workRoot.join("project-" + packageIndex.toString())
    Directory.create(artifactRoot, recursive: true)
    let arguments = ArrayList<String>()
    arguments.add("-p")
    arguments.add(sourceRoot.toString())
    for (packageContext in previousPackages) {
        arguments.add("--import-path")
        arguments.add(packageContext.artifactRoot.toString())
        arguments.add("--library-path")
        arguments.add(packageContext.artifactRoot.toString())
    }
    arguments.add("--output-type")
    arguments.add("staticlib")
    arguments.add("--output-dir")
    arguments.add(artifactRoot.toString())
    for (cfg in cfgValues) {
        arguments.add("--cfg")
        arguments.add(cfg.name + "=" + cfg.value)
    }
    let (command, boundedArguments) = memoryBoundedCommand("cjc", arguments.toArray(), config.memoryMb)
    let result = runBoundedProcess(command, boundedArguments, sourceRoot, config.timeoutMs,
        DOCTEST_MAX_OUTPUT_BYTES)
    if (result.timedOut) {
        throw IllegalStateException("doctest project package compilation timed out")
    }
    if (result.outputLimit) {
        throw IllegalStateException("doctest project package compilation exceeded the output limit")
    }
    if (result.exitCode != 0) {
        throw IllegalStateException("doctest project package compilation failed: " + result.stderr)
    }
    DoctestPackageContext(packageDoc.name, module.id, module.dependencyIds.toArray(), artifactRoot)
}

private func compileModulePackages(documentation: public_model.DocumentationSet,
    module: public_model.ModuleDoc, projectRoot: Path, sourceOrigins: Array<SourceFileOrigin>,
    config: DoctestConfig, workRoot: Path, cfgValues: Array<CfgValue>,
    packages: ArrayList<DoctestPackageContext>, packageIndex: Int64): Int64 {
    var nextPackageIndex = packageIndex
    let pending = ArrayList<public_model.PackageDoc>()
    for (packageDoc in documentation.packages where packageDoc.moduleId == module.id) {
        pending.add(packageDoc)
    }
    while (!pending.isEmpty()) {
        let deferred = ArrayList<public_model.PackageDoc>()
        var compiledAny = false
        var firstFailure: ?String = None
        for (packageDoc in pending) {
            try {
                let sourceRoot = packageSourceRoot(documentation, packageDoc, projectRoot, sourceOrigins)
                let attemptIndex = nextPackageIndex
                nextPackageIndex++
                let packageContext = compileProjectPackage(packageDoc, module, sourceRoot, config,
                    workRoot, cfgValues, attemptIndex, packages)
                packages.add(packageContext)
                compiledAny = true
            } catch (error: Exception) {
                deferred.add(packageDoc)
                if (firstFailure.isNone()) { firstFailure = Some(error.message) }
            }
        }
        if (!compiledAny) {
            let message = match (firstFailure) {
                case Some(value) => value
                case None => "doctest package compilation made no progress"
            }
            throw IllegalStateException(message)
        }
        pending.clear()
        pending.add(all: deferred.toArray())
    }
    nextPackageIndex
}

private func prepareProjectContext(documentation: public_model.DocumentationSet,
    projectRoot: Path, sourceOrigins: Array<SourceFileOrigin>, config: DoctestConfig,
    workRoot: Path, cfgValues: Array<CfgValue>): ?DoctestProjectContext {
    if (documentation.packages.isEmpty()) { return None }
    let packages = ArrayList<DoctestPackageContext>()
    var packageIndex: Int64 = 0
    for (module in orderedDoctestModules(documentation)) {
        packageIndex = compileModulePackages(documentation, module, projectRoot, sourceOrigins,
            config, workRoot, cfgValues, packages, packageIndex)
    }
    Some(DoctestProjectContext(packages.toArray()))
}


private func executeSnippet(snippet: DoctestSnippet, config: DoctestConfig,
    workRoot: Path, index: Int64, projectContext: ?DoctestProjectContext): DoctestCaseResult {
    if (snippet.code.trimAscii().isEmpty()) {
        return skippedResult(snippet, "no executable Cangjie fence")
    }
    let caseRoot = workRoot.join("case-" + index.toString())
    Directory.create(caseRoot, recursive: true)
    let source = caseRoot.join("example.cj")
    let executable = caseRoot.join("example")
    let selectedPackage = match (projectContext) {
        case Some(context) =>
            match (context.packageFor(snippet.packageName)) {
                case Some(value) => Some(value)
                case None => return DoctestCaseResult(snippet, "failed",
                    message: "documented package context is unavailable")
            }
        case None => None<DoctestPackageContext>
    }
    let projectPackageName = match (selectedPackage) {
        case Some(packageContext) => Some(packageContext.packageName)
        case None => None<String>
    }
    File.writeTo(source, doctestProgram(snippet.code,
        projectPackageName: projectPackageName).toArray())
    let compileArguments = ArrayList<String>()
    compileArguments.add(source.toString())
    compileArguments.add("-o")
    compileArguments.add(executable.toString())
    compileArguments.add("--static")
    match ((projectContext, selectedPackage)) {
        case (Some(context), Some(packageContext)) =>
            context.appendLibraryPaths(compileArguments)
            context.appendLibraries(compileArguments, packageContext)
        case _ => ()
    }
    let (compileCommand, boundedCompileArguments) = memoryBoundedCommand(
        "cjc", compileArguments.toArray(), config.memoryMb)
    let started = MonoTime.now()
    let compile = try {
        runBoundedProcess(compileCommand, boundedCompileArguments, caseRoot,
            config.timeoutMs, DOCTEST_MAX_OUTPUT_BYTES)
    } catch (_: Exception) {
        return DoctestCaseResult(snippet, "failed", message: "compiler unavailable")
    }
    let compileMs = (MonoTime.now() - started).toMilliseconds()
    if (compile.timedOut) {
        return DoctestCaseResult(snippet, "timeout", durationMs: compileMs,
            stdout: compile.stdout, stderr: compile.stderr, message: "compile timed out")
    }
    if (compile.outputLimit) {
        return DoctestCaseResult(snippet, "failed", durationMs: compileMs,
            stdout: compile.stdout, stderr: compile.stderr,
            message: "compile output exceeded the limit")
    }
    if (compile.exitCode != 0) {
        return DoctestCaseResult(snippet, "failed", exitCode: Some(compile.exitCode),
            durationMs: compileMs, stdout: compile.stdout, stderr: compile.stderr,
            message: "compile failed")
    }
    let (runtimeCommand, runtimeArguments) = memoryBoundedCommand(
        executable.toString(), [], config.memoryMb)
    let run = try {
        runBoundedProcess(runtimeCommand, runtimeArguments, caseRoot, config.timeoutMs,
            DOCTEST_MAX_OUTPUT_BYTES)
    } catch (_: Exception) {
        return DoctestCaseResult(snippet, "failed", message: "runtime unavailable")
    }
    let durationMs = (MonoTime.now() - started).toMilliseconds()
    if (run.timedOut) {
        return DoctestCaseResult(snippet, "timeout", durationMs: durationMs,
            stdout: run.stdout, stderr: run.stderr, message: "execution timed out")
    }
    if (run.outputLimit) {
        return DoctestCaseResult(snippet, "failed", durationMs: durationMs,
            stdout: run.stdout, stderr: run.stderr, message: "execution output exceeded the limit")
    }
    let status = if (run.exitCode == 0) { "passed" } else { "failed" }
    let message = if (status == "passed") { "" } else { "execution failed" }
    DoctestCaseResult(snippet, status, exitCode: Some(run.exitCode), durationMs: durationMs,
        stdout: run.stdout, stderr: run.stderr, message: message)
}

private func runSnippetBatch(snippets: Array<DoctestSnippet>, config: DoctestConfig,
    workRoot: Path, projectContext: ?DoctestProjectContext): Array<DoctestCaseResult> {
    let results = ArrayList<DoctestCaseResult>()
    var index: Int64 = 0
    while (index < snippets.size) {
        let futures = ArrayList<Future<DoctestCaseResult>>()
        var offset: Int64 = 0
        while (offset < config.jobs && index + offset < snippets.size) {
            let snippet = snippets[index + offset]
            let caseIndex = index + offset
            futures.add(spawn { executeSnippet(snippet, config, workRoot, caseIndex, projectContext) })
            offset++
        }
        for (future in futures) {
            results.add(future.get())
        }
        index += offset
    }
    results.toArray()
}
internal func runDoctests(documentation: public_model.DocumentationSet, config: DoctestConfig,
    outputRoot: Path, projectRoot!: Path = Path("."),
    sourceOrigins!: Array<SourceFileOrigin> = [],
    cfgValues!: Array<CfgValue> = []): DoctestReport {
    let snippets = collectSnippets(documentation)
    if (!exists(outputRoot)) { Directory.create(outputRoot, recursive: true) }
    let workRoot = Directory.createTemp(outputRoot)
    try {
        let projectContext = if (snippets.isEmpty()) {
            None<DoctestProjectContext>
        } else {
            prepareProjectContext(documentation, projectRoot, sourceOrigins, config, workRoot, cfgValues)
        }
        let results = runSnippetBatch(snippets, config, workRoot, projectContext)
        return DoctestReport(config, results)
    } finally {
        let _ = removeIfExists(workRoot, recursive: true)
    }
}

private func appendJsonString(out: StringBuilder, value: String): Unit {
    out.append(public_render.escapeJsonString(value))
}

private func appendOptionalInt(out: StringBuilder, value: ?Int64): Unit {
    match (value) {
        case Some(number) => out.append(number.toString())
        case None => out.append("null")
    }
}

private func appendDoctestResult(out: StringBuilder, result: DoctestCaseResult): Unit {
    out.append("{\"id\":"); appendJsonString(out, result.id)
    out.append(",\"symbolId\":"); appendJsonString(out, result.symbolId)
    out.append(",\"qualifiedName\":"); appendJsonString(out, result.qualifiedName)
    out.append(",\"title\":"); appendJsonString(out, result.title)
    out.append(",\"language\":"); appendJsonString(out, result.language)
    out.append(",\"status\":"); appendJsonString(out, result.status)
    out.append(",\"exitCode\":"); appendOptionalInt(out, result.exitCode)
    out.append(",\"durationMs\":"); out.append(result.durationMs.toString())
    out.append(",\"stdout\":"); appendJsonString(out, result.stdout)
    out.append(",\"stderr\":"); appendJsonString(out, result.stderr)
    out.append(",\"message\":"); appendJsonString(out, result.message)
    out.append("}")
}

internal func encodeDoctestReport(report: DoctestReport): String {
    var passed: Int64 = 0
    var failed: Int64 = 0
    var timedOut: Int64 = 0
    var skipped: Int64 = 0
    for (result in report.results) {
        match (result.status) {
            case "passed" => passed++
            case "failed" => failed++
            case "timeout" => timedOut++
            case _ => skipped++
        }
    }
    let out = StringBuilder()
    out.append("{\"schemaVersion\":"); appendJsonString(out, DOCTEST_SCHEMA_VERSION)
    out.append(",\"mode\":"); appendJsonString(out, report.mode)
    out.append(",\"timeoutMs\":"); out.append(report.timeoutMs.toString())
    out.append(",\"memoryMb\":"); out.append(report.memoryMb.toString())
    out.append(",\"jobs\":"); out.append(report.jobs.toString())
    out.append(",\"summary\":{\"passed\":"); out.append(passed.toString())
    out.append(",\"failed\":"); out.append(failed.toString())
    out.append(",\"timedOut\":"); out.append(timedOut.toString())
    out.append(",\"skipped\":"); out.append(skipped.toString())
    out.append("},\"results\":[")
    var first = true
    for (result in report.results) {
        if (!first) { out.append(",") }
        first = false
        appendDoctestResult(out, result)
    }
    out.append("]}\n")
    out.toString()
}

internal func doctestReportHasFailure(report: DoctestReport): Bool {
    for (result in report.results) {
        if (result.status == "failed" || result.status == "timeout") { return true }
    }
    false
}

internal func doctestReportSummary(report: DoctestReport): String {
    var passed: Int64 = 0
    var failed: Int64 = 0
    var timedOut: Int64 = 0
    var skipped: Int64 = 0
    for (result in report.results) {
        match (result.status) {
            case "passed" => passed++
            case "failed" => failed++
            case "timeout" => timedOut++
            case _ => skipped++
        }
    }
    "doctest: passed=" + passed.toString() + ", failed=" + failed.toString() +
        ", timed-out=" + timedOut.toString() + ", skipped=" + skipped.toString()
}
