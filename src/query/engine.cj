protected package cjdoc.query

import cjdoc.render.agent as agent_render

import cjdoc.render.search as search_engine
import cjdoc.model as query_model
import std.collection.*
import std.sort.*
import std.sync.*
import yjson.*

/**
 * Operation dispatch over one frozen, already loaded documentation catalog.
 *
 * Every snapshot, inventory, dependency graph and report was captured before this
 * class exists, so dispatch never scans source, chooses an SDK, downloads a
 * dependency, compiles a consumer or reaches the network. The same parsed request
 * and the same frozen inputs therefore always produce the same object.
 *
 * The most recent language/audience projection is cached under a lock. Replaced
 * views remain immutable for callers already using them; cache memory cannot grow
 * with arbitrary request strings. `dispatch` supports concurrent calls. Request
 * validation, the failure envelope and the published exit status belong to the
 * public session; this class never decides how a rejected request is reported.
 */
protected class QueryExecution {
    private let baseInputs: ArrayList<QuerySnapshotInput>
    private let baseCatalogId: String
    private let contentIdentity: String
    private let lock = ReentrantMutex()
    private var projectionKey = ""
    private var cachedProjection: ?QueryProjection = None

    /** Dispatch over the frozen inputs this catalog was loaded from. */
    protected init(inputs: ArrayList<QuerySnapshotInput>) {
        baseInputs = inputs
        baseCatalogId = documentationQueryCatalogId(inputs)
        contentIdentity = queryContentIdentity(baseCatalogId, inputs)
    }

    /** Dispatch one already validated `cjdoc.query-request/3` object. */
    protected func dispatch(request: JsonObject): JsonObject {
        let operation = queryString(request, "operation")
        // A named snapshot is resolved against the frozen catalog first, so the
        // language/audience projection cannot change which identity was asked for.
        let baseSelected = querySelectSnapshots(baseInputs, request)
        if (baseSelected.isEmpty()) {
            throw DocumentationQueryException("scope_mismatch", "snapshot_unavailable",
                "The requested documentation scope is not loaded in this query catalog.")
        }
        let contextSelected = querySelectContextSnapshots(baseInputs, baseSelected, request)
        let narrowed = projectionFor(request, contextSelected)
        var primaryVisible = false
        for (input in narrowed.inputs) {
            if (querySnapshotMatches(input, request)) { primaryVisible = true; break }
        }
        if (!primaryVisible) {
            throw DocumentationQueryException("scope_mismatch", "projection_unavailable",
                "The requested language, audience or cfg profile is outside the loaded documentation.")
        }
        if (operation == "resolve_docs") {
            return synchronized(lock) { resolveDocumentationQuery(narrowed.inputs, request, baseCatalogId) }
        }
        if (operation == "search") {
            let outcome = querySearch(narrowed, request, contentIdentity)
            return outcome.toResponse(request, narrowed.inputs, baseCatalogId)
        }
        let outcome = queryGetSymbol(narrowed, request, contentIdentity)
        return outcome.toResponse(request, narrowed.inputs, baseCatalogId)
    }

    /**
     * Keep one frozen projection. In-flight callers retain their own immutable
     * view when another request replaces the bounded cache.
     */
    private func projectionFor(request: JsonObject,
        baseSelected: ArrayList<QuerySnapshotInput>): QueryProjection {
        let language = queryString(request, "language")
        let audience = queryString(request, "audience")
        let fallback = queryBool(request, "languageFallback")
        let key = StringBuilder()
        key.append(language)
        key.append("\n")
        key.append(audience)
        key.append("\n")
        key.append(fallback.toString())
        key.append("\n" + queryString(request, "cfgProfile"))
        for (input in baseSelected) {
            key.append("\n")
            key.append(input.snapshot.snapshotId)
        }
        let cacheKey = key.toString()
        return synchronized(lock) {
            if (projectionKey == cacheKey && cachedProjection.isSome()) {
                cachedProjection.getOrThrow()
            } else {
                let projected = projectDocumentationQuerySources(baseSelected, request)
                let value = QueryProjection(projected, QueryCatalog(projected))
                projectionKey = cacheKey
                cachedProjection = Some(value)
                value
            }
        }
    }

    /**
     * Report one rejected request in the published failure envelope over this
     * frozen catalog. The caller decides which rejection warrants it; the scope
     * metadata stays this catalog's captured evidence.
     */
    protected func failure(request: JsonObject, status: String, code: String,
        message: String): String {
        queryFailureResult(request, baseInputs, baseCatalogId, status, code, message)
    }

