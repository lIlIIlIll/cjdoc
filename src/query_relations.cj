package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// Bounded relationship expansion over captured evidence only. A walk starts at a
// captured symbol identity and follows captured symbol/type relationships and
// owner links. A different loaded snapshot is entered only when it was named in
// `relatedSnapshotIds` and a captured resolved navigation binds the target's own
// portable key and document-set identity. Bare names are never used as equality.

internal let QUERY_RELATION_MAX_DEPTH: Int64 = 4
internal let QUERY_RELATION_MAX_LIMIT: Int64 = 100
internal let QUERY_RELATION_DEFAULT_DEPTH: Int64 = 1
internal let QUERY_RELATION_DEFAULT_LIMIT: Int64 = 25
internal let QUERY_RELATION_ITEM_MIN_BYTES: Int64 = 96

internal class QueryRelationRequest {
    let direction: String
    let kinds: HashSet<String>
    let depth: Int64
    let limit: Int64

    init(direction: String, kinds: HashSet<String>, depth: Int64, limit: Int64) {
        this.direction = direction
        this.kinds = kinds
        this.depth = depth
        this.limit = limit
    }

    func admitsDirection(edgeDirection: String): Bool {
        direction == "both" || direction == edgeDirection
    }

    func admitsKind(kind: String): Bool {
        kinds.isEmpty() || kinds.contains(kind)
    }
}

internal func queryRelationRequest(request: JsonObject): QueryRelationRequest {
    let object = match (request.get("relations")) {
        case Some(value) => value.asObject()
        case None => JsonNode.object()
    }
    let direction = queryString(object, "direction", fallback: "both")
    if (direction != "outgoing" && direction != "incoming" && direction != "both") {
        throw DocumentationQueryException("invalid_request", "relation_direction",
            "Relation direction must be outgoing, incoming or both.")
    }
    let kinds = HashSet<String>()
    for (kind in queryStrings(object, "kinds")) { let _ = kinds.add(kind) }
    let depth = queryClamp(queryInt(object, "depth", fallback: QUERY_RELATION_DEFAULT_DEPTH),
        0, QUERY_RELATION_MAX_DEPTH)
    let limit = queryClamp(queryInt(object, "limit", fallback: QUERY_RELATION_DEFAULT_LIMIT),
        0, QUERY_RELATION_MAX_LIMIT)
    QueryRelationRequest(direction, kinds, depth, limit)
}

/** One queued walk position: a captured identity plus the depth reached. */
internal class QueryRelationStep {
    let input: QuerySnapshotInput
    let document: QueryDocument
    let symbolId: String
    let depth: Int64

    init(input: QuerySnapshotInput, document: QueryDocument, symbolId: String, depth: Int64) {
        this.input = input
        this.document = document
        this.symbolId = symbolId
        this.depth = depth
    }
}

internal class QueryRelationBuild {
    let relations = ArrayList<JsonObject>()
    let omitted = ArrayList<JsonObject>()
    var nextOffset: ?Int64 = None
    var complete = true
    var truncated = false
    var depthTruncated = false
    var limitTruncated = false
    var bytesTruncated = false
    var usedBytes: Int64 = 0

    func add(item: JsonObject): Unit {
        usedBytes += item.toJson().size
        relations.add(item)
    }
}

/**
 * Expand the captured relationships of one visible declaration.
 *
 * Cycles and duplicates are removed by (snapshot, SymbolId), preserving each
 * item's own snapshot and document-set identity. At the depth, count or byte
 * boundary the build records an explicit omission plus a real continuation.
 */
