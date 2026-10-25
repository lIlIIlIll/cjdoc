package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// get_symbol reads one captured declaration (or conceptual page) at a time.
// Markdown chapters come from the shared declaration projection, so this result
// cannot drift from the published representation. Nothing here summarizes or
// rebuilds author facts; a chapter that the source lacks stays missing.

internal let QUERY_CALL_SECTIONS: Array<String> = ["signature", "parameters", "returns",
    "contracts", "examples"]
internal let QUERY_MANDATORY_CALL_SECTIONS: Array<String> = ["signature", "parameters", "returns",
    "contracts"]
internal let QUERY_REPORT_SECTIONS: Array<String> = ["validation", "diff"]

/** One requested chapter with its captured facts and current availability. */
internal class QueryChapter {
    let name: String
    var state: String
    let value: JsonNode
    let mandatory: Bool
    var rendered: String = ""

    init(name: String, state: String, value: JsonNode, mandatory: Bool) {
        this.name = name
        this.state = state
        this.value = value
        this.mandatory = mandatory
    }
}

internal func querySelectedSections(request: JsonObject): ArrayList<String> {
    let result = ArrayList<String>()
    if (let Some(values) <- request.get("sections")) {
        let array = values.asArray()
        let seen = HashSet<String>()
        for (index in 0..array.size()) {
            let name = array[index].asString()
            if (seen.add(name)) { result.add(name) }
        }
        return result
    }
    let preset = queryString(request, "preset")
    if (preset == "summary") {
        for (name in QUERY_SUMMARY_SECTIONS) { result.add(name) }
        return result
    }
    if (preset == "call") {
        for (name in QUERY_CALL_SECTIONS) { result.add(name) }
        return result
    }
    for (name in QUERY_SELECTED_SECTIONS) { result.add(name) }
    result
}

// Chapter order is the published order, never the request's field order, so the
// same facts always appear in the same sequence.
private func querySectionOrder(selected: ArrayList<String>): ArrayList<String> {
    let result = ArrayList<String>()
    for (name in QUERY_SELECTED_SECTIONS) {
        if (selected.contains(name)) { result.add(name) }
    }
    result
}

private func queryMandatorySections(request: JsonObject, selected: ArrayList<String>): ArrayList<String> {
    let result = ArrayList<String>()
    if (queryString(request, "preset") == "call") {
        for (name in QUERY_MANDATORY_CALL_SECTIONS) {
            if (selected.contains(name)) { result.add(name) }
        }
        return result
    }
    if (selected.contains("signature")) { result.add("signature") }
    result
}


/**
 * get_symbol: one captured identity with intact selected chapters.
 *
 * Budget semantics are explicit. A required unit that cannot fit the requested
 * budget is `budget_exceeded` with its real byte requirement and a retry budget;
 * a unit beyond the documented 64 MiB resource limit is `resource_limit`; an
 * optional chapter that does not fit is `budget_omitted` with its own reason.
 */
internal func queryGetSymbol(projection: QueryProjection, request: JsonObject,
    catalogId: String): QueryOutcome {
    let outcome = QueryOutcome("ok", "declaration")
    outcome.limit = 1
    let candidates = queryGetCandidates(projection, request)
    if (candidates.isEmpty()) {
        outcome.status = "not_found"
        outcome.complete = true
        outcome.reason = "no_identity_in_scope"
        outcome.contentComplete = querySourceComplete(projection.inputs)
        if (!outcome.contentComplete) {
            outcome.status = "source_incomplete"
            outcome.reason = "no_identity_with_incomplete_api_collection"
        }
        outcome.text = "No declaration or page matching the requested identity is visible in " +
            queryScopeSummary(projection.inputs) + ". " +
            if (outcome.contentComplete) { "The loaded API collection is complete for its captured scope." }
            else { "The API collection is incomplete, so absence does not prove the declaration is absent from the whole library." }
        return outcome
    }
    if (candidates.size > 1) {
        return queryAmbiguousSymbol(outcome, candidates, request, catalogId)
    }
    let candidate = candidates[0]
    match (candidate.symbol) {
        case Some(symbol) => queryFillSymbol(outcome, candidate.input, candidate.document, symbol,
            projection, request, catalogId)
        case None => queryFillPage(outcome, candidate.input, candidate.page.getOrThrow(), request)
    }
    outcome
}

internal class QueryGetCandidate {
    let input: QuerySnapshotInput
    let document: QueryDocument
    let symbol: ?query_model.SymbolDoc
    let page: ?query_model.DocumentationPage
    let reason: String

    init(input: QuerySnapshotInput, document: QueryDocument, symbol: ?query_model.SymbolDoc,
        page: ?query_model.DocumentationPage, reason: String) {
        this.input = input
        this.document = document
        this.symbol = symbol
        this.page = page
        this.reason = reason
    }
}

