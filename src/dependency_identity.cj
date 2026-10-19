package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*
import std.sort.*

internal class DependencyIdentityModule {
    let id: String
    let name: String
    let packageName: String
    let root: String
    let manifest: String
    init(id: String, name: String, root: String, manifest: String, packageName: String) {
        this.id = id; this.name = name; this.root = root; this.manifest = manifest; this.packageName = packageName
    }
}

private func dependencyCapturedModules(origins: Array<SourceFileOrigin>): HashMap<String, String> {
    let result = HashMap<String, String>()
    let roots = HashMap<String, String>()
    for (origin in origins) {
        if (origin.moduleId.isEmpty()) { continue }
        let root = match (roots.get(origin.actualRoot)) {
            case Some(value) => value
            case None =>
                let value = try { canonicalize(origin.actualRoot).toString() } catch (_: Exception) { continue }
                roots[origin.actualRoot] = value
                value
        }
        if (let Some(previous) <- result.get(root)) {
            if (previous != origin.moduleId) { result[root] = "" }
        } else { result[root] = origin.moduleId }
    }
    result
}

internal class DependencyIdentityCapture {
    let entries = ArrayList<public_model.DependencyInstance>()
    let modules = ArrayList<DependencyIdentityModule>()
    let sourceRoots = HashMap<String, String>()
    private let identityCache = HashMap<String, String>()
    private let manifestDigests = HashMap<String, String>()
    private let identityBytes: SourceAuxiliaryBudget
    private let identityEntries: SourceDirectoryBudget
    private let capturedModules: HashMap<String, String>
    let diagnostics: ?ArrayList<public_model.Diagnostic>
    let request: GenerationRequest
    let documentation: public_model.DocumentationSet
    let cfg: String
    var target: String

    init(documentation: public_model.DocumentationSet, request: GenerationRequest,
        diagnostics: ?ArrayList<public_model.Diagnostic>, observationBytes!: ?SourceAuxiliaryBudget = None,
        observationEntries!: ?SourceDirectoryBudget = None,
        capturedModules!: ?HashMap<String, String> = None) {
        this.documentation = documentation; this.request = request; this.diagnostics = diagnostics
        identityBytes = observationBytes.getOrDefault({ => SourceAuxiliaryBudget(512 * 1024 * 1024, 512 * 1024 * 1024) })
        identityEntries = observationEntries.getOrDefault({ => SourceDirectoryBudget(maxEntries: 100000, maxDepth: 128) })
        this.capturedModules = capturedModules.getOrDefault({ => HashMap<String, String>() })
        this.cfg = dependencyCfg(request); this.target = dependencyTarget(request)
    }

    func receiptObservation(): DependencyIdentityCapture {
        let stagedDiagnostics = match (diagnostics) {
            case Some(_) => Some(ArrayList<public_model.Diagnostic>())
            case None => None<ArrayList<public_model.Diagnostic>>
        }
        let staged = DependencyIdentityCapture(documentation, request, stagedDiagnostics,
            observationBytes: Some(identityBytes), observationEntries: Some(identityEntries), capturedModules: Some(capturedModules))
        // Reuse observed bytes without sharing the transaction's mutable cache.
        for ((key, value) in identityCache) { staged.identityCache[key] = value }
        for ((key, value) in manifestDigests) { staged.manifestDigests[key] = value }
        staged
    }

    func inputIdentity(path: String, source: Bool): String {
        let key = canonicalize(path).toString() + if (source) { "|source" } else { "|artifact" }
        if (let Some(value) <- identityCache.get(key)) { return value }
        let manifestDigest = [""]
        let value = dependencyObservedIdentity(path, source,
            byteBudget: Some(identityBytes), directoryBudget: Some(identityEntries),
            manifestDigest: Some({ digest => manifestDigest[0] = digest }))
        identityCache[key] = value
        if (source) { manifestDigests[key] = manifestDigest[0] }
        value
    }

    func diagnostic(code: String, message: String): Unit {
        if (let Some(output) <- diagnostics) {
            if (output.size < 4096) { output.add(public_model.Diagnostic("warning", code, message)) }
        }
    }

