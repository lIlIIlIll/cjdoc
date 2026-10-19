package cjdoc

import cjdoc.model as nav_model
import std.collection.*
import std.sort.*

private func bindDependencyMarkdown(node: nav_model.MarkdownNode, owner: nav_model.SymbolDoc,
    binder: DependencyNavigationBinder, importScope!: Bool = true): Unit {
    if (node.kind == "semantic_link") {
        if (let Some(metadata) <- node.metadata) {
            if (let Some(target) <- metadata.semanticTarget) {
                let decision = binder.resolveReference(owner, target, importScope: importScope,
                    preferredLocalId: metadata.semanticTargetSymbolId)
                metadata.semanticNavigation = Some(decision)
                metadata.semanticState = decision.state
                metadata.semanticExternalUrl = if (decision.state == "resolved") { Some(decision.url) } else { None }
                metadata.semanticTargetSymbolId = if (decision.state == "resolved" && decision.documentSetId.isEmpty() &&
                    decision.matchLevel == "exact") { Some(decision.symbolKey) } else { None }
            }
        }
    }
    for (child in node.children) { bindDependencyMarkdown(child, owner, binder, importScope: importScope) }
}

private func bindDependencyComment(comment: nav_model.DocComment, owner: nav_model.SymbolDoc,
    binder: DependencyNavigationBinder): nav_model.DocComment {
    bindDependencyMarkdown(comment.markdown, owner, binder)
    for (text in comment.localizedTexts) { bindDependencyMarkdown(text.markdown, owner, binder) }
    let tags = ArrayList<nav_model.DocTag>()
    for (tag in comment.tags) {
        if (let Some(tree) <- tag.exampleMarkdown) { bindDependencyMarkdown(tree, owner, binder) }
        if (let Some(tree) <- tag.descriptionMarkdown) { bindDependencyMarkdown(tree, owner, binder) }
        var navigation: ?nav_model.TypeNavigation = tag.navigation
        let genericReference = (tag.name == "see" || tag.name == "throws") && binder.genericReference(owner, tag.subject)
        if (tag.name == "see" || tag.name == "throws") {
            navigation = Some(binder.resolveReference(owner, tag.subject, preferredLocalId: tag.targetSymbolId))
        }
        tags.add(nav_model.DocTag(tag.name, tag.subject, tag.description,
            referenceState: if (genericReference) { "unavailable" } else { tag.referenceState },
            targetSymbolId: if (genericReference) { None<String> } else { tag.targetSymbolId },
            directives: tag.directives, exampleMarkdown: tag.exampleMarkdown,
            contentLanguage: tag.contentLanguage, translationState: tag.translationState,
            fieldId: tag.fieldId, descriptionMarkdown: tag.descriptionMarkdown,
            evidenceKey: tag.evidenceKey, navigation: navigation))
    }
    let localized = ArrayList<nav_model.DocumentationText>()
    for (text in comment.localizedTexts) {
        let genericReference = (text.kind == "see" || text.kind == "throws") && binder.genericReference(owner, text.subject)
        let navigation: ?nav_model.TypeNavigation = if (text.kind == "see" || text.kind == "throws") {
            Some(binder.resolveReference(owner, text.subject, preferredLocalId: text.targetSymbolId))
        } else { text.navigation }
        localized.add(nav_model.DocumentationText(text.fieldId, text.kind, text.subject, text.language,
            text.text, text.markdown, source: text.source, state: text.state,
            referenceState: if (genericReference) { "unavailable" } else { text.referenceState },
            targetSymbolId: if (genericReference) { None<String> } else { text.targetSymbolId },
            directives: text.directives, navigation: navigation))
    }
    nav_model.DocComment(comment.rawText, comment.summary, comment.description, comment.markdown,
        tags: tags.toArray(), defaultLanguage: comment.defaultLanguage, localizedTexts: localized.toArray())
}

private func bindDependencySymbol(symbol: nav_model.SymbolDoc,
    binder: DependencyNavigationBinder): nav_model.SymbolDoc {
    let parameters = ArrayList<nav_model.ParameterDoc>()
    let relationships = ArrayList<nav_model.TypeRelationship>()
    for (parameter in symbol.parameters) {
        parameters.add(nav_model.ParameterDoc(parameter.name, binder.bindType(symbol, parameter.typeRef),
            documentation: parameter.documentation, defaultExpression: parameter.defaultExpression))
    }
    for (relationship in symbol.typeRelationships) {
        relationships.add(nav_model.TypeRelationship(relationship.kind, binder.bindType(symbol, relationship.target)))
    }
    nav_model.SymbolDoc(symbol.id, symbol.kind, symbol.name, symbol.qualifiedName, symbol.packageName,
        symbol.moduleId, symbol.visibility, symbol.source, symbol.headerSpelling, symbol.semantic,
        symbol.enumNonExhaustive, ownerId: symbol.ownerId, genericParameters: symbol.genericParameters.toArray(),
        parameters: parameters.toArray(), returnType: match (symbol.returnType) {
            case Some(typeRef) => Some(binder.bindType(symbol, typeRef))
            case None => None
        }, annotations: symbol.annotations.toArray(), typeRelationships: relationships.toArray(),
        symbolRelationships: symbol.symbolRelationships.toArray(), documentation: match (symbol.documentation) {
            case Some(comment) => Some(bindDependencyComment(comment, symbol, binder))
            case None => None
        }, origin: symbol.origin, sourceApiSignature: symbol.sourceApiSignature,
        signatureHighlight: symbol.signatureHighlight)
}