private func queryGetCandidates(projection: QueryProjection,
    request: JsonObject): ArrayList<QueryGetCandidate> {
    let symbolId = queryString(request, "symbolId")
    let symbolKey = queryString(request, "symbolKey")
    let pageId = queryString(request, "pageId")
    let result = ArrayList<QueryGetCandidate>()
    let seen = HashSet<String>()
    for (input in projection.inputs) {
        if (!querySnapshotMatches(input, request)) { continue }
        let document = match (projection.catalog.byInput.get(input.snapshot.snapshotId)) {
            case Some(value) => value
            case None => continue
        }
        if (!symbolId.isEmpty()) {
            if (!document.visibleIds.contains(symbolId)) { continue }
            if (let Some(symbol) <- document.bySymbolId.get(symbolId)) {
                if (!queryCandidateAdmitted(input, symbol, request)) { continue }
                if (seen.add(input.snapshot.snapshotId + "\nsymbol\n" + symbol.id)) {
                    result.add(QueryGetCandidate(input, document, Some(symbol), Option<query_model.DocumentationPage>.None, "symbol_id"))
                }
            }
        } else if (!symbolKey.isEmpty()) {
            for (symbol in document.visibleSymbols) {
                if (input.symbolKeys[symbol.id] != symbolKey) { continue }
                if (!queryCandidateAdmitted(input, symbol, request)) { continue }
                if (seen.add(input.snapshot.snapshotId + "\nsymbol\n" + symbol.id)) {
                    result.add(QueryGetCandidate(input, document, Some(symbol), Option<query_model.DocumentationPage>.None, "symbol_key"))
                }
            }
        } else if (!pageId.isEmpty()) {
            for (page in document.pages where page.id == pageId) {
                if (!queryPageAdmitted(input, page, request)) { continue }
                if (seen.add(input.snapshot.snapshotId + "\npage\n" + page.id)) {
                    result.add(QueryGetCandidate(input, document, Option<query_model.SymbolDoc>.None, Some(page), "page_id"))
                }
            }
        }
    }
    result
}

private func queryCandidateAdmitted(input: QuerySnapshotInput, symbol: query_model.SymbolDoc,
    request: JsonObject): Bool {
    if (!queryModuleIdMatches(input, symbol.moduleId, request)) { return false }
    if (!queryPackageMatches(symbol, request)) { return false }
    if (!queryKindMatches(symbol, request)) { return false }
    let (dependency, _) = queryDependencyState(input, symbol.moduleId)
    queryScopeAdmits(queryDocumentSetFor(input, symbol.moduleId), dependency, request)
}

private func queryAmbiguousSymbol(outcome: QueryOutcome, candidates: ArrayList<QueryGetCandidate>,
    request: JsonObject, catalogId: String): QueryOutcome {
    outcome.status = "ambiguous"
    outcome.reason = "several_distinct_captured_identities"
    outcome.total = Some(candidates.size)
    outcome.offset = queryReadCursor(request, catalogId)
    let limit = if (request.get("limit").isSome()) { queryClamp(queryInt(request, "limit"), 0, 100) }
        else { QUERY_GET_DEFAULT_LIMIT }
    let maxBytes = queryClamp(queryInt(request, "maxBytes", fallback: QUERY_DEFAULT_BYTES), 1024, QUERY_MAX_BYTES)
    outcome.limit = limit
    outcome.contentComplete = false
    outcome.selectedSections = querySectionOrder(querySelectedSections(request))
    let end = if (outcome.offset + limit > candidates.size) { candidates.size }
        else { outcome.offset + limit }
    let text = StringBuilder()
    text.append("Ambiguous documentation identity: ${candidates.size} distinct captured declarations match. ")
    text.append("They differ by snapshot, document set or owner, so relevance and list order do not select one.\n")
    var used: Int64 = 0
    var position = outcome.offset
    while (position < end) {
        let candidate = candidates[position]
        let item = queryCandidateIdentityItem(candidate)
        let line = queryAmbiguousCandidateText(candidate)
        let size = item.toJson().size + line.size
        if (used + size > maxBytes) {
            if (outcome.items.isEmpty() && queryRejectRequiredBudget(outcome, size, maxBytes)) { return outcome }
            break
        }
        used += size
        outcome.items.add(item)
        text.append(line)
        position++
    }
    outcome.complete = position >= candidates.size
    if (!outcome.complete) {
        outcome.next = Some(queryNextCursor(request, catalogId, position))
        text.append("\nMore candidates exist; continue with the returned cursor and the identical request.")
    }
    outcome.text = text.toString()
    outcome
}