    func put(owner: String, name: String, kind: String, identity: String, state: String,
        evidence: String, version!: String = "", revision!: String = ""): Unit {
        // Final owner- and transitive-context-scoped IDs are derived once the
        // entire selected graph has been captured, never from a partial prefix.
        let instance = "pending"
        let value = public_model.DependencyInstance(owner, name, instance, kind, identity, state, evidence,
            version: version, revision: revision, target: target, cfg: cfg)
        for (index in 0..entries.size) {
            if (entries[index].moduleId == owner && entries[index].name == name && entries[index].kind == kind) {
                entries[index] = value
                return
            }
        }
        if (entries.size >= 16384) { diagnostic("CJDOC2302", "dependency graph exceeds the edge inventory limit"); return }
        entries.add(value)
    }

    // The manifest text that supplies a version must belong to the same source
    // observation as the identity; a separate read could see a rewritten file
    // whose digest this call cannot attribute to the identity it was paired with.
    func manifestVersion(path: String): String {
        let manifestBytes = readAuxiliaryFileBounded(Path(path).join("cjpm.toml"), MAX_MANIFEST_ADAPTER_BYTES,
            SourceAuxiliaryBudget(MAX_MANIFEST_ADAPTER_BYTES, MAX_MANIFEST_ADAPTER_BYTES))
        if (let Some(observed) <- manifestDigests.get(canonicalize(path).toString() + "|source")) {
            if (observed != Sha256Digest.digestBytes(manifestBytes)) {
                throw IllegalArgumentException("dependency manifest changed while observing")
            }
        }
        dependencyManifestVersion(try { String.fromUtf8(manifestBytes) } catch (_: Exception) {
            throw IllegalArgumentException("dependency manifest is not valid UTF-8")
        })
    }

    func observe(owner: String, name: String, path: String, evidence: String): Unit {
        try {
            sourceRoots[owner + "\nsource\n" + name] = canonicalize(path).toString()
            let identity = inputIdentity(path, true)
            // Read the version from the manifest bytes that belong to the same
            // observation as the identity. A second independent read could see a
            // rewritten manifest whose digest the end-of-graph check cannot
            // attribute to this call, pairing an old tree identity with a new
            // version.
            let version = manifestVersion(path)
            var conflict = false
            for (entry in entries) {
                if (entry.moduleId == owner && entry.name == name && entry.kind == "source" &&
                    (entry.state == "conflict" || (!entry.identity.isEmpty() && entry.identity != identity))) { conflict = true }
            }
            put(owner, name, "source", identity, if (conflict) { "conflict" } else { "observed" },
                if (conflict) { "explicit and manifest source selections disagree" } else { evidence }, version: version)
            if (conflict) { diagnostic("CJDOC2301", "dependency has conflicting explicit and manifest source selections") }
        }
        catch (_: Exception) {
            put(owner, name, "source", "", "unknown", "source observation unavailable")
            diagnostic("CJDOC2302", "dependency source bytes could not be observed within inventory limits")
        }
    }

    func addModule(path: String, role: String, owner!: String = ""): ?DependencyIdentityModule {
        try {
            let resolved = canonicalize(path).toString()
            for (module in modules) { if (module.root == resolved) { return Some(module) } }
            if (modules.size >= 4096) { throw IllegalArgumentException("dependency module limit exceeded") }
            let text = readTextBounded(Path(resolved).join("cjpm.toml"), MAX_MANIFEST_ADAPTER_BYTES)
            let parsed = parseCjpmPackageNameChecked(text)
            if (parsed.invalid || parsed.limitReached) { throw IllegalArgumentException("invalid manifest") }
            let name = parsed.value.getOrDefault({ => "workspace" })
            let organization = parsed.organization.getOrDefault({ => "" })
            let packageName = if (organization.isEmpty()) { name } else { organization + "::" + name }
            var prefix = relativePathFromResolved(canonicalize(request.projectRoot).toString(), resolved)
                .getOrDefault({ => "dependencies/" + name })
            var selectedName = name
            if (role == "pathDependency") {
                selectedName = packageName
                prefix = "dependencies/" + percentEscapeSymbolPart(selectedName).replace("/", "%2F").replace("\\", "%5C")
            }
            if (role == "externalDependency") {
                for (input in request.dependencySources) {
                    let selectedRoot = try { canonicalize(input.path).toString() } catch (_: Exception) { continue }
                    if (selectedRoot == resolved) { selectedName = input.name; prefix = dependencyPrefix(input.name) }
                }
            }
            var id = ""
            if (let Some(captured) <- capturedModules.get(resolved)) {
                if (!captured.isEmpty()) { id = captured }
            }
            if (role == "root") {
                for (module in documentation.modules where module.role == "root") { id = module.id; break }
            }
            if (id.isEmpty()) {
                id = moduleId(role, selectedName, prefix + "/context/" + Sha256Digest.digest(owner) +
                    "/content/" + inputIdentity(resolved, true))
            }
            let result = DependencyIdentityModule(id, name, resolved, text, packageName)
            modules.add(result)
            return Some(result)
        } catch (_: Exception) {
            diagnostic("CJDOC2302", "dependency manifest could not be observed within inventory limits")
            None
        }
    }

