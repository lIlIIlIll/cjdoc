package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// Search ranks only with evidence the projection already holds: stable symbol
// identity, source spellings, re-export exposure, owner and literal author text.
// Relevance is never presented as overload applicability or compiler resolution.

/** One comparable match level together with the exact reason it was reached. */
internal class QueryMatch {
    let level: Int64
    let reason: String
    let score: Int64

    init(level: Int64, reason: String, score: Int64) {
        this.level = level
        this.reason = reason
        this.score = score
    }
}

/**
 * Whether one captured document set satisfies the request's fixed-scope filters.
 *
 * The filters can only narrow the captured scope. A value that contradicts the
 * captured evidence excludes the candidate instead of being reinterpreted, and an
 * unknown captured value never matches a requested one.
 */
internal func queryScopeAdmits(documentSet: ?query_model.DocumentSetIdentity,
    dependency: ?query_model.DependencyInstance, request: JsonObject): Bool {
    let documentSetId = queryString(request, "documentSetId")
    if (!documentSetId.isEmpty()) {
        let matched = match (documentSet) {
            case Some(value) => value.id == documentSetId
            case None => false
        }
        if (!matched) { return false }
    }
    let apiVersion = queryString(request, "apiVersion")
    if (!apiVersion.isEmpty()) {
        let matched = match (documentSet) {
            case Some(value) => value.apiVersion == apiVersion
            case None => false
        }
        if (!matched) { return false }
    }
    let library = queryString(request, "library")
    if (!library.isEmpty()) {
        let matched = match (documentSet) {
            case Some(value) => value.library == library
            case None => false
        }
        if (!matched) { return false }
    }
    let dependencyInstanceId = queryString(request, "dependencyInstanceId")
    if (!dependencyInstanceId.isEmpty()) {
        let matched = match (dependency) {
            case Some(value) => value.instanceId == dependencyInstanceId
            case None => false
        }
        if (!matched) { return false }
    }
    let target = queryString(request, "target")
    if (!target.isEmpty() && !queryScopeTargetAdmits(documentSet, dependency, target)) { return false }
    let cfg = queryString(request, "cfg")
    if (!cfg.isEmpty() && !queryScopeCfgAdmits(documentSet, dependency, cfg)) { return false }
    true
}

// `*` is the captured wildcard used by document coverage, never a guess.
private func queryScopeTargetAdmits(documentSet: ?query_model.DocumentSetIdentity,
    dependency: ?query_model.DependencyInstance, requested: String): Bool {
    var known = false
    match (documentSet) {
        case Some(value) =>
            if (!value.target.isEmpty()) {
                known = true
                if (value.target != requested && value.target != "*") { return false }
            }
        case None => ()
    }
    match (dependency) {
        case Some(value) =>
            if (!value.target.isEmpty()) {
                known = true
                if (value.target != requested) { return false }
            }
        case None => ()
    }
    known
}

private func queryScopeCfgAdmits(documentSet: ?query_model.DocumentSetIdentity,
    dependency: ?query_model.DependencyInstance, requested: String): Bool {
    var known = false
    match (documentSet) {
        case Some(value) =>
            if (!value.cfg.isEmpty()) {
                known = true
                if (value.cfg != requested && value.cfg != "*") { return false }
            }
        case None => ()
    }
    match (dependency) {
        case Some(value) =>
            if (!value.cfg.isEmpty()) {
                known = true
                if (value.cfg != requested) { return false }
            }
        case None => ()
    }
    known
}

internal func queryModuleIdMatches(input: QuerySnapshotInput, moduleId: String,
    request: JsonObject): Bool {
    let requested = queryString(request, "moduleId")
    if (requested.isEmpty()) { return true }
    if (moduleId == requested) { return true }
    match (queryModuleFor(input, moduleId)) {
        case Some(module) => module.name == requested
        case None => false
    }
}