private func queryAmbiguousCandidateText(candidate: QueryGetCandidate): String {
    let text = StringBuilder()
    text.append("\n- ")
    match (candidate.symbol) {
        case Some(symbol) =>
            text.append(symbol.qualifiedName)
            text.append(" [")
            text.append(symbol.kind)
            text.append("] snapshot ")
            text.append(candidate.input.snapshot.snapshotId)
            text.append(" symbolKey ")
            text.append(candidate.input.symbolKeys[symbol.id])
        case None =>
            text.append("concept page ")
            text.append(candidate.page.map({ value => value.id }).getOrDefault({ => "" }))
            text.append(" snapshot ")
            text.append(candidate.input.snapshot.snapshotId)
    }
    text.toString()
}

private func queryCandidateIdentityItem(candidate: QueryGetCandidate): JsonObject {
    let item = JsonNode.object()
    let matchNode = JsonNode.object()
    matchNode.put("score", JsonNode.int64(0))
    matchNode.put("reason", JsonNode.string(candidate.reason))
    match (candidate.symbol) {
        case Some(symbol) =>
            item.put("kind", JsonNode.string("symbol"))
            item.put("identity", queryIdentityNode(candidate.input, Some(symbol.id), Option<String>.None, ownerId: symbol.ownerId))
            item.put("signature", queryNullable(querySignature(symbol)))
            item.put("summary", querySymbolSummary(symbol))
            item.put("match", matchNode)
            item.put("sections", JsonNode.array())
            item.put("representations", querySymbolRepresentations(symbol))
            item.put("source", querySymbolSource(candidate.input, symbol))
            item.put("exposures", querySymbolExposures(candidate.document, symbol))
        case None =>
            let page = candidate.page.getOrThrow()
            item.put("kind", JsonNode.string("concept"))
            item.put("identity", queryIdentityNode(candidate.input, Option<String>.None, Some(page.id)))
            item.put("signature", JsonNode.nullValue)
            item.put("summary", queryNullable(Some(page.title)))
            item.put("match", matchNode)
            item.put("sections", JsonNode.array())
            item.put("representations", queryPageRepresentations(page))
            item.put("source", queryPageSource(page))
            item.put("exposures", JsonNode.array())
    }
    item
}

private func queryFillSymbol(outcome: QueryOutcome, input: QuerySnapshotInput,
    document: QueryDocument, symbol: query_model.SymbolDoc, projection: QueryProjection,
    request: JsonObject, catalogId: String): Unit {
    let selected = querySelectedSections(request)
    let mandatory = queryMandatorySections(request, selected)
    let maxBytes = if (request.get("maxBytes").isSome()) {
        queryClamp(queryInt(request, "maxBytes"), 1024, QUERY_MAX_BYTES)
    } else { QUERY_DEFAULT_BYTES }
    let chapters = queryChapters(symbol, selected, input, mandatory)
    for (chapter in chapters) {
        if (!query_render.DECLARATION_MARKDOWN_SECTIONS.contains(chapter.name)) { continue }
        chapter.rendered = input.snapshot.renderDeclarationChapter(symbol.id, chapter.name,
            pagePath: "llms-full.txt").getOrDefault({ => "" })
    }
    outcome.selectedSections = querySectionOrder(selected)
    var requiredBytes: Int64 = 0
    for (chapter in chapters where chapter.mandatory) { requiredBytes += queryChapterBytes(chapter) }
    if (queryRejectRequiredBudget(outcome, requiredBytes, maxBytes)) { return }
    let used = queryBudgetOptionalChapters(outcome, chapters, requiredBytes, maxBytes)
    for (name in QUERY_SELECTED_SECTIONS) {
        if (selected.contains(name)) { continue }
        outcome.omitted.add(queryOmission(name, "not_selected",
            Some(queryRetryNode(maxBytes, "Request section '${name}' explicitly."))))
    }
    let chaptersOut = JsonNode.array()
    var contentComplete = true
    for (chapter in chapters) {
        chaptersOut.add(queryChapterResult(chapter))
        if (!queryChapterIncluded(chapter)) { contentComplete = false }
        if (chapter.state == "missing") { outcome.missing.add(chapter.name) }
    }
    outcome.selectedSections = querySectionOrder(selected)
    outcome.contentComplete = contentComplete
    outcome.total = Some(1)
    // Relations use the bounded shared walk and the remaining byte budget.
    var relationsIncluded = false
    for (chapter in chapters) {
        if (chapter.name == "relations" && queryChapterIncluded(chapter)) { relationsIncluded = true }
    }
    if (relationsIncluded) {
        outcome.scope = "relations"
        outcome.total = None
        outcome.limit = queryRelationRequest(request).limit
        let relationBudget = maxBytes - used
        // A continuation cursor pages the same relation walk; it never changes
        // which declaration or chapters were requested.
        let relationOffset = queryReadCursor(request, catalogId)
        outcome.offset = relationOffset
        let build = queryRelations(projection.catalog, document, symbol, request, relationBudget,
            relationOffset, catalogId)
        outcome.complete = build.complete
        for (relation in build.relations) { outcome.relations.add(relation) }
        for (omission in build.omitted) {
            outcome.omitted.add(omission)
            outcome.contentComplete = false
        }
        if (build.truncated) {
            outcome.contentComplete = false
            outcome.next = Some(queryNextCursor(request, catalogId, build.nextOffset.getOrThrow()))
        }
    }
    for (chapter in chapters) {
        if (queryChapterIncluded(chapter) && QUERY_REPORT_SECTIONS.contains(chapter.name)) {
            outcome.reports.add(chapter.value.asObject())
        }
    }
    let source = querySymbolSource(input, symbol)
    outcome.sources.add(querySourceNode(input.snapshot.snapshotId, "source",
        Some(symbol.source.path), queryOptionalString(source, "url"), "recorded"))
    let item = JsonNode.object()
    item.put("kind", JsonNode.string("symbol"))
    item.put("identity", queryIdentityNode(input, Some(symbol.id), Option<String>.None, ownerId: symbol.ownerId))
    item.put("signature", JsonNode.nullValue)
    item.put("summary", JsonNode.nullValue)
    for (chapter in chapters) {
        if (chapter.name == "signature" && queryChapterIncluded(chapter)) {
            item.put("signature", chapter.value.asObject().get("headerSpelling").getOrThrow())
        }
    }
    let matchNode = JsonNode.object()
    matchNode.put("score", JsonNode.int64(0))
    matchNode.put("reason", JsonNode.string("requested_identity"))
    item.put("match", matchNode)
    item.put("sections", chaptersOut)
    item.put("representations", querySymbolRepresentations(symbol))
    item.put("source", source)
    item.put("exposures", querySymbolExposures(document, symbol))
    outcome.items.add(item)
    outcome.reason = if (outcome.contentComplete) { "" } else { "content_omitted" }
    outcome.text = querySymbolText(outcome, input, symbol, chapters)
}



