package cjdoc.render

import cjdoc.model.*
import std.collection.*

private class AgentNavigationChunk {
    let offset: Int64
    let count: Int64
    let content: String
    let contentComplete: Bool

    init(offset: Int64, count: Int64, content: String, contentComplete: Bool) {
        this.offset = offset
        this.count = count
        this.content = content
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

internal func appendAgentNavigationArtifacts(artifacts: RenderArtifactCollector,
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
    let chunks = ArrayList<AgentNavigationChunk>()
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
            chunks.add(AgentNavigationChunk(offset, count, body.toString(), complete))
            offset += count
            body = RenderTextBuffer(limit: limit)
            count = 0
            complete = true
        }
        if (count > 0) { body.append(",") }
        body.append(entry)
        count++
        if (page.summary.getOrDefault({ => "" }).size > AGENT_FIELD_LIMIT) { complete = false }
    }
    chunks.add(AgentNavigationChunk(offset, count, body.toString(), complete))
    for (part in 0..chunks.size) {
        let chunk = chunks[part]
        let next: ?String = if (part + 1 < chunks.size) { Some(agentNavigationPath(part + 1)) } else { None }
        let out = RenderTextBuffer(limit: limit)
        out.append(prefix)
        out.append(",\"completeness\":{\"enumerationComplete\":${chunks.size == 1}," +
            "\"contentComplete\":${chunk.contentComplete}},\"pagination\":{")
        out.append("\"offset\":${chunk.offset},\"returned\":${chunk.count},\"total\":${pages.size}," +
            "\"part\":${part},\"parts\":${chunks.size},\"next\":${nullableString(next)}," +
            "\"pathBase\":\"document-root\"},\"pages\":[")
        out.append(chunk.content)
        out.append("]}\n")
        artifacts.addText("html/" + agentNavigationPath(part), "application/json", out.toString())
    }
}