internal func queryPackageMatches(symbol: query_model.SymbolDoc, request: JsonObject): Bool {
    let requested = queryString(request, "packageName")
    requested.isEmpty() || symbol.packageName == requested
}

internal func queryKindMatches(symbol: query_model.SymbolDoc, request: JsonObject): Bool {
    let requested = queryString(request, "kind")
    requested.isEmpty() || symbol.kind == requested
}


/** Captured identity reattached after the pure projection executor selects it. */
internal class QueryCandidate {
    let input: QuerySnapshotInput
    let document: QueryDocument
    let symbol: ?query_model.SymbolDoc
    let page: ?query_model.DocumentationPage
    let relevance: QueryMatch
    let matchedExposureIds = ArrayList<String>()

    init(input: QuerySnapshotInput, document: QueryDocument, symbol: ?query_model.SymbolDoc,
        page: ?query_model.DocumentationPage, relevance: QueryMatch,
        matchedExposureIds!: Array<String> = []) {
        this.input = input
        this.document = document
        this.symbol = symbol
        this.page = page
        this.relevance = relevance
        this.matchedExposureIds.add(all: matchedExposureIds)
    }

}

/** Search through the shared projection executor, then reattach captured DTOs. */
internal func querySearch(projection: QueryProjection, request: JsonObject,
    contentBinding: String): QueryOutcome {
    let outcome = QueryOutcome("ok", "catalog")
    if (queryBool(request, "latest") && !queryAnyLatest(projection.inputs)) {
        throw DocumentationQueryException("unavailable", "latest_not_declared",
            "No loaded snapshot is declared latest; name an explicit snapshot identity instead.")
    }
    let mode = querySearchMode(request)
    let profile = querySearchProfile(request)
    let filterOnly = query_render.searchRequestIsFilterOnly(request)
    let admitted = HashSet<String>()
    let byKey = HashMap<String, QueryCandidate>()
    let selectedInputs = ArrayList<QuerySnapshotInput>()
    let projectionSet = query_render.SearchProjectionSet()
    for (input in projection.inputs) {
        if (queryBool(request, "latest") && !input.isLatest) { continue }
        let document = match (projection.catalog.byInput.get(input.snapshot.snapshotId)) {
            case Some(value) => value
            case None => continue
        }
        selectedInputs.add(input)
        projectionSet.addPrepared(document.searchExecutionProjectionFor(profile))
        for (symbol in document.visibleSymbols) {
            if (!queryModuleIdMatches(input, symbol.moduleId, request)) { continue }
            if (!queryPackageMatches(symbol, request)) { continue }
            if (!queryKindMatches(symbol, request)) { continue }
            let (dependency, _) = queryDependencyState(input, symbol.moduleId)
            if (!queryScopeAdmits(queryDocumentSetFor(input, symbol.moduleId), dependency, request)) {
                continue
            }
            let key = query_render.searchIdentityKey(input.snapshot.snapshotId, symbol.id)
            if (admitted.contains(key)) { continue }
            let _ = admitted.add(key)
            byKey[key] = QueryCandidate(input, document, Some(symbol),
                Option<query_model.DocumentationPage>.None, QueryMatch(0, "", 0))
        }
        for (page in document.pages) {
            if (!queryPageAdmitted(input, page, request)) { continue }
            let key = query_render.searchIdentityKey(input.snapshot.snapshotId, page.id)
            if (admitted.contains(key)) { continue }
            let _ = admitted.add(key)
            byKey[key] = QueryCandidate(input, document,
                Option<query_model.SymbolDoc>.None, Some(page), QueryMatch(0, "", 0))
        }
    }

    let limit = if (request.get("limit").isSome()) {
        queryInt(request, "limit")
    } else { query_render.searchContractInteger("defaultLimit") }
    var offset: Int64 = 0
    try {
        offset = queryReadSearchCursor(request, contentBinding, profile,
            projectionSet.projectionId, selectedInputs)
    } catch (error: DocumentationQueryException) {
        outcome.status = error.status
        outcome.error = Some(queryErrorNode(error.code, error.message,
            Option<Int64>.None, Option<Int64>.None))
        outcome.limit = limit
        outcome.contentComplete = querySourceComplete(selectedInputs)
        outcome.coverage = Some(querySearchCoverageFromSet(projectionSet, profile))
        outcome.selectedSections = querySectionList(QUERY_SUMMARY_SECTIONS)
        outcome.text = "Documentation query failed: ${error.status}. ${error.message}"
        return outcome
    }
    let execution = query_render.executeDocumentationSearchAcross(projectionSet, request,
        Some(admitted), Some(filterOnly), offset)
    let executionStatus = queryString(execution, "status")
    let executionError = queryString(execution, "errorCode")
    outcome.status = executionStatus
    outcome.offset = queryInt(execution, "offset")
    outcome.limit = limit
    outcome.returned = queryInt(execution, "returned")
    outcome.total = Some(queryInt(execution, "total"))
    outcome.complete = queryBool(execution, "complete")
    outcome.coverage = match (execution.get("coverage")) {
        case Some(node) => querySearchCoverageFromNode(node)
        case None => None
    }
    outcome.facets = match (execution.get("facets")) {
        case Some(value) => value.asObject()
        case None => queryEmptyFacetsNode()
    }
    outcome.contentComplete = querySourceComplete(selectedInputs)
    if (!executionError.isEmpty()) {
        let message = if (executionError == "cursor_out_of_range") {
            "Continuation cursor is beyond the current result set."
        } else { "Search execution could not use the requested profile or request fields." }
        outcome.error = Some(queryErrorNode(executionError, message,
            Option<Int64>.None, Option<Int64>.None))
        outcome.selectedSections = querySectionList(QUERY_SUMMARY_SECTIONS)
        outcome.text = "Documentation query failed: ${outcome.status}. ${message}"
        return outcome
    }
    let items = execution.get("items").getOrThrow().asArray()
    let candidates = ArrayList<QueryCandidate>()
    for (index in 0..items.size()) {
        let hit = items[index].asObject()
        let snapshotId = queryString(hit, "snapshotId")
        let canonicalId = queryString(hit, "canonicalId")
        let key = query_render.searchIdentityKey(snapshotId, canonicalId)
        let captured = match (byKey.get(key)) {
            case Some(value) => value
            case None => throw IllegalStateException(
                "Search projection returned an identity outside its captured snapshot scope.")
        }
        let reason = queryString(hit, "reason")
        let relevance = QueryMatch(query_render.searchEvidenceLevel(mode, reason), reason,
            queryInt(hit, "score"))
        let matchedExposureIds = ArrayList<String>()
        let exposureIds = hit.get("matchedExposureIds").getOrThrow().asArray()
        for (exposureIndex in 0..exposureIds.size()) {
            matchedExposureIds.add(exposureIds[exposureIndex].asString())
        }
        candidates.add(QueryCandidate(captured.input, captured.document, captured.symbol,
            captured.page, relevance, matchedExposureIds: matchedExposureIds.toArray()))
    }
    outcome.reason = queryString(execution, "reason")
    for (candidate in candidates) { outcome.items.add(querySearchItem(candidate)) }
    let returnedEnd = offset + outcome.returned
    if (limit > 0 && returnedEnd < outcome.total.getOrDefault({ => 0 })) {
        outcome.next = Some(queryNextSearchCursor(request, contentBinding,
            projectionSet.projectionId, profile, returnedEnd, selectedInputs))
    }
    outcome.selectedSections = querySectionList(QUERY_SUMMARY_SECTIONS)
    outcome.text = querySearchText(outcome, candidates, selectedInputs)
    outcome
}

