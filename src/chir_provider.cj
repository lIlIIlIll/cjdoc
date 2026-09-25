package cjdoc

import cjdoc.model as public_model
import cjdoc.provider as public_provider
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*
private func chirManifestUnsupportedReason(manifest: ?String): ?String {
    match (manifest) {
        case None => None
        case Some(text) =>
            for (line in text.split("\n")) {
                let trimmed = line.trimAscii()
                if (trimmed == "[features]" || trimmed.startsWith("[package-configuration") ||
                    trimmed == "[build]") {
                    return Some("CHIR does not support this cjpm manifest section")
                }
                let code = match (trimmed.indexOf("#")) {
                    case Some(index) => trimmed[..index].trimAscii()
                    case None => trimmed
                }
                match (code.indexOf("=")) {
                    case Some(index) =>
                        let key = code[..index].trimAscii()
                        let value = code[index + 1..].trimAscii()
                        if (key == "compile-option" || key == "override-compile-option") {
                            if (!chirCompileOptionValueSupported(value)) {
                                return Some("CHIR rejects unsupported compiler options in cjpm.toml")
                            }
                        }
                    case None => ()
                }
            }
            None
    }
}

private func chirCompileOptionValueSupported(value: String): Bool {
    if (value.isEmpty() || value == "[]" || value == "\"\"" || value == "''") { return true }
    let allowed = ["-O0", "-O1", "-O2", "-O3", "-g", "--static", "--static-libs",
        "CJDOC_STDX_LINK_OPTIONS", "-lstdc++", "-lgcc_s"]
    for (byte in value.toArray()) {
        if (byte == b'\n' || byte == b'\r') { return false }
    }
    if (value.contains("--")) {
        var remaining = value
        while (let Some(index) <- remaining.indexOf("--")) {
            let tail = remaining[index..]
            var end: Int64 = 0
            while (end < tail.size && tail[end] != b' ' && tail[end] != b'\t' &&
                tail[end] != b'\"' && tail[end] != b',' && tail[end] != b']') { end++ }
            let token = tail[..end]
            var known = false
            for (candidate in allowed) { if (token == candidate) { known = true; break } }
            if (!known) { return false }
            if (end >= tail.size) { break }
            remaining = tail[end..]
        }
    }
    true
}

// CHIR remains an enrichment provider. Source declarations and comments remain
// the binding boundary; this factory only returns records for declarations that
// were present in the source view supplied by the public adapter.
internal class AutoChirSemanticProvider <: SemanticProvider {
    private let options: ChirOptions
    private let workerExecutable: ?String

    init(options: ChirOptions, workerExecutable!: ?String = None) {
        this.options = options
        this.workerExecutable = workerExecutable
    }

    public func providerName(): String { "chir" }

    public func providerVersion(): String {
        "1/" + ToolchainIdentity(compilerExecutable: Some(options.compilerExecutable)).compilerVersion
    }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let factory = ChirSemanticProviderFactory(source, options, providerVersion(),
            workerExecutable: workerExecutable)
        try {
            return FactorySemanticProviderAdapter(factory).analyze(source)
        } finally {
            factory.dispose()
        }
    }
}
internal class ChirSemanticProviderFactory <: public_provider.SemanticProviderFactory {
    private let source: SourceSnapshot
    private let options: ChirOptions
    private let workerExecutable: ?String
    private let identityVersion: String
    private let unsupportedManifestReason: ?String
    private let compiled = HashSet<String>()
    private let failed = HashMap<String, String>()
    private let summaries = HashMap<String, ChirWorkerSummary>()
    private let compiling = HashSet<String>()
    private let artifactRoots = HashMap<String, String>()
    private let retainedDirectories = ArrayList<Path>()
    init(source: SourceSnapshot, options: ChirOptions, identityVersion: String,
        workerExecutable!: ?String = None) {
        this.source = source
        this.options = options
        this.workerExecutable = workerExecutable
        this.identityVersion = identityVersion
        this.unsupportedManifestReason = chirManifestUnsupportedReason(source.manifestText)
    }

    public prop name: String { get() { "chir" } }
    public prop version: String { get() { identityVersion } }

    public func open(module: public_provider.SemanticModule): public_provider.SemanticProviderSession {
        ChirSemanticProviderSession(this, module.id)
    }
    func dispose(): Unit {
        for (directory in retainedDirectories) {
            try { let _ = removeIfExists(directory, recursive: true) } catch (_: Exception) {}
        }
    }

