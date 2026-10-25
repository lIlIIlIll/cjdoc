package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// Shared result construction for every query operation. Search, get_symbol and
// the parent's resolve_docs all describe their evidence with the same envelope,
// identity objects and completeness dimensions, so a client never has to learn a
// second result shape per operation.

internal let QUERY_RESULT_SCHEMA_VERSION: String = "cjdoc.query-result/1"
internal let QUERY_SEARCH_DEFAULT_LIMIT: Int64 = 20
internal let QUERY_GET_DEFAULT_LIMIT: Int64 = 10
internal let QUERY_SUMMARY_SECTIONS: Array<String> = ["signature", "description"]
// Published chapter order for every selected-section projection.
internal let QUERY_SELECTED_SECTIONS: Array<String> = ["signature", "parameters", "returns",
    "contracts", "examples", "description", "relations", "source", "diagnostics",
    "validation", "diff"]

internal func queryClamp(value: Int64, minimum: Int64, maximum: Int64): Int64 {
    if (value < minimum) { return minimum }
    if (value > maximum) { return maximum }
    value
}

/** A detached copy of one captured identity object, encoded by its canonical codec. */
internal func queryDocumentSetNode(identity: query_model.DocumentSetIdentity): JsonObject {
    let out = StringBuilder()
    query_render.appendDocumentSetIdentity(out, identity)
    querySnapshotJson(out.toString())
}

internal func queryDependencyNode(dependency: query_model.DependencyInstance): JsonObject {
    let out = StringBuilder()
    query_render.appendDependencyInstance(out, dependency)
    querySnapshotJson(out.toString())
}

internal func queryModuleFor(input: QuerySnapshotInput,
    moduleId: String): ?query_model.ModuleDoc {
    input.snapshot.moduleFor(moduleId)
}

/**
 * The captured dependency instance for one declaration's module.
 *
 * Root and workspace declarations are local, so a missing dependency instance is
 * `not_applicable` rather than an unrecorded dependency. A dependency module with
 * several captured instances is reported as ambiguous instead of choosing one by
 * traversal order.
 */
internal func queryDependencyState(input: QuerySnapshotInput,
    moduleId: String): (?query_model.DependencyInstance, String) {
    input.snapshot.moduleDependencyState(moduleId)
}

/** Captured document-set identity for a declaration's producer module. */
internal func queryDocumentSetFor(input: QuerySnapshotInput,
    moduleId: String): ?query_model.DocumentSetIdentity {
    match (input.scopeForModule(moduleId)) {
        case Some(scope) => Some(scope.original)
        case None => input.snapshot.documentSetForModule(moduleId)
    }
}

internal func queryIdentityNode(input: QuerySnapshotInput, symbolId: ?String,
    pageId: ?String, ownerId!: ?String = None): JsonObject {
    let identity = JsonNode.object()
    identity.put("snapshotId", JsonNode.string(input.snapshot.snapshotId))
    identity.put("sourceSnapshotId", JsonNode.string(input.sourceSnapshotId))
    let symbol = match (symbolId) {
        case Some(id) => input.symbols.get(id)
        case None => None<query_model.SymbolDoc>
    }
    let moduleId = match (symbol) {
        case Some(value) => Some(value.moduleId)
        case None => None<String>
    }
    match (moduleId) {
        case Some(id) => match (queryDocumentSetFor(input, id)) {
            case Some(documentSet) => identity.put("documentSet", queryDocumentSetNode(documentSet))
            case None => identity.put("documentSet", JsonNode.nullValue)
        }
        case None => identity.put("documentSet", JsonNode.nullValue)
    }
    match (moduleId) {
        case Some(id) => identity.put("moduleId", JsonNode.string(id))
        case None => identity.put("moduleId", JsonNode.nullValue)
    }
    var dependencyState = "not_applicable"
    match (moduleId) {
        case Some(id) =>
            let (dependency, state) = queryDependencyState(input, id)
            dependencyState = state
            match (dependency) {
                case Some(value) => identity.put("dependencyInstance", queryDependencyNode(value))
                case None => identity.put("dependencyInstance", JsonNode.nullValue)
            }
        case None => identity.put("dependencyInstance", JsonNode.nullValue)
    }
    identity.put("dependencyInstanceState", JsonNode.string(dependencyState))
    match (symbolId) {
        case Some(id) => identity.put("symbolId", JsonNode.string(id))
        case None => identity.put("symbolId", JsonNode.nullValue)
    }
    match (symbol) {
        case Some(value) => identity.put("symbolKey", JsonNode.string(input.symbolKeys[value.id]))
        case None => identity.put("symbolKey", JsonNode.nullValue)
    }
    match (pageId) {
        case Some(id) => identity.put("pageId", JsonNode.string(id))
        case None => identity.put("pageId", JsonNode.nullValue)
    }
    match (ownerId) {
        case Some(id) => identity.put("ownerId", JsonNode.string(id))
        case None => identity.put("ownerId", JsonNode.nullValue)
    }
    identity
}

