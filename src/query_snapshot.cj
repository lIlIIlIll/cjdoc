package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

internal class QueryDocumentScope {
    let original: query_model.DocumentSetIdentity
    let inventory: query_model.DocumentSetIdentity

    init(original: query_model.DocumentSetIdentity, inventory: query_model.DocumentSetIdentity) {
        this.original = original
        this.inventory = inventory
    }
}

internal func querySnapshotJson(text: String): JsonObject {
    JsonNode.parse(text, config: JsonReadOptions(maxInputBytes: QUERY_MAX_BYTES,
        maxStringBytes: QUERY_MAX_BYTES, maxBufferedValueBytes: QUERY_MAX_BYTES, maxDepth: 128)).asObject()
}

internal func queryOptionalString(value: JsonObject, key: String): ?String {
    match (value.get(key)) {
        case Some(node) => if (node.isNull) { None } else { Some(node.asString()) }
        case None => None
    }
}

// Every member is created from captured validated bytes. This class has no
// source/SDK lookup and exposes no path-based re-observation to query handlers.
internal class QuerySnapshotInput {
    let snapshot: query_render.DocumentationReadSnapshot
    let documentation: query_model.DocumentationSet
    let raw: JsonObject
    let sourceKind: String
    let sourceIdentity: String
    let sourceSnapshotId: String
    let packagedRepresentations: Bool
    let isLatest: Bool
    let inventory: ExternalDocResolver
    let scopes = ArrayList<QueryDocumentScope>()
    let symbols = HashMap<String, query_model.SymbolDoc>()
    let symbolNodes = HashMap<String, JsonObject>()
    let symbolKeys = HashMap<String, String>()
    let pages = HashMap<String, query_model.DocumentationPage>()
    let pageNodes = HashMap<String, JsonObject>()
    let attachments: JsonArray
    let graph: DependencyGraphIndex
    let importContexts: JsonArray
    let pageModules: HashMap<String, ?String>
    let capturedNavigations = HashMap<String, ArrayList<JsonObject>>()

    init(snapshot: query_render.DocumentationReadSnapshot, sourceKind: String, sourceIdentity: String,
        sourceSnapshotId!: String = "", packagedRepresentations!: Bool = false,
        inventoryPinned!: Bool = false, inventoryText!: ?String = None,
        isLatest!: Bool = false, attachments!: ?JsonArray = None) {
        this.snapshot = snapshot
        this.documentation = snapshot.documentation
        this.raw = querySnapshotJson(snapshot.encodedDocumentation)
        this.sourceKind = sourceKind
        this.sourceIdentity = sourceIdentity
        this.sourceSnapshotId = if (sourceSnapshotId.isEmpty()) { snapshot.snapshotId } else { sourceSnapshotId }
        this.packagedRepresentations = packagedRepresentations
        this.isLatest = isLatest
        this.attachments = attachments.getOrDefault({ => JsonArray() })
        let inventoryJson = inventoryText.getOrDefault({ => snapshot.renderSymbolInventory() })
        inventory = ExternalDocResolver("loaded-snapshot", "", fingerprint: query_model.contractFingerprint(inventoryJson),
            format: "cjdoc.symbol-index/2")
        inventory.inventoryPinned = inventoryPinned
        let inventoryRoot = querySnapshotJson(inventoryJson)
        // Module IDs are local to a document set. Imported inventories may also
        // contain a "root", but their source graph is not this snapshot's graph.
        // Normalize only the sets that actually own the loaded declarations.
        let localSets = JsonNode.array()
        for (module in documentation.modules) {
            if (let Some(original) <- snapshot.documentSetForModule(module.id)) {
                localSets.add(queryDocumentSetNode(original))
            }
        }
        inventoryRoot.put("documentSets", localSets)
        let budget = ExternalDocInventoryBudget()
        budget.reserveInventories(1)
        readExternalDocumentSets(inventory, inventoryRoot, budget)
        readExternalDependencyGraph(inventory, inventoryRoot, budget)
        for (module in documentation.modules) {
            if (let Some(original) <- snapshot.documentSetForModule(module.id)) {
                if (let Some(boundId) <- inventory.documentSetIds.get(original.id)) {
                    for (published in inventory.documentSets where published.id == boundId) {
                        scopes.add(QueryDocumentScope(original, published))
                    }
                }
            }
        }
        for (symbol in documentation.declarations) {
            symbols[symbol.id] = symbol
            symbolKeys[symbol.id] = queryPortableSymbolKey(symbol)
        }
        let declarations = raw.get("declarations").getOrThrow().asArray()
        for (index in 0..declarations.size()) {
            let node = declarations[index].asObject()
            symbolNodes[queryString(node, "id")] = node
        }
        let rawPages = HashMap<String, JsonObject>()
        if (let Some(values) <- raw.get("pages")) {
            let nodes = values.asArray()
            for (index in 0..nodes.size()) {
                let node = nodes[index].asObject()
                rawPages[queryPageKey(queryString(node, "id"), queryString(node, "source"), queryOptionalString(node, "language"))] = node
            }
        }
        let selectedPages = snapshot.selectedPages()
        pageModules = queryCapturedPageModules(documentation, selectedPages)
        for (page in selectedPages) {
            pages[page.id] = page
            if (let Some(node) <- rawPages.get(queryPageKey(page.id, page.source, page.language))) { pageNodes[page.id] = node }
        }
        graph = DependencyGraphIndex(ArrayList<query_model.DependencyInstance>(documentation.dependencies.toArray()))
        importContexts = queryCapturedImportContexts(raw, snapshot)
        collectQueryNavigations(raw, capturedNavigations)
    }

