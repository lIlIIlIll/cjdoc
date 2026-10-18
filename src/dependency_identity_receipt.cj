package cjdoc

import std.collection.*
import std.fs.*
import yjson.*

private func dependencyReceiptObject(node: JsonNode, keys: Array<String>): JsonObject {
    let object = node.asObject()
    for (index in 0..object.size()) {
        if (!keys.contains(object.nameAt(index))) { throw IllegalArgumentException("unsupported build context field") }
    }
    object
}

private func dependencyReceiptString(object: JsonObject, key: String): String {
    match (object.get(key)) { case Some(value) => value.asString(); case None => "" }
}

private func dependencyReceiptPath(base: String, path: String): String {
    if (path.isEmpty() || path.contains("\u{0}")) { throw IllegalArgumentException("invalid build context path") }
    canonicalize(if (highlightHostPathIsAbsolute(path)) { Path(path) } else { Path(base).join(path) }).toString()
}

private func dependencyReceiptBase(path: String): String {
    let resolved = normalizedHostPath(canonicalize(path).toString())
    let slash = resolved.lastIndexOf("/").getOrThrow()
    if (slash == 0) { "/" } else { resolved[..slash] }
}


private func dependencyReceiptShape(record: JsonObject): Unit {
    if (!safeCjpmTargetName(record["target"].asString())) { throw IllegalArgumentException("invalid build record target") }
    let project = dependencyReceiptObject(record["project"], ["path", "identity"])
    let _ = project["path"].asString()
    let _ = project["identity"].asString()
    let _ = record["cfg"].asString()
    let modules = record["modules"].asArray()
    if (modules.size() > 4096) { throw IllegalArgumentException("build record module limit exceeded") }
    for (index in 0..modules.size()) {
        let module = dependencyReceiptObject(modules.get(index).getOrThrow(), ["name", "path", "identity", "dependencies"])
        for (key in ["name", "path", "identity"]) {
            if (module[key].asString().isEmpty()) { throw IllegalArgumentException("incomplete build record module") }
        }
        let dependencies = module["dependencies"].asArray()
        if (dependencies.size() > 16384) { throw IllegalArgumentException("build record dependency limit exceeded") }
        let names = HashSet<String>()
        for (entryIndex in 0..dependencies.size()) {
            let entry = dependencyReceiptObject(dependencies.get(entryIndex).getOrThrow(),
                ["name", "kind", "path", "identity", "version", "revision", "content"])
            for (key in ["name", "kind", "path", "identity"]) {
                if (entry[key].asString().isEmpty()) { throw IllegalArgumentException("incomplete build record dependency") }
            }
            if (!["source", "binary", "std", "stdx", "toolchain"].contains(entry["kind"].asString()) ||
                !names.add(entry["kind"].asString() + "\n" + entry["name"].asString())) {
                throw IllegalArgumentException("invalid or duplicate build record dependency")
            }
            let content = dependencyReceiptString(entry, "content")
            if (!content.isEmpty() && content != "source" && content != "artifact") {
                throw IllegalArgumentException("invalid build record content kind")
            }
            let _ = dependencyReceiptString(entry, "version")
            let _ = dependencyReceiptString(entry, "revision")
        }
    }
}

private func dependencyReceiptBound(capture: DependencyIdentityCapture, record: JsonObject, base: String): Bool {
    let project = record["project"].asObject()
    let projectRoot = canonicalize(capture.request.projectRoot).toString()
    dependencyReceiptPath(base, project["path"].asString()) == projectRoot &&
        project["identity"].asString() == capture.inputIdentity(projectRoot, true) &&
        record["cfg"].asString() == capture.cfg &&
        (capture.target.isEmpty() || record["target"].asString() == capture.target)
}


private func dependencyReceiptModule(capture: DependencyIdentityCapture, entry: JsonObject,
    base: String): DependencyIdentityModule {
    let path = dependencyReceiptPath(base, entry["path"].asString())
    let name = entry["name"].asString()
    for (module in capture.modules) {
        if (module.root == path && module.name == name) { return module }
    }
    throw IllegalArgumentException("build record module is not in the observed project graph")
}

