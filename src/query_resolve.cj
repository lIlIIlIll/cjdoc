package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import std.sort.*
import yjson.*

private class QueryDependencyContext {
    let input: QuerySnapshotInput
    let dependency: query_model.DependencyInstance
    let encoded: JsonObject
    let key: String
    init(input: QuerySnapshotInput, dependency: query_model.DependencyInstance) {
        this.input = input
        this.dependency = dependency
        this.encoded = resolveDependencyJson(dependency)
        this.key = input.snapshot.snapshotId + "\n" + this.encoded.toJson()
    }
}

/** The three request fields that ask for an explicit captured consumer context. */
private let QUERY_CONTEXT_FIELDS: Array<String> = ["contextSnapshotId", "contextModuleId",
    "dependencyInstanceId"]

private class QueryResolutionCandidate {
    let input: QuerySnapshotInput
    let scope: QueryDocumentScope
    let context: ?QueryDependencyContext
    var level = "none"
    var score: Int64 = 0
    var reason = ""
    var pinned = false
    var binding = "unavailable"
    var admitted = false

    init(input: QuerySnapshotInput, scope: QueryDocumentScope, context: ?QueryDependencyContext) {
        this.input = input
        this.scope = scope
        this.context = context
    }
}

private func resolveSetJson(value: query_model.DocumentSetIdentity): JsonObject {
    let out = StringBuilder()
    query_render.appendDocumentSetIdentity(out, value)
    querySnapshotJson(out.toString())
}

private func resolveDependencyJson(value: query_model.DependencyInstance): JsonObject {
    let out = StringBuilder()
    query_render.appendDependencyInstance(out, value)
    querySnapshotJson(out.toString())
}

private func resolveCandidateJson(candidate: QueryResolutionCandidate): JsonObject {
    let result = JsonObject()
    result.put("snapshotId", JsonNode.string(candidate.input.snapshot.snapshotId))
    result.put("documentSet", resolveSetJson(candidate.scope.original))
    result.put("inventoryDocumentSet", resolveSetJson(candidate.scope.inventory))
    result.put("contextSnapshotId", match (candidate.context) {
        case Some(context) => JsonNode.string(context.input.snapshot.snapshotId)
        case None => JsonNode.nullValue
    })
    result.put("dependency", match (candidate.context) {
        case Some(context) => context.encoded
        case None => JsonNode.nullValue
    })
    result.put("matchLevel", JsonNode.string(candidate.level))
    result.put("reason", JsonNode.string(candidate.reason))
    result.put("score", JsonNode.int64(candidate.score))
    result.put("inventoryPinned", JsonNode.boolean(candidate.pinned))
    result.put("sourceBinding", JsonNode.string(candidate.binding))
    result.put("admitted", JsonNode.boolean(candidate.admitted))
    result
}

private func resolveLibraryForDependency(input: QuerySnapshotInput,
    dependency: query_model.DependencyInstance): String {
    if (let Some(scope) <- input.scopeForModule(dependency.componentModuleId)) { return scope.original.library }
    dependency.name
}

/** Whether the request asked for one explicit captured consumer context. */
private func resolveContextRequested(request: JsonObject): Bool {
    for (field in QUERY_CONTEXT_FIELDS) {
        if (!queryString(request, field).isEmpty()) { return true }
    }
    false
}