    func sourceGraph(): Unit {
        let _ = addModule(request.projectRoot, "root")
        var cursor: Int64 = 0
        while (cursor < modules.size) {
            let owner = modules[cursor]
            cursor++
            observe(owner.id, owner.name, owner.root, "project source and manifest bytes")
            let parsed = parseCjpmManifest(owner.manifest)
            if (parsed.invalid || parsed.limitReached) {
                diagnostic("CJDOC2302", "dependency manifest inventory is invalid or exceeds limits")
                continue
            }
            for (member in parsed.workspaceMembers) {
                let _ = addModule(Path(owner.root).join(member).toString(), "workspace")
            }
            let paths = parseCjpmPathDependencies(owner.manifest, 16384,
                selectedTarget: if (target.isEmpty()) { None<String> } else { Some(target) })
            if (paths.invalid || paths.partial || paths.limitReached) {
                diagnostic("CJDOC2302", "dependency path inventory is partial; unsupported selections remain unknown")
            }
            captureManifestDependencySelections(this, owner)
            if (cursor == 1) {
                for (input in request.dependencySources) {
                    if (let Some(dependency) <- addModule(input.path, "externalDependency", owner: owner.id)) {
                        observe(owner.id, input.name, dependency.root, "explicit dependency source input and source bytes")
                    }
                }
            }
            locked(owner)
            for (kind in ["std", "stdx", "toolchain"]) {
                put(owner.id, kind, kind, "", "unknown", "target build input not supplied")
            }
        }
        // Root and captured-ID modules are observed only after addModule has
        // read their manifests. Before publishing any graph, pair every parsed
        // manifest with the digest captured by that same source observation.
        for (module in modules) {
            if (let Some(digest) <- manifestDigests.get(module.root + "|source")) {
                if (digest != Sha256Digest.digest(module.manifest)) {
                    entries.clear(); modules.clear(); sourceRoots.clear()
                    diagnostic("CJDOC2302", "dependency manifest could not be observed within inventory limits")
                    return
                }
            }
        }
    }

    func locked(owner: DependencyIdentityModule): Unit {
        let path = Path(owner.root).join("cjpm.lock")
        if (!exists(path)) { return }
        try {
            let lock = parseCjpmLock(readTextBounded(path, MAX_MANIFEST_ADAPTER_BYTES))
            if (lock.invalid || lock.limitReached) { throw IllegalArgumentException("invalid lock") }
            for (dependency in lock.dependencies) {
                let version = dependency.version.getOrDefault({ => "" })
                let revision = dependency.commitId.getOrDefault({ => "" })
                var matched = false
                for (entry in entries) {
                    if (entry.moduleId != owner.id || entry.name != dependency.name || entry.kind != "source") { continue }
                    matched = true
                    var actual = ""
                    if (let Some(selectedRoot) <- sourceRoots.get(owner.id + "\nsource\n" + dependency.name)) {
                        actual = dependencyManifestVersion(readTextBounded(Path(selectedRoot).join("cjpm.toml"), MAX_MANIFEST_ADAPTER_BYTES))
                    }
                    let conflict = entry.state == "conflict" || (!version.isEmpty() && !actual.isEmpty() && version != actual) ||
                        (!entry.version.isEmpty() && !version.isEmpty() && entry.version != version) ||
                        (!entry.revision.isEmpty() && !revision.isEmpty() && entry.revision != revision)
                    put(owner.id, dependency.name, "source", entry.identity, if (conflict) { "conflict" } else { entry.state },
                        if (conflict) { "lock declaration conflicts with selected source or manifest" }
                        else { entry.evidence + "; lock version/revision declared" }, version: version, revision: revision)
                    if (conflict) { diagnostic("CJDOC2301", "locked dependency conflicts with observed source or manifest") }
                    break
                }
                if (!matched) { put(owner.id, dependency.name, "source", "", "declared",
                    "lock declaration only; cache location is not evidence of selection", version: version, revision: revision) }
            }
        } catch (_: Exception) { diagnostic("CJDOC2302", "dependency lock inventory could not be observed") }
    }

