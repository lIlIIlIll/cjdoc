protected package cjdoc.render.search

import cjdoc.model.*
import std.collection.*
import std.convert.Parsable
import std.sort.*
import yjson.*


/**
 * Attach published comment fields to the retrieval projection.
 *
 * The dictionary is module-scoped and locale-selected: only the title this index
 * actually publishes enters the dictionary, and only declarations of the same
 * module may carry its values. A definition no entry uses is not published.
 */
protected func attachSearchCommentFields(documentation: DocumentationSet,
    result: DocumentationSearchProjection): Unit {
    let locale = result.language
    let defsByScope = HashMap<String, SearchProjectionCommentField>()
    let rowsByEntry = HashMap<String, ArrayList<SearchCommentFieldUse>>()
    for (field in documentation.metadata.fields) {
        let scope = match (result.modulePosition(field.moduleId)) {
            case Some(value) => value
            case None => continue
        }
        let definition = SearchProjectionCommentField(scope, field.id, field.titleFor(locale),
            field.repeatable)
        defsByScope[field.moduleId + "\u{0}" + field.id] = definition
        for (use in field.uses) {
            let key = field.moduleId + "\u{0}" + use.symbolId
            let row = SearchCommentFieldUse(field.id, use.values.toArray())
            match (rowsByEntry.get(key)) {
                case Some(rows) => rows.add(row)
                case None =>
                    let rows = ArrayList<SearchCommentFieldUse>()
                    rows.add(row)
                    rowsByEntry[key] = rows
            }
        }
    }
    if (defsByScope.isEmpty()) { return }
    let usedDefinitions = HashSet<String>()
    for (entry in result.entries) {
        if (entry.concept) { continue }
        let rows = match (rowsByEntry.get(entry.moduleId + "\u{0}" + entry.canonicalId)) {
            case Some(value) => value
            case None => continue
        }
        sort(rows, lessThan: { left, right =>
            searchUtf8ByteLess(left.id, right.id)
        }, stable: true)
        for (row in rows) {
            let _ = usedDefinitions.add(entry.moduleId + "\u{0}" + row.id)
        }
        entry.commentFieldRows = rows.toArray()
    }
    let dictionary = ArrayList<SearchProjectionCommentField>()
    for (key in usedDefinitions) {
        match (defsByScope.get(key)) {
            case Some(value) => dictionary.add(value)
            case None => ()
        }
    }
    sort(dictionary, lessThan: { left, right =>
        if (left.scope != right.scope) { left.scope < right.scope }
        else { searchUtf8ByteLess(left.id, right.id) }
    }, stable: true)
    result.commentFieldDictionary.add(all: dictionary)
}

/**
 * Reject a projection whose field data could not have been produced.
 *
 * Definitions and uses must share one module scope, every definition must be
 * used, each entry may reference a field at most once, and a single-value field
 * may not carry two values. Both executors call this before answering.
 */
protected func searchValidateCommentFields(projection: DocumentationSearchProjection): Unit {
    let definitions = HashMap<String, SearchProjectionCommentField>()
    var previous: ?SearchProjectionCommentField = None
    for (definition in projection.commentFieldDictionary) {
        if (definition.scope < 0 || definition.scope >= Int64(projection.modules.size) ||
            !isDocumentationFieldId(definition.id)) {
            throw IllegalArgumentException("search comment field scope is outside the module table")
        }
        let key = definition.scope.toString() + "\u{0}" + definition.id
        if (let Some(prior) <- previous) {
            if (prior.scope > definition.scope || (prior.scope == definition.scope &&
                !searchUtf8ByteLess(prior.id, definition.id))) {
                throw IllegalArgumentException("search comment field dictionary is not strictly ordered")
            }
        }
        previous = Some(definition)
        definitions[key] = definition
    }
    let used = HashSet<String>()
    for (entry in projection.entries) {
        var previousId = ""
        for (row in entry.commentFieldRows) {
            if (entry.concept || (!previousId.isEmpty() && !searchUtf8ByteLess(previousId, row.id))) {
                throw IllegalArgumentException("search entry comment fields are invalid or out of order")
            }
            previousId = row.id
            let key = entry.scope.toString() + "\u{0}" + row.id
            let definition = match (definitions.get(key)) {
                case Some(value) => value
                case None =>
                    throw IllegalArgumentException("search entry references an unpublished comment field")
            }
            let _ = used.add(key)
            let values = row.values()
            if (values.isEmpty() || (!definition.repeatable && values.size > 1)) {
                throw IllegalArgumentException("search comment field has invalid value cardinality")
            }
            for (value in values) {
                if (!isDocumentationFieldValue(value)) {
                    throw IllegalArgumentException("search entry has an invalid comment field value")
                }
            }
        }
    }
    for (key in definitions.keys()) {
        if (!used.contains(key)) {
            throw IllegalArgumentException("search comment field dictionary has an unused definition")
        }
    }
}