/** Select captured contexts before applying filters to target documentation. */
private func resolveDependencyContexts(inputs: ArrayList<QuerySnapshotInput>,
    request: JsonObject): (ArrayList<QueryDependencyContext>, Bool) {
    let contexts = ArrayList<QueryDependencyContext>()
    if (!resolveContextRequested(request)) { return (contexts, false) }
    let contextId = queryString(request, "contextSnapshotId")
    let moduleId = queryString(request, "contextModuleId")
    let instanceId = queryString(request, "dependencyInstanceId")
    let seen = HashSet<String>()
    var captured = false
    for (input in inputs) {
        if (!contextId.isEmpty() && contextId != input.snapshot.snapshotId &&
            contextId != input.sourceSnapshotId) { continue }
        var moduleKnown = moduleId.isEmpty() || queryModuleFor(input, moduleId).isSome()
        if (!moduleKnown) {
            for (dependency in input.documentation.dependencies) {
                if (dependency.moduleId == moduleId || dependency.componentModuleId == moduleId) {
                    moduleKnown = true
                    break
                }
            }
        }
        if (!moduleKnown) { continue }
        if (instanceId.isEmpty()) { captured = true }
        for (dependency in input.documentation.dependencies) {
            if (!moduleId.isEmpty() && dependency.moduleId != moduleId &&
                dependency.componentModuleId != moduleId) { continue }
            if (!instanceId.isEmpty() && dependency.instanceId != instanceId) { continue }
            captured = true
            let context = QueryDependencyContext(input, dependency)
            if (seen.add(context.key)) { contexts.add(context) }
        }
    }
    (contexts, captured)
}

private func resolveCapturedDecision(context: QueryDependencyContext,
    scope: QueryDocumentScope, inventory: ExternalDocResolver): (Bool, Bool) {
    let key = queryNavigationEvidenceKey(context.dependency.instanceId, scope.original.identity, inventory.fingerprint)
    let entries = context.input.capturedNavigations.get(key).getOrDefault({ => ArrayList<JsonObject>() })
    var exact = false
    var compatible = false
    for (entry in entries) {
        if (queryString(entry, "state") != "resolved") { continue }
        for (set in context.input.documentation.documentSets) {
            if (set.id != queryString(entry, "documentSetId") || set.indexIdentity != inventory.fingerprint ||
                set.identity != scope.original.identity || set.library != scope.original.library ||
                set.moduleId != scope.original.moduleId || set.target != scope.original.target ||
                set.cfg != scope.original.cfg || set.audience != scope.original.audience) { continue }
            exact = exact || queryString(entry, "matchLevel") == "exact"
            compatible = compatible || queryString(entry, "matchLevel") == "compatible"
        }
    }
    (exact, compatible)
}

private func resolveCandidateScope(input: QuerySnapshotInput, scope: QueryDocumentScope,
    request: JsonObject): String {
    let set = scope.original
    let snapshot = queryString(request, "snapshotId")
    if (!snapshot.isEmpty() && snapshot != input.snapshot.snapshotId && snapshot != input.sourceSnapshotId) { return "snapshot scope does not match" }
    let id = queryString(request, "documentSetId")
    if (!id.isEmpty() && id != set.id && id != scope.inventory.id) { return "document-set scope does not match" }
    let version = queryString(request, "apiVersion")
    if (!version.isEmpty() && version != set.apiVersion) { return "requested API package version is not this document's API version" }
    let target = queryString(request, "target")
    if (!target.isEmpty() && set.target != target && set.target != "*") { return "requested target is not covered by this captured document set" }
    let cfg = queryString(request, "cfg")
    if (!cfg.isEmpty() && set.cfg != cfg && set.cfg != "*") { return "requested cfg is not covered by this captured document set" }
    if (!querySnapshotMatches(input, request)) { return "requested language/audience/cfg scope is not available" }
    ""
}

