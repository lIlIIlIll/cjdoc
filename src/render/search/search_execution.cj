protected package cjdoc.render.search

import cjdoc.render.publication.declarationClassificationJsonNode
import std.collection.*
import std.sort.*
import yjson.*

private func searchApplyMatchedExposures(evidence: SearchEvidence,
    filterMatch: SearchFilterMatch): Unit {
    for (exposureId in filterMatch.matchedExposureIds) {
        if (!evidence.matchedExposureIds.contains(exposureId)) {
            evidence.matchedExposureIds.add(exposureId)
        }
    }
    sort(evidence.matchedExposureIds,
        lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
}

protected func executeDocumentationSearchAcross(set: SearchProjectionSet,
    request: JsonObject, admitted: ?HashSet<String>, filterOnly: ?Bool,
    offset: Int64): JsonObject {
    let operation = searchRequestString(request, "operation")
    if (!operation.isEmpty() && operation != "search") {
        let unavailable = SearchExecutionResult()
        unavailable.status = "invalid_request"
        unavailable.errorCode = "operation_unavailable"
        unavailable.errorMessage = "The search executor only accepts operation 'search'."
        return searchExecutionJson(unavailable)
    }
    var normalized: ?SearchRequest = None
    try {
        normalized = Some(searchBuildRequest(request, admitted, filterOnly, offset))
    } catch (error: Exception) {
        let _ = error
        let failure = SearchExecutionResult()
        failure.status = "invalid_request"
        failure.errorCode = "request_schema"
        failure.errorMessage = "Search request does not satisfy the shared contract."
        return searchExecutionJson(failure)
    }
    searchExecutionJson(searchExecute(set, normalized.getOrThrow()))
}

private func searchTopLevelAmbiguous(entries: ArrayList<SearchRankedEntry>): Bool {
    if (entries.size < 2) { return false }
    let highestLevel = entries[0].evidence.level
    if (highestLevel <= 0) { return false }
    var count: Int64 = 0
    for (entry in entries) {
        if (entry.evidence.level != highestLevel) { break }
        count++
    }
    count > 1
}

private func searchExecute(set: SearchProjectionSet, request: SearchRequest): SearchExecutionResult {
    let result = SearchExecutionResult()
    result.coverage = Some(searchCoverageOf(set))
    if (request.profile != set.profile) {
        result.status = "unavailable"
        result.errorCode = "search_profile_unavailable"
        result.errorMessage = "The requested search profile is not available in this projection."
        result.coverage = None
        return result
    }
    for (projection in set.projections) {
        if (projection.profile != request.profile) {
            result.status = "unavailable"
            result.errorCode = "search_profile_unavailable"
            result.errorMessage = "Search projections in one execution must share a profile."
            result.coverage = None
            return result
        }
    }
    let query = request.query
    let emptyQuery = query.trimAscii().isEmpty()
    if (emptyQuery && !request.filterOnly && !searchRequestHasFlatSelector(request.fields)) {
        result.status = "not_found"
        result.reason = "no_match_in_scope"
        result.complete = true
        return result
    }
    let tokens = searchTokens(query)
    let editTokenRunes: Array<Rune> =
        if (request.mode == "discovery" && tokens.size == 1) {
            searchRunes(tokens[0])
        } else { [] }
    let foldedQuery = if (query.isEmpty()) { "" } else { searchAsciiFold(query) }
    let candidates = ArrayList<SearchRankedEntry>()
    let hasSelectors = match (request.fields.get("parameterTypes")) {
        case Some(_) => true
        case None => match (request.fields.get("genericArity")) {
            case Some(_) => true
            case None => false
        }
    }
    for (projection in set.projections) {
        for (facts in projection.entries) {
            let entry = facts.entry
            if (let Some(allowed) <- request.admitted) {
                if (!allowed.contains(searchIdentityKey(entry.snapshotId, entry.canonicalId))) {
                    continue
                }
            }
            if (!searchSelectorsAdmit(entry, request.fields)) { continue }
            let filterMatch = searchFilterAdmits(facts, request.filters)
            if (!filterMatch.admitted ||
                !searchSetPredicatesAdmit(entry, request.setPredicates)) { continue }
            let explicit = searchExplicitSelector(facts, request.fields, request.mode, hasSelectors)
            let evidence: ?SearchEvidence = if (explicit.selected) {
                explicit.evidence
            } else if (emptyQuery && request.filterOnly) {
                Some(searchRuleEvidence(request.mode, "filter_only", "", false))
            } else if (emptyQuery) {
                None
            } else if (request.mode == "precise") {
                searchPreciseQueryEvidence(facts, query, tokens, hasSelectors)
            } else {
                searchDiscoveryEvidence(facts, query, foldedQuery, tokens, editTokenRunes)
            }
            match (evidence) {
                case Some(value) =>
                    searchApplyMatchedExposures(value, filterMatch)
                    candidates.add(SearchRankedEntry(entry, value))
                case None => ()
            }
        }
    }
    let unique = searchDeduplicate(candidates)
    searchSortRanked(unique)
    result.offset = request.offset
    result.total = unique.size
    if (request.offset > unique.size) {
        result.status = "stale_cursor"
        result.errorCode = "cursor_out_of_range"
        result.errorMessage = "Continuation cursor is beyond the current result set."
        return result
    }
    for (facet in searchBuildTagFacets(unique)) { result.facets.add(facet) }
    let end = if (request.offset + request.limit > unique.size) {
        unique.size
    } else { request.offset + request.limit }
    result.complete = end >= unique.size
    result.reason = if (unique.isEmpty()) { "no_match_in_scope" }
        else if (request.filterOnly && emptyQuery) { "filter_only" } else { "" }
    var position = request.offset
    while (position < end) {
        let candidate = unique[position]
        result.hits.add(SearchHit(candidate.entry.snapshotId, candidate.entry.canonicalId,
            candidate.evidence.score, candidate.evidence.reason,
            candidate.evidence.matchedExposureIds.toArray(), candidate.evidence.anchor,
            candidate.entry.classification))
        position++
    }
    result.returned = result.hits.size
    let ambiguous = request.mode == "precise" && !request.filterOnly &&
        searchTopLevelAmbiguous(unique)
    result.status = if (unique.isEmpty()) { "not_found" }
        else if (ambiguous) { "ambiguous" } else { "ok" }
    if (ambiguous) { result.reason = "several_captured_identities_tie" }
    if (unique.isEmpty() && !set.sourceComplete) {
        result.status = "source_incomplete"
        result.reason = "no_match_with_incomplete_api_collection"
    }
    if (request.limit == 0 && !unique.isEmpty()) { result.reason = "zero_limit_requested" }
    result
}

private func searchCoverageOf(set: SearchProjectionSet): SearchCoverage {
    let profile = set.profile
    SearchCoverage(profile, set.projectionId,
        if (profile == searchContractString("defaultProfile")) { None }
            else { Some(searchContractInteger("staticBodyTextLimit")) },
        set.bodyComplete, set.truncatedCount)
}

private func searchNullableString(value: ?String): JsonNode {
    match (value) {
        case Some(text) => JsonNode.string(text)
        case None => JsonNode.nullValue
    }
}

private func searchCoverageJson(coverage: ?SearchCoverage): JsonNode {
    match (coverage) {
        case Some(value) =>
            let node = JsonObject()
            node.put("profile", JsonNode.string(value.profile))
            node.put("projectionId", JsonNode.string(value.projectionId))
            match (value.bodyTextLimit) {
                case Some(limit) => node.put("bodyTextLimit", JsonNode.int64(limit))
                case None => node.put("bodyTextLimit", JsonNode.nullValue)
            }
            node.put("bodyComplete", JsonNode.boolean(value.bodyComplete))
            node.put("truncatedEntries", JsonNode.int64(value.truncatedEntries))
            node
        case None => JsonNode.nullValue
    }
}
private func searchTagFacetsJson(facets: ArrayList<SearchTagFacet>): JsonObject {
    let out = StringBuilder()
    out.append("{\"tags\":[")
    var first = true
    for (facet in facets) {
        if (!first) { out.append(",") }
        first = false
        appendSearchTagFacetJson(out, facet.tag, facet.count)
    }
    out.append("]}")
    JsonNode.parse(out.toString()).asObject()
}


private func searchExecutionJson(result: SearchExecutionResult): JsonObject {
    let node = JsonObject()
    node.put("status", JsonNode.string(result.status))
    node.put("errorCode", JsonNode.string(result.errorCode))
    node.put("reason", JsonNode.string(result.reason))
    let items = JsonArray()
    for (hit in result.hits) {
        let item = JsonObject()
        item.put("snapshotId", JsonNode.string(hit.snapshotId))
        item.put("canonicalId", JsonNode.string(hit.canonicalId))
        item.put("score", JsonNode.int64(hit.score))
        item.put("reason", JsonNode.string(hit.reason))
        let exposures = JsonArray()
        for (id in hit.matchedExposureIds) { exposures.add(JsonNode.string(id)) }
        item.put("matchedExposureIds", exposures)
        item.put("anchor", JsonNode.string(hit.anchor))
        item.put("classification", declarationClassificationJsonNode(hit.classification))
        items.add(item)
    }
    node.put("items", items)
    node.put("offset", JsonNode.int64(result.offset))
    node.put("returned", JsonNode.int64(result.returned))
    node.put("total", JsonNode.int64(result.total))
    node.put("complete", JsonNode.boolean(result.complete))
    node.put("next", searchNullableString(result.next))
    node.put("coverage", searchCoverageJson(result.coverage))
    node.put("facets", searchTagFacetsJson(result.facets))
    node
}
