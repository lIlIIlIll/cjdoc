package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.fs.*

internal func captureDocumentationPages(value: public_model.DocumentationSet,
    request: GenerationRequest, assetCollector!: ?LocalAssetCollector = None): public_model.DocumentationSet {
    let pages = ArrayList<public_model.DocumentationPage>()
    let previousAssetDiagnostics = assetCollector.map({ collector => collector.diagnostics().size }).getOrDefault({ => 0 })
    let captured = conceptualPagesForProject(request.projectRoot, value)
    let options = value.languageOptions
    let defaultLanguage: ?String = match (options) { case Some(profile) => Some(profile.defaultLanguage); case None => None }
    let identities = HashSet<String>()
    for (page in captured) {
        if (page.language.isSome() && page.id.isEmpty()) {
            value.appendDiagnostic(public_model.Diagnostic("error", "CJDOC3110",
                "localized page '" + page.source + "' requires an explicit id; page omitted"))
            continue
        }
        let id = if (page.id.isEmpty()) { page.route } else { page.id }
        let language: ?String = if (page.language.isSome()) { page.language }
            else if (exists(Path(request.projectRoot).join(page.source))) { defaultLanguage } else { None }
        let identity = id + ":" + language.getOrDefault({ => "unknown" })
        if (!identities.add(identity)) {
            value.appendDiagnostic(public_model.Diagnostic("error", "CJDOC3110", "duplicate logical page '" + id + "' for language " + language.getOrDefault({ => "unknown" })))
            continue
        }
        let targets = ArrayList<String>()
        let bindings = ArrayList<public_model.DocumentationPageBinding>()
        for (binding in page.bindings) {
            if (let Some(target) <- binding.targetSymbolId) { if (!targets.contains(target)) { targets.add(target) } }
            bindings.add(public_model.DocumentationPageBinding(binding.target, binding.selector,
                binding.provenance, binding.version, binding.sourceLine, language: binding.language,
                state: binding.state, targetSymbolId: binding.targetSymbolId))
        }
        let (text, tree) = capturePageMarkdown(value, page, request, assetCollector)
        let sections = capturePageSections(value, page.sections.toArray(), tree, id)
        pages.add(public_model.DocumentationPage(id, page.source, page.route, page.title, page.kind,
            text, tree, language: language,
            defaultLanguage: defaultLanguage, packageName: page.packageName,
            sections: sections, targetSymbolIds: targets.toArray(), bindings: bindings.toArray()))
    }
    if (let Some(collector) <- assetCollector) {
        let diagnostics = collector.diagnostics()
        for (index in previousAssetDiagnostics..diagnostics.size) { value.appendDiagnostic(diagnostics[index]) }
    }
    let assets = match (assetCollector) {
        case Some(collector) => collector.assets()
        case None => value.assets.toArray()
    }
    let status = if (value.status == "complete" && assetCollector.isSome() &&
        assetCollector.getOrThrow().incomplete) { "partial" } else { value.status }
    public_model.DocumentationSet(value.generator, status, value.project, value.configuration,
        providers: value.providers.toArray(), modules: value.modules.toArray(), packages: value.packages.toArray(),
        files: value.files.toArray(), declarations: value.declarations.toArray(), assets: assets,
        orphanDocComments: value.orphanDocComments.toArray(), macroInvocations: value.macroInvocations.toArray(),
        unsupportedDeclarations: value.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: value.unboundSemanticDeclarations.toArray(), diagnostics: value.diagnostics.toArray(),
        languageOptions: value.languageOptions, pages: pages.toArray(),
        externalDocumentation: captureExternalDocumentationReferences(value, request.projectRoot))
}