    func analyzeModule(moduleId: String,
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): public_provider.SemanticBatch {
        let capabilities = public_model.SemanticCapabilities(true, true, true, false, false)
        let diagnostics = ArrayList<public_model.Diagnostic>()
        if (identityVersion.contains("unknown-cjc")) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2101",
                "CHIR compiler version is unavailable"))
            return public_provider.SemanticBatch(
                public_model.SemanticCapabilities(false, false, false, false, false),
                diagnostics: diagnostics.toArray())
        }
        match (unsupportedManifestReason) {
            case Some(reason) =>
                diagnostics.add(public_model.Diagnostic("warning", "CJDOC2102", reason))
                return public_provider.SemanticBatch(
                    public_model.SemanticCapabilities(false, false, false, false, false),
                    diagnostics: diagnostics.toArray())
            case None => ()
        }
        let packageNames = HashSet<String>()
        for (declaration in declarations) { let _ = packageNames.add(declaration.packageName) }
        var usable = true
        for (packageName in packageNames) {
            let key = moduleId + ":" + packageName
            if (compiled.contains(key)) { continue }
            if (let Some(message) <- failed.get(key)) {
                usable = false
                let code = chirDiagnosticCode(message)
                diagnostics.add(public_model.Diagnostic("warning", code,
                    "CHIR package '" + packageName + "' is unavailable: " +
                    chirDiagnosticDetail(message)))
                continue
            }
            match (compilePackage(moduleId, packageName)) {
                case Some(message) =>
                    failed[key] = message
                    usable = false
                    let code = chirDiagnosticCode(message)
                    diagnostics.add(public_model.Diagnostic("warning", code,
                        "CHIR package '" + packageName + "' is unavailable: " +
                        chirDiagnosticDetail(message)))
                case None =>
                    let _ = compiled.add(key)
            }
        }
        if (!usable) {
            return public_provider.SemanticBatch(
                public_model.SemanticCapabilities(false, false, false, false, false),
                diagnostics: diagnostics.toArray())
        }
        let result = ArrayList<public_provider.SemanticDeclaration>()
        var unmatched: Int64 = 0
        var ambiguous: Int64 = 0
        var notReliablyMapped: Int64 = 0
        for (view in declarations) {
            let key = moduleId + ":" + view.packageName
            let summary = summaries[key]
            let matchState = chirBacksDeclaration(summary, view, declarations)
            let backed = matchState != 0
            if (matchState == 0) { unmatched++ }
            if (matchState == 2) { ambiguous++ }
            if (matchState == 3) { notReliablyMapped++ }
            let semanticState = if (backed) { "partial" } else { "unavailable" }
            let parameters = ArrayList<public_provider.SemanticParameter>()
            if (backed) {
                for (parameter in view.parameters) {
                    parameters.add(public_provider.SemanticParameter(parameter.name,
                        partialChirType(parameter.typeSpelling)))
                }
            }
            let returnType: ?public_model.TypeRef = if (backed) {
                match (view.returnTypeSpelling) {
                    case Some(spelling) => Some(partialChirType(spelling))
                    case None => None
                }
            } else {
                None
            }
            let visibility: ?String = if (backed) { Some(view.visibility) } else { None }
            let ownerId: ?public_provider.SourceDeclarationId = if (backed) {
                view.ownerId
            } else {
                None
            }
            result.add(public_provider.SemanticDeclaration(view.id, semanticState,
                visibility: visibility, ownerId: ownerId,
                parameters: parameters.toArray(), returnType: returnType))
        }
        if (ambiguous > 0) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2105",
                "CHIR could not establish a one-to-one mapping for " + ambiguous.toString() +
                " source declarations"))
        }
        if (unmatched > 0) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2106",
                "CHIR recognized but could not reliably map " + unmatched.toString() +
                " source declarations"))
        }
        if (notReliablyMapped > 0) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2106",
                "CHIR recognized " + notReliablyMapped.toString() +
                " source declarations without a reliable structured mapping"))
        }
        public_provider.SemanticBatch(capabilities, declarations: result.toArray(),
            diagnostics: diagnostics.toArray())
    }

    private func partialChirType(spelling: String): public_model.TypeRef {
        public_model.TypeRef("source", spelling,
            public_model.SemanticType("partial", provider: Some("chir")))
    }

    private func chirBacksDeclaration(summary: ChirWorkerSummary,
        view: public_provider.SourceDeclarationView,
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): Int64 {
        if (view.kind == "class" || view.kind == "interface" ||
            view.kind == "struct" || view.kind == "enum") {
            for (record in summary.typeRecords) {
                if (record.packageName == view.packageName && record.name == view.name) { return 1 }
            }
            return 0
        }
        if (view.kind == "extend") {
            let targetName = sourceBaseTypeName(view.name)
            for (record in summary.extendRecords) {
                if (record.packageName == view.packageName && record.targetName == targetName) {
                    return 1
                }
            }
            return 0
        }
        if (view.kind == "typeAlias" || view.kind == "property") { return 3 }
        if (view.kind == "enumCase") {
            let owner = sourceOwnerIdentity(view, declarations)
            for (record in summary.enumCaseRecords) {
                if (record.packageName == view.packageName && record.ownerName == owner[2] &&
                    record.name == view.name) { return 1 }
            }
            return 0
        }
        if (view.kind == "variable") {
            let owner = sourceOwnerIdentity(view, declarations)
            for (record in summary.memberRecords) {
                if (record.packageName == view.packageName && record.name == view.name &&
                    record.ownerPackageName == owner[1] && record.ownerName == owner[2]) {
                    return 1
                }
            }
            return chirHasFunction(summary, view, owner)
        }
        if (view.kind == "function" || view.kind == "constructor") {
            return chirHasFunction(summary, view, sourceOwnerIdentity(view, declarations))
        }
        0
    }

    private func chirHasFunction(summary: ChirWorkerSummary,
        view: public_provider.SourceDeclarationView, owner: (String, String, String)): Int64 {
        var candidates: Int64 = 0
        var shaped: Int64 = 0
        for (record in summary.functionRecords) {
            if (record.packageName != view.packageName || record.name != view.name) { continue }
            let ownerMatches = if (owner[0] == "none") {
                record.ownerKind == "none"
            } else if (owner[0] == "type") {
                record.ownerKind == "type" && record.ownerPackageName == owner[1] &&
                    record.ownerName == owner[2]
            } else if (owner[0] == "extend") {
                record.ownerKind == "extend" && record.ownerPackageName == owner[1] &&
                    (record.targetName == owner[2] || record.ownerName == owner[2])
            } else {
                false
            }
            if (!ownerMatches) { continue }
            candidates++
            if (record.genericArity == view.genericArity &&
                record.parameterCount == view.parameters.size) {
                shaped++
            }
        }
        if (candidates == 0) { return 0 }
        if (candidates == 1 || shaped == 1) { return 1 }
        2
    }

    private func sourceOwnerIdentity(view: public_provider.SourceDeclarationView,
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): (String, String, String) {
        match (view.ownerId) {
            case Some(ownerId) =>
                for (candidate in declarations) {
                    if (candidate.id != ownerId) { continue }
                    if (candidate.kind == "extend") {
                        return ("extend", candidate.packageName, sourceBaseTypeName(candidate.name))
                    }
                    return ("type", candidate.packageName, candidate.name)
                }
                ("unknown", "", "")
            case None => ("none", "", "")
        }
    }

    private func sourceBaseTypeName(value: String): String {
        match (value.indexOf("<")) {
            case Some(index) => value[..index].trimAscii()
            case None => value.trimAscii()
        }
    }

    private func packageOrigins(moduleId: String, packageName: String): Array<SourceFileOrigin> {
        let result = ArrayList<SourceFileOrigin>()
        for (pkg in source.packages) {
            if (pkg.moduleId != moduleId || pkg.name != packageName) { continue }
            for (logicalPath in pkg.sourceFiles) {
                for (origin in source.sourceFileOrigins) {
                    if (origin.logicalPath == logicalPath) { result.add(origin) }
                }
            }
        }
        sort(result, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
        result.toArray()
    }

    private func moduleDependencyIds(moduleId: String): Array<String> {
        for (module in source.modules) {
            if (module.id == moduleId) {
                let dependencies = ArrayList<String>()
                dependencies.add(all: module.dependencyIds)
                sort(dependencies)
                return dependencies.toArray()
            }
        }
        []
    }

    private func modulePackageNames(moduleId: String): Array<String> {
        let names = ArrayList<String>()
        for (pkg in source.packages) {
            if (pkg.moduleId == moduleId) { names.add(pkg.name) }
        }
        sort(names)
        names.toArray()
    }
    private func packageDependsOn(moduleId: String, packageName: String,
        dependencyName: String): Bool {
        for (origin in source.sourceFileOrigins) {
            if (origin.packageName != packageName) { continue }
            for (importText in origin.imports) {
                let value = importText.trimAscii()
                if (value.contains("import " + dependencyName) ||
                    value.contains(" " + dependencyName + ".")) { return true }
            }
        }
        false
    }

    private func packageDependencies(moduleId: String, packageName: String): Array<String> {
        let names = ArrayList<String>()
        for (pkg in source.packages) {
            if (pkg.moduleId != moduleId || pkg.name == packageName) { continue }
            if (packageDependsOn(moduleId, packageName, pkg.name)) { names.add(pkg.name) }
        }
        sort(names)
        names.toArray()
    }


    private func canonicalChirImportPath(value: String): String {
        let path = Path(value)
        let info = try {
            FileInfo(path)
        } catch (_: Exception) {
            throw IllegalArgumentException("CHIR import path is unavailable")
        }
        if (!info.isDirectory() || info.isSymbolicLink()) {
            throw IllegalArgumentException("CHIR import path must be a regular non-symbolic-link directory")
        }
        try {
            canonicalize(path).toString()
        } catch (_: Exception) {
            throw IllegalArgumentException("CHIR import path cannot be canonicalized")
        }
    }

    private func appendChirImportPath(paths: ArrayList<String>, seen: HashSet<String>,
        value: String): Unit {
        let canonical = canonicalChirImportPath(value)
        if (seen.add(canonical)) { paths.add(canonical) }
    }

    private func dependencyImportPaths(moduleId: String, packageName: String): ArrayList<String> {
        let paths = ArrayList<String>()
        let seen = HashSet<String>()
        for (path in options.importPaths) { appendChirImportPath(paths, seen, path) }
        for (dependency in packageDependencies(moduleId, packageName)) {
            let key = moduleId + ":" + dependency
            if (let Some(path) <- artifactRoots.get(key)) {
                appendChirImportPath(paths, seen, path)
            }
        }
        for (dependencyModuleId in moduleDependencyIds(moduleId)) {
            for (dependencyPackage in modulePackageNames(dependencyModuleId)) {
                let key = dependencyModuleId + ":" + dependencyPackage
                if (let Some(path) <- artifactRoots.get(key)) {
                    appendChirImportPath(paths, seen, path)
                }
            }
        }
        paths
    }

    private func normalizedChirCompiler(): String {
        if (!options.compilerExecutable.contains("/") && !options.compilerExecutable.contains("\\")) {
            return options.compilerExecutable
        }
        try { canonicalize(Path(options.compilerExecutable)).toString() } catch (_: Exception) { options.compilerExecutable }
    }

    private func chirCfgValues(): ArrayList<String> {
        let values = ArrayList<String>()
        for (entry in source.cfgProfile.values) {
            if (entry.name.isEmpty() || entry.value.isEmpty() || entry.name.contains("\n") ||
                entry.name.contains("\r") || entry.value.contains("\n") || entry.value.contains("\r")) {
                throw IllegalArgumentException("CHIR cfg value is not representable")
            }
            values.add(entry.name + "=" + entry.value)
        }
        values
    }

    private func compilePackage(moduleId: String, packageName: String): ?String {
        let key = moduleId + ":" + packageName
        if (compiled.contains(key)) { return None }
        if (let Some(message) <- failed.get(key)) { return Some(message) }
        if (!compiling.add(key)) { return Some("CHIR package dependency cycle") }
        try {
            var moduleName: ?String = None
            for (item in source.modules) {
                if (item.id == moduleId) { moduleName = Some(item.name); break }
            }
            if (moduleName.isNone()) { return Some("source module is missing") }
            for (dependencyModuleId in moduleDependencyIds(moduleId)) {
                for (dependencyPackage in modulePackageNames(dependencyModuleId)) {
                    match (compilePackage(dependencyModuleId, dependencyPackage)) {
                        case Some(message) =>
                            return Some("dependency module '" + dependencyModuleId +
                                ":" + dependencyPackage + "' is unavailable: " + message)
                        case None => ()
                    }
                }
            }
            for (dependency in packageDependencies(moduleId, packageName)) {
                match (compilePackage(moduleId, dependency)) {
                    case Some(message) =>
                        return Some("dependency '" + dependency + "' is unavailable: " + message)
                    case None => ()
                }
            }
            let origins = packageOrigins(moduleId, packageName)
            if (origins.isEmpty()) { return Some("captured source set is empty") }
            let temporary = try {
                Directory.createTemp(getTempDirectory())
            } catch (_: Exception) {
                return Some("private CHIR directory could not be created")
            }
            retainedDirectories.add(temporary)
            let sourcePaths = ArrayList<String>()
            var index: Int64 = 0
            for (origin in origins) {
                let staged = temporary.join("source-${index}.cj")
                File.writeTo(staged, origin.capturedSource.toArray())
                sourcePaths.add(staged.toString())
                index++
            }
            let request = temporary.join("request.txt")
            let response = temporary.join("response.txt")
            let importPaths = dependencyImportPaths(moduleId, packageName)
            let cfgValues = chirCfgValues()
            writeChirWorkerRequest(request, normalizedChirCompiler(), moduleName.getOrThrow(),
                packageName, importPaths, cfgValues, sourcePaths)
            let workerCode = match (workerExecutable) {
                case Some(executable) =>
                    let workerPath = try { canonicalize(Path(executable)).toString() } catch (_: Exception) { executable }
                    let (code, stdout, stderr) = executeWithBoundedOutput(workerPath,
                        ["--internal-chir-analyze", request.toString(), response.toString()],
                        workingDirectory: Some(temporary))
                    if (code != 0) {
                        return Some("CHIR worker failed: " + boundedChirCompilerOutput(stdout, stderr))
                    }
                    code
                case None => runChirAnalyzeWorker(request.toString(), response.toString())
            }
            if (workerCode != 0) { return Some("CHIR worker could not be started") }
            let summary = readChirWorkerResponse(response)
            if (summary.functionCount < 0 || summary.typeCount < 0 || summary.extendCount < 0) {
                return Some("CHIR worker returned invalid declaration counts")
            }
            summaries[key] = summary
            artifactRoots[key] = temporary.join("chir-out").toString()
            let _ = compiled.add(key)
            None
        } catch (error: Exception) {
            let message = error.message
            if (message.startsWith("CJDOC2101:") || message.startsWith("CJDOC2102:") ||
                message.startsWith("CJDOC2103:") || message.startsWith("CJDOC2104:")) {
                Some(message)
            } else {
                Some("CHIR compilation raised an exception: ${message}")
            }
        } finally {
            let _ = compiling.remove(key)
        }
    }

}

