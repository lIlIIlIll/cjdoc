protected package cjdoc.semantic.chir

import cjdoc.source.model.SourceSnapshot
import cjdoc.model as public_model
import cjdoc.provider as public_provider
import cjdoc.source.cfg.validateCompilerBuiltinCfg
import cjdoc_chir_protocol.*
import std.collection.*
import std.fs.*

protected struct ChirExecutionOptions {
    let compilerExecutable: String
    let workerExecutable: ?String
    let importPaths: ReadOnlyList<String>

    protected init(compilerExecutable: String, workerExecutable: ?String, importPaths: ReadOnlyList<String>) {
        this.compilerExecutable = compilerExecutable
        this.workerExecutable = workerExecutable
        this.importPaths = importPaths
    }
}

// CHIR remains an enrichment provider. Source declarations and comments remain
// the binding boundary; this factory only returns records for declarations that
// were present in the source view supplied by the public adapter.
protected class ChirSemanticProviderFactory <: public_provider.SemanticProviderFactory {
    private let source: SourceSnapshot
    private let options: ChirExecutionOptions
    private let identityVersion: String
    private let compiled = HashSet<String>()
    private let failed = HashMap<String, String>()
    private let summaries = HashMap<String, ChirWorkerSummary>()
    private let compiling = HashSet<String>()
    private let artifactRoots = HashMap<String, String>()
    private let retainedDirectories = ArrayList<Path>()
    private var workerValidationAttempted = false
    private var workerValidationFailure: ?String = None
    private var validatedWorkerPath: ?String = None
    protected init(source: SourceSnapshot, options: ChirExecutionOptions, identityVersion: String) {
        this.source = source
        this.options = options
        this.identityVersion = identityVersion
    }

    public prop name: String { get() { "chir" } }
    public prop version: String { get() { identityVersion } }

    public func open(module: public_provider.SemanticModule): public_provider.SemanticProviderSession {
        ChirSemanticProviderSession(this, module.id)
    }
    protected func dispose(): Unit {
        for (directory in retainedDirectories) {
            try { let _ = removeIfExists(directory, recursive: true) } catch (_: Exception) {}
        }
    }

    private func manifestForModule(moduleId: String): ?String {
        for (module in source.modules) {
            if (module.id != moduleId) { continue }
            if (module.manifestText.isSome()) { return module.manifestText }
            if (module.role == "root") { return source.manifestText }
            return None
        }
        if (source.modules.isEmpty()) { return source.manifestText }
        None
    }

    private func unsupportedManifestReasonForModule(moduleId: String): ?String {
        chirManifestUnsupportedReason(manifestForModule(moduleId))
    }

    private func prepareWorker(): ?String {
        if (workerValidationAttempted) { return workerValidationFailure }
        workerValidationAttempted = true
        workerValidationFailure = match (options.workerExecutable) {
            case Some(executable) =>
                try {
                    let path = canonicalize(Path(executable))
                    if (!FileInfo(path).isRegular()) {
                        Some("CJDOC2101: CHIR worker executable is not a regular file")
                    } else {
                        let failure = chirWorkerCompatibilityFailure(path.toString())
                        if (failure.isNone()) { validatedWorkerPath = Some(path.toString()) }
                        failure
                    }
                } catch (error: Exception) {
                    Some("CJDOC2101: CHIR worker executable is unavailable: " + error.message)
                }
            case None => Some("CJDOC2101: CHIR worker executable is not configured")
        }
        workerValidationFailure
    }
    func analyzeModule(moduleId: String,
        declarations: ReadOnlyList<public_provider.SourceDeclarationView>): public_provider.SemanticBatch {
        // Canonical types come only from structured CHIR. The host binder keeps
        // its conservative source-local navigation fallback, including when
        // CHIR is unavailable; this does not claim compiler-proven relationships.
        let capabilities = public_model.SemanticCapabilities(true, true, true, true, false,
            relationships: true)
        let diagnostics = ArrayList<public_model.Diagnostic>()
        if (identityVersion.contains("unknown-cjc")) {
            diagnostics.add(public_model.Diagnostic("warning", "CJDOC2101",
                "CHIR compiler version is unavailable"))
            return public_provider.SemanticBatch(
                public_model.SemanticCapabilities(false, false, false, false, false, relationships: true),
                diagnostics: diagnostics.toArray())
        }
        match (unsupportedManifestReasonForModule(moduleId)) {
            case Some(reason) =>
                diagnostics.add(public_model.Diagnostic("warning", "CJDOC2102", reason))
                return public_provider.SemanticBatch(
                    public_model.SemanticCapabilities(false, false, false, false, false, relationships: true),
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
                public_model.SemanticCapabilities(false, false, false, false, false, relationships: true),
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
            let resolved = chirResolvedSignature(summary, view, declarations)
            let parameters = ArrayList<public_provider.SemanticParameter>()
            if (backed) {
                var parameterIndex: Int64 = 0
                for (parameter in view.parameters) {
                    // A resolved type is used only when the worker reported one at
                    // this position; otherwise the source spelling stays partial.
                    let typeRef = match (resolved) {
                        case Some(value) =>
                            match (value.parameterTypeRef(parameterIndex, parameter.typeSpelling)) {
                                case Some(workerType) => workerType
                                case None => partialChirType(parameter.typeSpelling)
                            }
                        case None => partialChirType(parameter.typeSpelling)
                    }
                    parameters.add(public_provider.SemanticParameter(parameter.name, typeRef))
                    parameterIndex++
                }
            }
            // A declaration with no source return type (a constructor) has no
            // return in the source API, even though CHIR reports the implicit
            // Unit; only a declaration that declares a return type gets one.
            let returnType: ?public_model.TypeRef =
                if (!backed) { None }
                else {
                    match (view.returnTypeSpelling) {
                        case Some(spelling) =>
                            match (resolved) {
                                case Some(value) => match (value.returnTypeRef(spelling)) {
                                    case Some(workerType) => Some(workerType)
                                    case None => Some(partialChirType(spelling))
                                }
                                case None => Some(partialChirType(spelling))
                            }
                        case None => None
                    }
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
        if (let Some(reason) <- prepareWorker()) { return Some(reason) }
        if (!compiling.add(key)) { return Some("CHIR package dependency cycle") }
        try {
            var moduleName: ?String = None
            for (item in source.modules) {
                if (item.id == moduleId) { moduleName = Some(item.name); break }
            }
            if (moduleName.isNone()) { return Some("source module is missing") }
            for (dependency in chirPackageDependencies(source, moduleId, packageName)) {
                match (compilePackage(dependency.moduleId, dependency.name)) {
                    case Some(message) =>
                        return Some("dependency '" + dependency.moduleId + ":" +
                            dependency.name + "' is unavailable: " + message)
                    case None => ()
                }
            }
            let origins = chirPackageOrigins(source, moduleId, packageName)
            if (origins.isEmpty()) { return Some("captured source set is empty") }
            match (chirRunWorker(validatedWorkerPath.getOrThrow(), normalizedChirCompiler(),
                moduleName.getOrThrow(), packageName, origins,
                chirDependencyImportPaths(source, options, moduleId, packageName, artifactRoots),
                chirCfgValues(),
                chirManifestCompilerOptions(manifestForModule(moduleId)),
                retainedDirectories)) {
                case ChirWorkerRunOutcome.Failed(message) => return Some(message)
                case ChirWorkerRunOutcome.Completed(summary, artifactRoot) =>
                    summaries[key] = summary
                    artifactRoots[key] = artifactRoot
                    let _ = compiled.add(key)
            }
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
