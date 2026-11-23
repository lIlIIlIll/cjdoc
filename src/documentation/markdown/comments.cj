protected package cjdoc.documentation.markdown

import cjdoc.documentation.assets.LocalAssetCollector
import cjdoc.documentation.comments.{DocComment, DocTag, isAdmonitionKind}
import cjdoc.source.SourceLocation
import cjdoc.model as public_model
import std.collection.*

internal func publicTag(value: DocTag, targetVisible!: Bool = true): public_model.DocTag {
    let state = if (!targetVisible) {
        "unavailable"
    } else {
        match (value.referenceState) {
            case "resolved" => "resolved"
            case "ambiguous" => "ambiguous"
            case "unresolved" => "unavailable"
            case "broken" => "unavailable"
            case _ => "unavailable"
        }
    }
    let targetSymbolId: ?String = if (state == "resolved") { value.targetSymbolId } else { None }
    public_model.DocTag(value.name, value.subject, value.description, referenceState: state,
        targetSymbolId: targetSymbolId, directives: value.directives, entryId: value.entryId)

}
internal func publicTagForAudience(value: DocTag, renderableIds: HashSet<String>): public_model.DocTag {
    match (value.targetSymbolId) {
        case Some(targetId) => publicTag(value, targetVisible: renderableIds.contains(targetId))
        case None => publicTag(value)
    }
}

private func publicLocalizedTexts(value: DocComment, assetCollector: LocalAssetCollector,
    sourcePath: String, declarationSource: public_model.SourceRange, symbolId: String,
    context: MarkdownGenerationContext, renderableIds: HashSet<String>,
    capturedRange: (SourceLocation) -> ?public_model.SourceRange): Array<public_model.DocumentationText> {
    let result = ArrayList<public_model.DocumentationText>()
    for (item in value.languageItems) {
        let tag = publicTagForAudience(item.tag, renderableIds)
        let admonition = isAdmonitionKind(tag.name)
        // Invalid/unconfigured/duplicate language fields are retained as author
        // input, but never contribute backend calls, metadata or visible budgets.
        let itemContext = if (item.highlightEligible && (item.state == "valid" || item.state == "unpaired")) { context }
            else { MarkdownGenerationContext(highlightMode: "off") }
        itemContext.consumeText(tag.description)
        if (admonition) {
            if (let Some(id) <- item.entryId) { itemContext.consumeText(id) }
        }
        let source: ?public_model.SourceRange = match (item.source) {
            case Some(location) => capturedRange(location)
            case None => None
        }
        let tree = if (admonition) {
            if ((item.state == "valid" || item.state == "unpaired") && !tag.description.trimAscii().isEmpty()) {
                publicAdmonitionMarkdown(tag.name, tag.description, assetCollector, sourcePath,
                    source.getOrDefault({ => declarationSource }), symbolId, itemContext)
            } else {
                public_model.MarkdownNode("document")
            }
        } else {
            publicMarkdown(tag.description, assetCollector, sourcePath,
                source.getOrDefault({ => declarationSource }), symbolId, itemContext)
        }
        let projectionState = if (admonition && (item.state == "valid" || item.state == "unpaired") &&
            tree.children.isEmpty()) {
            context.admonitionWithoutBody(symbolId, source: source)
            if (item.fieldId.isEmpty()) { "invalid" } else { "empty" }
        } else {
            item.state
        }
        result.add(public_model.DocumentationText(item.fieldId, tag.name, tag.subject, item.language,
            tag.description, tree, source: source, state: projectionState,
            referenceState: tag.referenceState, targetSymbolId: tag.targetSymbolId, directives: tag.directives,
            entryId: if (admonition) { item.entryId } else { None }))
    }
    result.toArray()
}

private func defaultPublicAdmonitionTag(text: public_model.DocumentationText,
    translationState: String): public_model.DocTag {
    public_model.DocTag(text.kind, text.subject, text.text, contentLanguage: text.language,
        translationState: translationState, fieldId: text.fieldId,
        descriptionMarkdown: Some(text.markdown), entryId: text.entryId, source: text.source)
}

private func defaultPublicAdmonitionTags(localized: Array<public_model.DocumentationText>): Array<public_model.DocTag> {
    let tags = ArrayList<public_model.DocTag>()
    let seen = HashSet<String>()
    for (text in localized where public_model.isAdmonitionLevel(text.kind)) {
        if (text.fieldId.isEmpty()) {
            if (text.state == "unpaired" && !text.text.trimAscii().isEmpty()) {
                tags.add(defaultPublicAdmonitionTag(text, "unpaired"))
            }
            continue
        }
        if (!seen.add(text.fieldId)) { continue }
        let valid = ArrayList<public_model.DocumentationText>()
        var unqualified: ?public_model.DocumentationText = None
        var unqualifiedCount: Int64 = 0
        for (candidate in localized where candidate.fieldId == text.fieldId &&
            public_model.isAdmonitionLevel(candidate.kind) && candidate.state == "valid" &&
            !candidate.text.trimAscii().isEmpty()) {
            valid.add(candidate)
            if (candidate.language.isNone()) {
                unqualified = Some(candidate)
                unqualifiedCount++
            }
        }
        if (unqualifiedCount == 1) {
            tags.add(defaultPublicAdmonitionTag(unqualified.getOrThrow(), "unknown"))
        } else {
            for (candidate in valid) {
                tags.add(defaultPublicAdmonitionTag(candidate, "unknown"))
            }
        }
    }
    tags.toArray()
}