    /**
     * Stable catalog identity of the frozen inputs, equal to the `scope.catalogId`
     * every result reports. It names captured content, not a host path, and is
     * never a publication or release credential.
     */
    protected prop catalogIdentity: String {
        get() { baseCatalogId }
    }
}

/**
 * Canonical catalog identity: a digest over each source identity and its frozen
 * content, in load order. It names content, never a host path.
 */
protected func documentationQueryCatalogId(inputs: ArrayList<QuerySnapshotInput>): String {
    let out = StringBuilder()
    out.append("cjdoc.query-catalog/1")
    for (input in inputs) {
        out.append("\n")
        out.append(input.snapshot.snapshotId)
        out.append("\n")
        out.append(input.sourceSnapshotId)
        out.append("\n")
        out.append(input.sourceIdentity)
        out.append("\n")
        out.append(input.isLatest.toString())
    }
    "cjdoc:catalog:v1:" + query_model.contractFingerprint(out.toString())
}

// Catalog identity plus every captured digest: a cursor also dies when only a
// report or inventory changed under the same snapshot id.
private func queryContentIdentity(catalogId: String, inputs: ArrayList<QuerySnapshotInput>): String {
    let out = StringBuilder()
    out.append(catalogId)
    for (input in inputs) {
        out.append("\n")
        out.append(input.snapshot.snapshotId)
        out.append("\n")
        out.append(input.inventory.fingerprint)
        out.append("\n")
        for (index in 0..input.attachments.size()) {
            let report = input.attachments[index].asObject()
            out.append(queryString(report, "kind") + "\n" + queryString(report, "sha256") +
                "\n" + queryString(report, "state") + "\n")
        }
    }
    query_model.contractFingerprint(out.toString())
}

protected class QueryProjection {
    let inputs: ArrayList<QuerySnapshotInput>
    let catalog: QueryCatalog

    init(inputs: ArrayList<QuerySnapshotInput>, catalog: QueryCatalog) {
        this.inputs = inputs
        this.catalog = catalog
    }
}

/**
 * One language/audience projection of the frozen inputs. Indexes are immutable
 * after construction so search, get and relations all read the same evidence.
 */
protected class QueryCatalog {
    let documents = ArrayList<QueryDocument>()
    let byInput = HashMap<String, QueryDocument>()

    init(inputs: ArrayList<QuerySnapshotInput>) {
        for (input in inputs) {
            if (byInput.contains(input.snapshot.snapshotId)) { continue }
            let document = QueryDocument(input)
            documents.add(document)
            byInput[input.snapshot.snapshotId] = document
        }
    }

}

/** A captured relationship edge used by the bounded relation walk. */
protected class QueryEdge {
    let kind: String
    let direction: String
    let targetId: ?String
    let targetDisplay: String
    let state: String
    let reason: String
    let targetSnapshotId: ?String
    let navigation: ?query_model.TypeNavigation

    init(kind: String, direction: String, targetId: ?String,
        targetDisplay: String, state: String, reason: String,
        targetSnapshotId!: ?String = None, navigation!: ?query_model.TypeNavigation = None) {
        this.kind = kind
        this.direction = direction
        this.targetId = targetId
        this.targetDisplay = targetDisplay
        this.state = state
        this.reason = reason
        this.targetSnapshotId = targetSnapshotId
        this.navigation = navigation
    }
}

/**
 * Queryable surface of one frozen snapshot.
 *
 * `visibleIds` is the audience/language projection's own visibility; a query may
 * narrow it but can never add a declaration the published projection removed.
 */
protected class QueryDocument {
    let input: QuerySnapshotInput
    let visibleIds = HashSet<String>()
    let bySymbolId = HashMap<String, query_model.SymbolDoc>()
    let visibleSymbols = ArrayList<query_model.SymbolDoc>()
    let pages = ArrayList<query_model.DocumentationPage>()
    let aliases = HashMap<String, ArrayList<String>>()
    let exposures = HashMap<String, JsonArray>()
    // Cache only the two contract profiles, built on first use. Identity-only
    // operations never allocate search facts, and concurrent searches share
    // one immutable raw projection and prepared matching view for each profile.
    private let searchLock = ReentrantMutex()
    private let searchProjections = HashMap<String, search_engine.DocumentationSearchProjection>()
    private let searchPreparedProjections =
        HashMap<String, search_engine.PreparedDocumentationSearchProjection>()
    let outgoing = HashMap<String, ArrayList<QueryEdge>>()
    let incoming = HashMap<String, ArrayList<QueryEdge>>()

