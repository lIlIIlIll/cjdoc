protected package cjdoc.query

import cjdoc.render.search as search_engine
import cjdoc.model as query_model
import std.collection.*
import std.convert.Parsable
import std.sort.*
import yjson.*

/**
 * Read a bounded continuation offset bound to the complete canonical request.
 *
 * Every field except `cursor` participates, and the binding also names the frozen
 * catalog content, so a changed snapshot, filter, sort, audience, language,
 * fallback or budget invalidates an old continuation instead of mixing two
 * observations. Cursors carry no secret and are not authentication.
 */
func queryReadCursor(request: JsonObject, catalogId: String): Int64 {
    let cursor = queryString(request, "cursor")
    if (cursor.isEmpty()) { return 0 }
    let profile = querySearchMode(request) + "/" + search_engine.searchRequestProfile(queryString(request, "profile"))
    let binding = queryCursorBinding(request, catalogId, profile)
    let prefix = "cjdoc.cursor/2:"
    if (!cursor.startsWith(prefix)) {
        throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor is not a cjdoc continuation cursor.")
    }
    let body = cursor[prefix.size..]
    let offsetSeparator = match (body.indexOf(":")) {
        case Some(value) => value
        case None => throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor is not a cjdoc continuation cursor.")
    }
    let offsetText = body[..offsetSeparator]
    let remainder = body[offsetSeparator + 1..]
    let profileSeparator = match (remainder.indexOf(":")) {
        case Some(value) => value
        case None => throw DocumentationQueryException("stale_cursor", "cursor_format",
            "Continuation cursor is not a cjdoc continuation cursor.")
    }
    let claimedProfile = remainder[..profileSeparator]
    let digest = remainder[profileSeparator + 1..]
    if (claimedProfile != profile || digest != binding) {
        throw DocumentationQueryException("stale_cursor", "cursor_binding",
            "Continuation cursor no longer matches this snapshot, mode, filters, ordering or budget.")
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
func queryNextCursor(request: JsonObject, catalogId: String, offset: Int64): String {
    let profile = querySearchMode(request) + "/" + search_engine.searchRequestProfile(queryString(request, "profile"))
    "cjdoc.cursor/2:" + offset.toString() + ":" + profile + ":" +
        queryCursorBinding(request, catalogId, profile)
}

private func queryCursorBinding(request: JsonObject, catalogId: String,
    profile: String): String {
    let canonical = JsonNode.object()
    for (index in 0..request.size()) {
        let key = request.nameAt(index)
        if (key == "cursor") { continue }
        if (key == "filters") {
            // Repeated and reordered predicates denote the same query, so the
            // binding sees the normalized set instead of the request spelling.
            let normalized = JsonNode.array()
            for (filter in querySearchFilters(request)) {
                let item = JsonNode.object()
                item.put("field", JsonNode.string(filter.field))
                item.put("op", JsonNode.string(filter.op))
                item.put("value", JsonNode.string(filter.value))
                normalized.add(item)
            }
            canonical.put(key, normalized)
            continue
        }
        canonical.put(key, request.valueAt(index))
    }
    "cjdoc.cursor-binding/2:" + query_model.contractFingerprint(catalogId + "\n" + profile +
        "\n" + queryCanonical(canonical))
}
private func querySearchScopeValue(inputs: ArrayList<QuerySnapshotInput>,
    field: String): JsonNode {
    let ordered = ArrayList<QuerySnapshotInput>()
    for (input in inputs) { ordered.add(input) }
    sort(ordered, lessThan: { left, right =>
        search_engine.searchUtf8ByteLess(left.snapshot.snapshotId, right.snapshot.snapshotId)
    }, stable: true)
    let values = ArrayList<String>()
    for (input in ordered) {
        values.add(match (field) {
            case "snapshotId" => input.snapshot.snapshotId
            case "language" => input.snapshot.locale
            case "audience" => input.documentation.configuration.audience
            case "cfgProfile" => input.documentation.configuration.cfgProfile
            case _ => ""
        })
    }
    if (values.isEmpty()) { return JsonNode.nullValue }
    var allSame = true
    for (value in values) {
        if (value != values[0]) { allSame = false; break }
    }
    if (allSame) { return JsonNode.string(values[0]) }
    let array = JsonArray()
    for (value in values) { array.add(JsonNode.string(value)) }
    array
}

/** Canonical request retains every condition while filling effective scope defaults. */
private func queryCanonicalSearchRequest(request: JsonObject,
    selectedInputs: ArrayList<QuerySnapshotInput>): JsonObject {
    let canonical = JsonObject()
    for (index in 0..request.size()) {
        let key = request.nameAt(index)
        if (["cursor", "filters", "tags", "mode", "profile", "limit", "query", "schemaVersion",
            "operation", "snapshotId", "language", "audience", "cfgProfile",
            "languageFallback", "latest"].contains(key)) { continue }
        canonical.put(key, request.valueAt(index))
    }
    canonical.put("schemaVersion", JsonNode.string(search_engine.searchContractRequestVersion()))
    canonical.put("operation", JsonNode.string("search"))
    canonical.put("query", JsonNode.string(queryString(request, "query")))
    canonical.put("_filterOnlyEligible", JsonNode.boolean(search_engine.searchRequestIsFilterOnly(request)))
    canonical.put("snapshotId", querySearchScopeValue(selectedInputs, "snapshotId"))
    for (field in ["language", "audience", "cfgProfile"]) {
        match (request.get(field)) {
            case Some(value) => canonical.put(field, value)
            case None => canonical.put(field, querySearchScopeValue(selectedInputs, field))
        }
    }
    canonical.put("languageFallback", JsonNode.boolean(queryBool(request, "languageFallback")))
    canonical.put("latest", JsonNode.boolean(queryBool(request, "latest")))
    canonical.put("mode", JsonNode.string(querySearchMode(request)))
    canonical.put("profile", JsonNode.string(querySearchProfile(request)))
    canonical.put("limit", JsonNode.int64(if (request.get("limit").isSome()) {
        queryInt(request, "limit")
    } else { search_engine.searchContractInteger("defaultLimit") }))
    let filters = JsonArray()
    for (filter in querySearchFilters(request)) {
        let item = JsonObject()
        item.put("field", JsonNode.string(filter.field))
        item.put("op", JsonNode.string(filter.op))
        item.put("value", JsonNode.string(filter.value))
        filters.add(item)
    }
    canonical.put("filters", filters)
    let tags = JsonArray()
    for (tag in search_engine.searchNormalizeSetPredicateValues(request, "tags")) {
        tags.add(JsonNode.string(tag))
    }
    canonical.put("tags", tags)
    canonical
}

private func querySearchCursorDigest(request: JsonObject, contentIdentity: String,
    projectionId: String, profile: String,
    selectedInputs: ArrayList<QuerySnapshotInput>): String {
    let contentBinding = contentIdentity + "\n" + projectionId
    let canonicalRequest = queryCanonical(queryCanonicalSearchRequest(request, selectedInputs))
    query_model.contractFingerprint("cjdoc.cursor-binding/2:" + contentBinding + "\n" +
        profile + "\n" + canonicalRequest)
}

private func querySearchCursorFormatFailure(message: String): Nothing {
    throw DocumentationQueryException("stale_cursor", "cursor_format", message)
}

private func querySearchCursorBindingFailure(): Nothing {
    throw DocumentationQueryException("stale_cursor", "cursor_binding",
        "Continuation cursor no longer matches this catalog, profile or canonical request.")
}

private func querySearchCursorDigestIsValid(value: String): Bool {
    if (value.size != 64) { return false }
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (!((code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x61u32 && code <= 0x66u32))) { return false }
    }
    true
}

/** Search cursor: `cjdoc.cursor/2:<offset>:<profile>:<digest>`. */
func queryReadSearchCursor(request: JsonObject, contentIdentity: String,
    profile: String, projectionId: String,
    selectedInputs: ArrayList<QuerySnapshotInput>): Int64 {
    let cursor = queryString(request, "cursor")
    if (cursor.isEmpty()) { return 0 }
    let prefix = "cjdoc.cursor/2:"
    if (!cursor.startsWith(prefix)) {
        querySearchCursorFormatFailure("Continuation cursor is not a cjdoc search cursor.")
    }
    let body = cursor[prefix.size..]
    let offsetSeparator = match (body.indexOf(":")) {
        case Some(value) => value
        case None => querySearchCursorFormatFailure("Continuation cursor has an invalid format.")
    }
    let offsetText = body[..offsetSeparator]
    let remainder = body[offsetSeparator + 1..]
    let profileSeparator = match (remainder.indexOf(":")) {
        case Some(value) => value
        case None => querySearchCursorFormatFailure("Continuation cursor has an invalid format.")
    }
    let claimedProfile = remainder[..profileSeparator]
    let digest = remainder[profileSeparator + 1..]
    if (digest.contains(":") || offsetText.isEmpty() ||
        !search_engine.searchContractProfileIsKnown(claimedProfile) ||
        !querySearchCursorDigestIsValid(digest)) {
        querySearchCursorFormatFailure("Continuation cursor has an invalid format.")
    }
    for (rune in offsetText.runes()) {
        let code = UInt32(rune)
        if (code < 0x30u32 || code > 0x39u32) {
            querySearchCursorFormatFailure("Continuation cursor offset is not a nonnegative integer.")
        }
    }
    let offset = try {
        Int64.parse(offsetText)
    } catch (_: Exception) {
        querySearchCursorFormatFailure("Continuation cursor offset is outside the supported range.")
    }
    if (claimedProfile != profile || digest != querySearchCursorDigest(
        request, contentIdentity, projectionId, profile, selectedInputs)) {
        querySearchCursorBindingFailure()
    }
    offset
}

/** Create a host-local opaque search continuation token. */
func queryNextSearchCursor(request: JsonObject, contentIdentity: String,
    projectionId: String, profile: String, offset: Int64,
    selectedInputs: ArrayList<QuerySnapshotInput>): String {
    "cjdoc.cursor/2:" + offset.toString() + ":" + profile + ":" +
        querySearchCursorDigest(request, contentIdentity, projectionId, profile, selectedInputs)
}
