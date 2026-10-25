package cjdoc.render

import cjdoc.model.*

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
    out.append("{\"schemaVersion\":\"cjdoc.declaration/1\",\"scope\":")
    appendAgentReadingScope(out, context, Some(symbol.moduleId))
    out.append(",\"symbolKey\":${escapeJsonString(symbolInventoryKey(symbol))}," +
        "\"dependencyInstanceId\":${nullableString(declarationDependencyInstance(context, symbol))},\"symbol\":")
    appendSymbol(out, symbol)
    out.append(",\"representations\":{\"pathBase\":\"document-root\",\"html\":" +
        escapeJsonString(symbolPagePath(symbol)) + ",\"markdown\":" + escapeJsonString(agentDeclarationMarkdownPath(symbol)) +
        ",\"json\":" + escapeJsonString(agentDeclarationJsonPath(symbol)) + "},\"source\":{\"url\":")
    out.append(nullableString(sourceUrl(context.documentation.project,
        context.modulesById[symbol.moduleId], symbol.source)))
    out.append(",\"range\":")
    appendRange(out, symbol.source)
    let revision = context.documentation.project.repository.map({ repository => repository.revision })
    out.append(",\"recordedRevision\":${nullableString(revision)},\"revisionKind\":" +
        if (revision.isSome()) { "\"recorded\"" } else { "\"unavailable\"" })
    out.append("},\"diagnostics\":[")
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
        appendAgentRepresentation(out, "symbol", symbol.id, symbolPagePath(symbol),
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

internal func appendAgentDeclarationArtifacts(artifacts: RenderArtifactCollector,
    context: DocumentationReadSnapshot, includeFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = []): Unit {
    let machine = RenderArtifactCollector()
    let docIrText = compactDocIr(context.documentation)
    let docIrDigest = contractFingerprint(docIrText)
    let inventoryText = context.renderSymbolInventory()
    let inventoryDigest = contractFingerprint(inventoryText)
    machine.addText("html/agent/docs.json", "application/json", docIrText)
    machine.addText("html/symbol-index.json", "application/json", inventoryText)
    for (symbol in context.projection.visibleSymbols) {
        let markdownPath = agentDeclarationMarkdownPath(symbol)
        let jsonPath = agentDeclarationJsonPath(symbol)
        let markdown = context.renderDeclarationMarkdown(symbol.id, pagePath: markdownPath).getOrThrow()
        machine.addText("html/" + markdownPath, "text/markdown; charset=utf-8", markdown)
        machine.addText("html/" + jsonPath, "application/json", renderAgentDeclarationJson(context, symbol, markdown: Some(markdown)))
    }
    appendAgentPageArtifacts(machine, context)
    let reportRows = appendCapturedReportArtifacts(machine, context, reports)
    let resources = machine.toArray()
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.machine-manifest/1\",\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
        "\"pathBase\":\"document-root\",\"projection\":\"cjdoc.read/1\",\"publicationRevision\":" +
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
    first = true
    for (resource in resources) {
        if (!first) { out.append(",") }; first = false
        let path = resource.path.removePrefix("html/")
        let digest = if (path == "agent/docs.json") { docIrDigest }
            else if (path == "symbol-index.json") { inventoryDigest }
            else { contractFingerprint(resource.content) }
        out.append("{\"path\":${escapeJsonString(path)},\"mediaType\":${escapeJsonString(resource.mediaType)}," +
            "\"bytes\":${resource.byteSize},\"sha256\":${escapeJsonString(digest)}}")
        artifacts.addText(resource.path, resource.mediaType, resource.content)
    }
    out.append("],\"reports\":[${reportRows}],\"fullReference\":" +
        if (includeFull) { "\"agent-full-index.json\"" } else { "null" })
    out.append(",\"limits\":{\"navigationPartBytes\":${AGENT_NAVIGATION_LIMIT}," +
        "\"fullPartBytes\":${AGENT_FULL_LIMIT},\"summaryBytes\":${AGENT_FIELD_LIMIT}," +
        "\"artifactBytes\":${RENDER_ARTIFACT_LIMIT},\"totalArtifactBytes\":${RENDER_ARTIFACT_TOTAL_LIMIT}," +
        "\"artifactCount\":${RENDER_ARTIFACT_ENTRY_LIMIT}}}\n")
    artifacts.addText("html/agent/manifest.json", "application/json", out.toString())
}
