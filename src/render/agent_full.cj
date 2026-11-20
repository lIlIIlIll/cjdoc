package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

// A unit is referenced by identifier only: its body is rendered when the part
// that contains it is emitted, so the whole aggregate is never held at once.
private class AgentFullUnit {
    let id: String
    let kind: String
    let key: String
    let packageName: String
    let standalone: String

    init(id: String, kind: String, key: String, packageName: String, standalone: String) {
        this.id = id
        this.kind = kind
        this.key = key
        this.packageName = packageName
        this.standalone = standalone
    }
}

private class AgentFullPart {
    let entry: Int64
    let offset: Int64
    let count: Int64
    let omitted: String
    let contentComplete: Bool

    init(entry: Int64, offset: Int64, count: Int64, omitted: String, contentComplete: Bool) {
        this.entry = entry
        this.offset = offset
        this.count = count
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
        units.add(AgentFullUnit("page:" + page.id, "page", page.id, "",
            agentPageMarkdownPath(page)))
    }
    for (pkg in context.projection.packages) {
        units.add(AgentFullUnit("package:" + pkg.source.moduleId + ":" + pkg.source.name,
            "package", pkg.source.moduleId, pkg.source.name,
            agentPackageMarkdownPath(pkg.source.moduleId, pkg.source.name)))
    }
    for (symbol in context.projection.visibleSymbols) {
        units.add(AgentFullUnit("symbol:" + symbol.id, "symbol", symbol.id, "",
            agentDeclarationMarkdownPath(symbol)))
    }
    sort(units, lessThan: { left, right => left.id < right.id }, stable: true)
    units
}

private func agentFullUnitContent(context: DocumentationReadSnapshot, unit: AgentFullUnit): String {
    match (unit.kind) {
        case "page" => context.renderPageMarkdown(unit.key).getOrThrow()
        case "package" =>
            let path = context.projection.packageFileHref(unit.key, unit.packageName)
            "# Package " + unit.packageName + "\n\nCanonical page: <" + path + ">\n"
        case _ => context.renderDeclarationMarkdown(unit.key).getOrThrow()
    }
}

internal func appendAgentFullArtifacts(artifacts: RenderArtifactStore,
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
    // Parts are emitted with their body first and their pagination header
    // prepended once the total part count is known. Only one part body is live
    // at a time, and unit bodies are rendered once, when their part is filled.
    let parts = ArrayList<AgentFullPart>()
    var body = RenderTextBuffer(limit: limit)
    var omitted = RenderTextBuffer()
    var offset: Int64 = 0
    var count: Int64 = 0
    var contentComplete = true
    var aggregateComplete = true
    for (unit in units) {
        let unitContent = agentFullUnitContent(context, unit)
        let inline = unitContent.size + 2 <= capacity
        let content = if (inline) { unitContent + "\n\n" } else {
            "\nComplete standalone unit: <" + unit.standalone +
                ">. Its intact content exceeds this aggregate part budget; no signature or code was cut.\n\n"
        }
        if (content.size > capacity) { throw RenderResourceLimitException("agent_full_reference_exceeds_budget") }
        if (count > 0 && body.size + content.size > capacity) {
            let entry = artifacts.addText("html/" + agentFullPath(parts.size), "text/plain; charset=utf-8",
                body.toString())
            parts.add(AgentFullPart(entry, offset, count, omitted.toString(), contentComplete))
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
    let finalEntry = artifacts.addText("html/" + agentFullPath(parts.size),
        "text/plain; charset=utf-8", body.toString())
    parts.add(AgentFullPart(finalEntry, offset, count, omitted.toString(), contentComplete))
    let manifest = RenderTextBuffer()
    manifest.append("{\"schemaVersion\":\"cjdoc.agent-full-index/1\",\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
        "\"audience\":${escapeJsonString(context.documentation.configuration.audience)}," +
        "\"language\":${escapeJsonString(context.locale)},\"apiCollectionState\":" +
        escapeJsonString(context.documentation.apiCollectionState) +
        ",\"completeness\":{\"enumerationComplete\":true,\"contentComplete\":${aggregateComplete}}," +
        "\"order\":\"kind,id\",\"unitCount\":${units.size},\"partByteLimit\":${limit},\"parts\":[")
    for (part in 0..parts.size) {
        let chunk = parts[part]
        let path = agentFullPath(part)
        let next: ?String = if (part + 1 < parts.size) { Some(agentFullPath(part + 1)) } else { None }
        let out = RenderTextBuffer(limit: limit)
        out.append(heading)
        out.append("\nPart ${part + 1} of ${parts.size}; units ${chunk.offset}..${chunk.offset + chunk.count} of ${units.size} (end exclusive).\n")
        out.append("Enumeration complete in this file: ${parts.size == 1}. Content complete in this file: ${chunk.contentComplete}.\n")
        out.append("Part metadata and omitted-unit references: <agent-full-index.json>.\n")
        if (let Some(path) <- next) { out.append("Continue this snapshot: <${path}>.\n") }
        out.append("\n")
        out.append(artifacts.readText(chunk.entry, limit))
        let content = out.toString()
        artifacts.replaceText(chunk.entry, content)
        if (part > 0) { manifest.append(",") }
        manifest.append("{\"path\":${escapeJsonString(path)},\"offset\":${chunk.offset},\"returned\":${chunk.count}," +
            "\"bytes\":${content.size},\"sha256\":${escapeJsonString(contractFingerprint(content))}," +
            "\"contentComplete\":${chunk.contentComplete},\"next\":${nullableString(next)}," +
            "\"omittedSections\":[${chunk.omitted}]}")
    }
    manifest.append("]}\n")
    let _ = artifacts.addText("html/agent-full-index.json", "application/json", manifest.toString())
}
