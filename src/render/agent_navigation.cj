package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Each part keeps a store entry and its own pagination numbers; entry payloads
// are never retained here, and every navigation entry is rendered exactly once.
private class AgentNavigationPart {
    let entry: Int64
    let offset: Int64
    let count: Int64
    let contentComplete: Bool

    init(entry: Int64, offset: Int64, count: Int64, contentComplete: Bool) {
        this.entry = entry
        this.offset = offset
        this.count = count
        this.contentComplete = contentComplete
    }
}


private func agentNavigationEntry(page: AgentNavigationPage): String {
    let out = RenderTextBuffer(limit: AGENT_NAVIGATION_LIMIT)
    out.append("{\"id\":${escapeJsonString(page.id)},\"kind\":${escapeJsonString(page.kind)}")
    out.append(",\"title\":${escapeJsonString(page.title)},\"href\":${escapeJsonString(page.href)}")
    let summary = page.summary.map({ text => agentTruncate(text, AGENT_FIELD_LIMIT) })
    let state = match (page.summary) {
        case Some(text) => if (text.size > AGENT_FIELD_LIMIT) { "budget_omitted" } else { "complete" }
        case None => "missing"
    }
    out.append(",\"summary\":${nullableString(summary)},\"summaryState\":${escapeJsonString(state)}")
    out.append(",\"symbolId\":${nullableString(page.symbolId)},\"moduleId\":${nullableString(page.moduleId)}")
    out.append(",\"packageName\":${nullableString(page.packageName)},\"semanticState\":${nullableString(page.semanticState)}}")
    out.toString()
}

private func agentNavigationPath(part: Int64): String {
    if (part == 0) { "navigation-index.json" } else { "navigation-index-part-${part}.json" }
}

internal func appendAgentNavigationArtifacts(artifacts: RenderArtifactStore,
    context: DocumentationReadSnapshot, pages: ArrayList<AgentNavigationPage>, version: ?String,
    includeValidation!: Bool = false, limit!: Int64 = AGENT_NAVIGATION_LIMIT): Unit {
    let documentation = context.documentation
    let scope = "{\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
        "\"audience\":${escapeJsonString(documentation.configuration.audience)}," +
        "\"language\":${escapeJsonString(context.locale)},\"order\":\"href,id\"," +
        "\"includeValidation\":${includeValidation}}"
    let queryId = "cjdoc:query:v1:" + contractFingerprint(scope + "\n" + nullableString(version))
    let prefix = "{\"schemaVersion\":\"cjdoc.navigation-index/2\",\"project\":{" +
        "\"name\":${escapeJsonString(documentation.project.name)}," +
        "\"audience\":${escapeJsonString(documentation.configuration.audience)}," +
        "\"version\":${nullableString(version)}},\"scope\":${scope}," +
        "\"queryId\":${escapeJsonString(queryId)},\"apiCollectionState\":" +
        escapeJsonString(documentation.apiCollectionState)
    // Counts and filenames are bounded by the existing artifact/entry budgets.
    // Reserve metadata before placing an entire entry; never cut identity fields.
    let capacity = limit - prefix.size - 512
    if (capacity <= 0) { throw RenderResourceLimitException("agent_navigation_metadata_exceeds_budget") }
    // One pass: each part body is appended once, then its pagination header is
    // prepended once the total part count is known. Only the current part body
    // is live, and no site-wide payload array is built.
    let parts = ArrayList<AgentNavigationPart>()
    var body = RenderTextBuffer(limit: limit)
    var offset: Int64 = 0
    var count: Int64 = 0
    var complete = true
    for (page in pages) {
        let entry = agentNavigationEntry(page)
        if (entry.size > capacity) {
            throw RenderResourceLimitException("agent_navigation_entry_exceeds_budget")
        }
        if (count > 0 && body.size + 1 + entry.size > capacity) {
            parts.add(AgentNavigationPart(
                artifacts.addText("html/" + agentNavigationPath(parts.size), "application/json",
                    body.toString()),
                offset, count, complete))
            offset += count
            count = 0
            body = RenderTextBuffer(limit: limit)
            complete = true
        }
        if (count > 0) { body.append(",") }
        body.append(entry)
        count++
        if (page.summary.getOrDefault({ => "" }).size > AGENT_FIELD_LIMIT) { complete = false }
    }
    let finalEntry = artifacts.addText("html/" + agentNavigationPath(parts.size),
        "application/json", body.toString())
    parts.add(AgentNavigationPart(finalEntry, offset, count, complete))
    for (part in 0..parts.size) {
        let chunk = parts[part]
        let next: ?String = if (part + 1 < parts.size) { Some(agentNavigationPath(part + 1)) } else { None }
        let out = RenderTextBuffer(limit: limit)
        out.append(prefix)
        out.append(",\"completeness\":{\"enumerationComplete\":${parts.size == 1}," +
            "\"contentComplete\":${chunk.contentComplete}},\"pagination\":{")
        out.append("\"offset\":${chunk.offset},\"returned\":${chunk.count},\"total\":${pages.size}," +
            "\"part\":${part},\"parts\":${parts.size},\"next\":${nullableString(next)}," +
            "\"pathBase\":\"document-root\"},\"pages\":[")
        out.append(artifacts.readText(chunk.entry, capacity))
        out.append("]}\n")
        artifacts.replaceText(chunk.entry, out.toString())
    }
}