private func bindDependencyPageMarkdown(node: nav_model.MarkdownNode, moduleId: String,
    source: String, binder: DependencyNavigationBinder): Unit {
    if (node.kind == "semantic_link") {
        if (let Some(metadata) <- node.metadata) {
            if (let Some(target) <- metadata.semanticTarget) {
                let decision = binder.resolvePageReference(moduleId, target, "", source, 0,
                    preferredLocalId: metadata.semanticTargetSymbolId)
                metadata.semanticNavigation = Some(decision)
                metadata.semanticState = decision.state
                metadata.semanticExternalUrl = if (decision.state == "resolved") { Some(decision.url) } else { None }
                metadata.semanticTargetSymbolId = if (decision.state == "resolved" && decision.documentSetId.isEmpty() &&
                    decision.matchLevel == "exact") { Some(decision.symbolKey) } else { None }
            }
        }
    }
    for (child in node.children) { bindDependencyPageMarkdown(child, moduleId, source, binder) }
}

private func bindDependencyPage(page: nav_model.DocumentationPage, moduleId: String,
    binder: DependencyNavigationBinder): nav_model.DocumentationPage {
    bindDependencyPageMarkdown(page.markdown, moduleId, page.source, binder)
    let bindings = ArrayList<nav_model.DocumentationPageBinding>()
    for (binding in page.bindings) {
        let navigation: ?nav_model.TypeNavigation = if (binding.state == "unavailable" || binding.state == "conflict") {
            None<nav_model.TypeNavigation>
        } else {
            Some(binder.resolvePageReference(moduleId, binding.target, binding.selector, page.source,
                binding.sourceLine, preferredLocalId: binding.targetSymbolId))
        }
        bindings.add(nav_model.DocumentationPageBinding(binding.target, binding.selector, binding.provenance,
            binding.version, binding.sourceLine, language: binding.language, state: binding.state,
            targetSymbolId: binding.targetSymbolId, navigation: navigation))
    }
    nav_model.DocumentationPage(page.id, page.source, page.route, page.title, page.kind, page.text, page.markdown,
        language: page.language, defaultLanguage: page.defaultLanguage, packageName: page.packageName,
        sections: page.sections.toArray(), targetSymbolIds: page.targetSymbolIds.toArray(), bindings: bindings.toArray())
}

internal func bindDependencyNavigation(documentation: nav_model.DocumentationSet, request: GenerationRequest,
    origins: Array<SourceFileOrigin>, externalResolvers!: ?Array<ExternalDocResolver> = None): nav_model.DocumentationSet {
    let binder = DependencyNavigationBinder(documentation, request, origins, externalResolvers: externalResolvers)
    let declarations = ArrayList<nav_model.SymbolDoc>()
    for (symbol in documentation.declarations) { declarations.add(bindDependencySymbol(symbol, binder)) }
    let modulesBySymbol = HashMap<String, String>()
    for (symbol in documentation.declarations) { modulesBySymbol[symbol.id] = symbol.moduleId }
    let roots = HashSet<String>()
    for (module in documentation.modules where module.role == "root") { roots.add(module.id) }
    if (roots.isEmpty() && documentation.modules.size == 1) { roots.add(documentation.modules[0].id) }
    let pages = ArrayList<nav_model.DocumentationPage>()
    for (page in documentation.pages) {
        let contexts = HashSet<String>()
        for (target in page.targetSymbolIds) {
            if (let Some(module) <- modulesBySymbol.get(target)) { contexts.add(module) }
        }
        if (contexts.isEmpty()) { for (root in roots) { contexts.add(root) } }
        var moduleId = ""
        if (contexts.size == 1) { for (context in contexts) { moduleId = context } }
        pages.add(bindDependencyPage(page, moduleId, binder))
    }
    let diagnostics = ArrayList<nav_model.Diagnostic>(documentation.diagnostics.toArray())
    diagnostics.add(all: binder.diagnostics)
    sort(diagnostics, lessThan: { left, right => comparePublicDiagnostic(left, right) < 0 }, stable: true)
    var status = documentation.status
    for (diagnostic in diagnostics where diagnostic.severity == "error") { status = "partial" }
    nav_model.DocumentationSet(documentation.generator, status, documentation.project, documentation.configuration,
        apiCollectionState: Some(documentation.apiCollectionState),
        documentationRevision: documentation.documentationRevision,
        providers: documentation.providers.toArray(), modules: documentation.modules.toArray(),
        packages: documentation.packages.toArray(), files: documentation.files.toArray(), declarations: declarations.toArray(),
        assets: documentation.assets.toArray(), orphanDocComments: documentation.orphanDocComments.toArray(),
        macroInvocations: documentation.macroInvocations.toArray(), unsupportedDeclarations: documentation.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: documentation.unboundSemanticDeclarations.toArray(), diagnostics: diagnostics.toArray(),
        languageOptions: documentation.languageOptions, pages: pages.toArray(), readingLanguage: documentation.readingLanguage,
        externalDocumentation: documentation.externalDocumentation.toArray(), dependencies: binder.dependencies,
        documentSets: binder.documentSets.toArray())
}