    init(input: QuerySnapshotInput) {
        this.input = input
        // `snapshot.documentation` is already the publication projection for the
        // captured audience, so its declarations are exactly the visible boundary.
        // Enumerating them never re-derives a second visibility rule.
        for (symbol in input.documentation.declarations) {
            visibleSymbols.add(symbol)
            bySymbolId[symbol.id] = symbol
            let _ = visibleIds.add(symbol.id)
        }
        for ((_, page) in input.pages) { pages.add(page) }
        sort(pages, lessThan: { left, right => left.id < right.id }, stable: true)
        queryBuildExposureIndex(this)
        queryBuildRelationshipIndex(this)
    }

    func searchProjectionFor(profile: String): search_engine.DocumentationSearchProjection {
        if (!search_engine.searchContractProfileIsKnown(profile)) {
            throw IllegalArgumentException("unknown search profile")
        }
        synchronized(searchLock) {
            match (searchProjections.get(profile)) {
                case Some(value) => value
                case None =>
                    let value = agent_render.buildDocumentationSearchProjection(input.snapshot,
                        profile, sourceSnapshotId: input.sourceSnapshotId)
                    searchProjections[profile] = value
                    value
            }
        }
    }

    func searchExecutionProjectionFor(profile: String):
        search_engine.PreparedDocumentationSearchProjection {
        if (!search_engine.searchContractProfileIsKnown(profile)) {
            throw IllegalArgumentException("unknown search profile")
        }
        synchronized(searchLock) {
            match (searchPreparedProjections.get(profile)) {
                case Some(value) => value
                case None =>
                    let rawProjection = match (searchProjections.get(profile)) {
                        case Some(value) => value
                        case None =>
                            let value = agent_render.buildDocumentationSearchProjection(input.snapshot,
                                profile, sourceSnapshotId: input.sourceSnapshotId)
                            searchProjections[profile] = value
                            value
                    }
                    let prepared =
                        search_engine.prepareDocumentationSearchProjection(rawProjection)
                    searchPreparedProjections[profile] = prepared
                    prepared
            }
        }
    }
}

protected func queryAppendEdge(index: HashMap<String, ArrayList<QueryEdge>>, key: String,
    edge: QueryEdge): Unit {
    match (index.get(key)) {
        case Some(values) => values.add(edge)
        case None => index[key] = ArrayList<QueryEdge>([edge])
    }
}

private func queryNavigationTarget(document: QueryDocument,
    navigation: query_model.TypeNavigation): ?String {
    if (navigation.state != "resolved" || navigation.symbolKey.isEmpty()) { return None }
    if (document.visibleIds.contains(navigation.symbolKey)) { return Some(navigation.symbolKey) }
    None
}

private func queryBuildRelationshipIndex(document: QueryDocument): Unit {
    for (symbol in document.visibleSymbols) {
        for (relation in symbol.symbolRelationships) {
            let target: ?String = match (relation.targetSymbolId) {
                case Some(value) => if (document.visibleIds.contains(value)) { Some(value) } else { None }
                case None => None
            }
            let edge = QueryEdge(relation.kind, "outgoing", target,
                relation.targetDisplay, relation.state, queryRelationshipReason(relation.state))
            queryAppendEdge(document.outgoing, symbol.id, edge)
            match (target) {
                case Some(value) => queryAppendEdge(document.incoming, value,
                    QueryEdge(relation.kind, "incoming", Some(symbol.id),
                        relation.targetDisplay, relation.state, queryRelationshipReason(relation.state)))
                case None => ()
            }
        }
        for (relationship in symbol.typeRelationships) {
            match (relationship.target.navigation) {
                case Some(navigation) =>
                    let target = queryNavigationTarget(document, navigation)
                    let state = if (target.isSome()) { "resolved" } else { navigation.state }
                    let edge = QueryEdge(relationship.kind, "outgoing", target,
                        relationship.target.spelling, state, navigation.reason)
                    queryAppendEdge(document.outgoing, symbol.id, edge)
                    match (target) {
                        case Some(value) => queryAppendEdge(document.incoming, value,
                            QueryEdge(relationship.kind, "incoming", Some(symbol.id),
                                relationship.target.spelling, state, navigation.reason))
                        case None => ()
                    }
                case None => ()
            }
        }
        match (symbol.ownerId) {
            case Some(ownerId) =>
                if (document.visibleIds.contains(ownerId)) {
                    queryAppendEdge(document.outgoing, symbol.id,
                        QueryEdge("owner", "outgoing", Some(ownerId), ownerId,
                            "resolved", "captured declaration owner"))
                    queryAppendEdge(document.incoming, ownerId,
                        QueryEdge("owner", "incoming", Some(symbol.id), symbol.id,
                            "resolved", "captured member declaration"))
                    queryAppendEdge(document.outgoing, ownerId,
                        QueryEdge("member", "outgoing", Some(symbol.id), symbol.id,
                            "resolved", "captured member declaration"))
                }
            case None => ()
        }
    }
}