/** Request defaults are sourced from the exported search contract. */
internal func querySearchMode(request: JsonObject): String {
    let value = queryString(request, "mode")
    if (value.isEmpty()) { return query_render.searchContractString("defaultMode") }
    value
}

internal func querySearchProfile(request: JsonObject): String {
    query_render.searchRequestProfile(queryString(request, "profile"))
}


/** Request filters use the shared field/op mappings and canonical byte order. */
internal func querySearchFilters(request: JsonObject): ArrayList<query_render.SearchFilter> {
    let filters = ArrayList<query_render.SearchFilter>()
    match (request.get("filters")) {
        case Some(node) =>
            let values = node.asArray()
            for (index in 0..values.size()) {
                let item = values[index].asObject()
                filters.add(query_render.SearchFilter(queryString(item, "field"),
                    queryString(item, "op"), queryString(item, "value")))
            }
        case None => ()
    }
    query_render.searchNormalizeFilters(filters)
}

private func querySearchCoverageFromSet(projectionSet: query_render.SearchProjectionSet,
    profile: String): query_render.SearchCoverage {
    query_render.SearchCoverage(profile, projectionSet.projectionId,
        if (profile == query_render.searchContractString("defaultProfile")) { None }
            else { Some(query_render.searchContractInteger("staticBodyTextLimit")) },
        projectionSet.bodyComplete, projectionSet.truncatedCount)
}