internal func searchAmbiguousCommentField(set: SearchProjectionSet,
    requested: Array<(String, String)>, moduleAdmitted: (SearchScopeModule) -> Bool): ?String {
    if (requested.isEmpty()) { return None }
    let wanted = HashSet<String>()
    for ((id, _) in requested) { let _ = wanted.add(id) }
    let resolved = HashMap<String, (String, String)>()
    for (prepared in set.projections) {
        for (field in prepared.projection.commentFieldDictionary where wanted.contains(field.id)) {
            let module = prepared.projection.modules[field.scope]
            if (!moduleAdmitted(module)) { continue }
            let scope = (prepared.scopeSnapshotId, module.moduleId)
            if (let Some(prior) <- resolved.get(field.id)) {
                if (prior != scope) { return Some(field.id) }
            } else {
                resolved[field.id] = scope
            }
        }
    }
    None
}

/**
 * Whether one entry satisfies every exact comment-field predicate.
 *
 * A predicate is satisfied when the declaration's own field carries the value
 * verbatim: no case folding, no prefix matching, no inherited owner value.
 */
protected func searchCommentFieldsAdmit(entry: SearchProjectedEntry,
    requested: Array<(String, String)>): Bool {
    if (requested.isEmpty()) { return true }
    if (entry.concept) { return false }
    for ((fieldId, value) in requested) {
        var found = false
        for (row in entry.commentFieldRows) {
            if (row.id != fieldId) { continue }
            for (stored in row.values()) {
                if (stored == value) {
                    found = true
                    break
                }
            }
            if (found) { break }
        }
        if (!found) { return false }
    }
    true
}

/** One counted facet row: a field value and how many declarations carry it. */
protected class SearchCommentFieldFacet {
    protected let snapshotId: String
    protected let moduleId: String
    protected let id: String
    protected let title: String
    protected let value: String
    protected let count: Int64

    protected init(snapshotId: String, moduleId: String, id: String, title: String,
        value: String, count: Int64) {
        this.snapshotId = snapshotId
        this.moduleId = moduleId
        this.id = id
        this.title = title
        this.value = value
        this.count = count
    }
}

/**
 * Count every canonical declaration admitted by the current conditions.
 *
 * Counting happens before the hit page window, so `limit: 0` or a late cursor
 * cannot change a count, and one declaration with a repeated value contributes
 * once per value.
 */
protected func searchCountCommentFieldFacets(set: SearchProjectionSet,
    requestedId: ?String, candidates: ArrayList<SearchRankedEntry>): ArrayList<SearchCommentFieldFacet> {
    // Titles are locale-selected per projection, so each snapshot resolves its own
    // display title instead of borrowing another snapshot's dictionary.
    let titlesBySnapshot = HashMap<String, HashMap<String, String>>()
    for (projection in set.projections) {
        let titles = HashMap<String, String>()
        for (definition in projection.projection.commentFieldDictionary) {
            let moduleId = projection.projection.modules[definition.scope].moduleId
            titles[moduleId + "\u{0}" + definition.id] = definition.title
        }
        titlesBySnapshot[projection.scopeSnapshotId] = titles
    }
    let counts = HashMap<String, SearchCommentFieldFacet>()
    let perEntry = HashMap<String, HashSet<String>>()
    for (candidate in candidates) {
        let entry = candidate.entry
        if (entry.concept) { continue }
        let identity = entry.snapshotId + "\u{0}" + entry.canonicalId
        let seen = match (perEntry.get(identity)) {
            case Some(value) => value
            case None =>
                let created = HashSet<String>()
                perEntry[identity] = created
                created
        }
        let titles = match (titlesBySnapshot.get(entry.snapshotId)) {
            case Some(value) => value
            case None => continue
        }
        for (row in entry.commentFieldRows) {
            if (let Some(filtered) <- requestedId) {
                if (row.id != filtered) { continue }
            }
            let fieldKey = entry.moduleId + "\u{0}" + row.id
            let title = titles.get(fieldKey).getOrDefault({ => row.id })
            for (value in row.values()) {
                // One bucket per snapshot: two snapshots publishing the same field
                // and value stay separate rows, never one merged count.
                let key = fieldKey + "\u{0}" + value
                if (!seen.add(key)) { continue }
                let bucket = entry.snapshotId + "\u{0}" + key
                match (counts.get(bucket)) {
                    case Some(existing) =>
                        counts[bucket] = SearchCommentFieldFacet(entry.snapshotId,
                            existing.moduleId, existing.id, existing.title, existing.value,
                            existing.count + 1)
                    case None =>
                        counts[bucket] = SearchCommentFieldFacet(entry.snapshotId,
                            entry.moduleId, row.id, title, value, 1)
                }
            }
        }
    }
    let ordered = ArrayList<SearchCommentFieldFacet>()
    for (key in counts.keys()) { ordered.add(counts[key]) }
    sort(ordered, lessThan: { left, right =>
        if (left.snapshotId != right.snapshotId) {
            searchUtf8ByteLess(left.snapshotId, right.snapshotId)
        } else if (left.moduleId != right.moduleId) {
            searchUtf8ByteLess(left.moduleId, right.moduleId)
        } else if (left.id != right.id) {
            searchUtf8ByteLess(left.id, right.id)
        } else { searchUtf8ByteLess(left.value, right.value) }
    }, stable: true)
    ordered
}