internal func queryRelations(catalog: QueryCatalog, root: QueryDocument,
    rootSymbol: query_model.SymbolDoc, request: JsonObject, budgetBytes: Int64,
    startingOffset: Int64, catalogId: String): QueryRelationBuild {
    let build = QueryRelationBuild()
    let spec = queryRelationRequest(request)
    let requestBytes = queryInt(request, "maxBytes", fallback: QUERY_DEFAULT_BYTES)
    if (spec.depth == 0) {
        build.complete = false
        build.omitted.add(queryOmission("relations", "relation_depth",
            Some(queryRetryNode(requestBytes, "relations.depth is 0; request depth 1..${QUERY_RELATION_MAX_DEPTH}."))))
        return build
    }
    if (spec.limit == 0) {
        build.complete = false
        build.omitted.add(queryOmission("relations", "relation_limit",
            Some(queryRetryNode(requestBytes, "relations.limit is 0; request 1..${QUERY_RELATION_MAX_LIMIT}."))))
        return build
    }
    let related = queryRelatedSnapshots(catalog, request)
    let queue = ArrayList<QueryRelationStep>()
    queue.add(QueryRelationStep(root.input, root, rootSymbol.id, 0))
    let visited = HashSet<String>()
    let _ = visited.add(root.input.snapshot.snapshotId + "\n" + rootSymbol.id)
    var cursor: Int64 = 0
    var emitted: Int64 = 0
    var skip = startingOffset
    while (cursor < queue.size && !build.truncated) {
        let step = queue[cursor]
        cursor++
        if (step.depth >= spec.depth) { continue }
        let edges = queryStepEdges(step, spec, related)
        for (edge in edges) {
            if (skip > 0) {
                skip--
                queryQueueTarget(queue, step, edge, spec, related, visited)
                continue
            }
            let item = queryRelationItem(step, edge, related)
            let itemBytes = item.toJson().size
            if (emitted == 0 && itemBytes > budgetBytes) {
                let required = requestBytes - budgetBytes + itemBytes
                build.complete = false
                let next: ?JsonNode = if (required <= QUERY_MAX_BYTES) {
                    Some(queryRetryNode(required,
                        "Retry from the beginning without cursor and maxBytes at least ${required}."))
                } else { None }
                build.omitted.add(queryOmission("relations",
                    if (next.isSome()) { "budget" } else { "resource_limit" }, next))
                return build
            }
            if (emitted >= spec.limit || build.usedBytes + itemBytes > budgetBytes) {
                build.truncated = true
                build.complete = false
                build.nextOffset = Some(startingOffset + emitted)
                if (emitted >= spec.limit) { build.limitTruncated = true } else { build.bytesTruncated = true }
                break
            }
            build.add(item)
            emitted++
            queryQueueTarget(queue, step, edge, spec, related, visited)
        }
    }
    if (skip > 0) {
        throw DocumentationQueryException("stale_cursor", "cursor_range",
            "The relation continuation offset exceeds this frozen bounded walk.")
    }
    if (!build.truncated && !queue.isEmpty()) {
        for (position in 0..queue.size) {
            let step = queue[position]
            if (step.depth >= spec.depth && !queryStepEdges(step, spec, related).isEmpty()) {
                build.depthTruncated = true
            }
        }
    }
    if (build.depthTruncated) {
        let next: ?JsonNode = if (spec.depth < QUERY_RELATION_MAX_DEPTH) {
            Some(queryRetryNode(requestBytes, "Increase relations.depth up to ${QUERY_RELATION_MAX_DEPTH}."))
        } else { None }
        build.omitted.add(queryOmission("relations",
            if (next.isSome()) { "relation_depth" } else { "resource_limit" }, next))
    }
    if (build.limitTruncated) {
        build.omitted.add(queryOmission("relations", "relation_limit",
            Some(queryRetryNode(requestBytes, "Continue with cursor ${queryNextCursor(request, catalogId, build.nextOffset.getOrThrow())} and the identical request."))))
    }
    if (build.bytesTruncated) {
        build.omitted.add(queryOmission("relations", "budget",
            Some(queryRetryNode(requestBytes, "Continue with cursor ${queryNextCursor(request, catalogId, build.nextOffset.getOrThrow())} and the identical request; a changed budget requires restarting without cursor."))))
    }
    build
}

