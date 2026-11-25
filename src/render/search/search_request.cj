protected package cjdoc.render.search

import cjdoc.model.*
import std.collection.*
import std.sort.*
import yjson.*

/** Profile of one request; absence means the shared contract's default. */
protected func searchRequestProfile(profile: String): String {
    if (profile.isEmpty()) { return searchContractString("defaultProfile") }
    profile
}

/** One normalized request, validated against the shared contract. */
protected class SearchRequest {
    protected let fields: JsonObject
    protected let query: String
    protected let mode: String
    protected let profile: String
    protected let limit: Int64
    protected let offset: Int64
    protected let filters: ArrayList<SearchFilter>
    protected let setPredicates: HashMap<String, Array<String>>
    protected let filterOnly: Bool
    // Exact author comment-field predicates, normalized and sorted. Each entry is
    // (field id, value); every predicate and every existing filter must hold.
    protected let commentFields: Array<(String, String)>
    // Requested value catalog: absent means "not requested", so no counting work
    // is performed and no facet member is emitted.
    protected let facetRequested: Bool
    protected let facetId: ?String
    protected let facetLimit: Int64
    protected let facetCursor: ?String
    // A request that only asks for the value catalog: it must not be reported as
    // a whole-library hit query, so its hit page stays empty.
    protected let catalogOnly: Bool
    // Canonical capture identities admitted by native snapshot/module/source
    // selection. Keys are `snapshotId\0canonicalId`.
    protected let admitted: ?HashSet<String>

    protected init(fields: JsonObject, query: String, mode: String, profile: String,
        limit: Int64, offset: Int64, filters: ArrayList<SearchFilter>,
        setPredicates: HashMap<String, Array<String>>,
        filterOnly: Bool, admitted: ?HashSet<String>,
        commentFields!: Array<(String, String)> = [], facetRequested!: Bool = false,
        facetId!: ?String = None, facetLimit!: Int64 = 20, facetCursor!: ?String = None,
        catalogOnly!: Bool = false) {
        this.fields = fields
        this.query = query
        this.mode = mode
        this.profile = profile
        this.limit = limit
        this.offset = offset
        this.setPredicates = setPredicates
        this.filters = filters
        this.filterOnly = filterOnly
        this.admitted = admitted
        this.commentFields = commentFields
        this.facetRequested = facetRequested
        this.facetId = facetId
        this.facetLimit = facetLimit
        this.facetCursor = facetCursor
        this.catalogOnly = catalogOnly
    }
}

private func searchSetValuePatternAdmits(value: String, pattern: String): Bool {
    if (pattern.isEmpty()) { return true }
    if (pattern != "^[A-Za-z0-9_-]{1,64}$") {
        throw IllegalStateException("unsupported search set-value pattern")
    }
    isDeclarationTagId(value)
}

protected func searchNormalizeSetPredicateValues(request: JsonObject,
    field: String): Array<String> {
    let predicate = match (searchSetPredicateFor(field)) {
        case Some(value) => value
        case None => throw IllegalArgumentException("search set predicate is not declared")
    }
    match (request.get(predicate.field)) {
        case Some(node) =>
            let schema = searchContractProperty(predicate.field)
            if (!searchJsonMatchesSchema(node, schema)) {
                throw IllegalArgumentException("search set predicate does not satisfy the shared schema")
            }
            let pattern = match (schema.asObject().get("items")) {
                case Some(item) =>
                    match (item.asObject().get("pattern")) {
                        case Some(value) => value.asString()
                        case None => ""
                    }
                case None => ""
            }
            let unique = ArrayList<String>()
            let seen = HashSet<String>()
            let values = node.asArray()
            for (index in 0..values.size()) {
                let value = values[index].asString()
                if (!searchSetValuePatternAdmits(value, pattern)) {
                    throw IllegalArgumentException("search set predicate value does not satisfy the shared schema")
                }
                if (seen.add(value)) { unique.add(value) }
            }
            sort(unique, lessThan: { left, right =>
                searchUtf8ByteLess(left, right)
            }, stable: true)
            unique.toArray()
        case None => []
    }
}

