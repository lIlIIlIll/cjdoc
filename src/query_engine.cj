package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import std.convert.Parsable
import std.sort.*
import std.sync.*
import yjson.*

/**
 * One frozen, read-only documentation query session over already loaded
 * snapshots.
 *
 * Every snapshot, inventory, dependency graph and report was captured before
 * this class exists, so execution never scans source, chooses an SDK, downloads
 * a dependency, compiles a consumer or reaches the network. The same request and
 * the same frozen inputs therefore always produce the same bytes.
 *
 * The most recent language/audience projection is cached under a session lock.
 * Replaced views remain immutable for callers already using them; cache memory
 * cannot grow with arbitrary request strings. `execute` supports concurrent calls.
 */
public class DocumentationQuerySession {
    private let baseInputs: ArrayList<QuerySnapshotInput>
    private let baseCatalogId: String
    private let contentIdentity: String
    private let lock = ReentrantMutex()
    private var projectionKey = ""
    private var cachedProjection: ?QueryProjection = None

    /** Load explicit frozen snapshots through the bounded caller-supplied loader. */
    public init(snapshotPaths: Array<String>) {
        let loaded = loadDocumentationQuerySources(snapshotPaths)
        baseInputs = loaded
        baseCatalogId = documentationQueryCatalogId(loaded)
        contentIdentity = queryContentIdentity(baseCatalogId, loaded)
    }

    /** Query one captured documentation model without touching the file system. */
    public init(documentation: query_model.DocumentationSet) {
        let loaded = loadDocumentationQueryModels([documentation])
        baseInputs = loaded
        baseCatalogId = documentationQueryCatalogId(loaded)
        contentIdentity = queryContentIdentity(baseCatalogId, loaded)
    }

    /** Query several captured documentation models as one explicit catalog. */
    public init(documents: Array<query_model.DocumentationSet>) {
        let loaded = loadDocumentationQueryModels(documents)
        baseInputs = loaded
        baseCatalogId = documentationQueryCatalogId(loaded)
        contentIdentity = queryContentIdentity(baseCatalogId, loaded)
    }

    /**
     * Execute one strict `cjdoc.query-request/1` request and return exactly one
     * `cjdoc.query-result/1` object.
     *
     * Domain outcomes (ambiguity, scoped absence, incomplete source) are ordinary
     * results; a malformed request is reported through the same envelope so a
     * machine client never parses a human error string.
     */
    public func execute(request: String): String {
        var parsed: ?JsonObject = None
        var failure: ?DocumentationQueryException = None
        try {
            parsed = Some(parseDocumentationQueryRequest(request))
        } catch (error: DocumentationQueryException) {
            failure = Some(error)
        } catch (_: Exception) {
            failure = Some(DocumentationQueryException("invalid_request", "request_json",
                "Query request is not one valid JSON object."))
        }
        if (parsed.isNone()) {
            let error = failure.getOrThrow()
            return queryFailureResult(JsonNode.object(), baseInputs, baseCatalogId,
                error.status, error.code, error.message)
        }
        let value = parsed.getOrThrow()
        try {
            return queryEncodeResponse(dispatch(value))
        } catch (error: DocumentationQueryException) {
            return queryFailureResult(value, baseInputs, baseCatalogId, error.status, error.code,
                error.message)
        } catch (error: query_render.RenderResourceLimitException) {
            return queryFailureResult(value, baseInputs, baseCatalogId, "resource_limit",
                "render_resource_limit", "The selected documentation exceeds a documented renderer resource limit.")
        } catch (_: IllegalArgumentException) {
            // A rejected language, audience or scope value is an invalid request,
            // never an internal failure.
            return queryFailureResult(value, baseInputs, baseCatalogId, "invalid_request",
                "request_value", "A request value is not supported by the loaded documentation.")
        }
    }