private func queryStepEdges(step: QueryRelationStep, spec: QueryRelationRequest,
    related: ArrayList<QueryDocument>): ArrayList<QueryEdge> {
    let result = queryDocumentEdges(step.document, step.symbolId, spec)
    if (let Some(symbol) <- step.input.symbols.get(step.symbolId)) {
        for (edge in queryNavigationEdges(step.document, symbol, related, spec)) { result.add(edge) }
    }
    result
}


private func queryDocumentEdges(document: QueryDocument, symbolId: String,
    spec: QueryRelationRequest): ArrayList<QueryEdge> {
    let result = ArrayList<QueryEdge>()
    if (spec.admitsDirection("outgoing")) {
        if (let Some(values) <- document.outgoing.get(symbolId)) {
            for (edge in values) { if (spec.admitsKind(edge.kind)) { result.add(edge) } }
        }
    }
    if (spec.admitsDirection("incoming")) {
        if (let Some(values) <- document.incoming.get(symbolId)) {
            for (edge in values) { if (spec.admitsKind(edge.kind)) { result.add(edge) } }
        }
    }
    result
}

private func queryQueueTarget(queue: ArrayList<QueryRelationStep>, step: QueryRelationStep,
    edge: QueryEdge, spec: QueryRelationRequest,
    related: ArrayList<QueryDocument>, visited: HashSet<String>): Unit {
    if (step.depth + 1 > spec.depth) { return }
    let targetId = match (edge.targetId) {
        case Some(value) => value
        case None => return
    }
    let targetDocument = match (queryEdgeDocument(step, edge, related)) {
        case Some(value) => value
        case None => return
    }
    if (!targetDocument.visibleIds.contains(targetId)) { return }
    let key = targetDocument.input.snapshot.snapshotId + "\n" + targetId
    if (!visited.add(key)) { return }
    queue.add(QueryRelationStep(targetDocument.input, targetDocument, targetId, step.depth + 1))
}

// The document an edge actually points into: the current snapshot unless the
// edge was bound into an explicitly selected related snapshot.
private func queryEdgeDocument(step: QueryRelationStep, edge: QueryEdge,
    related: ArrayList<QueryDocument>): ?QueryDocument {
    let targetId = match (edge.targetId) {
        case Some(value) => value
        case None => return None
    }
    if (edge.targetSnapshotId.isNone()) {
        return if (step.document.visibleIds.contains(targetId)) { Some(step.document) } else { None }
    }
    for (document in related) {
        if (Some(document.input.snapshot.snapshotId) == edge.targetSnapshotId &&
            document.visibleIds.contains(targetId)) { return Some(document) }
    }
    None
}

// Local SymbolIds may be identical in unrelated snapshots. Never index these
// documents by a bare local id or pick the first matching content observation.
private func queryRelatedSnapshots(catalog: QueryCatalog,
    request: JsonObject): ArrayList<QueryDocument> {
    let selected = HashSet<String>()
    for (id in queryStrings(request, "relatedSnapshotIds")) { let _ = selected.add(id) }
    let result = ArrayList<QueryDocument>()
    let observed = HashSet<String>()
    for (document in catalog.documents) {
        let input = document.input
        if (!selected.contains(input.snapshot.snapshotId) && !selected.contains(input.sourceSnapshotId)) { continue }
        observed.add(input.snapshot.snapshotId)
        observed.add(input.sourceSnapshotId)
        result.add(document)
    }
    for (id in selected where !observed.contains(id)) {
        throw DocumentationQueryException("scope_mismatch", "related_snapshot_not_loaded",
            "An explicitly requested related snapshot is not loaded in the selected projection.")
    }
    result
}

