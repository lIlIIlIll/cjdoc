package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.fs.*

internal func captureDocumentationPages(value: public_model.DocumentationSet,
    request: GenerationRequest): public_model.DocumentationSet {
    let pages = ArrayList<public_model.DocumentationPage>()
    let captured = conceptualPagesForProject(request.projectRoot, value)
    let options = value.languageOptions
    let defaultLanguage: ?String = match (options) { case Some(profile) => Some(profile.defaultLanguage); case None => None }
    let identities = HashSet<String>()
    var localizedPages = false
    for (page in captured) {
        if (page.language.isSome() && page.id.isEmpty()) {
            value.appendDiagnostic(public_model.Diagnostic("error", "CJDOC3110",
                "localized page '" + page.source + "' requires an explicit id; page omitted"))
            continue
        }
        let id = if (page.id.isEmpty()) { page.route } else { page.id }
        let language: ?String = if (page.language.isSome()) { page.language }
            else if (exists(Path(request.projectRoot).join(page.source))) { defaultLanguage } else { None }
        if (language.isSome()) { localizedPages = true }
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
        let (text, tree) = capturePageMarkdown(value, page, request)
        let sections = ArrayList<public_model.DocumentationSection>()
        let sectionIds = HashSet<String>()
        for (section in page.sections) {
            if (!sectionIds.add(section.id) || public_render.documentationSectionAnchor(tree, section.anchor).isNone()) {
                value.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC3110", "page '" + id + "' section '" + section.id + "' has no unique captured heading; mapping omitted"))
            } else { sections.add(section) }
        }
        pages.add(public_model.DocumentationPage(id, page.source, page.route, page.title, page.kind,
            text, tree, language: language,
            defaultLanguage: defaultLanguage, packageName: page.packageName,
            sections: sections.toArray(), targetSymbolIds: targets.toArray(), bindings: bindings.toArray()))
    }
    public_model.DocumentationSet(value.generator, value.status, value.project, value.configuration,
        providers: value.providers.toArray(), modules: value.modules.toArray(), packages: value.packages.toArray(),
        files: value.files.toArray(), declarations: value.declarations.toArray(), assets: value.assets.toArray(),
        orphanDocComments: value.orphanDocComments.toArray(), macroInvocations: value.macroInvocations.toArray(),
        unsupportedDeclarations: value.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: value.unboundSemanticDeclarations.toArray(), diagnostics: value.diagnostics.toArray(),
        languageOptions: value.languageOptions, pages: pages.toArray(),
        externalDocumentation: captureExternalDocumentationReferences(value, request.projectRoot,
            value.languageOptions.isSome() || localizedPages))
}

private func capturePageMarkdown(value: public_model.DocumentationSet,
    page: ConceptualPage, request: GenerationRequest): (String, public_model.MarkdownNode) {
    try {
        let text = conceptualMarkdownWithoutBindings(page.markdown, sentinels: false)
        (text, parseStandaloneMarkdown(text, highlightAdapter: request.highlightAdapter, highlightNode: request.highlightNode))
    } catch (_: Exception) {
        let source = public_model.SourceRange(page.source, public_model.SourcePosition(1, 1, 0),
            public_model.SourcePosition(1, 1, 0))
        value.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC3026",
            "conceptual Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
            source: Some(source)))
        (MARKDOWN_FALLBACK_TEXT, fallbackPublicMarkdown())
    }
}

private func captureExternalDocumentationReferences(value: public_model.DocumentationSet,
    root: String, enabled: Bool): Array<public_model.ExternalDocumentationReference> {
    if (!enabled) { return [] }
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
