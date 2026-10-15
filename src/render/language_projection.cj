package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func localizedTextFor(comment: DocComment, fieldId: String, language: ?String): ?DocumentationText {
    var result: ?DocumentationText = None
    for (text in comment.localizedTexts) {
        if (text.fieldId != fieldId || text.language != language || text.state != "valid") { continue }
        if (result.isSome()) { return None }
        result = Some(text)
    }
    result
}

private func referenceOnlyTextFor(comment: DocComment, fieldId: String, language: ?String): ?DocumentationText {
    var result: ?DocumentationText = None
    for (text in comment.localizedTexts) {
        if (text.fieldId != fieldId || text.language != language || text.state != "empty" ||
            !["see", "throws"].contains(text.kind) || text.subject.isEmpty()) { continue }
        if (result.isSome()) { return None }
        result = Some(text)
    }
    result
}

internal func selectedDocumentationText(comment: DocComment, fieldId: String, locale: String): ?DocumentationText {
    let selected = localizedTextFor(comment, fieldId, Some(locale))
    if (selected.isSome()) { return selected }
    let fallback = localizedTextFor(comment, fieldId, comment.defaultLanguage)
    if (fallback.isSome()) { return fallback }
    let reference = referenceOnlyTextFor(comment, fieldId, Some(locale))
    if (reference.isSome()) { return reference }
    referenceOnlyTextFor(comment, fieldId, comment.defaultLanguage)
}

private func selectedDocumentationTag(text: DocumentationText, locale: String, symbolId: String,
    requestedState!: String = ""): DocTag {
    let state = if (!requestedState.isEmpty() && text.language != Some(locale)) { requestedState + "-fallback" }
        else if (text.state == "unpaired") { "unpaired" }
        else if (text.language.isNone()) { "unknown" }
        else if (text.state == "empty") {
            if (text.language == Some(locale)) { "empty" } else { "empty-fallback" }
        }
        else if (text.language == Some(locale)) { "complete" } else { "fallback" }
    DocTag(text.kind, text.subject, text.text, referenceState: text.referenceState,
        targetSymbolId: text.targetSymbolId, directives: text.directives,
        exampleMarkdown: if (text.kind == "example") { Some(text.markdown) } else { None },
        contentLanguage: text.language, translationState: state, fieldId: text.fieldId,
        descriptionMarkdown: if (text.kind == "example") { None } else { Some(text.markdown) },
        evidenceKey: if (text.kind == "example") { documentationExampleKey(symbolId, text) } else { "" })
}

private func requestedDocumentationState(comment: DocComment, fieldId: String, locale: String): String {
    for (text in comment.localizedTexts where text.fieldId == fieldId && text.language == Some(locale)) {
        if (text.state == "empty") { return "empty" }
        if (text.state == "invalid" || text.state == "conflict") { return "conflict" }
    }
    ""
}

private func missingDocumentationTag(kind: String, subject: String, id: String,
    value: DocComment, locale: String): DocTag {
    let state = requestedDocumentationState(value, id, locale)
    DocTag(kind, subject, "", fieldId: id, translationState: if (state.isEmpty()) { "missing" } else { state })
}