private func queryNavigationEdges(source: QueryDocument, symbol: query_model.SymbolDoc,
    related: ArrayList<QueryDocument>, spec: QueryRelationRequest): ArrayList<QueryEdge> {
    let result = ArrayList<QueryEdge>()
    if (!spec.admitsDirection("outgoing") || related.isEmpty()) { return result }
    let navigations = ArrayList<(String, String, query_model.TypeNavigation)>()
    for (relationship in symbol.typeRelationships) {
        if (let Some(navigation) <- relationship.target.navigation) {
            navigations.add((relationship.kind, relationship.target.spelling, navigation))
        }
    }
    if (let Some(comment) <- symbol.documentation) {
        for (tag in comment.tags) {
            if (let Some(navigation) <- tag.navigation) {
                navigations.add((tag.name, tag.subject, navigation))
            }
        }
    }
    for ((kind, display, navigation) in navigations) {
        if (!spec.admitsKind(kind) || navigation.state != "resolved") { continue }
        let matches = ArrayList<(QueryDocument, query_model.SymbolDoc)>()
        for (document in related) {
            if (document.input.snapshot.snapshotId == source.input.snapshot.snapshotId) { continue }
            for (target in document.visibleSymbols) {
                if (document.input.symbolKeys[target.id] != navigation.symbolKey) { continue }
                if (queryNavigationScopeMatches(document, target.moduleId, navigation)) {
                    matches.add((document, target))
                }
            }
        }
        if (matches.size == 1) {
            let (document, target) = matches[0]
            result.add(QueryEdge(kind, "outgoing", Some(target.id), display, "resolved",
                navigation.reason, targetSnapshotId: Some(document.input.snapshot.snapshotId),
                navigation: Some(navigation)))
        } else {
            result.add(QueryEdge(kind, "outgoing", Option<String>.None, display,
                if (matches.isEmpty()) { "unavailable" } else { "ambiguous" },
                if (matches.isEmpty()) { "Captured API identity and portable key do not bind an explicitly selected related snapshot." }
                else { "Multiple selected snapshots bind the captured API identity and portable key; select one snapshot explicitly." },
                navigation: Some(navigation)))
        }
    }
    result
}

private func queryNavigationScopeMatches(document: QueryDocument, moduleId: String,
    navigation: query_model.TypeNavigation): Bool {
    let documentSet = match (queryDocumentSetFor(document.input, moduleId)) {
        case Some(value) => value
        case None => return false
    }
    // Producer-local document-set ids are not portable between root and
    // dependency captures. The captured API identity and portable key are.
    !navigation.apiIdentity.isEmpty() && navigation.apiIdentity == documentSet.identity &&
        !navigation.symbolKey.isEmpty()
}

private func queryRelationItem(step: QueryRelationStep, edge: QueryEdge,
    related: ArrayList<QueryDocument>): JsonObject {
    let item = JsonNode.object()
    item.put("kind", JsonNode.string(edge.kind))
    item.put("direction", JsonNode.string(edge.direction))
    item.put("depth", JsonNode.int64(step.depth + 1))
    item.put("from", queryIdentityNode(step.input, Some(step.symbolId), Option<String>.None))
    item.put("source", JsonNode.nullValue)
    match (edge.targetId) {
        case Some(targetId) =>
            let targetDocument = queryEdgeDocument(step, edge, related)
            item.put("to", match (targetDocument) {
                case Some(document) =>
                    if (let Some(target) <- document.bySymbolId.get(targetId)) {
                        item.put("source", querySymbolSource(document.input, target))
                    }
                    queryIdentityNode(document.input, Some(targetId), Option<String>.None)
                case None => JsonNode.nullValue
            })
        case None => item.put("to", JsonNode.nullValue)
    }
    item.put("state", JsonNode.string(edge.state))
    item.put("reason", JsonNode.string(edge.reason))
    let navigation = StringBuilder()
    query_render.appendTypeNavigation(navigation, edge.navigation)
    item.put("navigation", JsonNode.parse(navigation.toString()))
    item
}
