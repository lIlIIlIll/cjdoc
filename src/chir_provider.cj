package cjdoc

import cjdoc.model as public_model
import cjdoc.provider as public_provider
import cjdoc_chir_protocol.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*

// CHIR remains an enrichment provider. Source declarations and comments remain
// the binding boundary; this factory only returns records for declarations that
// were present in the source view supplied by the public adapter.
internal class AutoChirSemanticProvider <: SemanticProvider {
    private let options: ChirOptions

    init(options: ChirOptions) {
        this.options = options
    }

    public func providerName(): String { "chir" }

    public func providerVersion(): String {
        "1/" + ToolchainIdentity(compilerExecutable: Some(options.compilerExecutable)).compilerVersion
    }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let factory = ChirSemanticProviderFactory(source, options, providerVersion())
        try {
            return FactorySemanticProviderAdapter(factory).analyze(source)
        } finally {
            factory.dispose()
        }
    }
}
private func chirSourceTypeIdentity(value: String): (String, String) {
    let base = match (value.indexOf("<")) {
        case Some(index) => value[..index].trimAscii()
        case None => value.trimAscii()
    }
    let components = base.split(".")
    if (components.isEmpty()) { return ("", base) }
    let targetName = components[components.size - 1].trimAscii()
    if (components.size == 1) { return ("", targetName) }
    var targetPackageName = components[0].trimAscii()
    var index: Int64 = 1
    while (index < components.size - 1) {
        targetPackageName += "." + components[index].trimAscii()
        index++
    }
    (targetPackageName, targetName)
}

internal func chirExtensionTargetMatch(summary: ChirWorkerSummary,
    extensionPackage: String, sourceName: String): (Int64, String) {
    let sourceIdentity = chirSourceTypeIdentity(sourceName)
    let sourceTargetPackage = sourceIdentity[0]
    let targetName = sourceIdentity[1]
    var targetPackageName = ""
    var candidateCount: Int64 = 0
    var hasMultipleTargetPackages = false
    var exactPackageMatch = false
    for (record in summary.extendRecords) {
        if (record.packageName != extensionPackage || record.targetName != targetName) { continue }
        if (candidateCount == 0) {
            targetPackageName = record.targetPackageName
        } else if (targetPackageName != record.targetPackageName) {
            hasMultipleTargetPackages = true
        }
        candidateCount++
        if (!sourceTargetPackage.isEmpty() && record.targetPackageName == sourceTargetPackage) {
            targetPackageName = record.targetPackageName
            exactPackageMatch = true
        }
    }
    if (candidateCount == 0) { return (0, "") }
    if (exactPackageMatch) { return (1, targetPackageName) }
    if (hasMultipleTargetPackages) { return (2, "") }
    (1, targetPackageName)
}