protected func queryRelationshipReason(state: String): String {
    match (state) {
        case "resolved" => "captured resolved relationship"
        case "partial" => "captured partially resolved relationship"
        case "ambiguous" => "captured relationship with several candidate targets"
        case "unavailable" => "captured relationship has no available target"
        case _ => "captured relationship state"
    }
}

/** Snapshot selection; narrowing a scope never widens it. */
protected func querySelectSnapshots(inputs: ArrayList<QuerySnapshotInput>,
    request: JsonObject): ArrayList<QuerySnapshotInput> {
    let snapshotId = queryString(request, "snapshotId")
    let result = ArrayList<QuerySnapshotInput>()
    let seen = HashSet<String>()
    for (input in inputs) {
        if (!snapshotId.isEmpty() && snapshotId != input.snapshot.snapshotId &&
            snapshotId != input.sourceSnapshotId) { continue }
        if (!seen.add(input.snapshot.snapshotId)) { continue }
        result.add(input)
    }
    result
}

private func querySelectContextSnapshots(inputs: ArrayList<QuerySnapshotInput>,
    primary: ArrayList<QuerySnapshotInput>, request: JsonObject): ArrayList<QuerySnapshotInput> {
    let result = ArrayList<QuerySnapshotInput>(primary)
    let selected = HashSet<String>()
    for (id in queryStrings(request, "relatedSnapshotIds")) { selected.add(id) }
    let contextId = queryString(request, "contextSnapshotId")
    if (selected.isEmpty() && contextId.isEmpty()) { return result }
    let seen = HashSet<String>()
    let observed = HashSet<String>()
    for (input in primary) { seen.add(input.snapshot.snapshotId) }
    for (input in inputs) {
        if (contextId != input.snapshot.snapshotId && contextId != input.sourceSnapshotId &&
            !selected.contains(input.snapshot.snapshotId) && !selected.contains(input.sourceSnapshotId)) { continue }
        observed.add(input.snapshot.snapshotId)
        observed.add(input.sourceSnapshotId)
        if (seen.add(input.snapshot.snapshotId)) { result.add(input) }
    }
    for (id in selected where !observed.contains(id)) {
        throw DocumentationQueryException("scope_mismatch", "related_snapshot_not_loaded",
            "An explicitly requested related snapshot is not loaded.")
    }
    result
}

protected func queryFailureResult(request: JsonObject, inputs: ArrayList<QuerySnapshotInput>,
    catalogId: String, status: String, code: String, message: String): String {
    let error = queryErrorNode(code, message, Option<Int64>.None, Option<Int64>.None)
    let text = "Documentation query failed: ${status}. ${message}"
    try {
        queryEncodeResponse(newDocumentationQueryResponse(request, status, inputs, catalogId,
            text: text, error: error))
    } catch (_: DocumentationQueryException) {
        // Even failure metadata can exceed the wire limit. Keep the request and
        // explicit resource error, rather than emit a partial/oversized context.
        let bounded = queryErrorNode("result_wire_byte_limit",
            "The result and its captured scope metadata exceed the 64 MiB wire limit.",
            Option<Int64>.None, Some(QUERY_RESULT_BYTES))
        queryEncodeResponse(newDocumentationQueryResponse(request, "resource_limit",
            ArrayList<QuerySnapshotInput>(), catalogId,
            text: "Query result exceeds the serialized wire resource limit.", error: bounded))
    }
}

/**
 * The published failure envelope for a request that never reached execution.
 *
 * Startup rejection (a bad command line, an unreadable snapshot, an unsupported
 * document root) is reported in exactly the same `cjdoc.query-result/4` shape as
 * a rejected request, so a machine client has one decoding path for both.
 */
protected func queryStartupFailure(catalogId: String, status: String, code: String,
    message: String): String {
    queryFailureResult(JsonNode.object(), ArrayList<QuerySnapshotInput>(), catalogId, status,
        code, message)
}