private func dependencyReceiptEntry(capture: DependencyIdentityCapture, owner: DependencyIdentityModule,
    node: JsonNode, base: String, binding: Bool): Unit {
    let entry = dependencyReceiptObject(node, ["name", "kind", "path", "identity", "version", "revision", "content"])
    let name = entry["name"].asString()
    let kind = entry["kind"].asString()
    if (name.isEmpty() || !["source", "binary", "std", "stdx", "toolchain"].contains(kind)) {
        throw IllegalArgumentException("invalid build record dependency kind")
    }
    let content = dependencyReceiptString(entry, "content")
    if (!content.isEmpty() && content != "source" && content != "artifact") {
        throw IllegalArgumentException("invalid build record content kind")
    }
    let source = content == "source" || (content.isEmpty() && kind == "source")
    let claimed = entry["identity"].asString()
    var version = dependencyReceiptString(entry, "version")
    var revision = dependencyReceiptString(entry, "revision")
    var observed = ""
    var valid = binding
    try {
        let path = dependencyReceiptPath(base, entry["path"].asString())
        observed = capture.inputIdentity(path, source)
        if (source && kind != "binary" && kind != "toolchain") {
            capture.sourceRoots[owner.id + "\n" + kind + "\n" + name] = path
        }
        valid = valid && claimed == observed
        let actualVersion = if (kind == "source") {
            dependencyManifestVersion(readTextBounded(Path(path).join("cjpm.toml"), MAX_MANIFEST_ADAPTER_BYTES))
        } else { "" }
        for (existing in capture.entries) {
            if (existing.moduleId != owner.id || existing.name != name || existing.kind != kind) { continue }
            if (existing.state == "conflict" || (!existing.identity.isEmpty() && existing.identity != observed) ||
                (!existing.version.isEmpty() && !version.isEmpty() && existing.version != version) ||
                (!existing.revision.isEmpty() && !revision.isEmpty() && existing.revision != revision)) { valid = false }
            if (version.isEmpty()) { version = existing.version }
            if (revision.isEmpty()) { revision = existing.revision }
        }
        if (!version.isEmpty() && !actualVersion.isEmpty() && version != actualVersion) { valid = false }
    } catch (_: Exception) {
        capture.put(owner.id, name, kind, "", "unknown", "build record input could not be observed",
            version: version, revision: revision)
        capture.diagnostic("CJDOC2302", "build record dependency input is inaccessible or exceeds observation limits")
        return
    }
    capture.put(owner.id, name, kind, observed, if (valid) { "verified" } else { "conflict" },
        if (valid) { "explicit build record selection; source/artifact bytes and project/configuration binding matched; version/revision declared" }
        else { "build record conflicts with observed bytes, lock, project or configuration" }, version: version, revision: revision)
    if (!valid) { capture.diagnostic("CJDOC2301", "build record dependency conflicts with observed target inputs") }
}

