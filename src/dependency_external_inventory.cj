package cjdoc

import cjdoc.model.*
import cjdoc.render as inventory_codec
import std.collection.*
import std.fs.*
import yjson.*

internal class ExternalDocEntry {
    let documentSet: DocumentSetIdentity
    let symbolKey: String
    let name: String
    let url: String
    let kind: String
    let genericArity: Int64
    let sourceHeader: String
    init(documentSet: DocumentSetIdentity, symbolKey: String, name: String, url: String, kind: String, genericArity: Int64,
        sourceHeader!: String = "") {
        this.documentSet = documentSet; this.symbolKey = symbolKey
        this.name = name; this.url = url; this.kind = kind; this.genericArity = genericArity
        this.sourceHeader = sourceHeader
    }
}

internal func externalString(object: JsonObject, key: String, fallback!: String = ""): String {
    match (object.get(key)) {
        case Some(value) => value.asString()
        case None => fallback
    }
}

internal func readExternalDocumentSets(resolver: ExternalDocResolver, object: JsonObject,
    budget: ExternalDocInventoryBudget): Unit {
    let sets = object.get("documentSets").getOrThrow().asArray()
    if (sets.size() > 256) { throw IllegalArgumentException("document set budget exceeded") }
    if (sets.size() > 1) { budget.reserveAdditionalDocumentSets(sets.size() - 1) }
    let ids = HashSet<String>()
    for (index in 0..sets.size()) {
        let item = sets.get(index).getOrThrow().asObject()
        let id = externalString(item, "id")
        if (id.isEmpty() || !ids.add(id)) { throw IllegalArgumentException("duplicate document set identity") }
        let publisherState = externalString(item, "state")
        if (!["unknown", "declared", "observed", "verified"].contains(publisherState)) {
            throw IllegalArgumentException("invalid document set evidence state")
        }
        let boundId = "cjdoc:external-document-set:v1:" + Sha256Digest.digest(id + "\n" + resolver.fingerprint + "\n" + resolver.baseUrl)
        resolver.documentSetIds[id] = boundId
        resolver.documentSets.add(DocumentSetIdentity(boundId, externalString(item, "library"),
            externalString(item, "identity"), if (publisherState == "unknown") { "unknown" } else { "declared" },
            externalString(item, "source"),
            target: externalString(item, "target"), cfg: externalString(item, "cfg"),
            audience: externalString(item, "audience", fallback: "external"),
            language: externalString(item, "language"), revision: externalString(item, "revision"),
            indexIdentity: resolver.fingerprint, baseUrl: resolver.baseUrl, moduleId: externalString(item, "moduleId"),
            apiVersion: externalString(item, "apiVersion"), documentationRevision: externalString(item, "documentationRevision")))
    }
}

internal func readExternalDependencyGraph(resolver: ExternalDocResolver, object: JsonObject,
    budget: ExternalDocInventoryBudget): Unit {
    let records = match (object.get("dependencies")) {
        case Some(value) => value.asArray()
        case None => return
    }
    if (records.size() > 16384) { throw IllegalArgumentException("external dependency graph edge budget exceeded") }
    budget.reserveDependencyEdges(records.size())
    let entries = ArrayList<DependencyInstance>()
    for (index in 0..records.size()) {
        let entry = records.get(index).getOrThrow().asObject()
        entries.add(DependencyInstance(externalString(entry, "moduleId"), externalString(entry, "name"),
            externalString(entry, "instanceId"), externalString(entry, "kind"), externalString(entry, "identity"),
            externalString(entry, "state"), externalString(entry, "evidence"), version: externalString(entry, "version"),
            revision: externalString(entry, "revision"), target: externalString(entry, "target"), cfg: externalString(entry, "cfg"),
            componentModuleId: externalString(entry, "componentModuleId")))
    }
    let graph = DependencyGraphIndex(entries)
    for (documentSet in resolver.documentSets) {
        if (let Some(declaration) <- graph.sourceDeclaration(documentSet.moduleId)) {
            if ((!documentSet.apiVersion.isEmpty() && !declaration.version.isEmpty() && documentSet.apiVersion != declaration.version) ||
                (!documentSet.revision.isEmpty() && !declaration.revision.isEmpty() && documentSet.revision != declaration.revision)) {
                throw IllegalArgumentException("document set package/source revision declaration contradicts its source snapshot")
            }
        }
    }
    resolver.sourceGraph = Some(graph)
}

private func addExternalDependencyKey(resolver: ExternalDocResolver, key: String, entry: ExternalDocEntry): Unit {
    if (key.isEmpty()) { return }
    match (resolver.entries.get(key)) {
        case Some(values) => values.add(entry)
        case None => resolver.entries[key] = ArrayList<ExternalDocEntry>([entry])
    }
}