private func querySymbolText(outcome: QueryOutcome, input: QuerySnapshotInput,
    symbol: query_model.SymbolDoc, chapters: ArrayList<QueryChapter>): String {
    let out = StringBuilder()
    out.append("# ")
    out.append(symbol.qualifiedName)
    out.append("\n\n")
    out.append("- snapshot: ")
    out.append(input.snapshot.snapshotId)
    out.append("\n- source snapshot: ")
    out.append(input.sourceSnapshotId)
    out.append("\n- document set: ")
    match (queryDocumentSetFor(input, symbol.moduleId)) {
        case Some(value) =>
            out.append(value.library)
            out.append(" (")
            out.append(value.id)
            out.append(")")
        case None => out.append("not applicable")
    }
    let (dependency, dependencyState) = queryDependencyState(input, symbol.moduleId)
    out.append("\n- dependency instance: ")
    match (dependency) {
        case Some(value) =>
            out.append(value.instanceId)
            out.append(" [")
            out.append(value.kind)
            out.append("]")
        case None => out.append(dependencyState)
    }
    out.append("\n- language: ")
    out.append(input.snapshot.locale)
    out.append("\n- audience: ")
    out.append(input.documentation.configuration.audience)
    out.append("\n- symbol id: ")
    out.append(symbol.id)
    match (symbol.ownerId) {
        case Some(ownerId) =>
            out.append("\n- owner: ")
            match (input.symbols.get(ownerId)) {
                case Some(owner) => out.append(owner.qualifiedName + " (" + ownerId + ")")
                case None => out.append(ownerId)
            }
        case None => ()
    }
    out.append("\n\n")
    for (chapter in chapters) {
        if (!queryChapterIncluded(chapter)) {
            out.append("## ")
            out.append(chapter.name)
            out.append("\n\nOmitted: ${chapter.state}; consult omittedSections for the available next step.\n\n")
            continue
        }
        if (chapter.name == "validation" || chapter.name == "diff") {
            out.append("## ")
            out.append(if (chapter.name == "validation") { "Validation" } else { "API diff" })
            out.append("\n\nAttached evidence state: ")
            out.append(queryString(chapter.value.asObject(), "state"))
            out.append(". ")
            if (queryString(chapter.value.asObject(), "state") == "not_attached") {
                out.append("The snapshot carries no such report; documentation and diagnostics are not a passing receipt.")
            }
            out.append("\n\n")
            continue
        }
        if (!chapter.rendered.isEmpty()) {
            out.append(chapter.rendered)
            if (!chapter.rendered.endsWith("\n")) { out.append("\n") }
            out.append("\n")
        }
    }
    if (outcome.contentComplete) {
        out.append("Content completeness: every selected chapter was returned intact.\n")
    } else {
        out.append("Content completeness: some chapters were omitted; the omitted sections above name each reason.\n")
    }
    out.toString()
}