    func connectSourceComponents(): Unit {
        let byRoot = HashMap<String, String>()
        for (module in modules) { byRoot[module.root] = module.id }
        for (index in 0..entries.size) {
            let entry = entries[index]
            if (entry.kind == "binary" || entry.kind == "toolchain") { continue }
            if (let Some(root) <- sourceRoots.get(entry.moduleId + "\n" + entry.kind + "\n" + entry.name)) {
                if (let Some(component) <- byRoot.get(root)) {
                    entries[index] = public_model.DependencyInstance(entry.moduleId, entry.name, entry.instanceId,
                        entry.kind, entry.identity, entry.state, entry.evidence, version: entry.version,
                        revision: entry.revision, target: entry.target, cfg: entry.cfg, componentModuleId: component)
                }
            }
        }
    }
}

internal func dependencyManifestVersion(manifest: String): String {
    let scanner = TomlLineScanner()
    var inPackage = false
    for (line in manifest.split("\n")) {
        if (let Some(code) <- scanner.code(line)) {
            let trimmed = code.trimAscii()
            if (trimmed.startsWith("[")) { inPackage = trimmed == "[package]"; continue }
            if (!inPackage) { continue }
            if (let Some(equals) <- tomlAssignmentEquals(code)) {
                if (code[..equals].trimAscii() == "version") {
                    return tomlAssignmentString(code, equals).value.getOrDefault({ => "" })
                }
            }
        }
    }
    ""
}

internal func captureDependencyIdentities(documentation: public_model.DocumentationSet,
    request: GenerationRequest, diagnostics!: ?ArrayList<public_model.Diagnostic> = None,
    origins!: Array<SourceFileOrigin> = [], navigationWork!: ?DependencyNavigationWork = None):
    (Array<public_model.DependencyInstance>, DependencyGraphIndex) {
    let capture = DependencyIdentityCapture(documentation, request, diagnostics,
        capturedModules: Some(dependencyCapturedModules(origins)))
    capture.sourceGraph()
    if (let Some(path) <- request.buildContext) { captureDependencyBuildContext(capture, path) }
    capture.connectSourceComponents()
    let work = navigationWork.getOrDefault({ => DependencyNavigationWork() })
    let packages = HashMap<String, String>()
    for (module in capture.modules) { packages[module.id] = module.packageName }
    let graph = DependencyGraphIndex(capture.entries, sourcePackages: Some(packages))
    for (index in 0..capture.entries.size) {
        let entry = capture.entries[index]
        let context = if (entry.componentModuleId.isEmpty()) { "no-source-module" }
            else { graph.context(entry.componentModuleId, work).fingerprint }
        let scoped = dependencyScopedInstance(entry, context, work)
        if (work.exhausted || scoped.isEmpty()) {
            capture.diagnostic("CJDOC2302", "dependency graph context work budget exceeded; navigation identity snapshot unavailable")
            capture.entries.clear()
            return (capture.entries.toArray(), DependencyGraphIndex(capture.entries))
        }
        capture.entries[index] = public_model.DependencyInstance(entry.moduleId, entry.name, scoped, entry.kind,
            entry.identity, entry.state, entry.evidence, version: entry.version, revision: entry.revision,
            target: entry.target, cfg: entry.cfg, componentModuleId: entry.componentModuleId)
    }
    sort(capture.entries, lessThan: { left, right =>
        let a = left.moduleId + "\n" + left.name + "\n" + left.kind
        let b = right.moduleId + "\n" + right.name + "\n" + right.kind
        a < b
    }, stable: true)
    (capture.entries.toArray(), graph)
}
