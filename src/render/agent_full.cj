package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

private class AgentFullUnit {
    let id: String
    let content: String
    let standalone: String

    init(id: String, content: String, standalone: String) {
        this.id = id
        this.content = content
        this.standalone = standalone
    }
}

private class AgentFullChunk {
    let offset: Int64
    let count: Int64
    let content: String
    let omitted: String
    let contentComplete: Bool

    init(offset: Int64, count: Int64, content: String, omitted: String, contentComplete: Bool) {
        this.offset = offset
        this.count = count
        this.content = content
        this.omitted = omitted
        this.contentComplete = contentComplete
    }
}

private func agentFullPath(part: Int64): String {
    if (part == 0) { "llms-full.txt" } else { "llms-full-part-${part}.txt" }
}

private func agentFullUnits(context: DocumentationReadSnapshot,
    concepts: Array<DocumentationPage>): ArrayList<AgentFullUnit> {
    let units = ArrayList<AgentFullUnit>()
    for (page in concepts) {
        units.add(AgentFullUnit("page:" + page.id,
            context.renderPageMarkdown(page.id).getOrThrow(),
            agentPageMarkdownPath(page)))
    }
    for (pkg in context.projection.packages) {
        let path = packagePagePath(pkg.source.moduleId, pkg.source.name)
        units.add(AgentFullUnit("package:" + pkg.source.moduleId + ":" + pkg.source.name,
            "# Package " + pkg.source.name + "\n\nCanonical page: <" + path + ">\n",
            agentPackageMarkdownPath(pkg.source.moduleId, pkg.source.name)))
    }
    for (symbol in context.projection.visibleSymbols) {
        units.add(AgentFullUnit("symbol:" + symbol.id,
            context.renderDeclarationMarkdown(symbol.id).getOrThrow(), agentDeclarationMarkdownPath(symbol)))
    }
    sort(units, lessThan: { left, right => left.id < right.id }, stable: true)
    units
}

internal func appendAgentFullArtifacts(artifacts: RenderArtifactCollector,
    context: DocumentationReadSnapshot, concepts: Array<DocumentationPage>,
    limit!: Int64 = AGENT_FULL_LIMIT): Unit {
    let title = agentTruncate(context.documentation.project.name.replace("\n", " ").replace("\r", " "), AGENT_FIELD_LIMIT)
    let heading = "# " + title + "\n\nSnapshot: " + context.snapshotId +
        "\nAudience: " + context.documentation.configuration.audience + "\nReading language: " + context.locale +
        "\nAPI collection state: " + context.documentation.apiCollectionState +
        "\nPublication revision: " + context.publicationRevision + "\n"
    let capacity = limit - heading.size - 1024
    if (capacity <= 0) { throw RenderResourceLimitException("agent_full_metadata_exceeds_budget") }
    let units = agentFullUnits(context, concepts)
    let chunks = ArrayList<AgentFullChunk>()
    var body = RenderTextBuffer(limit: limit)
    var omitted = RenderTextBuffer()
    var offset: Int64 = 0
    var count: Int64 = 0
    var contentComplete = true
    var aggregateComplete = true
    for (unit in units) {
        let inline = unit.content.size + 2 <= capacity
        let content = if (inline) { unit.content + "\n\n" } else {
            "\nComplete standalone unit: <" + unit.standalone +
                ">. Its intact content exceeds this aggregate part budget; no signature or code was cut.\n\n"
        }
        if (content.size > capacity) { throw RenderResourceLimitException("agent_full_reference_exceeds_budget") }
        if (count > 0 && body.size + content.size > capacity) {
            chunks.add(AgentFullChunk(offset, count, body.toString(), omitted.toString(), contentComplete))
            offset += count
            count = 0
            body = RenderTextBuffer(limit: limit)
            omitted = RenderTextBuffer()
            contentComplete = true
        }
        body.append(content)
        count++
        if (!inline) {
            if (!contentComplete) { omitted.append(",") }
            omitted.append("{\"unitId\":${escapeJsonString(unit.id)},\"sections\":[\"reference\"]," +
                "\"reason\":\"aggregate_unit_budget\",\"next\":${escapeJsonString(unit.standalone)}}")
            contentComplete = false
            aggregateComplete = false
        }
    }
    chunks.add(AgentFullChunk(offset, count, body.toString(), omitted.toString(), contentComplete))
    let manifest = RenderTextBuffer()
    manifest.append("{\"schemaVersion\":\"cjdoc.agent-full-index/1\",\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
        "\"audience\":${escapeJsonString(context.documentation.configuration.audience)}," +
        "\"language\":${escapeJsonString(context.locale)},\"apiCollectionState\":" +
        escapeJsonString(context.documentation.apiCollectionState) +
        ",\"completeness\":{\"enumerationComplete\":true,\"contentComplete\":${aggregateComplete}}," +
        "\"order\":\"kind,id\",\"unitCount\":${units.size},\"partByteLimit\":${limit},\"parts\":[")
    for (part in 0..chunks.size) {
        let chunk = chunks[part]
        let path = agentFullPath(part)
        let next: ?String = if (part + 1 < chunks.size) { Some(agentFullPath(part + 1)) } else { None }
        let out = RenderTextBuffer(limit: limit)
        out.append(heading)
        out.append("\nPart ${part + 1} of ${chunks.size}; units ${chunk.offset}..${chunk.offset + chunk.count} of ${units.size} (end exclusive).\n")
        out.append("Enumeration complete in this file: ${chunks.size == 1}. Content complete in this file: ${chunk.contentComplete}.\n")
        out.append("Part metadata and omitted-unit references: <agent-full-index.json>.\n")
        if (let Some(path) <- next) { out.append("Continue this snapshot: <${path}>.\n") }
        out.append("\n")
        out.append(chunk.content)
        let content = out.toString()
        artifacts.addText("html/" + path, "text/plain; charset=utf-8", content)
        if (part > 0) { manifest.append(",") }
        manifest.append("{\"path\":${escapeJsonString(path)},\"offset\":${chunk.offset},\"returned\":${chunk.count}," +
            "\"bytes\":${content.size},\"sha256\":${escapeJsonString(contractFingerprint(content))}," +
            "\"contentComplete\":${chunk.contentComplete},\"next\":${nullableString(next)}," +
            "\"omittedSections\":[${chunk.omitted}]}")
    }
    manifest.append("]}\n")
    artifacts.addText("html/agent-full-index.json", "application/json", manifest.toString())
}
