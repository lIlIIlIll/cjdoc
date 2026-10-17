package cjdoc

import std.collection.*
import std.fs.*
import yjson.*
import cjdoc.model.*

internal let EXTERNAL_DOC_INDEX_MAX_BYTES: Int64 = 8 * 1024 * 1024
internal let EXTERNAL_DOC_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let EXTERNAL_DOC_TOTAL_MAX_BYTES: Int64 = 32 * 1024 * 1024

// One generation owns this budget, including catalogs and legacy inventories.
// Reservations survive failed reads/parses: malformed inputs cannot reset it.
internal class ExternalDocInventoryBudget {
    private var bytes: Int64 = 0
    private var inventories: Int64 = 0
    private var documentSets: Int64 = 0
    private var dependencyEdges: Int64 = 0

    func reserveInventories(count: Int64): Unit {
        if (count < 0 || count > 256 - inventories || count > 256 - documentSets) {
            throw IllegalArgumentException("documentation set budget exceeded")
        }
        inventories += count
        documentSets += count
    }

    func reserveAdditionalDocumentSets(count: Int64): Unit {
        if (count < 0 || count > 256 - documentSets) {
            throw IllegalArgumentException("documentation set budget exceeded")
        }
        documentSets += count
    }

    func reserveDependencyEdges(count: Int64): Unit {
        if (count < 0 || count > 100000 - dependencyEdges) {
            throw IllegalArgumentException("external dependency graph edge budget exceeded")
        }
        dependencyEdges += count
    }

    func reserveFileBytes(path: Path): Int64 {
        let info = FileInfo(path)
        let size = info.size
        if (!info.isRegular() || info.isSymbolicLink() || size < 0 ||
            size > EXTERNAL_DOC_INDEX_MAX_BYTES || size > EXTERNAL_DOC_TOTAL_MAX_BYTES - bytes) {
            throw IllegalArgumentException("external inventory byte budget exceeded")
        }
        bytes += size
        size
    }
}

internal class ExternalDocInventory {
    let resolver: ExternalDocResolver
    let path: Path
    var readLimit: Int64 = -1
    init(resolver: ExternalDocResolver, path: Path) {
        this.resolver = resolver; this.path = path
    }
}

internal class ExternalDocResolver {
    public let name: String
    public let baseUrl: String
    public let version: ?String
    public let indexPath: String
    public var fingerprint: String
    public var format: String
    public var state: String
    public var reason: String
    public var legacyReference: Bool = false
    public var expectedFingerprint: String = ""
    public var inventoryPinned: Bool = false
    public var sourceGraph: ?DependencyGraphIndex = None
    private let targets = HashMap<String, String>()
    public let documentSets = ArrayList<DocumentSetIdentity>()
    public let entries = HashMap<String, ArrayList<ExternalDocEntry>>()
    public let documentSetIds = HashMap<String, String>()
    public let entryKeys = HashSet<String>()
    public var priority: Int64 = 0
    public let compatibilityMappings = HashMap<String, String>()

    init(name: String, baseUrl: String, state!: String = "available", reason!: String = "",
        version!: ?String = None, indexPath!: String = "", fingerprint!: String = "", format!: String = "") {
        this.name = name
        this.baseUrl = baseUrl
        this.version = version
        this.indexPath = indexPath
        this.fingerprint = fingerprint
        this.format = format
        this.state = state
        this.reason = reason
    }

    func addTarget(key: String, url: String): Unit {
        if (key.isEmpty()) { return }
        match (targets.get(key)) {
            case Some(existing) => if (existing != url) { targets[key] = "" }
            case None => targets[key] = url
        }
    }

    func matchTarget(target: String): (String, Bool) {
        match (targets.get(target)) {
            case Some(url) => (url, url.isEmpty())
            case None => ("", false)
        }
    }
}

private func externalTomlValue(value: String): String {
    var cleaned = value.trimAscii()
    match (cleaned.indexOf("#")) {
        case Some(index) => cleaned = cleaned[..index].trimAscii()
        case None => ()
    }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        return cleaned.removePrefix("\"").removeSuffix("\"")
    }
    cleaned
}


private func safeExternalBaseUrl(value: String): Bool {
    safeDependencyExternalBase(value)
}

internal func safeExternalHref(baseUrl: String, href: String): ?String {
    safeDependencyExternalHref(baseUrl, href)
}

private func externalIndexLabel(value: String): String {
    if (value.startsWith("/") || value.contains(":")) { return "configured index" }
    value
}

private func externalDocFingerprint(value: String): String {
    contractFingerprint(value)
}

private func jsonObjectField(object: JsonObject, key: String): ?JsonNode {
    object.get(key)
}

private func jsonStringField(object: JsonObject, key: String): ?String {
    match (jsonObjectField(object, key)) {
        case Some(value) => try { Some(value.asString()) } catch (_: Exception) { None }
        case None => None
    }
}


private func addExternalEntry(resolver: ExternalDocResolver, object: JsonObject): Unit {
    let href = match (jsonStringField(object, "href")) {
        case Some(value) => value
        case None => return
    }
    let url = match (safeExternalHref(resolver.baseUrl, href)) {
        case Some(value) => value
        case None => return
    }
    for (key in ["id", "canonicalId", "qualifiedName", "name"]) {
        match (jsonStringField(object, key)) {
            case Some(value) => resolver.addTarget(value, url)
            case None => ()
        }
    }
}