private func searchRequestSetPredicates(request: JsonObject): HashMap<String, Array<String>> {
    let result = HashMap<String, Array<String>>()
    for (predicate in SEARCH_SET_PREDICATES) {
        let values = searchNormalizeSetPredicateValues(request, predicate.field)
        if (!values.isEmpty()) { result[predicate.field] = values }
    }
    result
}

internal func searchRequestString(request: JsonObject, key: String): String {
    match (request.get(key)) {
        case Some(value) => if (value.kind() == JsonKind.String) { value.asString() } else { "" }
        case None => ""
    }
}

private func searchContractEnumContains(property: String, value: String): Bool {
    let propertyNode = searchContractProperty(property).asObject()
    match (propertyNode.get("enum")) {
        case Some(node) =>
            for (index in 0..node.asArray().size()) {
                if (node.asArray()[index].asString() == value) { return true }
            }
            false
        case None => false
    }
}

private func searchRequestFilters(request: JsonObject): ArrayList<SearchFilter> {
    let filters = ArrayList<SearchFilter>()
    match (request.get("filters")) {
        case Some(node) =>
            if (node.kind() != JsonKind.Array) {
                throw IllegalArgumentException("search filters must be an array")
            }
            let values = node.asArray()
            if (values.size() > searchContractInteger("maxFilters")) {
                throw IllegalArgumentException("search filter count exceeds the contract")
            }
            for (index in 0..values.size()) {
                let item = values[index].asObject()
                if (item.size() != 3) {
                    throw IllegalArgumentException("search filters must contain exactly field, op and value")
                }
                let field = searchRequestString(item, "field")
                let op = searchRequestString(item, "op")
                let value = searchRequestString(item, "value")
                let knownField = match (searchFilterSpec(field)) {
                    case Some(_) => true
                    case None => false
                }
                if (!knownField || !SEARCH_FILTER_OPS.contains(op) || value.isEmpty() ||
                    searchRuneCount(value) > 16384) {
                    throw IllegalArgumentException("search filter does not satisfy the contract")
                }
                filters.add(SearchFilter(field, op, value))
            }
        case None => ()
    }
    searchNormalizeFilters(filters)
}

/**
 * Read the exact comment-field predicates of one request.
 *
 * A predicate names a published field and one complete value. Values are
 * compared without case folding or normalization, so `Platform` never matches
 * `platform`.
 */
protected func searchRequestCommentFields(request: JsonObject): Array<(String, String)> {
    let result = ArrayList<(String, String)>()
    match (request.get("commentFields")) {
        case Some(node) =>
            if (node.kind() != JsonKind.Array) {
                throw IllegalArgumentException("comment field predicates must be an array")
            }
            let values = node.asArray()
            if (values.size() == 0 || values.size() > 64) {
                throw IllegalArgumentException("comment field predicate count is outside the contract")
            }
            let seen = HashSet<String>()
            for (index in 0..values.size()) {
                let item = values[index].asObject()
                if (item.size() != 2) {
                    throw IllegalArgumentException("comment field predicates require id and value")
                }
                let id = searchRequestString(item, "id")
                let value = searchRequestString(item, "value")
                if (!isDocumentationFieldId(id) || !isDocumentationFieldValue(value)) {
                    throw IllegalArgumentException("comment field predicate does not satisfy the contract")
                }
                if (seen.add(id + "\u{0}" + value)) { result.add((id, value)) }
            }
        case None => ()
    }
    // Equivalent conditions share one identity: sort by (id, value) bytes so a
    // reordered or repeated request keeps its cursor valid.
    sort(result, lessThan: { left, right =>
        if (left[0] != right[0]) { searchUtf8ByteLess(left[0], right[0]) }
        else { searchUtf8ByteLess(left[1], right[1]) }
    }, stable: true)
    result.toArray()
}


private class SearchFacetRequest {
    let requested: Bool
    let id: ?String
    let limit: Int64
    let cursor: ?String