private func validateInventoryNavigations(entry: JsonObject): Unit {
    for (key in ["typeNavigations", "references"]) {
        let rows = entry.get(key).getOrThrow().asArray()
        for (index in 0..rows.size()) {
            let node = rows.get(index).getOrThrow().asObject().get("navigation").getOrThrow()
            if (node.isNull) {
                if (key == "typeNavigations") { throw IllegalArgumentException("type navigation cannot be null") }
                continue
            }
            let value = inventory_codec.decodeNavigationDecision(node, "$.entries[]." + key + "[].navigation")
            if (!value.url.isEmpty() && !isSafeAbsoluteDocumentationUrl(value.url) &&
                !isSafeDocumentationRoute(value.url.removePrefix("./"))) {
                throw IllegalArgumentException("unsafe inventory navigation URL")
            }
        }
    }
}

internal func addDependencyExternalEntry(resolver: ExternalDocResolver, object: JsonObject): Unit {
    let setId = externalString(object, "documentSetId")
    let identity = externalString(object, "identity")
    var selected: ?DocumentSetIdentity = None
    for (item in resolver.documentSets) {
        if ((!setId.isEmpty() && item.id == resolver.documentSetIds.get(setId).getOrDefault({ => "" })) ||
            (setId.isEmpty() && item.identity == identity)) {
            if (selected.isSome()) { throw IllegalArgumentException("ambiguous entry document identity") }
            selected = Some(item)
        }
    }
    let documentSet = selected.getOrThrow()
    if (identity != documentSet.identity) { throw IllegalArgumentException("entry identity mismatch") }
    let visibility = externalString(object, "visibility")
    if ((documentSet.audience == "external" && visibility != "public" && visibility != "protected") ||
        (documentSet.audience == "package" && visibility == "private")) { return }
    validateInventoryNavigations(object)
    let packageName = externalString(object, "packageName")
    // Library includes the manifest organization; package names and portable
    // keys preserve source spelling. Only unqualified source packages may omit
    // that organization; qualified packages must still match it.
    var libraryNamespace = documentSet.library
    if (!packageName.contains("::")) {
        if (let Some(separator) <- libraryNamespace.indexOf("::")) {
            libraryNamespace = libraryNamespace[separator + 2..]
        }
    }
    if (packageName != libraryNamespace && !packageName.startsWith(libraryNamespace + ".")) {
        throw IllegalArgumentException("inventory symbol package is outside its library namespace")
    }
    let moduleId = externalString(object, "moduleId")
    if (!moduleId.isEmpty() && !documentSet.moduleId.isEmpty() && moduleId != documentSet.moduleId) {
        throw IllegalArgumentException("inventory symbol belongs to another producer module")
    }
    let url = safeExternalHref(resolver.baseUrl, externalString(object, "href")).getOrThrow()
    let name = externalString(object, "qualifiedName")
    let fullName = if (name.startsWith(packageName + ".")) { name }
        else { packageName + "." + name }
    let kind = externalString(object, "kind")
    let key = externalString(object, "symbolKey")
    if (key.isEmpty()) { throw IllegalArgumentException("inventory symbol key missing") }
    let prefix = fullName + "|" + kind + "|"
    if (!key.startsWith(prefix) || !key.endsWith(")")) {
        throw IllegalArgumentException("inventory portable symbol key contradicts its declaration identity")
    }
    var cursor = prefix.size
    var arity: Int64 = 0
    while (cursor < key.size && key[cursor] >= b'0' && key[cursor] <= b'9') {
        let digit = Int64(key[cursor] - b'0')
        if (arity > 922337203685477580 || (arity == 922337203685477580 && digit > 7)) {
            throw IllegalArgumentException("inventory generic arity exceeds the integer range")
        }
        arity = arity * 10 + digit
        cursor++
    }
    if (cursor == prefix.size || cursor >= key.size || key[cursor] != b'(' ||
        (cursor - prefix.size > 1 && key[prefix.size] == b'0') ||
        (["class", "struct", "interface", "enum", "typeAlias"].contains(kind) && cursor + 2 != key.size)) {
        throw IllegalArgumentException("inventory portable symbol key has invalid generic arity or declaration parameters")
    }
    if (!resolver.entryKeys.add(documentSet.id + "|" + key)) {
        throw IllegalArgumentException("duplicate portable inventory symbol key")
    }
    let entry = ExternalDocEntry(documentSet, key, fullName, url, kind, arity,
        sourceHeader: externalString(object, "sourceHeader"))
    addExternalDependencyKey(resolver, fullName, entry)
    addExternalDependencyKey(resolver, key, entry)
    // Explicit overload notation retains its exact parameter witness; bare names
    // remain multi-valued and are never silently resolved to the first overload.
    addExternalDependencyKey(resolver, fullName + key[cursor..], entry)
}

private func dependencySourceJson(path: Path, budget: ExternalDocInventoryBudget): JsonObject {
    let limit = budget.reserveFileBytes(path)
    JsonNode.parse(readTextBounded(path, limit),
        config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            maxDepth: 32, maxInputBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
            maxStringBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
            maxBufferedValueBytes: EXTERNAL_DOC_INDEX_MAX_BYTES)).asObject()
}