internal class ChirSemanticProviderFactory <: public_provider.SemanticProviderFactory {
    private let source: SourceSnapshot
    private let options: ChirOptions
    private let identityVersion: String
    private let compiled = HashSet<String>()
    private let failed = HashMap<String, String>()
    private let summaries = HashMap<String, ChirWorkerSummary>()
    private let compiling = HashSet<String>()
    private let artifactRoots = HashMap<String, String>()
    private let retainedDirectories = ArrayList<Path>()
    init(source: SourceSnapshot, options: ChirOptions, identityVersion: String) {
        this.source = source
        this.options = options
        this.identityVersion = identityVersion
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

    private func unsupportedManifestReasonForModule(moduleId: String): ?String {
        for (module in source.modules) {
            if (module.id != moduleId) { continue }
            match (module.manifestText) {
                case Some(text) => return chirManifestUnsupportedReason(Some(text))
                case None =>
                    if (module.role == "root") {
                        return chirManifestUnsupportedReason(source.manifestText)
                    }
                    return None
            }
        }
        if (source.modules.isEmpty()) {
            return chirManifestUnsupportedReason(source.manifestText)
        }
        None
    }
    func analyzeModule(moduleId: String,
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): public_provider.SemanticBatch {
        // CHIR resolves qualified type identities for signatures, so canonical
        // type data is supplied when the worker returns it.
        let capabilities = public_model.SemanticCapabilities(true, true, true, true, false)
        let diagnostics = ArrayList<public_model.Diagnostic>()
        if (identityVersion.contains("unknown-cjc")) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2101",
                "CHIR compiler version is unavailable"))
            return public_provider.SemanticBatch(
                public_model.SemanticCapabilities(false, false, false, false, false),
                diagnostics: diagnostics.toArray())
        }
        match (unsupportedManifestReasonForModule(moduleId)) {
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
            let semanticState = if (matchState == 2) { "ambiguous" }
                else if (backed) { "partial" } else { "unavailable" }
            let resolved = chirResolvedSignature(summary, view)
            let parameters = ArrayList<public_provider.SemanticParameter>()
            if (backed) {
                var parameterIndex: Int64 = 0
                for (parameter in view.parameters) {
                    // A resolved type is used only when the worker reported one at
                    // this position; otherwise the source spelling stays partial.
                    let typeRef = match (resolved) {
                        case Some(value) => match (value.parameterType(parameterIndex)) {
                            case Some(node) => chirTypeRefFromNodes(value.nodes, node)
                            case None => partialChirType(parameter.typeSpelling)
                        }
                        case None => partialChirType(parameter.typeSpelling)
                    }
                    parameters.add(public_provider.SemanticParameter(parameter.name, typeRef))
                    parameterIndex++
                }
            }
            let returnType: ?public_model.TypeRef = if (backed) {
                let fromWorker: ?public_model.TypeRef = match (resolved) {
                    case Some(value) => match (value.returnNode) {
                        case Some(node) => Some(chirTypeRefFromNodes(value.nodes, node))
                        case None => None
                    }
                    case None => None
                }
                match (fromWorker) {
                    case Some(value) => Some(value)
                    case None => match (view.returnTypeSpelling) {
                        case Some(spelling) => Some(partialChirType(spelling))
                        case None => None
                    }
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


// A CHIR-resolved signature for one declaration: the pre-order node list plus
// the top-level node index of each parameter and of the return type. Nodes are
// matched positionally by owner/name, never by spelling.
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
            let targetMatch = chirExtensionTargetMatch(summary, view.packageName, view.name)
            return targetMatch[0]
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
        view: public_provider.SourceDeclarationView,
        owner: (String, String, String, String)): Int64 {
        var targetPackageName = ""
        if (owner[0] == "extend") {
            let targetMatch = chirExtensionTargetMatch(summary, owner[1], owner[3])
            if (targetMatch[0] != 1) { return targetMatch[0] }
            targetPackageName = targetMatch[1]
        }
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
                    record.targetPackageName == targetPackageName && record.targetName == owner[2]
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
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): (String, String, String, String) {
        match (view.ownerId) {
            case Some(ownerId) =>
                for (candidate in declarations) {
                    if (candidate.id != ownerId) { continue }
                    if (candidate.kind == "extend") {
                        return ("extend", candidate.packageName, sourceBaseTypeName(candidate.name), candidate.name)
                    }
                    return ("type", candidate.packageName, candidate.name, "")
                }
                ("unknown", "", "", "")
            case None => ("none", "", "", "")
        }
    }

    private func sourceBaseTypeName(value: String): String {
        let base = match (value.indexOf("<")) {
            case Some(index) => value[..index].trimAscii()
            case None => value.trimAscii()
        }
        let components = base.split(".")
        if (components.isEmpty()) { return base }
        components[components.size - 1].trimAscii()
    }

    private func packageOrigins(moduleId: String, packageName: String): Array<SourceFileOrigin> {
        let result = ArrayList<SourceFileOrigin>()
        for (pkg in source.packages) {
            if (pkg.moduleId != moduleId || pkg.name != packageName) { continue }
            for (logicalPath in pkg.sourceFiles) {
                for (origin in source.sourceFileOrigins) {
                    if (origin.moduleId == moduleId && origin.logicalPath == logicalPath) { result.add(origin) }
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

    private func moduleOrganization(moduleId: String): ?String {
        for (module in source.modules) {
            if (module.id == moduleId) { return module.organization }
        }
        None
    }

    private func importAliasSeparator(value: String): ?Int64 {
        let bytes = value.toArray()
        var index: Int64 = 0
        while (index + 1 < bytes.size) {
            if (bytes[index] == b'a' && bytes[index + 1] == b's') {
                let before = index == 0 || bytes[index - 1] == b' ' || bytes[index - 1] == b'\t'
                let after = index + 2 >= bytes.size || bytes[index + 2] == b' ' ||
                    bytes[index + 2] == b'\t'
                if (before && after) { return Some(index) }
            }
            index++
        }
        None
    }

    private func chirImportReference(importText: String): (String, String) {
        let trimmed = importText.trimAscii()
        let value = if (trimmed.startsWith("public ")) {
            trimmed.removePrefix("public ").trimAscii()
        } else {
            trimmed
        }
        if (!value.startsWith("import ")) { return ("", "") }
        var importedName = value[7..].trimAscii()
        if (let Some(alias) <- importAliasSeparator(importedName)) {
            importedName = importedName[..alias].trimAscii()
        }
        match (importedName.indexOf("::")) {
            case Some(index) =>
                if (index <= 0 || index + 2 >= importedName.size) { return ("", "") }
                (importedName[..index].trimAscii(), importedName[index + 2..].trimAscii())
            case None => ("", importedName)
        }
    }

    private func chirImportMatchingPathLength(importedPath: String, packageName: String): Int64 {
        let length = sourcePackagePathPrefixLength(packageName, importedPath)
        if (length < 0 || importedPath.size == length) { return length }
        let boundary = importedPath[length]
        if (boundary == b'.' || boundary == b'{' || boundary == b'*' || boundary == b' ' ||
            boundary == b'\n' || boundary == b'\r') { length } else { -1 }
    }

    private func chirImportMatchesOrganization(packageDoc: SourcePackage,
        organization: String): Bool {
        if (organization.isEmpty()) { return true }
        if (let Some(index) <- packageDoc.name.indexOf("::")) {
            return index == organization.size && packageDoc.name.startsWith(organization)
        }
        match (moduleOrganization(packageDoc.moduleId)) {
            case Some(value) => value == organization
            case None => false
        }
    }

    private func importReferencesPackage(importText: String, dependencyPackage: SourcePackage,
        candidates: Array<SourcePackage>): Bool {
        let reference = chirImportReference(importText)
        let organization = reference[0]
        let importedPath = reference[1]
        if (!chirImportMatchesOrganization(dependencyPackage, organization)) { return false }
        let selectedLength = chirImportMatchingPathLength(importedPath, dependencyPackage.name)
        if (selectedLength < 0) { return false }
        var longest: Int64 = -1
        for (candidate in candidates) {
            if (!chirImportMatchesOrganization(candidate, organization)) { continue }
            let length = chirImportMatchingPathLength(importedPath, candidate.name)
            if (length > longest) { longest = length }
        }
        selectedLength == longest
    }

    private func packageDependsOn(moduleId: String, packageName: String,
        dependency: SourcePackage, candidates: Array<SourcePackage>): Bool {
        for (pkg in source.packages) {
            if (pkg.moduleId != moduleId || pkg.name != packageName) { continue }
            for (logicalPath in pkg.sourceFiles) {
                for (origin in source.sourceFileOrigins) {
                    if (origin.moduleId != moduleId || origin.logicalPath != logicalPath) { continue }
                    for (importText in origin.imports) {
                        if (importReferencesPackage(importText, dependency, candidates)) { return true }
                    }
                }
            }
        }
        false
    }

    private func packageDependencies(moduleId: String,
        packageName: String): Array<SourcePackage> {
        let allowedModules = HashSet<String>()
        let _ = allowedModules.add(moduleId)
        for (dependencyId in moduleDependencyIds(moduleId)) {
            let _ = allowedModules.add(dependencyId)
        }
        let candidates = ArrayList<SourcePackage>()
        for (pkg in source.packages) {
            if (!allowedModules.contains(pkg.moduleId) ||
                (pkg.moduleId == moduleId && pkg.name == packageName)) { continue }
            candidates.add(pkg)
        }
        let dependencies = ArrayList<SourcePackage>()
        let candidateValues = candidates.toArray()
        for (pkg in candidateValues) {
            if (packageDependsOn(moduleId, packageName, pkg, candidateValues)) {
                dependencies.add(pkg)
            }
        }
        sort(dependencies, lessThan: { left, right =>
            if (left.moduleId == right.moduleId) { left.name < right.name }
            else { left.moduleId < right.moduleId }
        }, stable: true)
        dependencies.toArray()
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
            let key = dependency.moduleId + ":" + dependency.name
            if (let Some(path) <- artifactRoots.get(key)) {
                appendChirImportPath(paths, seen, path)
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
            if (validateCompilerBuiltinCfg(entry)) { continue }
            values.add(entry.name + "=" + entry.value)
        }
        values
    }

    private func compilePackage(moduleId: String, packageName: String): ?String {
        let key = moduleId + ":" + packageName
        if (compiled.contains(key)) { return None }
        if (let Some(message) <- failed.get(key)) { return Some(message) }
        match (unsupportedManifestReasonForModule(moduleId)) {
            case Some(reason) => return Some("CJDOC2102: " + reason)
            case None => ()
        }
        if (!compiling.add(key)) { return Some("CHIR package dependency cycle") }
        try {
            var moduleName: ?String = None
            for (item in source.modules) {
                if (item.id == moduleId) { moduleName = Some(item.name); break }
            }
            if (moduleName.isNone()) { return Some("source module is missing") }
            for (dependency in packageDependencies(moduleId, packageName)) {
                match (compilePackage(dependency.moduleId, dependency.name)) {
                    case Some(message) =>
                        return Some("dependency '" + dependency.moduleId + ":" +
                            dependency.name + "' is unavailable: " + message)
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
            let executable = match (options.workerExecutable) {
                case Some(value) => value
                case None => return Some("CJDOC2101: CHIR worker executable is not configured")
            }
            writeChirWorkerRequest(request, normalizedChirCompiler(), moduleName.getOrThrow(),
                packageName, importPaths, cfgValues, sourcePaths)
            let workerPath = try {
                canonicalize(Path(executable)).toString()
            } catch (_: Exception) {
                executable
            }
            let (workerCode, stdout, stderr) = executeWithBoundedOutput(workerPath,
                ["--internal-chir-analyze", request.toString(), response.toString()],
                workingDirectory: Some(temporary))
            if (workerCode != 0) {
                return Some("CHIR worker failed: " + boundedChirCompilerOutput(stdout, stderr))
            }
            let summary = readChirWorkerResponse(
                readTextBounded(response, MAX_CHIR_RESPONSE_BYTES))
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

private class ChirResolvedSignature {
    let nodes: ArrayList<ChirTypeNode>
    let parameters: ArrayList<Int64>
    let returnNode: ?Int64

    init(nodes: ArrayList<ChirTypeNode>, parameters: ArrayList<Int64>, returnNode: ?Int64) {
        this.nodes = nodes
        this.parameters = parameters
        this.returnNode = returnNode
    }

    func parameterType(index: Int64): ?Int64 {
        if (index < 0 || index >= parameters.size) { return None }
        Some(parameters[index])
    }
}

private func chirResolvedSignature(summary: ChirWorkerSummary,
    view: public_provider.SourceDeclarationView): ?ChirResolvedSignature {
    for (record in summary.signatureRecords) {
        if (record.packageName != view.packageName || record.name != view.name) { continue }
        // A record whose node list disagrees with the declared parameter count is
        // not trusted; the source spelling is kept instead.
        if (record.paramCount != view.parameters.size) { return None }
        let parameters = ArrayList<Int64>()
        var index: Int64 = 0
        var topLevel: Int64 = 0
        for (node in record.types) {
            if (node.depth == 0) {
                if (topLevel < record.paramCount) { parameters.add(index) }
                topLevel++
            }
            index++
        }
        if (parameters.size != record.paramCount) { return None }
        let returnNode: ?Int64 = if (topLevel > record.paramCount) {
            Some(topLevelNodeIndex(record.types, record.paramCount))
        } else {
            None
        }
        return Some(ChirResolvedSignature(record.types, parameters, returnNode))
    }
    None
}

// Top-level node index of the (count)th depth-0 entry.
private func topLevelNodeIndex(nodes: ArrayList<ChirTypeNode>, count: Int64): Int64 {
    var seen: Int64 = 0
    var index: Int64 = 0
    while (index < nodes.size) {
        if (nodes[index].depth == 0) {
            if (seen == count) { return index }
            seen++
        }
        index++
    }
    -1
}

// Rebuild a TypeRef from the flattened node list. The node's own subtree is the
// run of following nodes with greater depth. A type the docset cannot resolve is
// still recorded as resolved identity from CHIR; the renderer decides whether a
// link target exists.
// The source-visible form of a resolved type: the unqualified name, matching how
// the declaration would have been written where it is used.
private func chirTypeDisplaySpelling(qualifiedName: String): String {
    var index = qualifiedName.size
    while (index > 0) {
        index--
        if (qualifiedName[index] == b'.') { return qualifiedName[index + 1..] }
    }
    qualifiedName
}

private func chirTypeRefFromNodes(nodes: ArrayList<ChirTypeNode>, start: Int64): public_model.TypeRef {
    if (start < 0 || start >= nodes.size) {
        return public_model.TypeRef("source", "",
            public_model.SemanticType("unavailable"))
    }
    let head = nodes[start]
    let arguments = ArrayList<public_model.TypeRef>()
    var index = start + 1
    let childDepth = head.depth + 1
    while (index < nodes.size && nodes[index].depth >= childDepth) {
        if (nodes[index].depth == childDepth) {
            arguments.add(chirTypeRefFromNodes(nodes, index))
        }
        // Skip the whole child subtree.
        var cursor = index + 1
        while (cursor < nodes.size && nodes[cursor].depth > nodes[index].depth) { cursor++ }
        index = cursor
    }
    // The spelling is the source-visible name; the resolved identity belongs in
    // `canonical`, so the rendered signature keeps the author's punctuation and
    // generic spelling exactly as written.
    let display = chirTypeDisplaySpelling(head.qualifiedName)
    return public_model.TypeRef("source", display,
        public_model.SemanticType("resolved", canonical: Some(head.qualifiedName),
            provider: Some("chir")),
        arguments: arguments.toArray())
}
