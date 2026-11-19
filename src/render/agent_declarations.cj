package cjdoc.render

import cjdoc.model.*
import std.collection.*

protected func agentDeclarationMarkdownPath(symbol: SymbolDoc): String {
    "agent/" + markdownSymbolPagePath(symbol)
}

protected func agentDeclarationJsonPath(symbol: SymbolDoc): String {
    "agent/symbols/symbol-${boundedHtmlSlug(symbol.id)}.json"
}

protected func agentPageMarkdownPath(page: DocumentationPage): String {
    "agent/pages/page-${boundedHtmlSlug(page.id)}.md"
}

protected func agentPageJsonPath(page: DocumentationPage): String {
    "agent/pages/page-${boundedHtmlSlug(page.id)}.json"
}

internal func agentPackageMarkdownPath(moduleId: String, name: String): String {
    "agent/packages/package-${boundedHtmlSlug(moduleId + ":" + name)}.md"
}

internal func agentPackageJsonPath(moduleId: String, name: String): String {
    "agent/packages/package-${boundedHtmlSlug(moduleId + ":" + name)}.json"
}

private func declarationDependencyInstance(context: DocumentationReadSnapshot, symbol: SymbolDoc): ?String {
    let (dependency, _) = context.moduleDependencyState(symbol.moduleId)
    dependency.map({ value => value.instanceId })
}

protected func appendAgentReadingScope(out: StringBuilder, context: DocumentationReadSnapshot,
    moduleId: ?String): Unit {
    let documentation = context.documentation
    out.append("{\"snapshotId\":${escapeJsonString(context.snapshotId)},\"audience\":" +
        escapeJsonString(documentation.configuration.audience) +
        ",\"cfgProfile\":${escapeJsonString(documentation.configuration.cfgProfile)}," +
        "\"readingLanguage\":${escapeJsonString(context.locale)},\"apiCollectionState\":" +
        escapeJsonString(documentation.apiCollectionState) +
        ",\"publicationRevision\":${escapeJsonString(context.publicationRevision)},\"documentSet\":")
    let identity: ?DocumentSetIdentity = match (moduleId) {
        case Some(id) => context.documentSetForModule(id)
        case None => None
    }
    match (identity) {
        case Some(value) => appendDocumentSetIdentity(out, value)
        case None => out.append("null")
    }
    out.append("}")
}

internal func renderAgentDeclarationJson(context: DocumentationReadSnapshot, symbol: SymbolDoc,
    markdown!: ?String = None): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.declaration/3\",\"scope\":")
    appendAgentReadingScope(out, context, Some(symbol.moduleId))
    out.append(",\"symbolKey\":${escapeJsonString(symbolInventoryKey(symbol))}," +
        "\"dependencyInstanceId\":${nullableString(declarationDependencyInstance(context, symbol))},\"symbol\":")
    appendSymbol(out, symbol)
    out.append(",\"classification\":")
    appendDeclarationClassificationJson(out, capturedDeclarationClassification(context, Some(symbol)))
    out.append(",\"representations\":{\"pathBase\":\"document-root\",\"html\":" +
        escapeJsonString(context.symbolHtmlPath(symbol.id).getOrThrow()) +
        ",\"markdown\":" + escapeJsonString(agentDeclarationMarkdownPath(symbol)) +
        ",\"json\":" + escapeJsonString(agentDeclarationJsonPath(symbol)) + "},\"source\":")
    out.append(sourceReferenceJson(context.projection.sourceReferences.project(
        symbol.moduleId, symbol.source)))
    out.append(",\"diagnostics\":[")
    var first = true
    for (diagnostic in context.documentation.diagnostics where diagnostic.symbolId == Some(symbol.id)) {
        if (!first) { out.append(",") }
        first = false
        appendDiagnostic(out, diagnostic)
    }
    out.append("],\"documentationState\":" + if (symbol.documentation.isSome()) { "\"available\"" } else { "\"missing\"" })
    out.append(",\"exampleEvidence\":{\"state\":\"not_attached\",\"reports\":[]," +
        "\"reason\":\"Documentation and diagnostics alone are not an example execution receipt.\"},\"markdown\":")
    out.append(escapeJsonString(markdown.getOrDefault({ =>
        context.renderDeclarationMarkdown(symbol.id, pagePath: agentDeclarationMarkdownPath(symbol)).getOrThrow()
    })))
    out.append("}\n")
    let result = out.toString()
    if (result.size > RENDER_ARTIFACT_LIMIT) {
        throw RenderResourceLimitException("agent_declaration_exceeds_resource_limit")
    }
    result
}