private func querySearchCoverageFromNode(node: JsonNode): ?query_render.SearchCoverage {
    if (node.kind() == JsonKind.Null) { return None }
    let value = node.asObject()
    let bodyTextLimit = match (value.get("bodyTextLimit")) {
        case Some(limit) =>
            if (limit.kind() == JsonKind.Null) { None<Int64> } else { Some(limit.asInt64()) }
        case None => None<Int64>
    }
    Some(query_render.SearchCoverage(queryString(value, "profile"),
        queryString(value, "projectionId"), bodyTextLimit,
        queryBool(value, "bodyComplete"), queryInt(value, "truncatedEntries")))
}

internal func queryAnyLatest(inputs: ArrayList<QuerySnapshotInput>): Bool {
    for (input in inputs) { if (input.isLatest) { return true } }
    false
}


internal func querySourceComplete(inputs: ArrayList<QuerySnapshotInput>): Bool {
    for (input in inputs) {
        if (input.documentation.apiCollectionState != "resolved") { return false }
    }
    true
}

internal func querySearchItem(candidate: QueryCandidate): JsonObject {
    let item = JsonNode.object()
    let matchNode = JsonNode.object()
    matchNode.put("score", JsonNode.int64(candidate.relevance.score))
    matchNode.put("reason", JsonNode.string(candidate.relevance.reason))
    item.put("classification",
        query_render.capturedDeclarationClassificationNode(candidate.input.snapshot, candidate.symbol))
    match (candidate.symbol) {
        case Some(symbol) =>
            item.put("kind", JsonNode.string("symbol"))
            item.put("identity", queryIdentityNode(candidate.input, Some(symbol.id), Option<String>.None, ownerId: symbol.ownerId))
            item.put("signature", queryNullable(querySignature(symbol)))
            item.put("summary", querySymbolSummary(symbol))
            item.put("match", matchNode)
            let sections = JsonNode.array()
            sections.add(querySection("signature",
                if (symbol.headerSpelling.trimAscii().isEmpty()) { "missing" } else { "available" },
                JsonNode.string(queryDisplayExcerpt(symbol.headerSpelling,
                    query_render.searchContractInteger("signatureDisplayLimit")))))
            match (querySymbolSummary(symbol)) {
                case Some(text) => sections.add(querySection("description", "available",
                    JsonNode.string(text)))
                case None => sections.add(querySection("description", "missing", JsonNode.nullValue))
            }
            item.put("sections", sections)
            item.put("representations", querySymbolRepresentations(symbol))
            item.put("source", querySymbolSource(candidate.input, symbol))
            item.put("exposures", queryMatchedSymbolExposures(candidate.document, symbol,
                candidate.matchedExposureIds))
        case None =>
            let page = candidate.page.getOrThrow()
            item.put("kind", JsonNode.string("concept"))
            item.put("identity", queryIdentityNode(candidate.input, Option<String>.None, Some(page.id)))
            item.put("signature", JsonNode.nullValue)
            item.put("summary", queryNullable(Some(queryDisplayExcerpt(page.text,
                query_render.searchContractInteger("summaryDisplayLimit")))))
            item.put("match", matchNode)
            let sections = JsonNode.array()
            sections.add(querySection("description",
                if (page.text.trimAscii().isEmpty()) { "missing" } else { "available" },
                JsonNode.string(queryDisplayExcerpt(page.text,
                    query_render.searchContractInteger("summaryDisplayLimit")))))
            item.put("sections", sections)
            item.put("representations", queryPageRepresentations(page))
            item.put("source", queryPageSource(page))
            item.put("exposures", JsonNode.array())
    }
    item
}