private func assessQueryResolutionCandidate(candidate: QueryResolutionCandidate,
    request: JsonObject, work: DependencyNavigationWork): Unit {
    candidate.reason = resolveCandidateScope(candidate.input, candidate.scope, request)
    if (!candidate.reason.isEmpty()) { return }
    let set = candidate.scope.inventory
    let policy = DependencyDocumentPolicy(candidate.input.documentation.configuration.audience,
        linkLanguage: queryString(request, "language"), linkLanguageFallback: queryBool(request, "languageFallback"),
        linkCompatible: queryBool(request, "compatible"))
    let dependency: ?query_model.DependencyInstance = candidate.context.map({ context => context.dependency })
    let contextRequested = resolveContextRequested(request)
    if (dependency.isNone() && contextRequested) {
        candidate.reason = "the explicit captured context has no matching selected dependency; no documentation-only substitution"
        return
    }
    // Document-set discovery has not asked for a missing type. The generation
    // guard for external fallback after an authoritative type miss is therefore
    // inapplicable here; name eligibility is handled by search on this scope.
    let rejection = dependencyDocumentEvidenceRejection(policy, set, dependency, HashSet<String>(), explicit: !contextRequested)
    if (!rejection.isEmpty()) { candidate.reason = rejection; return }
    let mappings = HashMap<String, String>()
    var compatible = false
    var instanceMapping = false
    if (let Some(context) <- candidate.context) {
        let (capturedExact, capturedCompatible) = resolveCapturedDecision(context, candidate.scope, candidate.input.inventory)
        if (capturedCompatible) {
            mappings[dependencyCompatibilityKey(context.dependency.instanceId, context.dependency.target, context.dependency.cfg)] = set.identity
        }
        let conflicted = context.input.graph.context(context.dependency.componentModuleId, work).conflicted
        let (reason, accepted, mapped, bindingRequired) = assessDependencyDocumentCompatibility(policy, set, context.dependency,
            mappings, sourceContextConflicted: conflicted)
        if (!reason.isEmpty()) { candidate.reason = reason; return }
        compatible = accepted
        instanceMapping = mapped
        if (bindingRequired) {
            if (let Some(graph) <- candidate.input.inventory.sourceGraph) {
                candidate.binding = graph.binding(context.input.graph, context.dependency.componentModuleId, set.moduleId, work)
            }
        }
        candidate.pinned = candidate.input.inventory.inventoryPinned || capturedExact
        if (capturedExact && candidate.binding == "unavailable") { candidate.binding = "matched" }
    }
    let (reason, level, score) = rateDependencyDocumentCandidate(policy, set, dependency,
        compatible: compatible, instanceMapping: instanceMapping, sourceBinding: candidate.binding,
        inventoryPinned: candidate.pinned, priority: candidate.input.inventory.priority)
    if (!reason.isEmpty()) { candidate.reason = reason; return }
    candidate.admitted = true
    candidate.level = level
    candidate.score = score
    candidate.reason = if (candidate.context.isNone()) {
        "explicit documentation-only reference; no captured consumer dependency or compilation proof was supplied"
    } else if (level == "exact") {
        "captured dependency identity and host-pinned inventory/source binding match; this is not compilation or behavior proof"
    } else if (level == "compatible") {
        "explicit compatibility policy uses a captured compatible navigation decision; actual API identity is returned"
    } else {
        "captured identity/scope is eligible but independent pin or complete source binding evidence is unavailable"
    }
}

private func resolveCandidateBefore(left: QueryResolutionCandidate, right: QueryResolutionCandidate): Bool {
    if (left.admitted != right.admitted) { return left.admitted }
    if (left.score != right.score) { return left.score > right.score }
    if (left.scope.original.library != right.scope.original.library) { return left.scope.original.library < right.scope.original.library }
    if (left.scope.original.id != right.scope.original.id) { return left.scope.original.id < right.scope.original.id }
    if (left.input.snapshot.snapshotId != right.input.snapshot.snapshotId) {
        return left.input.snapshot.snapshotId < right.input.snapshot.snapshotId
    }
    let leftContext = left.context.map({ context => context.key }).getOrDefault({ => "" })
    let rightContext = right.context.map({ context => context.key }).getOrDefault({ => "" })
    leftContext < rightContext
}

/** Whether every query token appears in the captured library, module or package names. */
private func resolveNameScopeAdmits(input: QuerySnapshotInput, scope: QueryDocumentScope,
    tokens: Array<String>): Bool {
    let out = StringBuilder()
    out.append(scope.original.library)
    out.append("\n")
    if (let Some(module) <- queryModuleFor(input, scope.original.moduleId)) {
        out.append(module.name)
        for (name in module.packageNames) {
            out.append("\n")
            out.append(name)
        }
    }
    for (pkg in input.documentation.packages where pkg.moduleId == scope.original.moduleId) {
        out.append("\n")
        out.append(pkg.name)
    }
    queryContainsAll(out.toString().toAsciiLower(), tokens)
}