    init(requested: Bool, id: ?String, limit: Int64, cursor: ?String) {
        this.requested = requested
        this.id = id
        this.limit = limit
        this.cursor = cursor
    }
}

private func searchRequestFacet(request: JsonObject): SearchFacetRequest {
    let node = match (request.get("commentFieldFacets")) {
        case Some(value) => value
        case None => return SearchFacetRequest(false, None, 20, None)
    }
    if (node.kind() != JsonKind.Object) {
        throw IllegalArgumentException("comment field facets must be an object")
    }
    let facet = node.asObject()
    let limit = match (facet.get("limit")) {
        case Some(value) => value.asInt64()
        case None => 20
    }
    if (limit < 1 || limit > 100) {
        throw IllegalArgumentException("comment field facet limit is outside 1..100")
    }
    let id: ?String = match (facet.get("id")) {
        case Some(value) =>
            let text = value.asString()
            if (!isDocumentationFieldId(text)) {
                throw IllegalArgumentException("comment field facet id does not satisfy the contract")
            }
            Some(text)
        case None => None
    }
    let cursor: ?String = match (facet.get("cursor")) {
        case Some(value) =>
            let text = searchRequestString(facet, "cursor")
            if (text.isEmpty() || searchRuneCount(text) > 1024) {
                throw IllegalArgumentException("comment field facet cursor is outside the contract")
            }
            Some(text)
        case None => None
    }
    SearchFacetRequest(true, id, limit, cursor)
}

/**
 * True when the only stated condition is the value catalog itself.
 *
 * Such a request is not a library-wide hit query: it lists candidate values and
 * returns no hit page, so an empty result is never mistaken for "nothing has
 * this field".
 */
internal func searchRequestIsCatalogOnly(request: JsonObject,
    commentFields: Array<(String, String)>): Bool {
    if (!commentFields.isEmpty() ||
        !searchRequestString(request, "query").trimAscii().isEmpty()) { return false }
    for (index in 0..request.size()) {
        let field = request.nameAt(index)
        if (["operation", "schemaVersion", "query", "mode", "profile", "limit", "cursor",
            "commentFieldFacets", "languageFallback", "snapshotId", "moduleId", "language",
            "audience", "cfgProfile", "documentSetId", "apiVersion", "library",
            "dependencyInstanceId", "target", "cfg", "latest"].contains(field)) { continue }
        if (field == "filters" && request.valueAt(index).asArray().size() == 0) { continue }
        return false
    }
    request.get("commentFieldFacets").isSome()
}

internal func searchRequestHasFlatSelector(request: JsonObject): Bool {
    for (field in ["symbolId", "symbolKey", "qualifiedName", "name"]) {
        if (!searchRequestString(request, field).isEmpty()) { return true }
    }
    false
}

protected func searchRequestIsFilterOnly(request: JsonObject): Bool {
    if (!searchRequestString(request, "query").trimAscii().isEmpty() ||
        searchRequestHasFlatSelector(request)) { return false }
    if (let Some(filters) <- request.get("filters")) {
        if (filters.asArray().size() > 0) { return true }
    }
    for (index in 0..request.size()) {
        let field = request.nameAt(index)
        if (["operation", "schemaVersion", "query", "mode", "profile", "limit", "cursor",
            "filters", "symbolId", "symbolKey", "qualifiedName", "name",
            "languageFallback", "commentFieldFacets"].contains(field)) { continue }
        if (field == "latest") {
            if (request.get(field).getOrThrow().asBool()) { return true }
            continue
        }
        return true
    }
    false
}

private func searchRequestFieldAllowed(field: String): Bool {
    if (SEARCH_GLOBAL_FIELD_VALUES.contains(field) || SEARCH_SEARCH_FIELD_VALUES.contains(field)) {
        return true
    }
    false
}

private func searchRequestMatchesContractSchema(request: JsonObject): Bool {
    if (request.get("operation").isNone() ||
        request.toJson().toArray().size > searchContractInteger("maxRequestBytes")) {
        return false
    }
    for (index in 0..request.size()) {
        let field = request.nameAt(index)
        if (!searchRequestFieldAllowed(field) ||
            !searchJsonMatchesSchema(request.valueAt(index), searchContractProperty(field))) {
            return false
        }
    }
    true
}

