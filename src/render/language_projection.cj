package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func isAdmonitionOnlyLocalization(comment: DocComment): Bool {
    comment.localizationScope == "admonitions"
}

private func localizedAdmonitionTextFor(comment: DocComment, fieldId: String,
    language: ?String): ?DocumentationText {
    var result: ?DocumentationText = None
    for (text in comment.localizedTexts) {
        if (text.fieldId != fieldId || !isAdmonitionLevel(text.kind) ||
            text.language != language || text.state != "valid" || text.text.trimAscii().isEmpty()) { continue }
        if (result.isSome()) { return None }
        result = Some(text)
    }
    result
}

private func selectedAdmonitionText(comment: DocComment, fieldId: String,
    locale: String): ?DocumentationText {
    let selected = localizedAdmonitionTextFor(comment, fieldId, Some(locale))
    if (selected.isSome()) { return selected }
    let original = localizedAdmonitionTextFor(comment, fieldId, comment.defaultLanguage)
    if (original.isSome()) { return original }
    var unique: ?DocumentationText = None
    for (text in comment.localizedTexts) {
        if (text.fieldId != fieldId || !isAdmonitionLevel(text.kind) ||
            text.state != "valid" || text.text.trimAscii().isEmpty() || text.language.isNone() ||
            text.language == Some(locale) || text.language == comment.defaultLanguage) { continue }
        if (unique.isSome()) { return None }
        unique = Some(text)
    }
    unique
}
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

// Preserve a documented exception condition when its only authored prose is
// in the other published language. This must never choose between candidates.
internal func soleForeignThrowsText(comment: DocComment, fieldId: String, locale: String): ?DocumentationText {
    var result: ?DocumentationText = None
    for (text in comment.localizedTexts) {
        if (text.fieldId != fieldId || text.kind != "throws" ||
            text.state != "valid" || text.language == Some(locale)) { continue }
        if (result.isSome()) { return None }
        result = Some(text)
    }
    result
}

internal func selectedDocumentationText(comment: DocComment, fieldId: String, locale: String): ?DocumentationText {
    for (text in comment.localizedTexts where text.fieldId == fieldId) {
        if (isAdmonitionLevel(text.kind)) {
            return selectedAdmonitionText(comment, fieldId, locale)
        }
    }
    let selected = localizedTextFor(comment, fieldId, Some(locale))
    if (selected.isSome()) { return selected }
    let fallback = localizedTextFor(comment, fieldId, comment.defaultLanguage)
    if (fallback.isSome()) { return fallback }
    let reference = referenceOnlyTextFor(comment, fieldId, Some(locale))
    if (reference.isSome()) { return reference }
    let defaultReference = referenceOnlyTextFor(comment, fieldId, comment.defaultLanguage)
    if (defaultReference.isSome()) { return defaultReference }
    soleForeignThrowsText(comment, fieldId, locale)
}
private func selectedDocumentationTag(text: DocumentationText, locale: String,
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
        navigation: text.navigation,
        entryId: if (isAdmonitionLevel(text.kind)) { text.entryId } else { None },
        source: if (isAdmonitionLevel(text.kind)) { text.source } else { None })
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

private func selectedAdmonitionTags(value: DocComment, locale: String): Array<DocTag> {
    let tags = ArrayList<DocTag>()
    let seen = HashSet<String>()
    for (text in value.localizedTexts where isAdmonitionLevel(text.kind)) {
        if (text.fieldId.isEmpty()) {
            if (text.state == "unpaired" && !text.text.trimAscii().isEmpty()) {
                tags.add(selectedDocumentationTag(text, locale))
            }
            continue
        }
        if (!seen.add(text.fieldId)) { continue }
        if (let Some(selected) <- selectedAdmonitionText(value, text.fieldId, locale)) {
            tags.add(selectedDocumentationTag(selected, locale,
                requestedState: requestedDocumentationState(value, text.fieldId, locale)))
        }
    }
    tags.toArray()
}

private func admonitionIntroductionTag(name: String): Bool {
    ["param", "example", "return", "throws", "see"].contains(name)
}