private func queryDisplayExcerpt(value: String, maximumScalars: Int64): String {
    let text = value.replace("\r", " ").replace("\n", " ").trimAscii()
    query_render.searchTextExcerpt(text, maximum: maximumScalars)
}

internal func querySignature(symbol: query_model.SymbolDoc): ?String {
    if (symbol.headerSpelling.trimAscii().isEmpty()) { return None }
    Some(queryDisplayExcerpt(symbol.headerSpelling,
        query_render.searchContractInteger("signatureDisplayLimit")))
}

internal func querySymbolSummary(symbol: query_model.SymbolDoc): ?String {
    match (symbol.documentation) {
        case Some(comment) =>
            if (!comment.summary.trimAscii().isEmpty()) {
                return Some(queryDisplayExcerpt(comment.summary,
                    query_render.searchContractInteger("summaryDisplayLimit")))
            }
            if (!comment.description.trimAscii().isEmpty()) {
                return Some(queryDisplayExcerpt(comment.description,
                    query_render.searchContractInteger("summaryDisplayLimit")))
            }
            None
        case None => None
    }
}

internal func querySymbolRepresentations(symbol: query_model.SymbolDoc): JsonObject {
    let node = JsonNode.object()
    node.put("html", JsonNode.string(query_render.symbolPagePath(symbol)))
    node.put("markdown", JsonNode.string(query_render.agentDeclarationMarkdownPath(symbol)))
    node.put("json", JsonNode.string(query_render.agentDeclarationJsonPath(symbol)))
    node
}

internal func queryPageRepresentations(page: query_model.DocumentationPage): JsonObject {
    let node = JsonNode.object()
    node.put("html", JsonNode.string(page.route))
    node.put("markdown", JsonNode.string(query_render.agentPageMarkdownPath(page)))
    node.put("json", JsonNode.string(query_render.agentPageJsonPath(page)))
    node
}

internal func querySymbolSource(input: QuerySnapshotInput, symbol: query_model.SymbolDoc): JsonObject {
    let node = JsonNode.object()
    let url: ?String = match (queryModuleFor(input, symbol.moduleId)) {
        case Some(module) => query_render.sourceUrl(input.documentation.project, module, symbol.source)
        case None => None
    }
    node.put("url", queryNullable(url))
    node.put("range", querySourceRangeNode(symbol.source))
    let repository = input.documentation.project.repository
    node.put("recordedRevision", queryNullable(repository.map({ value => value.revision })))
    node.put("revisionKind", JsonNode.string(if (repository.isSome()) { "recorded" } else { "unavailable" }))
    node
}

internal func queryPageSource(page: query_model.DocumentationPage): JsonObject {
    let node = JsonNode.object()
    node.put("url", JsonNode.nullValue)
    node.put("path", JsonNode.string(page.source))
    node.put("revisionKind", JsonNode.string("unavailable"))
    node
}