internal func searchBuildRequest(request: JsonObject, admitted: ?HashSet<String>,
    filterOnlyOverride: ?Bool, offset: Int64): SearchRequest {
    let operation = searchRequestString(request, "operation")
    if (!operation.isEmpty() && operation != "search") {
        throw IllegalArgumentException("search executor only accepts the search operation")
    }
    if (!searchRequestMatchesContractSchema(request)) {
        throw IllegalArgumentException("search request does not satisfy the shared schema")
    }
    let modeValue = searchRequestString(request, "mode")
    let mode = if (modeValue.isEmpty()) { searchContractString("defaultMode") } else { modeValue }
    if (!searchContractEnumContains("mode", mode)) {
        throw IllegalArgumentException("search mode is not declared by the contract")
    }
    let profileValue = searchRequestString(request, "profile")
    let profile = searchRequestProfile(profileValue)
    if (!searchContractProfileIsKnown(profile)) {
        throw IllegalArgumentException("search profile is not declared by the contract")
    }
    let limit = match (request.get("limit")) {
        case Some(value) => value.asInt64()
        case None => searchContractInteger("defaultLimit")
    }
    if (limit < 0 || limit > searchContractInteger("maxLimit")) {
        throw IllegalArgumentException("search limit is outside the contract")
    }
    if (offset < 0) { throw IllegalArgumentException("search offset cannot be negative") }
    let filters = searchRequestFilters(request)
    let setPredicates = searchRequestSetPredicates(request)
    let commentFields = searchRequestCommentFields(request)
    let facet = searchRequestFacet(request)
    let catalogOnly = searchRequestIsCatalogOnly(request, commentFields)
    let filterOnly = match (filterOnlyOverride) {
        case Some(value) => value
        case None => searchRequestIsFilterOnly(request)
    }
    SearchRequest(request, searchRequestString(request, "query"), mode, profile,
        limit, offset, filters, setPredicates, filterOnly, admitted,
        commentFields: commentFields, facetRequested: facet.requested,
        facetId: facet.id, facetLimit: facet.limit, facetCursor: facet.cursor,
        catalogOnly: catalogOnly)
}

/**
 * Normalize filters once: remove duplicates, then sort by field/op/value UTF-8
 * bytes so request order cannot affect execution or cursor identity.
 */
protected func searchNormalizeFilters(filters: ArrayList<SearchFilter>): ArrayList<SearchFilter> {
    let unique = ArrayList<SearchFilter>()
    let seen = HashSet<String>()
    for (filter in filters) {
        if (!seen.contains(filter.key())) {
            let _ = seen.add(filter.key())
            unique.add(filter)
        }
    }
    sort(unique, lessThan: { left, right =>
        if (left.field != right.field) { searchUtf8ByteLess(left.field, right.field) }
        else if (left.op != right.op) { searchUtf8ByteLess(left.op, right.op) }
        else { searchUtf8ByteLess(left.value, right.value) }
    }, stable: true)
    unique
}

internal func searchSelectorsAdmit(entry: SearchProjectedEntry, request: JsonObject): Bool {
    let hasParameters = match (request.get("parameterTypes")) {
        case Some(_) => true
        case None => false
    }
    let hasArity = match (request.get("genericArity")) {
        case Some(_) => true
        case None => false
    }
    if (!hasParameters && !hasArity) { return true }
    if (entry.concept) { return false }
    if (hasArity && entry.genericArity != request.get("genericArity").getOrThrow().asInt64()) {
        return false
    }
    if (hasParameters) {
        let requested = request.get("parameterTypes").getOrThrow().asArray()
        if (requested.size() != entry.parameterTypes.size) { return false }
        for (index in 0..requested.size()) {
            if (requested[index].asString() != entry.parameterTypes[index]) { return false }
        }
    }
    true
}