internal class ChirSemanticProviderSession <: public_provider.SemanticProviderSession {
    private let factory: ChirSemanticProviderFactory
    private let moduleId: String
    private var closed = false

    init(factory: ChirSemanticProviderFactory, moduleId: String) {
        this.factory = factory
        this.moduleId = moduleId
    }

    public func analyze(declarations: ReadOnlyList<public_provider.SourceDeclarationView>): public_provider.SemanticBatch {
        if (closed) { throw IllegalStateException("CHIR provider session is already closed") }
        factory.analyzeModule(moduleId, declarations)
    }

    public func close(): Unit {
        if (closed) { return }
        closed = true
    }
}

private func boundedChirCompilerOutput(stdout: Array<Byte>, stderr: Array<Byte>): String {
    let out = try { String.fromUtf8(stdout).trimAscii() } catch (_: Exception) { "" }
    let err = try { String.fromUtf8(stderr).trimAscii() } catch (_: Exception) { "" }
    let combined = if (out.isEmpty()) { err } else if (err.isEmpty()) { out } else { out + "\\n" + err }
    let bytes = combined.toArray()
    if (bytes.size <= 8192) { return combined }
    String.fromUtf8(bytes[..8192]) + "\\n... CHIR compiler output truncated"
}

private func chirDiagnosticCode(message: String): String {
    if (message.startsWith("CJDOC2101:")) { return "CJDOC2101" }
    if (message.startsWith("CJDOC2102:")) { return "CJDOC2102" }
    if (message.startsWith("CJDOC2103:")) { return "CJDOC2103" }
    if (message.startsWith("CJDOC2104:")) { return "CJDOC2104" }
    if (message.contains("compiler executable") || message.contains("No such file") ||
        message.contains("not found") || message.contains("could not be started")) {
        return "CJDOC2101"
    }
    if (message.contains("dependency") || message.contains("source module") ||
        message.contains("import path") || message.contains("cfg")) {
        return "CJDOC2102"
    }
    "CJDOC2104"
}

private func chirDiagnosticDetail(message: String): String {
    let prefixes = ["CJDOC2101:", "CJDOC2102:", "CJDOC2103:", "CJDOC2104:"]
    for (prefix in prefixes) {
        if (message.startsWith(prefix)) { return message[prefix.size..].trimAscii() }
    }
    message
}