private func addResolutionCandidate(candidates: ArrayList<QueryResolutionCandidate>,
    candidate: QueryResolutionCandidate, request: JsonObject,
    work: DependencyNavigationWork, latestDeclared: Bool): Unit {
    assessQueryResolutionCandidate(candidate, request, work)
    if (queryBool(request, "latest") && latestDeclared && !candidate.input.isLatest) {
        candidate.admitted = false; candidate.level = "none"; candidate.score = 0
        candidate.reason = "not the explicit versions catalog latest alias target"
    }
    candidates.add(candidate)
}

private func collectResolutionCandidates(inputs: ArrayList<QuerySnapshotInput>,
    request: JsonObject, contexts: ArrayList<QueryDependencyContext>,
    work: DependencyNavigationWork): (ArrayList<QueryResolutionCandidate>, Bool) {
    let candidates = ArrayList<QueryResolutionCandidate>()
    let library = queryString(request, "library")
    let moduleId = queryString(request, "moduleId")
    let packageName = queryString(request, "packageName")
    let tokens = queryTokens(queryString(request, "query"))
    var latestDeclared = false
    for (input in inputs) { latestDeclared = latestDeclared || input.isLatest }
    for (input in inputs) {
        for (scope in input.scopes) {
            if (!moduleId.isEmpty() && moduleId != scope.original.moduleId) { continue }
            if (!packageName.isEmpty()) {
                var contains = false
                for (pkg in input.documentation.packages where
                    pkg.moduleId == scope.original.moduleId && pkg.name == packageName) { contains = true }
                if (!contains) { continue }
            }
            if (!tokens.isEmpty() && !resolveNameScopeAdmits(input, scope, tokens)) { continue }
            let requestedLibrary = if (library.isEmpty()) { scope.original.library } else { library }
            var contextAdded = false
            for (context in contexts) {
                if (context.dependency.name != requestedLibrary &&
                    resolveLibraryForDependency(context.input, context.dependency) != requestedLibrary) { continue }
                if (!library.isEmpty() && library != scope.original.library &&
                    !(context.dependency.name == library &&
                    context.dependency.identity == scope.original.identity)) { continue }
                addResolutionCandidate(candidates, QueryResolutionCandidate(input, scope, Some(context)),
                    request, work, latestDeclared)
                contextAdded = true
            }
            if (!contextAdded && (library.isEmpty() || library == scope.original.library)) {
                addResolutionCandidate(candidates, QueryResolutionCandidate(input, scope, Option<QueryDependencyContext>.None),
                    request, work, latestDeclared)
            }
        }
    }
    (candidates, latestDeclared)
}

private func resolutionCandidateText(row: JsonObject): String {
    let set = row.get("documentSet").getOrThrow().asObject()
    "\n- " + queryString(set, "library") + "; API version=" + queryString(set, "apiVersion") +
        "; snapshot=" + queryString(row, "snapshotId") + "; documentSet=" + queryString(set, "id") +
        "; contextSnapshot=" + queryString(row, "contextSnapshotId") +
        "; matchLevel=" + queryString(row, "matchLevel") + ": " + queryString(row, "reason")
}

private class QueryResolutionPage {
    let selected: JsonArray
    let rows = JsonArray()
    let lines = ArrayList<String>()
    let offset: Int64
    let maxBytes: Int64
    var position: Int64
    var used: Int64 = 0
    var required: Int64 = 0