private func dependencyReceiptApply(capture: DependencyIdentityCapture, record: JsonObject, base: String): Unit {
    if (!safeCjpmTargetName(record["target"].asString())) { throw IllegalArgumentException("invalid build record target") }
    let project = dependencyReceiptObject(record["project"], ["path", "identity"])
    let projectRoot = canonicalize(capture.request.projectRoot).toString()
    let binding = dependencyReceiptPath(base, project["path"].asString()) == projectRoot &&
        project["identity"].asString() == capture.inputIdentity(projectRoot, true) &&
        record["cfg"].asString() == capture.cfg && record["target"].asString() == capture.target
    if (!binding) { capture.diagnostic("CJDOC2301", "build record project bytes or target/configuration binding conflicts") }
    if (!binding) { throw IllegalArgumentException("build record project or configuration binding conflicts") }
    let modules = record["modules"].asArray()
    if (modules.size() > 4096) { throw IllegalArgumentException("build record module limit exceeded") }
    let seenModules = HashSet<String>()
    for (index in 0..modules.size()) {
        let entry = dependencyReceiptObject(modules.get(index).getOrThrow(), ["name", "path", "identity", "dependencies"])
        let owner = dependencyReceiptModule(capture, entry, base)
        if (!seenModules.add(owner.id)) { throw IllegalArgumentException("duplicate build record module") }
        let identity = capture.inputIdentity(owner.root, true)
        let verified = binding && identity == entry["identity"].asString()
        capture.put(owner.id, owner.name, "source", identity, if (verified) { "verified" } else { "conflict" },
            if (verified) { "build record project/configuration binding and module source bytes matched" }
            else { "build record module or project/configuration binding conflicts" }, version: dependencyManifestVersion(owner.manifest))
        if (!verified) { capture.diagnostic("CJDOC2301", "build record module source bytes conflict") }
        let dependencies = entry["dependencies"].asArray()
        if (dependencies.size() > 16384) { throw IllegalArgumentException("build record dependency limit exceeded") }
        let names = HashSet<String>()
        for (dependencyIndex in 0..dependencies.size()) {
            let node = dependencies.get(dependencyIndex).getOrThrow()
            let dependency = node.asObject()
            if (!names.add(dependency["kind"].asString() + "\n" + dependency["name"].asString())) {
                throw IllegalArgumentException("duplicate build record dependency")
            }
            dependencyReceiptEntry(capture, owner, node, base, verified)
        }
    }
}

internal func captureDependencyBuildContext(capture: DependencyIdentityCapture, path: String): Unit {
    // Parse and apply into a separate snapshot: malformed records never leave partially verified claims.
    let staged = capture.receiptObservation()
    staged.target = capture.target
    try {
        let record = dependencyReceiptObject(JsonNode.parse(readTextBounded(Path(path), 4 * 1024 * 1024),
            config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 8,
                maxStringBytes: 65536, maxInputBytes: 4 * 1024 * 1024,
                maxBufferedValueBytes: 4 * 1024 * 1024)), ["schemaVersion", "project", "target", "cfg", "modules"])
        if (record["schemaVersion"].asString() != "cjdoc.build-context/1") {
            throw IllegalArgumentException("unsupported build context schema")
        }
        if (staged.target.isEmpty()) { staged.target = record["target"].asString() }
        dependencyReceiptShape(record)
        let base = dependencyReceiptBase(path)
        if (!dependencyReceiptBound(staged, record, base)) {
            capture.diagnostic("CJDOC2301", "build record project bytes or target/configuration binding conflicts")
            throw IllegalArgumentException("unbound build record")
        }
        staged.sourceGraph()
        let graphDiagnosticCount = match (staged.diagnostics) { case Some(output) => output.size; case None => 0 }
        dependencyReceiptApply(staged, record, base)
        capture.target = staged.target
        capture.modules.clear()
        capture.modules.add(all: staged.modules)
        capture.sourceRoots.clear()
        for ((key, value) in staged.sourceRoots) { capture.sourceRoots[key] = value }
        capture.entries.clear()
        capture.entries.add(all: staged.entries)
        if (let Some(output) <- capture.diagnostics) {
            if (let Some(pending) <- staged.diagnostics) {
                // The live graph was already observed, but a receipt can select a
                // different target. Keep new graph warnings and receipt warnings;
                // consume only the repeated occurrences from the graph rebuild.
                let previous = HashMap<String, Int64>()
                if (graphDiagnosticCount > 0) {
                    for (diagnostic in output) {
                        let key = diagnostic.code + "\n" + diagnostic.message
                        previous[key] = previous.get(key).getOrDefault({ => 0 }) + 1
                    }
                }
                for (index in 0..pending.size) {
                    if (output.size >= 4096) { break }
                    let diagnostic = pending[index]
                    if (index < graphDiagnosticCount) {
                        let key = diagnostic.code + "\n" + diagnostic.message
                        let remaining = previous.get(key).getOrDefault({ => 0 })
                        if (remaining > 0) { previous[key] = remaining - 1; continue }
                    }
                    output.add(diagnostic)
                }
            }
        }
    } catch (_: Exception) {
        capture.diagnostic("CJDOC2300", "build context is invalid or cannot be bound to the observed project graph; record ignored")
    }
}