    private func dispatch(request: JsonObject): JsonObject {
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
     * Stable catalog identity of the frozen inputs, equal to the `scope.catalogId`
     * every result reports. It names captured content, not a host path, and is
     * never a publication or release credential.
     */
    public prop catalogIdentity: String {
        get() { baseCatalogId }
    }
}

/**
 * Canonical catalog identity: a digest over each source identity and its frozen
 * content, in load order. It names content, never a host path.
 */
internal func documentationQueryCatalogId(inputs: ArrayList<QuerySnapshotInput>): String {
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

internal class QueryProjection {
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
internal class QueryCatalog {
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
internal class QueryEdge {
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
internal class QueryDocument {
    let input: QuerySnapshotInput
    let visibleIds = HashSet<String>()
    let bySymbolId = HashMap<String, query_model.SymbolDoc>()
    let visibleSymbols = ArrayList<query_model.SymbolDoc>()
    let pages = ArrayList<query_model.DocumentationPage>()
    let aliases = HashMap<String, ArrayList<String>>()
    let exposures = HashMap<String, JsonArray>()
    let searchText = HashMap<String, String>()
    let pageText = HashMap<String, String>()
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
            searchText[symbol.id] = querySearchableSymbolText(symbol)
        }
        for ((_, page) in input.pages) {
            pages.add(page)
            pageText[page.id] = (page.title + "\n" + page.text).toAsciiLower()
        }
        sort(pages, lessThan: { left, right => left.id < right.id }, stable: true)
        queryBuildExposureIndex(this)
        queryBuildRelationshipIndex(this)
    }
}

internal func queryAppendEdge(index: HashMap<String, ArrayList<QueryEdge>>, key: String,
    edge: QueryEdge): Unit {
    match (index.get(key)) {
        case Some(values) => values.add(edge)
        case None => index[key] = ArrayList<QueryEdge>([edge])
    }
}

// Literal author text only: summary, description and tag text. No type inference
// and no HTML parsing feed ranking.
internal func querySearchableSymbolText(symbol: query_model.SymbolDoc): String {
    let out = StringBuilder()
    match (symbol.documentation) {
        case Some(comment) =>
            out.append(comment.summary)
            out.append("\n")
            out.append(comment.description)
            for (tag in comment.tags) {
                out.append("\n")
                out.append(tag.name)
                out.append("\n")
                out.append(tag.subject)
                out.append("\n")
                out.append(tag.description)
            }
        case None => ()
    }
    out.toString().toAsciiLower()
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

internal func queryRelationshipReason(state: String): String {
    match (state) {
        case "resolved" => "captured resolved relationship"
        case "partial" => "captured partially resolved relationship"
        case "ambiguous" => "captured relationship with several candidate targets"
        case "unavailable" => "captured relationship has no available target"
        case _ => "captured relationship state"
    }
}

/** Snapshot selection; narrowing a scope never widens it. */
internal func querySelectSnapshots(inputs: ArrayList<QuerySnapshotInput>,
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
    if (selected.isEmpty()) { return result }
    let seen = HashSet<String>()
    let observed = HashSet<String>()
    for (input in primary) { seen.add(input.snapshot.snapshotId) }
    for (input in inputs) {
        if (!selected.contains(input.snapshot.snapshotId) && !selected.contains(input.sourceSnapshotId)) { continue }
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

internal func queryFailureResult(request: JsonObject, inputs: ArrayList<QuerySnapshotInput>,
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
 * Read a bounded continuation offset bound to the complete canonical request.
 *
 * Every field except `cursor` participates, and the binding also names the frozen
 * catalog content, so a changed snapshot, filter, sort, audience, language,
 * fallback or budget invalidates an old continuation instead of mixing two
 * observations. Cursors carry no secret and are not authentication.
 */
internal func queryReadCursor(request: JsonObject, catalogId: String): Int64 {
    let cursor = queryString(request, "cursor")
    if (cursor.isEmpty()) { return 0 }
    let binding = queryCursorBinding(request, catalogId)
    let prefix = "cjdoc.cursor/1:"
    if (!cursor.startsWith(prefix)) {
        throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor is not a cjdoc continuation cursor.")
    }
    let body = cursor[prefix.size..]
    let separator = body.indexOf(":")
    if (separator.isNone()) {
        throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor is not a cjdoc continuation cursor.")
    }
    let offsetText = body[..separator.getOrThrow()]
    let digest = body[separator.getOrThrow() + 1..]
    if (digest != binding) {
        throw DocumentationQueryException("stale_cursor", "cursor_binding",
            "Continuation cursor no longer matches this snapshot, filters, ordering or budget.")
    }
    let value = try {
        Int64.parse(offsetText)
    } catch (_: Exception) {
        throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor offset is not an integer.")
    }
    if (value < 0) {
        throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor offset is negative.")
    }
    value
}

/** Build the continuation cursor for the next stable page of the same request. */
internal func queryNextCursor(request: JsonObject, catalogId: String, offset: Int64): String {
    "cjdoc.cursor/1:" + offset.toString() + ":" + queryCursorBinding(request, catalogId)
}

private func queryCursorBinding(request: JsonObject, catalogId: String): String {
    let canonical = JsonNode.object()
    for (index in 0..request.size()) {
        let key = request.nameAt(index)
        if (key == "cursor") { continue }
        canonical.put(key, request.valueAt(index))
    }
    "cjdoc.cursor-binding/1:" + query_model.contractFingerprint(catalogId + "\n" + queryCanonical(canonical))
}