private let SEARCH_FACET_CURSOR_PREFIX = "cjdoc.comment-field-facets/1:"
private let SEARCH_FACET_PAGE_BYTES: Int64 = 1024 * 1024

internal func searchFacetCursorDigest(requestBinding: String): String {
    contractFingerprint("cjdoc.comment-field-facets-binding/1:" + requestBinding)
}

internal func searchReadFacetCursor(cursor: String, expectedDigest: String): Int64 {
    if (!cursor.startsWith(SEARCH_FACET_CURSOR_PREFIX)) {
        throw IllegalArgumentException("Comment field facet cursor has an unsupported format.")
    }
    let body = cursor[SEARCH_FACET_CURSOR_PREFIX.size..]
    let separator = match (body.indexOf(":")) {
        case Some(value) => value
        case None => throw IllegalArgumentException("Comment field facet cursor has an unsupported format.")
    }
    let offset = body[..separator]
    if (offset.isEmpty() || (offset.size > 1 && offset[0] == b'0') ||
        body[separator + 1..] != expectedDigest) {
        throw IllegalArgumentException("Comment field facet cursor no longer matches this search request.")
    }
    for (index in 0..offset.size) {
        if (offset[index] < b'0' || offset[index] > b'9') {
            throw IllegalArgumentException("Comment field facet cursor offset is not an integer.")
        }
    }
    try { Int64.parse(offset) } catch (_: Exception) {
        throw IllegalArgumentException("Comment field facet cursor offset is outside the supported range.")
    }
}

private func searchFacetRowJson(row: SearchCommentFieldFacet): JsonObject {
    let item = JsonObject()
    let scope = JsonObject()
    scope.put("snapshotId", JsonNode.string(row.snapshotId))
    scope.put("moduleId", JsonNode.string(row.moduleId))
    item.put("scope", scope)
    item.put("id", JsonNode.string(row.id))
    item.put("title", JsonNode.string(row.title))
    item.put("value", JsonNode.string(row.value))
    item.put("count", JsonNode.int64(row.count))
    item
}

internal func searchAppendFacetPage(result: SearchExecutionResult, rows: ArrayList<SearchCommentFieldFacet>,
    start: Int64, limit: Int64, digest: String): Bool {
    if (start > rows.size) {
        result.status = "stale_cursor"
        result.errorCode = "cursor_out_of_range"
        result.errorMessage = "Comment field facet cursor is beyond the current value set."
        return false
    }
    let items = JsonArray()
    var position = start
    var bytes: Int64 = 0
    while (position < rows.size && position - start < limit) {
        let item = searchFacetRowJson(rows[position])
        let itemBytes = item.toJson().size
        let next = SEARCH_FACET_CURSOR_PREFIX + (position + 1).toString() + ":" + digest
        let trailerBytes = if (position + 1 < rows.size) { next.size + 2 } else { 4 }
        let separatorBytes = if (position == start) { 0 } else { 1 }
        if (bytes + itemBytes + separatorBytes + trailerBytes + "{\"items\":[],\"next\":}".size >
            SEARCH_FACET_PAGE_BYTES) {
            if (position > start) { break }
            result.status = "resource_limit"
            result.errorCode = "comment_field_facet_byte_limit"
            result.errorMessage = "A comment field facet row exceeds the encoded page budget."
            return false
        }
        items.add(item)
        bytes += itemBytes + separatorBytes
        position++
    }
    let page = JsonObject()
    page.put("items", items)
    page.put("next", if (position == rows.size) { JsonNode.nullValue }
        else { JsonNode.string(SEARCH_FACET_CURSOR_PREFIX + position.toString() + ":" + digest) })
    result.commentFacetPage = Some(page)
    true
}