protected func publicComment(value: DocComment, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext,
    renderableIds: HashSet<String>, capturedRange: (SourceLocation) -> ?public_model.SourceRange): public_model.DocComment {
    try {
        context.consumeText(value.raw)
        context.consumeText(value.summaryMarkdown)
        context.consumeText(value.descriptionMarkdown)
        context.requireBodySize(value.summaryMarkdown, value.descriptionMarkdown)
        let localized = publicLocalizedTexts(value, assetCollector, sourcePath, declarationSource,
            symbolId, context, renderableIds, capturedRange)
        let tags = ArrayList<public_model.DocTag>()
        for (tag in value.params) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        for (tag in value.examples) {
            var tree: ?public_model.MarkdownNode = None
            if (value.localizationScope == "admonitions" || localized.isEmpty()) {
                tree = publicExampleMarkdown(tag.description, assetCollector, sourcePath,
                    declarationSource, symbolId, context)
            } else {
                for (text in localized where text.kind == "example" && text.language == value.defaultLanguage &&
                    text.subject == tag.subject && text.text == tag.description) {
                    if (publicMarkdownContainsCode(text.markdown)) { tree = Some(text.markdown) }
                    break
                }
            }
            let ordinary = publicTagForAudience(tag, renderableIds)
            tags.add(public_model.DocTag(ordinary.name, ordinary.subject, ordinary.description,
                referenceState: ordinary.referenceState, targetSymbolId: ordinary.targetSymbolId,
                directives: ordinary.directives,
                exampleMarkdown: tree))
        }
        match (value.returns) {
            case Some(tag) => tags.add(publicTagForAudience(tag, renderableIds))
            case None => ()
        }
        for (tag in value.throwsTags) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        for (tag in value.see) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        tags.add(all: defaultPublicAdmonitionTags(localized))
        for (tag in value.replacements) {
            let projected = publicTagForAudience(tag, renderableIds)
            let source = tag.source.flatMap(capturedRange)
            let failure: ?public_model.TypeNavigation = if (tag.referenceState == "resolved" &&
                projected.targetSymbolId.isNone()) {
                Some(public_model.TypeNavigation("unavailable", "none", "target excluded by documentation audience"))
            } else if (tag.referenceState == "broken") {
                Some(public_model.TypeNavigation("unavailable", "none", "replacement points to its own declaration"))
            } else { None }
            tags.add(public_model.DocTag(projected.name, projected.subject, projected.description,
                referenceState: projected.referenceState, targetSymbolId: projected.targetSymbolId,
                source: source, navigation: failure))
        }
        for (tag in value.contracts) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        match (value.since) {
            case Some(text) => tags.add(public_model.DocTag("since", "", text))
            case None => ()
        }
        match (value.deprecated) {
            case Some(text) =>
                let legacy = localized.isEmpty() || value.localizationScope == "admonitions"
                let tree: ?public_model.MarkdownNode = if (legacy && !text.isEmpty()) {
                    Some(publicMarkdown(text, assetCollector, sourcePath, declarationSource, symbolId, context))
                } else { None }
                tags.add(public_model.DocTag("deprecated", "", text, descriptionMarkdown: tree))
            case None => ()
        }
        for (text in value.authors) {
            tags.add(public_model.DocTag("author", "", text))
        }
        match (value.version) {
            case Some(text) => tags.add(public_model.DocTag("version", "", text))
            case None => ()
        }
        for (tag in tags) {
            context.consumeText(tag.name);
            context.consumeText(tag.subject)
            context.consumeText(tag.description)
            match (tag.targetSymbolId) {
                case Some(value) => context.consumeText(value)
                case None => ()
            }
            if (let Some(entryId) <- tag.entryId) { context.consumeText(entryId) }
            if (let Some(source) <- tag.source) { context.consumeText(source.path) }
            if (!tag.directives.isEmpty()) { context.consumeText(tag.directives) }
        }
        let body = if (value.descriptionMarkdown.isEmpty()) {
            value.summaryMarkdown
        } else {
            "${value.summaryMarkdown}\n\n${value.descriptionMarkdown}"
        }
        let bodyTree = if (value.localizationScope == "admonitions" || localized.isEmpty()) {
            publicMarkdown(body, assetCollector, sourcePath, declarationSource, symbolId, context)
        } else {
            let children = ArrayList<public_model.MarkdownNode>()
            for (kind in ["summary", "description"]) {
                for (text in localized) {
                    if (text.kind == kind && text.language == value.defaultLanguage && text.state == "valid") {
                        children.add(all: text.markdown.children)
                    }
                }
            }
            public_model.MarkdownNode("document", children: children.toArray())
        }
        return public_model.DocComment(value.raw, value.summaryMarkdown, value.descriptionMarkdown,
            bodyTree, tags: tags.toArray(), defaultLanguage: value.defaultLanguage, localizedTexts: localized,
            localizationScope: value.localizationScope)
    } catch (_: Exception) {
        context.fail(declarationSource, symbolId)
        return public_model.DocComment("", MARKDOWN_FALLBACK_TEXT, "", fallbackPublicMarkdown(),
            defaultLanguage: value.defaultLanguage, localizationScope: value.localizationScope)
    }
}
