package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import std.sort.*
import yjson.*

// Search ranks only with evidence the projection already holds: stable symbol
// identity, source spellings, re-export exposure, owner and literal author text.
// Relevance is never presented as overload applicability or compiler resolution.

private let QUERY_MATCH_SYMBOL_ID: Int64 = 4
private let QUERY_MATCH_SYMBOL_KEY: Int64 = 4
private let QUERY_MATCH_QUALIFIED: Int64 = 3
private let QUERY_MATCH_OWNER: Int64 = 2
private let QUERY_MATCH_NAME: Int64 = 2
private let QUERY_MATCH_ALIAS: Int64 = 2
private let QUERY_MATCH_TEXT: Int64 = 1

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

/** Split one free-text query into lower-cased ASCII/Unicode alphanumeric tokens. */
internal func queryTokens(value: String): Array<String> {
    let tokens = ArrayList<String>()
    var current = StringBuilder()
    for (rune in value.runes()) {
        let code = UInt32(rune)
        let accepted = (code >= 0x30u32 && code <= 0x39u32) || (code >= 0x41u32 && code <= 0x5Au32) ||
            (code >= 0x61u32 && code <= 0x7Au32) || code == 0x5Fu32 || code >= 0x80u32
        if (accepted) {
            current.append(rune)
        } else if (current.size > 0) {
            tokens.add(current.toString().toAsciiLower())
            current = StringBuilder()
        }
    }
    if (current.size > 0) { tokens.add(current.toString().toAsciiLower()) }
    tokens.toArray()
}

internal func queryContainsAll(haystack: String, tokens: Array<String>): Bool {
    if (tokens.isEmpty()) { return false }
    for (token in tokens) {
        if (!haystack.contains(token)) { return false }
    }
    true
}

/**
 * Match one visible declaration against the request's identity and text fields.
 *
 * Overload selectors (exact captured parameter spellings and generic arity)
 * narrow an identity match; they never stand in for an applicability proof.
 */