private func selectedComment(value: DocComment, symbol: SymbolDoc, locale: String): DocComment {
    if (value.localizedTexts.isEmpty()) { return value }
    var summary = ""
    var description = ""
    let children = ArrayList<MarkdownNode>()
    let tags = ArrayList<DocTag>()
    for (kind in ["summary", "description"]) {
        let id = symbol.id + ":doc:" + kind + ":"
        if (let Some(text) <- selectedDocumentationText(value, id, locale)) {
            if (kind == "summary") { summary = text.text } else { description = text.text }
            children.add(all: text.markdown.children)
            tags.add(selectedDocumentationTag(text, locale, symbol.id, requestedState: requestedDocumentationState(value, id, locale)))
        } else if (kind == "summary") { tags.add(missingDocumentationTag(kind, "", id, value, locale)) }
    }
    for (tag in value.tags) {
        if (["since", "version", "author"].contains(tag.name)) { tags.add(tag) }
    }
    let seen = HashSet<String>()
    for (parameter in symbol.parameters) {
        let id = symbol.id + ":doc:param:" + parameter.name
        let _ = seen.add(id)
        match (selectedDocumentationText(value, id, locale)) {
            case Some(text) => tags.add(selectedDocumentationTag(text, locale, symbol.id, requestedState: requestedDocumentationState(value, id, locale)))
            case None => tags.add(missingDocumentationTag("param", parameter.name, id, value, locale))
        }
    }
    for (text in value.localizedTexts) {
        if (["summary", "description", "param"].contains(text.kind)) { continue }
        if (text.state == "unpaired") {
            // Without a proven association these are independent author entries,
            // including contract facts. Hiding one would pretend it was a translation.
            tags.add(selectedDocumentationTag(text, locale, symbol.id))
        } else if (seen.add(text.fieldId)) {
            match (selectedDocumentationText(value, text.fieldId, locale)) {
                case Some(selected) => tags.add(selectedDocumentationTag(selected, locale, symbol.id, requestedState: requestedDocumentationState(value, text.fieldId, locale)))
                case None => tags.add(missingDocumentationTag(text.kind, text.subject, text.fieldId, value, locale))
            }
        }
    }
    return DocComment(value.rawText, summary, description, MarkdownNode("document", children: children.toArray()),
        tags: tags.toArray(), defaultLanguage: value.defaultLanguage, localizedTexts: value.localizedTexts.toArray())
}

private func selectedSymbol(value: SymbolDoc, locale: String): SymbolDoc {
    if (value.documentation.isNone() || value.documentation.getOrThrow().localizedTexts.isEmpty()) {
        return value
    }
    let comment: ?DocComment = match (value.documentation) {
        case Some(documentation) => Some(selectedComment(documentation, value, locale))
        case None => None
    }
    let parameters = ArrayList<ParameterDoc>()
    for (parameter in value.parameters) {
        var text = parameter.documentation
        if (let Some(documentation) <- comment) {
            for (tag in documentation.tags) {
                if (tag.name == "param" && tag.subject == parameter.name) {
                    text = if (tag.description.isEmpty()) { None } else { Some(tag.description) }
                    break
                }
            }
        }
        parameters.add(ParameterDoc(parameter.name, parameter.typeRef, documentation: text,
            defaultExpression: parameter.defaultExpression))
    }
    SymbolDoc(value.id, value.kind, value.name, value.qualifiedName, value.packageName, value.moduleId,
        value.visibility, value.source, value.headerSpelling, value.semantic, value.enumNonExhaustive,
        ownerId: value.ownerId, genericParameters: value.genericParameters.toArray(), parameters: parameters.toArray(),
        returnType: value.returnType, annotations: value.annotations.toArray(),
        typeRelationships: value.typeRelationships.toArray(), symbolRelationships: value.symbolRelationships.toArray(),
        documentation: comment, origin: value.origin, sourceApiSignature: value.sourceApiSignature,
        signatureHighlight: value.signatureHighlight)
}

/** Select reading content without mutating the complete author documentation. */
public func projectDocumentationLanguage(value: DocumentationSet, locale: String): DocumentationSet {
    let language = documentationLanguage(locale)
    let declarations = ArrayList<SymbolDoc>()
    for (symbol in value.declarations) { declarations.add(selectedSymbol(symbol, language)) }
    DocumentationSet(value.generator, value.status, value.project, value.configuration,
        apiCollectionState: Some(value.apiCollectionState),
        providers: value.providers.toArray(), modules: value.modules.toArray(), packages: value.packages.toArray(),
        files: value.files.toArray(), declarations: declarations.toArray(), assets: value.assets.toArray(),
        orphanDocComments: value.orphanDocComments.toArray(), macroInvocations: value.macroInvocations.toArray(),
        unsupportedDeclarations: value.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: value.unboundSemanticDeclarations.toArray(), diagnostics: value.diagnostics.toArray(),
        languageOptions: value.languageOptions, pages: value.pages.toArray(), readingLanguage: Some(language),
        externalDocumentation: value.externalDocumentation.toArray())
}