private func capturePageSections(value: public_model.DocumentationSet,
    sections: Array<public_model.DocumentationSection>, tree: public_model.MarkdownNode,
    pageId: String): Array<public_model.DocumentationSection> {
    let idCounts = HashMap<String, Int64>()
    let anchorCounts = HashMap<String, Int64>()
    let anchors = ArrayList<?String>()
    for (section in sections) {
        idCounts[section.id] = idCounts.get(section.id).getOrDefault({ => 0 }) + 1
        let resolved = public_render.documentationSectionAnchor(tree, section.anchor)
        anchors.add(resolved)
        if (let Some(anchor) <- resolved) {
            anchorCounts[anchor] = anchorCounts.get(anchor).getOrDefault({ => 0 }) + 1
        }
    }
    let result = ArrayList<public_model.DocumentationSection>()
    for (index in 0..sections.size) {
        let section = sections[index]
        let anchor = anchors[index]
        if (idCounts[section.id] != 1 || anchor.isNone() || anchorCounts[anchor.getOrThrow()] != 1) {
            value.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC3110",
                "page '" + pageId + "' section '" + section.id + "' has no unique captured heading; mapping omitted"))
        } else { result.add(section) }
    }
    result.toArray()
}

private func capturePageMarkdown(value: public_model.DocumentationSet,
    page: ConceptualPage, request: GenerationRequest,
    assetCollector: ?LocalAssetCollector): (String, public_model.MarkdownNode) {
    try {
        let text = conceptualMarkdownWithoutBindings(page.markdown, sentinels: false)
        if (let Some(collector) <- assetCollector) {
            if (page.source.endsWith(".md")) {
                if (let Some(origin) <- capturedPageSourceOrigin(page.source, request.projectRoot)) {
                    collector.registerSource(origin)
                }
                return (text, parseCapturedPageMarkdown(text, collector, page.source, request))
            }
        }
        let collector = LocalAssetCollector(ArrayList<SourceFileOrigin>())
        (text, parseCapturedPageMarkdown(text, collector, page.source, request))
    } catch (_: Exception) {
        let source = public_model.SourceRange(page.source, public_model.SourcePosition(1, 1, 0),
            public_model.SourcePosition(1, 1, 0))
        value.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC3026",
            "conceptual Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
            source: Some(source)))
        (MARKDOWN_FALLBACK_TEXT, fallbackPublicMarkdown())
    }
}

// Only source pages already read inside the project can supply image origins.
// Synthetic overviews never acquire a guessed filesystem location.
private func capturedPageSourceOrigin(source: String, projectRoot: String): ?SourceFileOrigin {
    let root = canonicalize(Path(projectRoot))
    let path = root.join(source).normalize()
    if (!exists(path)) { return None }
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink()) { return None }
    let actualRoot = normalizedHostPath(root.toString())
    let actualPath = normalizedHostPath(path.toString())
    if (actualPath == actualRoot || !hostPathIsWithin(actualRoot, actualPath) ||
        normalizedHostPath(canonicalize(path).toString()) != actualPath) { return None }
    Some(SourceFileOrigin(source, actualPath, actualRoot, "", ""))
}

private func captureExternalDocumentationReferences(value: public_model.DocumentationSet,
    root: String): Array<public_model.ExternalDocumentationReference> {
    let references = ArrayList<public_model.ExternalDocumentationReference>()
    let resolvers = loadExternalDocResolvers(root)
    for (symbol in value.declarations) {
        if (!conceptualVisibleForAudience(symbol, value)) { continue }
        for (resolver in resolvers) {
            let (idUrl, idAmbiguous) = resolver.matchTarget(symbol.id)
            let (url, ambiguous) = if (idUrl.isEmpty() && !idAmbiguous) {
                resolver.matchTarget(symbol.qualifiedName)
            } else { (idUrl, idAmbiguous) }
            if (url.isEmpty() && !ambiguous && resolver.state == "available") { continue }
            references.add(public_model.ExternalDocumentationReference(symbol.id, resolver.name,
                if (ambiguous) { "ambiguous" } else { resolver.state }, url, reason: resolver.reason,
                version: resolver.version.getOrDefault({ => "" }), index: resolver.indexPath,
                format: resolver.format, fingerprint: resolver.fingerprint))
        }
    }
    references.toArray()
}