internal func querySymbolMatch(document: QueryDocument, symbol: query_model.SymbolDoc,
    request: JsonObject): ?QueryMatch {
    let symbolId = queryString(request, "symbolId")
    let symbolKey = queryString(request, "symbolKey")
    let qualifiedName = queryString(request, "qualifiedName")
    let name = queryString(request, "name")
    let query = queryString(request, "query")
    let hasSelectors = request.get("parameterTypes").isSome() || request.get("genericArity").isSome()
    var level: Int64 = -1
    var reason = ""
    if (!symbolId.isEmpty()) {
        if (symbol.id != symbolId) { return None }
        level = QUERY_MATCH_SYMBOL_ID
        reason = "symbol_id"
    } else if (!symbolKey.isEmpty()) {
        if (document.input.symbolKeys[symbol.id] != symbolKey) { return None }
        level = QUERY_MATCH_SYMBOL_KEY
        reason = "symbol_key"
    } else if (!qualifiedName.isEmpty()) {
        if (symbol.qualifiedName != qualifiedName) { return None }
        level = QUERY_MATCH_QUALIFIED
        reason = "qualified_name"
    } else if (!name.isEmpty()) {
        let ownerName = queryOwnerName(document, symbol)
        if (symbol.name == name) {
            level = QUERY_MATCH_NAME
            reason = "declaration_name"
        } else if (symbol.qualifiedName == name) {
            level = QUERY_MATCH_QUALIFIED
            reason = "qualified_name"
        } else if (!ownerName.isEmpty() && ownerName + "." + symbol.name == name) {
            level = QUERY_MATCH_OWNER
            reason = "owner_member_name"
        } else if (queryAliasExposes(document, symbol.id, name)) {
            level = QUERY_MATCH_ALIAS
            reason = "exposed_reexport_alias"
        } else {
            return None
        }
    } else if (!query.isEmpty() && query == symbol.id) {
        level = QUERY_MATCH_SYMBOL_ID
        reason = "symbol_id"
    } else if (!query.isEmpty() && query == document.input.symbolKeys[symbol.id]) {
        level = QUERY_MATCH_SYMBOL_KEY
        reason = "symbol_key"
    } else if (!query.isEmpty() && query == symbol.qualifiedName) {
        level = QUERY_MATCH_QUALIFIED
        reason = "qualified_name"
    } else if (!query.isEmpty() && query == symbol.name) {
        level = QUERY_MATCH_NAME
        reason = "declaration_name"
    } else if (!query.isEmpty() && queryAliasExposes(document, symbol.id, query)) {
        level = QUERY_MATCH_ALIAS
        reason = "exposed_reexport_alias"
    } else if (!query.isEmpty()) {
        let tokens = queryTokens(query)
        if (tokens.isEmpty()) { return None }
        let identifier = (symbol.qualifiedName + "\n" + symbol.name + "\n" +
            queryOwnerName(document, symbol)).toAsciiLower()
        let text = document.searchText.get(symbol.id).getOrDefault({ => "" })
        let identifierHit = queryContainsAll(identifier, tokens)
        if (!identifierHit && !queryContainsAll(text, tokens)) { return None }
        level = QUERY_MATCH_TEXT
        reason = if (identifierHit) { "declaration_text" } else { "documentation_text" }
    } else {
        return None
    }
    if (hasSelectors && !querySelectorsMatch(symbol, request)) { return None }
    if (hasSelectors && reason != "symbol_key" && reason != "symbol_id") {
        reason = reason + "_with_overload_selector"
    }
    var score = level * 1000
    if (!name.isEmpty() && symbol.name == name) { score += 40 }
    if (level == QUERY_MATCH_ALIAS) { score += 30 }
    if (level == QUERY_MATCH_OWNER) { score += 20 }
    if (level == QUERY_MATCH_TEXT) { score += 10 }
    QueryMatch(level, reason, score)
}

internal func queryOwnerName(document: QueryDocument, symbol: query_model.SymbolDoc): String {
    match (symbol.ownerId) {
        case Some(ownerId) => match (document.bySymbolId.get(ownerId)) {
            case Some(owner) => owner.name
            case None => ""
        }
        case None => ""
    }
}

private func queryAliasExposes(document: QueryDocument, symbolId: String, name: String): Bool {
    match (document.aliases.get(name)) {
        case Some(targets) => targets.contains(symbolId)
        case None => false
    }
}

// Selectors are exact captured source spellings and arity, not canonical types.
internal func querySelectorsMatch(symbol: query_model.SymbolDoc, request: JsonObject): Bool {
    if (let Some(node) <- request.get("genericArity")) {
        if (symbol.genericParameters.size != node.asInt64()) { return false }
    }
    if (let Some(node) <- request.get("parameterTypes")) {
        let requested = node.asArray()
        if (requested.size() != symbol.parameters.size) { return false }
        for (index in 0..requested.size()) {
            if (requested[index].asString() != symbol.parameters[index].typeRef.spelling) { return false }
        }
    }
    true
}

/** One ranked candidate before pagination. */
internal class QueryCandidate {
    let input: QuerySnapshotInput
    let document: QueryDocument
    let symbol: ?query_model.SymbolDoc
    let page: ?query_model.DocumentationPage
    let relevance: QueryMatch
    let order: Int64

    init(input: QuerySnapshotInput, document: QueryDocument, symbol: ?query_model.SymbolDoc,
        page: ?query_model.DocumentationPage, relevance: QueryMatch, order: Int64) {
        this.input = input
        this.document = document
        this.symbol = symbol
        this.page = page
        this.relevance = relevance
        this.order = order
    }

    func key(): String {
        match (symbol) {
            case Some(value) => "symbol:" + input.snapshot.snapshotId + "\n" + value.id
            case None => "page:" + input.snapshot.snapshotId + "\n" +
                page.map({ value => value.id }).getOrDefault({ => "" })
        }
    }
}