    init(request: JsonObject, catalogId: String, total: Int64, selected: JsonArray) {
        this.offset = queryReadCursor(request, catalogId)
        if (this.offset > total) {
            throw DocumentationQueryException("stale_cursor", "cursor_range",
                "Continuation offset is outside the frozen candidate set.")
        }
        this.position = this.offset
        this.maxBytes = queryClamp(queryInt(request, "maxBytes", fallback: QUERY_DEFAULT_BYTES),
            1024, QUERY_MAX_BYTES)
        this.selected = selected
    }
}

/** Charge each actual candidate copy and its readable summary, without slicing. */
private func resolutionCandidatePage(candidates: ArrayList<QueryResolutionCandidate>,
    request: JsonObject, catalogId: String, selected: JsonArray): QueryResolutionPage {
    let page = QueryResolutionPage(request, catalogId, candidates.size, selected)
    let selectedBytes = if (selected.size() == 0) { 0 } else { selected[0].toJson().size }
    page.used = selectedBytes
    if (selectedBytes > page.maxBytes) { page.required = selectedBytes }
    let limit = queryInt(request, "limit", fallback: 20)
    while (page.position < candidates.size && page.rows.size() < limit) {
        let row = if (page.position == 0 && selected.size() > 0) {
            selected[0].asObject()
        } else { resolveCandidateJson(candidates[page.position]) }
        let line = resolutionCandidateText(row)
        let size = row.toJson().size + line.size
        if (page.used + size > page.maxBytes) {
            if (page.rows.size() == 0) { page.required = selectedBytes + size }
            break
        }
        page.used += size
        page.rows.add(row)
        page.lines.add(line)
        page.position++
    }
    if (page.required > 0 && page.rows.size() == 0) {
        while (selected.size() > 0) { let _ = selected.removeAt(0) }
        page.used = 0
    }
    page
}

private func resolutionResultText(request: JsonObject, page: QueryResolutionPage,
    status: String, latestDeclared: Bool, total: Int64): String {
    let text = StringBuilder()
    text.append("# resolve_docs: " + status +
        "\n\nSelection is documentation matching, not compilation or behavior verification.\n")
    if (queryBool(request, "latest") && !latestDeclared && total > 0) {
        text.append("No explicit latest alias is recorded by these standalone inputs; no API version was guessed.\n")
    }
    if (resolveContextRequested(request)) {
        text.append("Candidates were restricted to explicitly named captured dependency contexts.\n")
    }
    for (line in page.lines) { text.append(line) }
    if (page.required > 0 && page.rows.size() == 0) {
        text.append("\n\nThe next intact candidate and required selection copies need ${page.required} " +
            "UTF-8 content bytes. No candidate content was returned.")
    }
    text.append("\n\nCandidates ${page.offset}..${page.position} of ${total}; " +
        "${page.used} content bytes used of a ${page.maxBytes}-byte budget. API collection states remain in " +
        "completeness.apiCollection. A missing selection says nothing about declarations outside these loaded scopes.\n")
    text.toString()
}