internal func appendAgentRepresentation(out: StringBuilder, kind: String, id: String,
    html: String, markdown: String, json: String): Unit {
    out.append("{\"kind\":${escapeJsonString(kind)},\"id\":${escapeJsonString(id)}," +
        "\"html\":${escapeJsonString(html)},\"markdown\":${escapeJsonString(markdown)},\"json\":${escapeJsonString(json)}}")
}

protected func agentRepresentationMappings(context: DocumentationReadSnapshot): String {
    let out = StringBuilder()
    var first = true
    for (symbol in context.projection.visibleSymbols) {
        if (!first) { out.append(",") }; first = false
        appendAgentRepresentation(out, "symbol", symbol.id, context.symbolHtmlPath(symbol.id).getOrThrow(),
            agentDeclarationMarkdownPath(symbol), agentDeclarationJsonPath(symbol))
    }
    for (page in context.selectedPages()) {
        if (!first) { out.append(",") }; first = false
        appendAgentRepresentation(out, "concept", page.id, page.route,
            agentPageMarkdownPath(page), agentPageJsonPath(page))
    }
    for (pkg in context.projection.packages) {
        let source = pkg.source
        if (!first) { out.append(",") }; first = false
        appendAgentRepresentation(out, "package", "cjdoc:package:${source.moduleId}:${source.name}",
            packagePagePath(source.moduleId, source.name),
            agentPackageMarkdownPath(source.moduleId, source.name),
            agentPackageJsonPath(source.moduleId, source.name))
    }
    if (!first) { out.append(",") }
    appendAgentRepresentation(out, "project", "cjdoc:page:index", "index.html",
        "agent/pages/index.md", "agent/pages/index.json")
    "[" + out.toString() + "]"
}

/**
 * One manifest row: only what the machine manifest publishes. Payloads are
 * forwarded to the real store, so no declaration, page or report body is kept
 * live a second time just to describe it.
 */
private class AgentManifestResource {
    let path: String
    let mediaType: String
    let bytes: Int64
    let digest: String

    init(path: String, mediaType: String, bytes: Int64, digest: String) {
        this.path = path
        this.mediaType = mediaType
        this.bytes = bytes
        this.digest = digest
    }
}

/**
 * Emitting store adapter: forwards every artifact to the real store in append
 * order and records only the manifest row. Digests already computed by the
 * caller (docs.json, symbol index) are reused instead of hashing the payload
 * again.
 */
internal class AgentManifestStore <: RenderArtifactStore {
    private let target: RenderArtifactStore
    private let knownDigests: HashMap<String, String>
    private let resources = ArrayList<AgentManifestResource>()

    init(target: RenderArtifactStore, knownDigests!: HashMap<String, String>) {
        this.target = target
        this.knownDigests = knownDigests
    }

    public func addText(path: String, mediaType: String, content: String): Int64 {
        let digest = knownDigests.get(path).getOrDefault({ => contractFingerprint(content) })
        // Forward first: a rejected append must not leave a manifest row behind.
        let entry = target.addText(path, mediaType, content)
        resources.add(AgentManifestResource(path, mediaType, content.size, digest))
        entry
    }

    public func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64 {
        let digest = contractFingerprintBytes(bytes)
        let entry = target.addOwnedBytes(path, mediaType, bytes)
        resources.add(AgentManifestResource(path, mediaType, bytes.size, digest))
        entry
    }