/** The same portable key the published symbol inventory uses. */
internal func queryPortableSymbolKey(symbol: query_model.SymbolDoc): String {
    let parameters = ArrayList<String>()
    for (parameter in symbol.parameters) { parameters.add(parameter.typeRef.spelling) }
    query_model.portableSymbolKey(symbol.packageName, symbol.qualifiedName, symbol.kind,
        symbol.genericParameters.size, parameterTypes: parameters.toArray())
}

/** A captured source location without inventing a repository URL. */
internal func querySourceRangeNode(source: query_model.SourceRange): JsonObject {
    let node = JsonNode.object()
    node.put("path", JsonNode.string(source.path))
    let start = JsonNode.object()
    start.put("line", JsonNode.int64(source.start.line))
    start.put("column", JsonNode.int64(source.start.column))
    start.put("byteOffset", JsonNode.int64(source.start.byteOffset))
    let end = JsonNode.object()
    end.put("line", JsonNode.int64(source.end.line))
    end.put("column", JsonNode.int64(source.end.column))
    end.put("byteOffset", JsonNode.int64(source.end.byteOffset))
    node.put("start", start)
    node.put("end", end)
    node
}

internal func querySourceNode(snapshotId: String, kind: String, path: ?String,
    url: ?String, state: String): JsonObject {
    let node = JsonNode.object()
    node.put("snapshotId", JsonNode.string(snapshotId))
    node.put("kind", JsonNode.string(kind))
    node.put("path", queryNullable(path))
    node.put("url", queryNullable(url))
    node.put("state", JsonNode.string(state))
    node
}

internal func queryReportNode(kind: String, state: String, snapshotId: String,
    report: ?JsonObject): JsonObject {
    let node = JsonNode.object()
    node.put("kind", JsonNode.string(kind))
    node.put("state", JsonNode.string(state))
    node.put("snapshotId", JsonNode.string(snapshotId))
    match (report) {
        case Some(value) =>
            node.put("sha256", value.get("sha256").getOrDefault({ => JsonNode.nullValue }))
            node.put("path", value.get("path").getOrDefault({ => JsonNode.nullValue }))
            node.put("binding", value.get("binding").getOrDefault({ => JsonNode.object() }))
            node.put("report", value.get("report").getOrDefault({ => JsonNode.nullValue }))
        case None =>
            node.put("sha256", JsonNode.nullValue)
            node.put("path", JsonNode.nullValue)
            node.put("binding", JsonNode.object())
            node.put("report", JsonNode.nullValue)
    }
    node
}

/**
 * The attached report of one kind, or an explicit `not_attached` report.
 *
 * A report is evidence only when it was attached to this frozen snapshot; a
 * code block or a diagnostic never becomes a passing receipt here.
 */