private func queryCandidateCompare(left: QueryCandidate, right: QueryCandidate): Int64 {
    if (left.relevance.score != right.relevance.score) { return right.relevance.score - left.relevance.score }
    if (left.order != right.order) { return left.order - right.order }
    let leftKey = left.key()
    let rightKey = right.key()
    if (leftKey < rightKey) { return -1 }
    if (leftKey > rightKey) { return 1 }
    0
}

/** Search: ranked symbols and conceptual pages with explicit paging. */
internal func querySearch(projection: QueryProjection, request: JsonObject,
    catalogId: String): QueryOutcome {
    let outcome = QueryOutcome("ok", "catalog")
    if (queryBool(request, "latest") && !queryAnyLatest(projection.inputs)) {
        throw DocumentationQueryException("unavailable", "latest_not_declared",
            "No loaded snapshot is declared latest; name an explicit snapshot identity instead.")
    }
    let tokens = queryTokens(queryString(request, "query"))
    let identityOnly = queryString(request, "query").isEmpty()
    let candidates = ArrayList<QueryCandidate>()
    let seen = HashSet<String>()
    var order: Int64 = 0
    for (input in projection.inputs) {
        if (queryBool(request, "latest") && !input.isLatest) { continue }
        let document = match (projection.catalog.byInput.get(input.snapshot.snapshotId)) {
            case Some(value) => value
            case None => continue
        }
        for (symbol in document.visibleSymbols) {
            let candidateOrder = order
            order++
            if (!queryModuleIdMatches(input, symbol.moduleId, request)) { continue }
            if (!queryPackageMatches(symbol, request)) { continue }
            if (!queryKindMatches(symbol, request)) { continue }
            let (dependency, _) = queryDependencyState(input, symbol.moduleId)
            if (!queryScopeAdmits(queryDocumentSetFor(input, symbol.moduleId), dependency, request)) { continue }
            let relevance = match (querySymbolMatch(document, symbol, request)) {
                case Some(value) => value
                case None => continue
            }
            let candidate = QueryCandidate(input, document, Some(symbol), Option<query_model.DocumentationPage>.None, relevance, candidateOrder)
            if (seen.add(candidate.key())) { candidates.add(candidate) }
        }
        // Guide text is searchable only for a free-text query; it never narrows
        // an identity lookup and never invents a symbol identity.
        if (identityOnly || tokens.isEmpty()) { continue }
        for (page in document.pages) {
            if (!queryPageAdmitted(input, page, request)) { continue }
            let candidateOrder = order
            order++
            let text = document.pageText.get(page.id).getOrDefault({ => "" })
            if (!queryContainsAll(text, tokens)) { continue }
            let relevance = QueryMatch(QUERY_MATCH_TEXT, "guide_text", QUERY_MATCH_TEXT * 1000)
            let candidate = QueryCandidate(input, document, Option<query_model.SymbolDoc>.None, Some(page), relevance, candidateOrder)
            if (seen.add(candidate.key())) { candidates.add(candidate) }
        }
    }
    sort(candidates, lessThan: { left, right => queryCandidateCompare(left, right) < 0 }, stable: true)
    let offset = queryReadCursor(request, catalogId)
    if (offset > candidates.size) {
        throw DocumentationQueryException("stale_cursor", "cursor_out_of_range",
            "Continuation cursor is beyond the current result set.")
    }
    let limit = if (request.get("limit").isSome()) { queryClamp(queryInt(request, "limit"), 0, 100) }
        else { QUERY_SEARCH_DEFAULT_LIMIT }
    let end = if (offset + limit > candidates.size) { candidates.size } else { offset + limit }
    let ambiguous = queryIsAmbiguous(candidates)
    outcome.status = if (candidates.isEmpty()) { "not_found" }
        else if (ambiguous) { "ambiguous" } else { "ok" }
    outcome.offset = offset
    outcome.limit = limit
    outcome.total = Some(candidates.size)
    outcome.complete = end >= candidates.size
    outcome.reason = if (candidates.isEmpty()) { "no_match_in_scope" }
        else if (ambiguous) { "several_captured_identities_tie" } else { "" }
    var position = offset
    while (position < end) {
        outcome.items.add(querySearchItem(candidates[position]))
        position++
    }
    if (end < candidates.size && limit > 0) {
        outcome.next = Some(queryNextCursor(request, catalogId, end))
    }
    outcome.contentComplete = querySourceComplete(projection.inputs)
    if (candidates.isEmpty() && !outcome.contentComplete) {
        outcome.status = "source_incomplete"
        outcome.reason = "no_match_with_incomplete_api_collection"
    }
    if (limit == 0 && !candidates.isEmpty()) { outcome.reason = "zero_limit_requested" }
    outcome.selectedSections = querySectionList(QUERY_SUMMARY_SECTIONS)
    outcome.text = querySearchText(outcome, candidates, projection.inputs)
    outcome
}