private func selectedAdmonitionsOnlyComment(value: DocComment, locale: String): DocComment {
    let admonitions = selectedAdmonitionTags(value, locale)
    let tags = ArrayList<DocTag>()
    var inserted = false
    for (tag in value.tags) {
        if (isAdmonitionLevel(tag.name)) {
            if (!inserted) { tags.add(all: admonitions); inserted = true }
            continue
        }
        if (!inserted && !admonitionIntroductionTag(tag.name)) {
            tags.add(all: admonitions)
            inserted = true
        }
        tags.add(tag)
    }
    if (!inserted) { tags.add(all: admonitions) }
    DocComment(value.rawText, value.summary, value.description, value.markdown,
        tags: tags.toArray(), defaultLanguage: value.defaultLanguage,
        localizedTexts: value.localizedTexts.toArray(), localizationScope: value.localizationScope)
}

private func selectedComment(value: DocComment, symbol: SymbolDoc, locale: String): DocComment {
    if (value.localizedTexts.isEmpty()) { return value }
    if (isAdmonitionOnlyLocalization(value)) { return selectedAdmonitionsOnlyComment(value, locale) }
    var summary = ""
    var description = ""
    let children = ArrayList<MarkdownNode>()
    let tags = ArrayList<DocTag>()
    for (kind in ["summary", "description"]) {
        let id = symbol.id + ":doc:" + kind + ":"
        if (let Some(text) <- selectedDocumentationText(value, id, locale)) {
            if (kind == "summary") { summary = text.text } else { description = text.text }
            children.add(all: text.markdown.children)
            tags.add(selectedDocumentationTag(text, locale, requestedState: requestedDocumentationState(value, id, locale)))
        } else if (kind == "summary") { tags.add(missingDocumentationTag(kind, "", id, value, locale)) }
    }
    for (tag in value.tags) {
        // Shared metadata keeps every declaration an author marked, in both
        // languages, because membership is not a translated field.
        if (["since", "version", "author", "group", "tag"].contains(tag.name)) { tags.add(tag) }
    }
    let seen = HashSet<String>()
    for (parameter in symbol.parameters) {
        let id = symbol.id + ":doc:param:" + parameter.name
        let _ = seen.add(id)
        match (selectedDocumentationText(value, id, locale)) {
            case Some(text) => tags.add(selectedDocumentationTag(text, locale, requestedState: requestedDocumentationState(value, id, locale)))
            case None => tags.add(missingDocumentationTag("param", parameter.name, id, value, locale))
        }
    }
    for (text in value.localizedTexts) {
        if (["summary", "description", "param"].contains(text.kind)) { continue }
        if (isAdmonitionLevel(text.kind) && text.fieldId.isEmpty()) {
            if (text.state == "unpaired" && !text.text.trimAscii().isEmpty()) {
                tags.add(selectedDocumentationTag(text, locale))
            }
            continue
        }
        if (text.state == "unpaired") {
            // Without a proven association these are independent author entries,
            // including contract facts. Hiding one would pretend it was a translation.
            tags.add(selectedDocumentationTag(text, locale))
        } else if (seen.add(text.fieldId)) {
            match (selectedDocumentationText(value, text.fieldId, locale)) {
                case Some(selected) => tags.add(selectedDocumentationTag(selected, locale, requestedState: requestedDocumentationState(value, text.fieldId, locale)))
                case None =>
                    if (!isAdmonitionLevel(text.kind)) {
                        tags.add(missingDocumentationTag(text.kind, text.subject, text.fieldId, value, locale))
                    }
            }
        }
    }
    return DocComment(value.rawText, summary, description, MarkdownNode("document", children: children.toArray()),
        tags: tags.toArray(), defaultLanguage: value.defaultLanguage,
        localizedTexts: value.localizedTexts.toArray(), localizationScope: value.localizationScope)
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
    let admonitionsOnly = match (value.documentation) {
        case Some(documentation) => isAdmonitionOnlyLocalization(documentation)
        case None => false
    }
    if (admonitionsOnly) {
        for (parameter in value.parameters) { parameters.add(parameter) }
    } else {
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
        documentationRevision: value.documentationRevision,
        providers: value.providers.toArray(), modules: value.modules.toArray(), packages: value.packages.toArray(),
        files: value.files.toArray(), declarations: declarations.toArray(), assets: value.assets.toArray(),
        orphanDocComments: value.orphanDocComments.toArray(), macroInvocations: value.macroInvocations.toArray(),
        unsupportedDeclarations: value.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: value.unboundSemanticDeclarations.toArray(), diagnostics: value.diagnostics.toArray(),
        languageOptions: value.languageOptions, pages: value.pages.toArray(), readingLanguage: Some(language),
        externalDocumentation: value.externalDocumentation.toArray(),
        dependencies: value.dependencies.toArray(), documentSets: value.documentSets.toArray(),
        metadata: value.metadata)
}