internal func queryEvidenceReport(input: QuerySnapshotInput, kind: String): JsonObject {
    for (index in 0..input.attachments.size()) {
        let node = input.attachments[index]
        if (node.kind() != JsonKind.Object) { continue }
        let object = node.asObject()
        if (queryString(object, "kind") != kind) { continue }
        var state = queryString(object, "state")
        if (let Some(value) <- object.get("binding")) {
            if (value.kind() == JsonKind.Object) {
                let bound = queryString(value.asObject(), "snapshotId")
                if (!bound.isEmpty() && bound != input.snapshot.snapshotId) { state = "binding_mismatch" }
            }
        }
        return queryReportNode(kind, if (state.isEmpty()) { "attached" } else { state },
            input.snapshot.snapshotId, Some(object))
    }
    queryReportNode(kind, "not_attached", input.snapshot.snapshotId, Option<JsonObject>.None)
}


internal func querySection(name: String, state: String, value: JsonNode): JsonObject {
    let node = JsonNode.object()
    node.put("name", JsonNode.string(name))
    node.put("state", JsonNode.string(state))
    node.put("value", value)
    node
}

internal func queryOmission(section: String, reason: String, next: ?JsonNode): JsonObject {
    let node = JsonNode.object()
    node.put("section", JsonNode.string(section))
    node.put("reason", JsonNode.string(reason))
    node.put("next", next.getOrDefault({ => JsonNode.nullValue }))
    node
}

internal func queryResultNode(items: ArrayList<JsonObject>, relations: ArrayList<JsonObject>,
    reports: ArrayList<JsonObject>): JsonObject {
    let node = JsonNode.object()
    let itemArray = JsonNode.array()
    for (item in items) { itemArray.add(item) }
    node.put("items", itemArray)
    let relationArray = JsonNode.array()
    for (relation in relations) { relationArray.add(relation) }
    node.put("relations", relationArray)
    let reportArray = JsonNode.array()
    for (report in reports) { reportArray.add(report) }
    node.put("reports", reportArray)
    node
}

internal func querySnapshotNode(input: QuerySnapshotInput): JsonObject {
    let node = JsonNode.object()
    node.put("snapshotId", JsonNode.string(input.snapshot.snapshotId))
    node.put("sourceSnapshotId", JsonNode.string(input.sourceSnapshotId))
    node.put("sourceKind", JsonNode.string(input.sourceKind))
    node.put("language", JsonNode.string(input.snapshot.locale))
    node.put("audience", JsonNode.string(input.documentation.configuration.audience))
    node.put("apiCollectionState", JsonNode.string(input.documentation.apiCollectionState))
    node.put("publicationRevision", JsonNode.string(input.snapshot.publicationRevision))
    node.put("packagedRepresentations", JsonNode.boolean(input.packagedRepresentations))
    node
}

internal func queryScopeNode(request: JsonObject, inputs: ArrayList<QuerySnapshotInput>,
    catalogId: String): JsonObject {
    let scope = JsonNode.object()
    let requested = JsonNode.object()
    for (index in 0..request.size()) { requested.put(request.nameAt(index), request.valueAt(index)) }
    scope.put("requested", requested)
    if (catalogId.isEmpty()) {
        scope.put("catalogId", JsonNode.nullValue)
    } else {
        scope.put("catalogId", JsonNode.string(catalogId))
    }
    let snapshots = JsonNode.array()
    for (input in inputs) { snapshots.add(querySnapshotNode(input)) }
    scope.put("snapshots", snapshots)
    scope
}

internal func queryApiCollectionNode(inputs: ArrayList<QuerySnapshotInput>): JsonArray {
    let values = JsonNode.array()
    let seen = HashSet<String>()
    for (input in inputs) {
        let id = input.snapshot.snapshotId
        if (!seen.add(id)) { continue }
        let entry = JsonNode.object()
        entry.put("snapshotId", JsonNode.string(id))
        entry.put("state", JsonNode.string(input.documentation.apiCollectionState))
        values.add(entry)
    }
    values
}

