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
    // Canonical capture identities admitted by native snapshot/module/source
    // selection. Keys are `snapshotId\0canonicalId`.
    protected let admitted: ?HashSet<String>

    protected init(fields: JsonObject, query: String, mode: String, profile: String,
        limit: Int64, offset: Int64, filters: ArrayList<SearchFilter>,
        setPredicates: HashMap<String, Array<String>>,
        filterOnly: Bool, admitted: ?HashSet<String>) {
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
            "languageFallback"].contains(field)) { continue }
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
    let filterOnly = match (filterOnlyOverride) {
        case Some(value) => value
        case None => searchRequestIsFilterOnly(request)
    }
    SearchRequest(request, searchRequestString(request, "query"), mode, profile,
        limit, offset, filters, setPredicates, filterOnly, admitted)
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