internal func resolveDocumentationQuery(inputs: ArrayList<QuerySnapshotInput>, request: JsonObject,
    catalogId: String): JsonObject {
    let (contexts, contextCaptured) = resolveDependencyContexts(inputs, request)
    let contextRequested = resolveContextRequested(request)
    if (contextRequested && !contextCaptured) {
        throw DocumentationQueryException("scope_mismatch", "context_not_captured",
            "The requested captured context is not loaded; no documentation-only substitution is made.")
    }
    let work = DependencyNavigationWork()
    let (candidates, latestDeclared) = collectResolutionCandidates(inputs, request, contexts, work)
    if (work.exhausted) {
        throw DocumentationQueryException("resource_limit", "dependency_evidence_work_limit",
            "Captured dependency matching exhausted its existing work budget; no absence conclusion is valid.")
    }
    sort(candidates, lessThan: resolveCandidateBefore, stable: true)
    let selected = JsonArray()
    var bestCount: Int64 = 0
    if (!candidates.isEmpty() && candidates[0].admitted) {
        let score = candidates[0].score
        for (candidate in candidates where candidate.admitted && candidate.score == score) { bestCount++ }
        if (bestCount == 1) { selected.add(resolveCandidateJson(candidates[0])) }
    }
    let latest = queryBool(request, "latest")
    var status = if (bestCount == 0) { "not_found" } else if (bestCount > 1) { "ambiguous" } else { "ok" }
    if (latest && !latestDeclared && bestCount > 0) {
        status = "ambiguous"
        while (selected.size() > 0) { let _ = selected.removeAt(0) }
    }
    let resultPage = resolutionCandidatePage(candidates, request, catalogId, selected)
    let response = newDocumentationQueryResponse(request, status, inputs, catalogId)
    let selection = JsonObject()
    selection.put("strategy", JsonNode.string(if (latest) { "explicit-latest-alias" } else { "captured-dependency-policy" }))
    selection.put("selected", resultPage.selected)
    selection.put("candidates", resultPage.rows)
    response.put("selection", selection)
    let page = response.get("completeness").getOrThrow().asObject().get("query").getOrThrow().asObject()
    let content = response.get("completeness").getOrThrow().asObject().get("content").getOrThrow().asObject()
    let budgetStopped = resultPage.rows.size() == 0 && resultPage.required > 0
    let limit = queryInt(request, "limit", fallback: 20)
    if (budgetStopped && resultPage.required > QUERY_MAX_BYTES) {
        status = "resource_limit"
        response.put("status", JsonNode.string(status))
        response.put("selection", JsonNode.nullValue)
        response.put("error", queryErrorNode("candidate_resource_limit",
            "No supported query budget fits the intact candidate; read the captured Doc IR or packaged representation.",
            Some(resultPage.required), Some(QUERY_MAX_BYTES)))
        content.get("omittedSections").getOrThrow().asArray().add(
            queryOmission("candidates", "resource_limit", Option<JsonNode>.None))
        content.put("complete", JsonNode.boolean(false))
    } else if (budgetStopped) {
        let retry = queryRetryNode(resultPage.required,
            "Retry from the beginning without cursor and maxBytes at least ${resultPage.required}; no candidate was truncated.")
        status = "budget_exceeded"
        response.put("status", JsonNode.string(status))
        response.put("error", queryErrorNode("candidate_exceeds_budget",
            "An intact candidate and required selection copies exceed the content budget.",
            Some(resultPage.required), Some(resultPage.maxBytes)))
        content.get("omittedSections").getOrThrow().asArray().add(
            queryOmission("candidates", "budget", Some(retry)))
        content.put("retry", retry)
        content.put("complete", JsonNode.boolean(false))
    } else if (limit > 0 && resultPage.position < candidates.size) {
        let next = queryNextCursor(request, catalogId, resultPage.position)
        content.get("omittedSections").getOrThrow().asArray().add(queryOmission("candidates", "budget",
            Some(queryRetryNode(resultPage.maxBytes,
                "Continue with cursor '${next}' and the identical request; changing budget requires restarting without cursor."))))
        content.put("complete", JsonNode.boolean(false))
        page.put("next", JsonNode.string(next))
    }
    page.put("complete", JsonNode.boolean(resultPage.position == candidates.size))
    page.put("scope", JsonNode.string("document_sets"))
    page.put("offset", JsonNode.int64(resultPage.offset))
    page.put("returned", JsonNode.int64(resultPage.rows.size()))
    page.put("total", JsonNode.int64(candidates.size))
    if (resultPage.position >= candidates.size || limit == 0) { page.put("next", JsonNode.nullValue) }
    page.put("reason", JsonNode.string(if (budgetStopped) { "candidate_exceeds_budget" }
        else if (limit == 0 && !candidates.isEmpty()) { "zero_limit_is_not_absence" }
        else if (resultPage.position < candidates.size) { "candidate_budget" }
        else if (contextRequested) { "explicit_captured_context" } else { "captured_scope_only" }))
    response.put("text", JsonNode.string(resolutionResultText(request, resultPage, status,
        latestDeclared, candidates.size)))
    response
}