    public func readText(entry: Int64, limit: Int64): String {
        target.readText(entry, limit)
    }

    public func replaceText(entry: Int64, content: String): Unit {
        target.replaceText(entry, content)
    }

    func appendResourceRows(out: StringBuilder): Unit {
        var first = true
        for (resource in resources) {
            if (!first) { out.append(",") }
            first = false
            out.append("{\"path\":${escapeJsonString(resource.path.removePrefix("html/"))}," +
                "\"mediaType\":${escapeJsonString(resource.mediaType)}," +
                "\"bytes\":${resource.bytes},\"sha256\":${escapeJsonString(resource.digest)}}")
        }
    }
}

internal func appendAgentDeclarationArtifacts(artifacts: RenderArtifactStore,
    context: DocumentationReadSnapshot, includeFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = []): Unit {
    let docIrText = context.encodedDocumentation
    let docIrDigest = contractFingerprint(docIrText)
    let inventoryText = context.renderSymbolInventory()
    let inventoryDigest = contractFingerprint(inventoryText)
    let knownDigests = HashMap<String, String>()
    knownDigests["html/agent/docs.json"] = docIrDigest
    knownDigests["html/symbol-index.json"] = inventoryDigest
    let machine = AgentManifestStore(artifacts, knownDigests: knownDigests)
    let _ = machine.addText("html/agent/docs.json", "application/json", docIrText)
    let _ = machine.addText("html/symbol-index.json", "application/json", inventoryText)
    for (symbol in context.projection.visibleSymbols) {
        let markdownPath = agentDeclarationMarkdownPath(symbol)
        let jsonPath = agentDeclarationJsonPath(symbol)
        let markdown = context.renderDeclarationMarkdown(symbol.id, pagePath: markdownPath).getOrThrow()
        let _ = machine.addText("html/" + markdownPath, "text/markdown; charset=utf-8", markdown)
        let _ = machine.addText("html/" + jsonPath, "application/json",
            renderAgentDeclarationJson(context, symbol, markdown: Some(markdown)))
    }
    appendAgentPageArtifacts(machine, context)
    let reportRows = appendCapturedReportArtifacts(machine, context, reports)
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.machine-manifest/2\",\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
        "\"pathBase\":\"document-root\",\"projection\":${escapeJsonString(CJDOC_READ_PROJECTION)},\"publicationRevision\":" +
        escapeJsonString(context.publicationRevision) + ",\"scope\":")
    appendAgentReadingScope(out, context, None)
    out.append(",\"docIr\":{\"path\":\"agent/docs.json\",\"sha256\":" +
        escapeJsonString(docIrDigest) + "},\"symbolIndex\":{\"path\":\"symbol-index.json\",\"sha256\":" +
        escapeJsonString(inventoryDigest) + "},\"documentSets\":[")
    var first = true
    for (module in context.documentation.modules) {
        if (let Some(identity) <- context.documentSetForModule(module.id)) {
            if (!first) { out.append(",") }; first = false
            appendDocumentSetIdentity(out, identity)
        }
    }
    out.append("],\"representations\":${agentRepresentationMappings(context)},\"resources\":[")
    machine.appendResourceRows(out)
    out.append("],\"reports\":[${reportRows}],\"fullReference\":" +
        if (includeFull) { "\"agent-full-index.json\"" } else { "null" })
    out.append(",\"limits\":{\"navigationPartBytes\":${AGENT_NAVIGATION_LIMIT}," +
        "\"fullPartBytes\":${AGENT_FULL_LIMIT},\"summaryBytes\":${AGENT_FIELD_LIMIT}," +
        "\"artifactBytes\":${RENDER_ARTIFACT_LIMIT},\"totalArtifactBytes\":${RENDER_ARTIFACT_TOTAL_LIMIT}," +
        "\"artifactCount\":${RENDER_ARTIFACT_ENTRY_LIMIT}}}\n")
    let _ = artifacts.addText("html/agent/manifest.json", "application/json", out.toString())
}