// Exposure is a captured re-export fact; it never becomes overload resolution.
internal func querySymbolExposures(document: QueryDocument, symbol: query_model.SymbolDoc): JsonArray {
    document.exposures.get(symbol.id).getOrDefault({ => JsonNode.array() })
}
internal func queryMatchedSymbolExposures(document: QueryDocument,
    symbol: query_model.SymbolDoc, matchedExposureIds: ArrayList<String>): JsonArray {
    let result = JsonNode.array()
    if (matchedExposureIds.isEmpty()) { return result }
    let exposures = querySymbolExposures(document, symbol)
    for (index in 0..exposures.size()) {
        let value = exposures[index]
        let exposure = value.asObject()
        let reExport = exposure.get("reExport").getOrThrow().asObject()
        let id = queryString(reExport, "id") + ":" + queryString(exposure, "exposedName") +
            ":" + queryString(exposure, "symbolId")
        if (matchedExposureIds.contains(id)) { result.add(value) }
    }
    result
}

internal func querySearchText(outcome: QueryOutcome, candidates: ArrayList<QueryCandidate>,
    inputs: ArrayList<QuerySnapshotInput>): String {
    let out = StringBuilder()
    out.append("Documentation search: ${outcome.status}. Scope: ${queryScopeSummary(inputs)}.\n")
    out.append("Matched ${outcome.total.getOrDefault({ => 0 })} declarations and guide pages; showing ")
    out.append("${outcome.items.size} from offset ${outcome.offset}.\n")
    if (outcome.status == "ambiguous") {
        out.append("Several distinct captured identities match at the same relevance level; ")
        out.append("choose by snapshot and symbol identity, not by list order.\n")
    }
    if (outcome.status == "source_incomplete") {
        out.append("The API collection is incomplete, so an absent match does not prove the ")
        out.append("declaration is absent from the whole library.\n")
    }
    if (outcome.status == "not_found" && outcome.complete) {
        out.append("No declaration matched inside the loaded scope.\n")
    }
    if (outcome.limit == 0 && outcome.total.getOrDefault({ => 0 }) > 0) {
        out.append("The requested limit was zero, so no item was returned; this is not an absence result.\n")
    }
    var position: Int64 = 0
    while (position < candidates.size) {
        let candidate = candidates[position]
        out.append("\n")
        match (candidate.symbol) {
            case Some(symbol) =>
                out.append("- symbol ")
                out.append(symbol.qualifiedName)
                out.append(" [")
                out.append(symbol.kind)
                out.append("] snapshot ")
                out.append(candidate.input.snapshot.snapshotId)
                out.append(" match ")
                out.append(candidate.relevance.reason)
                out.append("\n  signature: ")
                out.append(if (symbol.headerSpelling.isEmpty()) { "unavailable" } else { symbol.headerSpelling })
                out.append("\n  record: ")
                out.append(query_render.agentDeclarationMarkdownPath(symbol))
            case None =>
                let page = candidate.page.getOrThrow()
                out.append("- concept ")
                out.append(page.title)
                out.append(" (page ")
                out.append(page.id)
                out.append(") snapshot ")
                out.append(candidate.input.snapshot.snapshotId)
                out.append(" match guide_text\n  record: ")
                out.append(query_render.agentPageMarkdownPath(page))
        }
        out.append("\n")
        position++
    }
    if (outcome.next.isSome()) {
        out.append("\nMore results exist. Continue with cursor '")
        out.append(outcome.next.getOrThrow())
        out.append("' and the identical request; a changed snapshot, filter, order or budget invalidates it.\n")
    }
    out.toString()
}

internal func queryScopeSummary(inputs: ArrayList<QuerySnapshotInput>): String {
    let out = StringBuilder()
    var first = true
    for (input in inputs) {
        if (!first) { out.append(", ") }
        first = false
        out.append(input.snapshot.snapshotId)
        out.append(" (")
        out.append(input.snapshot.locale)
        out.append("/")
        out.append(input.documentation.configuration.audience)
        out.append(")")
    }
    if (first) { return "no loaded snapshot" }
    out.toString()
}