private func appendDependencyInventory(inventories: ArrayList<ExternalDocInventory>,
    path: Path, item: JsonObject): Unit {
    let relative = externalString(item, "index")
    if (!safeLocalExternalPath(relative)) { throw IllegalArgumentException("unsafe inventory path") }
    let inventory = path.parent.join(relative)
    ensureNoSymbolicLinkAncestors(inventory, "external inventory")
    let resolver = ExternalDocResolver("source-" + inventories.size.toString(), externalString(item, "baseUrl"),
        indexPath: relative)
    if (!safeDependencyExternalBase(resolver.baseUrl)) { throw IllegalArgumentException("unsafe inventory base URL") }
    if (let Some(priority) <- item.get("priority")) { resolver.priority = priority.asInt64() }
    if (resolver.priority < -1000 || resolver.priority > 1000) {
        throw IllegalArgumentException("source priority must be in -1000..1000")
    }
    readExternalCompatibilityMappings(resolver, item)
    inventories.add(ExternalDocInventory(resolver, inventory))
}

internal func loadDependencyDocSources(request: GenerationRequest): Array<ExternalDocResolver> {
    // Reject source-count overflow before even reading the legacy configuration.
    if (request.documentSources.size > 64) { throw IllegalArgumentException("documentation source budget exceeded") }
    let budget = ExternalDocInventoryBudget()
    let inventories = configuredExternalInventories(request.projectRoot, budget)
    for (configured in request.documentSources) {
        let source = if (Path(configured).isAbsolute()) { Path(configured) }
            else { Path(request.projectRoot).join(configured) }
        try {
            let path = if (FileInfo(source).isDirectory()) { source.join("cjdoc-documents.json") } else { source }
            let object = dependencySourceJson(path, budget)
            if (externalString(object, "schemaVersion") != "cjdoc.doc-sources/1") {
                throw IllegalArgumentException("documentation source catalog schema mismatch")
            }
            let documents = object.get("documents").getOrThrow().asArray()
            // Count all declarations, including missing/invalid inventories,
            // before opening any inventory. A rejected catalog is not expanded.
            budget.reserveInventories(documents.size())
            for (index in 0..documents.size()) {
                try {
                    appendDependencyInventory(inventories, path, documents.get(index).getOrThrow().asObject())
                } catch (_: Exception) {
                    inventories.add(ExternalDocInventory(ExternalDocResolver("source-invalid", "", state: "unavailable",
                        reason: "documentation inventory is invalid, unavailable or over budget"), path))
                }
            }
        } catch (_: Exception) {
            inventories.add(ExternalDocInventory(ExternalDocResolver("source-" + inventories.size.toString(), "",
                state: "unavailable", reason: "documentation source catalog is invalid, unavailable or over budget"), source))
        }
    }
    let pins = HashMap<String, String>()
    for (pin in request.documentInventoryPins) {
        let configured = if (Path(pin.path).isAbsolute()) { Path(pin.path) } else { Path(request.projectRoot).join(pin.path) }
        let path = try { canonicalize(configured).toString() } catch (_: Exception) { continue }
        if (let Some(previous) <- pins.get(path)) {
            if (previous != pin.sha256) { pins[path] = "" }
        } else { pins[path] = pin.sha256 }
    }
    for (inventory in inventories) {
        let path = try { canonicalize(inventory.path).toString() } catch (_: Exception) { continue }
        if (let Some(expected) <- pins.get(path)) {
            if (expected.isEmpty()) {
                inventory.resolver.state = "unavailable"
                inventory.resolver.reason = "conflicting independently supplied inventory pins"
            } else { inventory.resolver.expectedFingerprint = expected }
        }
    }
    loadExternalInventories(inventories, budget)
}

internal func dependencyCompatibilityKey(identity: String, target: String, cfg: String): String {
    let out = StringBuilder()
    for (part in [identity, target, cfg]) { out.append(part.size.toString()); out.append(":"); out.append(part) }
    out.toString()
}

internal func readExternalCompatibilityMappings(resolver: ExternalDocResolver, object: JsonObject): Unit {
    let mappings = match (object.get("compatibilityMappings")) {
        case Some(value) => value.asArray()
        case None => return
    }
    if (mappings.size() > 256) { throw IllegalArgumentException("compatibility mapping budget exceeded") }
    for (index in 0..mappings.size()) {
        let mapping = mappings.get(index).getOrThrow().asObject()
        let fromIdentity = externalString(mapping, "fromIdentity")
        let toIdentity = externalString(mapping, "toIdentity")
        if (fromIdentity.isEmpty() || toIdentity.isEmpty() || externalString(mapping, "evidence").isEmpty()) {
            throw IllegalArgumentException("compatibility mapping requires identities and evidence")
        }
        let key = dependencyCompatibilityKey(fromIdentity, externalString(mapping, "target"), externalString(mapping, "cfg"))
        if (resolver.compatibilityMappings.contains(key)) { throw IllegalArgumentException("duplicate compatibility mapping") }
        resolver.compatibilityMappings[key] = toIdentity
    }
}