internal func queryAnyLatest(inputs: ArrayList<QuerySnapshotInput>): Bool {
    for (input in inputs) { if (input.isLatest) { return true } }
    false
}

// Ambiguity is a normal outcome: several distinct captured identities tie at the
// highest relevance level. Relevance never claims overload applicability.
private func queryIsAmbiguous(candidates: ArrayList<QueryCandidate>): Bool {
    if (candidates.size < 2) { return false }
    let best = candidates[0].relevance.level
    var count: Int64 = 0
    for (candidate in candidates) {
        if (candidate.relevance.level != best) { break }
        count++
    }
    count > 1
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
                JsonNode.string(symbol.headerSpelling)))
            match (querySymbolSummary(symbol)) {
                case Some(text) => sections.add(querySection("description", "available",
                    JsonNode.string(text)))
                case None => sections.add(querySection("description", "missing", JsonNode.nullValue))
            }
            item.put("sections", sections)
            item.put("representations", querySymbolRepresentations(symbol))
            item.put("source", querySymbolSource(candidate.input, symbol))
            item.put("exposures", querySymbolExposures(candidate.document, symbol))
        case None =>
            let page = candidate.page.getOrThrow()
            item.put("kind", JsonNode.string("concept"))
            item.put("identity", queryIdentityNode(candidate.input, Option<String>.None, Some(page.id)))
            item.put("signature", JsonNode.nullValue)
            item.put("summary", queryNullable(Some(queryExcerpt(page.text, 512))))
            item.put("match", matchNode)
            let sections = JsonNode.array()
            sections.add(querySection("description",
                if (page.text.trimAscii().isEmpty()) { "missing" } else { "available" },
                JsonNode.string(queryExcerpt(page.text, 512))))
            item.put("sections", sections)
            item.put("representations", queryPageRepresentations(page))
            item.put("source", queryPageSource(page))
            item.put("exposures", JsonNode.array())
    }
    item
}

internal func querySignature(symbol: query_model.SymbolDoc): ?String {
    if (symbol.headerSpelling.trimAscii().isEmpty()) { return None }
    Some(symbol.headerSpelling)
}

internal func querySymbolSummary(symbol: query_model.SymbolDoc): ?String {
    match (symbol.documentation) {
        case Some(comment) =>
            if (!comment.summary.trimAscii().isEmpty()) { return Some(queryExcerpt(comment.summary, 512)) }
            if (!comment.description.trimAscii().isEmpty()) { return Some(queryExcerpt(comment.description, 512)) }
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
    if (outcome.limit == 0 && !candidates.isEmpty()) {
        out.append("The requested limit was zero, so no item was returned; this is not an absence result.\n")
    }
    var position = outcome.offset
    let end = outcome.offset + outcome.items.size
    while (position < end) {
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