    func scopeForModule(moduleId: String): ?QueryDocumentScope {
        for (scope in scopes where scope.original.moduleId == moduleId) { return Some(scope) }
        None
    }
}

internal func queryNavigationEvidenceKey(instance: String, identity: String, index: String): String {
    instance + "\n" + identity + "\n" + index
}

private func collectQueryNavigations(node: JsonNode,
    result: HashMap<String, ArrayList<JsonObject>>): Unit {
    match (node) {
        case object: JsonObject =>
            if (object.get("dependencyInstanceId").isSome() && object.get("apiIdentity").isSome() &&
                object.get("indexIdentity").isSome() && object.get("matchLevel").isSome()) {
                let key = queryNavigationEvidenceKey(queryString(object, "dependencyInstanceId"),
                    queryString(object, "apiIdentity"), queryString(object, "indexIdentity"))
                let entries = result.get(key).getOrDefault({ => ArrayList<JsonObject>() })
                var duplicate = false
                for (entry in entries) {
                    if (queryString(entry, "documentSetId") == queryString(object, "documentSetId") &&
                        queryString(entry, "matchLevel") == queryString(object, "matchLevel")) { duplicate = true; break }
                }
                if (!duplicate) { entries.add(object) }
                result[key] = entries
            }
            for (index in 0..object.size()) { collectQueryNavigations(object.valueAt(index), result) }
        case array: JsonArray =>
            for (index in 0..array.size()) { collectQueryNavigations(array[index], result) }
        case _ => ()
    }
}

private func queryPageKey(id: String, source: String, language: ?String): String {
    id + "\n" + source + "\n" + language.getOrDefault({ => "" })
}

internal func querySnapshotMatches(input: QuerySnapshotInput, request: JsonObject): Bool {
    let snapshotId = queryString(request, "snapshotId")
    if (!snapshotId.isEmpty() && snapshotId != input.snapshot.snapshotId && snapshotId != input.sourceSnapshotId) { return false }
    let audience = queryString(request, "audience")
    if (!audience.isEmpty() && audience != input.documentation.configuration.audience) { return false }
    let language = queryString(request, "language")
    if (!language.isEmpty() && language != input.snapshot.locale && !queryBool(request, "languageFallback")) { return false }
    let cfgProfile = queryString(request, "cfgProfile")
    if (!cfgProfile.isEmpty() && cfgProfile != input.documentation.configuration.cfgProfile) { return false }
    true
}