private func parseExternalIndex(resolver: ExternalDocResolver, indexText: String,
    budget: ExternalDocInventoryBudget): Unit {
    resolver.fingerprint = externalDocFingerprint(indexText)
    if (!resolver.expectedFingerprint.isEmpty() && resolver.fingerprint != resolver.expectedFingerprint) {
        resolver.state = "unavailable"
        resolver.reason = "inventory SHA-256 does not match the independently supplied host pin"
        return
    }
    resolver.inventoryPinned = !resolver.expectedFingerprint.isEmpty()
    let parsed = JsonNode.parse(indexText,
        config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            maxDepth: 32, maxStringBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
            maxBufferedValueBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
            maxInputBytes: EXTERNAL_DOC_INDEX_MAX_BYTES))
    let object = parsed.asObject()
    let schemaVersion = jsonStringField(object, "schemaVersion").getOrDefault({ => "" })
    resolver.format = schemaVersion
    if (schemaVersion != "cjdoc.symbol-index/1" && schemaVersion != "cjdoc.symbol-index/2") {
        resolver.state = "unavailable"
        resolver.reason = "external documentation index schema is stale"
        return
    }
    if (schemaVersion == "cjdoc.symbol-index/2") { readExternalDocumentSets(resolver, object, budget) }
    if (schemaVersion == "cjdoc.symbol-index/2") { readExternalDependencyGraph(resolver, object, budget) }
    if (let Some(version) <- resolver.version) {
        if (jsonStringField(object, "version") != Some(version)) {
            resolver.state = "unavailable"
            resolver.reason = "external documentation index version is stale"
            return
        }
    }
    let entries = match (jsonObjectField(object, "symbols")) {
        case Some(value) => value.asArray()
        case None => object.get("entries").getOrThrow().asArray()
    }
    if (entries.size() > 32768) { throw IllegalArgumentException("external index entry budget exceeded") }
    for (index in 0..entries.size()) {
        let entry = entries.get(index).getOrThrow().asObject()
        if (schemaVersion == "cjdoc.symbol-index/2") { addDependencyExternalEntry(resolver, entry) }
        else { addExternalEntry(resolver, entry) }
    }
}

internal func loadExternalInventories(inventories: ArrayList<ExternalDocInventory>,
    budget: ExternalDocInventoryBudget): Array<ExternalDocResolver> {
    // Preflight every admitted inventory before opening any of them. A missing
    // or oversized index leaves later, independent inventories eligible.
    for (inventory in inventories where inventory.resolver.state == "available") {
        try {
            inventory.readLimit = budget.reserveFileBytes(inventory.path)
        } catch (_: Exception) {
            inventory.resolver.state = "unavailable"
            inventory.resolver.reason = "external documentation index is missing, unsafe or over budget"
        }
    }
    let result = ArrayList<ExternalDocResolver>()
    for (inventory in inventories) {
        let resolver = inventory.resolver
        if (resolver.state == "available") {
            try {
                parseExternalIndex(resolver, readTextBounded(inventory.path, inventory.readLimit), budget)
            } catch (_: Exception) {
                resolver.state = "unavailable"
                resolver.reason = "external documentation index is invalid or over budget"
            }
        }
        result.add(resolver)
    }
    result.toArray()
}

private func appendExternalInventory(result: ArrayList<ExternalDocInventory>, projectRoot: String,
    name: String, indexPath: String, baseUrl: String, version: ?String): Unit {
    if (name.isEmpty() || result.size > 256) { return }
    let resolver = ExternalDocResolver(name, baseUrl, version: version, indexPath: externalIndexLabel(indexPath))
    resolver.legacyReference = true
    if (result.size == 256) {
        resolver.state = "unavailable"
        resolver.reason = "documentation set budget exceeded"
    } else if (indexPath.isEmpty() || baseUrl.isEmpty()) {
        resolver.state = "unavailable"
        resolver.reason = "external documentation configuration is incomplete"
    } else if (!safeExternalBaseUrl(baseUrl)) {
        resolver.state = "unavailable"
        resolver.reason = "external documentation base URL is unsafe"
    }
    let path = if (indexPath.startsWith("/") || indexPath.contains(":")) { Path(indexPath) }
        else { Path(projectRoot).join(indexPath) }
    result.add(ExternalDocInventory(resolver, path))
}

internal func configuredExternalInventories(projectRoot: String,
    budget: ExternalDocInventoryBudget): ArrayList<ExternalDocInventory> {
    let result = ArrayList<ExternalDocInventory>()
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return result }
    let text = readTextBounded(path, EXTERNAL_DOC_CONFIG_MAX_BYTES)
    var section = ""
    var name = ""
    var indexPath = ""
    var baseUrl = ""
    var version: ?String = None
    for (rawLine in text.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            if (section.startsWith("external-docs.")) {
                appendExternalInventory(result, projectRoot, name, indexPath, baseUrl, version)
                name = ""
                indexPath = ""
                baseUrl = ""
                version = None
            }
            section = line.removePrefix("[").removeSuffix("]").trimAscii()
            if (section.startsWith("external-docs.")) { name = section.removePrefix("external-docs.") }
            continue
        }
        if (!section.startsWith("external-docs.")) { continue }
        let parts = line.split("=", 2)
        if (parts.size != 2) { continue }
        let key = parts[0].trimAscii()
        let value = externalTomlValue(parts[1])
        match (key) {
            case "index" => indexPath = value
            case "base-url" => baseUrl = if (value.endsWith("/")) { value[..value.size - 1] } else { value }
            case "version" => version = Some(value)
            case _ => ()
        }
    }
    if (section.startsWith("external-docs.")) {
        appendExternalInventory(result, projectRoot, name, indexPath, baseUrl, version)
    }
    budget.reserveInventories(if (result.size > 256) { 256 } else { result.size })
    result
}

internal func loadExternalDocResolvers(projectRoot: String): Array<ExternalDocResolver> {
    let budget = ExternalDocInventoryBudget()
    loadExternalInventories(configuredExternalInventories(projectRoot, budget), budget)
}