internal func queryErrorNode(code: String, message: String, requiredBytes: ?Int64,
    maximumBytes: ?Int64): JsonObject {
    let node = JsonNode.object()
    node.put("code", JsonNode.string(code))
    node.put("message", JsonNode.string(message))
    match (requiredBytes) {
        case Some(value) => node.put("requiredBytes", JsonNode.int64(value))
        case None => node.put("requiredBytes", JsonNode.nullValue)
    }
    match (maximumBytes) {
        case Some(value) => node.put("maximumBytes", JsonNode.int64(value))
        case None => node.put("maximumBytes", JsonNode.nullValue)
    }
    node
}

internal func queryRetryNode(maxBytes: Int64, detail: String): JsonObject {
    let node = JsonNode.object()
    node.put("maxBytes", JsonNode.int64(maxBytes))
    node.put("detail", JsonNode.string(detail))
    node
}

/**
 * The single strict response envelope shared by every operation.
 *
 * Callers supply the already-computed selection, result, completeness and
 * readable text; the builder never re-derives evidence, so the CLI, MCP and the
 * parent's resolve path cannot disagree about the same query.
 */
internal func newDocumentationQueryResponse(request: JsonObject, status: String,
    inputs: ArrayList<QuerySnapshotInput>, catalogId: String,
    selection!: ?JsonObject = None, result!: ?JsonObject = None,
    completeness!: ?JsonObject = None, text!: String = "",
    sources!: ?JsonArray = None, error!: ?JsonObject = None): JsonObject {
    let envelope = JsonNode.object()
    envelope.put("schemaVersion", JsonNode.string(QUERY_RESULT_SCHEMA_VERSION))
    envelope.put("status", JsonNode.string(status))
    envelope.put("operation", JsonNode.string(if (request.kind() == JsonKind.Object) {
        queryString(request, "operation") } else { "" }))
    envelope.put("scope", queryScopeNode(request, inputs, catalogId))
    match (selection) {
        case Some(value) => envelope.put("selection", value)
        case None => envelope.put("selection", JsonNode.nullValue)
    }
    match (result) {
        case Some(value) => envelope.put("result", value)
        case None => envelope.put("result", queryResultNode(ArrayList<JsonObject>(),
            ArrayList<JsonObject>(), ArrayList<JsonObject>()))
    }
    match (completeness) {
        case Some(value) => envelope.put("completeness", value)
        case None => envelope.put("completeness", queryDefaultCompleteness(inputs))
    }
    match (sources) {
        case Some(values) => envelope.put("sources", values)
        case None => envelope.put("sources", JsonNode.array())
    }
    match (error) {
        case Some(value) => envelope.put("error", value)
        case None => envelope.put("error", JsonNode.nullValue)
    }
    let body = if (text.isEmpty()) { "Documentation query status: ${status}." } else { text }
    envelope.put("text", JsonNode.string(body))
    envelope
}

internal func queryDefaultCompleteness(inputs: ArrayList<QuerySnapshotInput>): JsonObject {
    let completeness = JsonNode.object()
    completeness.put("apiCollection", queryApiCollectionNode(inputs))
    let query = JsonNode.object()
    query.put("complete", JsonNode.boolean(false))
    query.put("scope", JsonNode.string(""))
    query.put("offset", JsonNode.int64(0))
    query.put("returned", JsonNode.int64(0))
    query.put("total", JsonNode.nullValue)
    query.put("next", JsonNode.nullValue)
    query.put("reason", JsonNode.string("not_executed"))
    completeness.put("query", query)
    let content = JsonNode.object()
    content.put("complete", JsonNode.boolean(false))
    content.put("selectedSections", JsonNode.array())
    content.put("omittedSections", JsonNode.array())
    content.put("missingSections", JsonNode.array())
    content.put("retry", JsonNode.nullValue)
    completeness.put("content", content)
    completeness
}

internal func queryCompletenessNode(inputs: ArrayList<QuerySnapshotInput>, outcome: QueryOutcome): JsonObject {
    let completeness = JsonNode.object()
    completeness.put("apiCollection", queryApiCollectionNode(inputs))
    let query = JsonNode.object()
    query.put("complete", JsonNode.boolean(outcome.complete && outcome.next.isNone()))
    query.put("scope", JsonNode.string(outcome.scope))
    query.put("offset", JsonNode.int64(outcome.offset))
    query.put("returned", JsonNode.int64(outcome.returned))
    match (outcome.total) {
        case Some(value) => query.put("total", JsonNode.int64(value))
        case None => query.put("total", JsonNode.nullValue)
    }
    match (outcome.next) {
        case Some(value) => query.put("next", JsonNode.string(value))
        case None => query.put("next", JsonNode.nullValue)
    }
    query.put("reason", JsonNode.string(outcome.reason))
    completeness.put("query", query)
    let content = JsonNode.object()
    content.put("complete", JsonNode.boolean(outcome.contentComplete))
    let selected = JsonNode.array()
    for (name in outcome.selectedSections) { selected.add(JsonNode.string(name)) }
    content.put("selectedSections", selected)
    let omitted = JsonNode.array()
    for (value in outcome.omitted) { omitted.add(value) }
    content.put("omittedSections", omitted)
    let missing = JsonNode.array()
    for (name in outcome.missing) { missing.add(JsonNode.string(name)) }
    content.put("missingSections", missing)
    match (outcome.retry) {
        case Some(value) => content.put("retry", value)
        case None => content.put("retry", JsonNode.nullValue)
    }
    completeness.put("content", content)
    completeness
}

internal func querySourcesNode(values: ArrayList<JsonObject>): JsonArray {
    let array = JsonNode.array()
    for (value in values) { array.add(value) }
    array
}

/**
 * Operation outcome assembled by search/get before envelope construction.
 * Only already-computed evidence is stored here.
 */
internal class QueryOutcome {
    var status: String
    // The independently paged catalog, declaration, page or relation walk.
    var scope: String
    var items = ArrayList<JsonObject>()
    var relations = ArrayList<JsonObject>()
    var reports = ArrayList<JsonObject>()
    var sources = ArrayList<JsonObject>()
    var text: String = ""
    var error: ?JsonObject = None
    var offset: Int64 = 0
    var limit: Int64 = 0
    var returned: Int64 = 0
    var total: ?Int64 = None
    var next: ?String = None
    var complete: Bool = true
    var reason: String = ""
    var selectedSections = ArrayList<String>()
    var omitted = ArrayList<JsonObject>()
    var missing = ArrayList<String>()
    var retry: ?JsonObject = None
    var contentComplete: Bool = true
    var selection: ?JsonObject = None

    init(status: String, scope: String) {
        this.status = status
        this.scope = scope
    }

    func toResponse(request: JsonObject, inputs: ArrayList<QuerySnapshotInput>,
        catalogId: String): JsonObject {
        returned = if (scope == "relations") { relations.size } else { items.size }
        newDocumentationQueryResponse(request, status, inputs, catalogId,
            selection: selection,
            result: queryResultNode(items, relations, reports),
            completeness: queryCompletenessNode(inputs, this),
            text: text, sources: querySourcesNode(sources), error: error)
    }
}

internal func querySectionList(values: Array<String>): ArrayList<String> {
    ArrayList<String>(values)
}

/** Byte-bounded excerpt for an index summary; never used for a contract chapter. */
internal func queryExcerpt(value: String, limitBytes: Int64): String {
    let text = value.replace("\r", " ").replace("\n", " ").trimAscii()
    if (text.size <= limitBytes) { return text }
    let out = StringBuilder()
    var written: Int64 = 0
    for (rune in text.runes()) {
        let code = UInt32(rune)
        let width: Int64 = if (code <= 0x7Fu32) { 1 } else if (code <= 0x7FFu32) { 2 }
            else if (code <= 0xFFFFu32) { 3 } else { 4 }
        if (written + width > limitBytes - 3) { break }
        out.append(rune)
        written += width
    }
    out.append("...")
    out.toString()
}
