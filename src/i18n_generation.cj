package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*

private func localizedParameterExists(symbol: SymbolDoc, name: String): Bool {
    for (parameter in symbol.parameters) { if (parameter.name == name) { return true } }
    false
}

private func localizedSingleField(kind: String): Bool {
    ["summary", "description", "param", "return", "deprecated"].contains(kind)
}

internal func validateLocalizedItems(documentation: DocumentationSet, symbol: SymbolDoc,
    comment: DocComment): Unit {
    let fields = HashMap<String, LocalizedCommentItem>()
    for (item in comment.languageItems) {
        let tag = item.tag
        if (isAdmonitionKind(tag.name)) {
            item.fieldId = match (item.entryId) {
                case Some(id) => symbol.id + ":doc:" + tag.name + ":author-" + id
                case None => ""
            }
            tag.entryId = item.entryId
            tag.source = item.source
        } else {
            item.fieldId = symbol.id + ":doc:" + tag.name + ":" + tag.subject
        }
        if (tag.name == "param" && !localizedParameterExists(symbol, tag.subject)) {
            item.state = "invalid"
            documentation.diagnostics.add(Diagnostic("error", "CJDOC3109",
                "language " + item.language.getOrDefault({ => "unknown" }) + ": unknown parameter '" + tag.subject + "'",
                source: item.source, symbolId: Some(symbol.id)))
        }
        if (localizedSingleField(tag.name)) {
            let key = item.fieldId + ":" + item.language.getOrDefault({ => "unknown" })
            match (fields.get(key)) {
                case Some(first) =>
                    first.state = "conflict"; item.state = "conflict"
                    documentation.diagnostics.add(Diagnostic("error", "CJDOC3106",
                        "duplicate documentation field " + tag.name + " '" + tag.subject +
                        "' for language " + item.language.getOrDefault({ => "unknown" }),
                        source: item.source, symbolId: Some(symbol.id)))
                case None => fields[key] = item
            }
        }
        if (tag.description.trimAscii().isEmpty() && item.state == "valid") {
            if (isAdmonitionKind(tag.name)) {
                item.state = if (item.entryId.isSome()) { "empty" } else { "invalid" }
                documentation.diagnostics.add(Diagnostic("error", "CJDOC3117",
                    "@" + tag.name + " requires non-empty documentation",
                    source: item.source, symbolId: Some(symbol.id)))
            } else {
                item.state = "empty"
            }
        }
    }
    // The compatibility view describes only the owning input's default language.
    // All other definitions remain available to the public IR and validation.
    for (item in comment.languageItems) {
        let tag = item.tag
        if (tag.name == "deprecated") { comment.deprecated = Some("") }
        if (item.language != comment.defaultLanguage || item.state != "valid") { continue }
        match (tag.name) {
            case "param" => comment.params.add(tag)
            case "return" => comment.returns = Some(tag); comment.returnTagCount++
            case "throws" => comment.throwsTags.add(tag)
            case "see" => comment.see.add(tag)
            case "example" => comment.examples.add(tag)
            case "deprecated" => comment.deprecated = Some(tag.description)
            case "summary" | "description" | "note" | "warning" | "danger" => ()
            case _ => comment.contracts.add(tag)
        }
    }
}

internal func prepareDocumentationLanguages(documentation: DocumentationSet, request: GenerationRequest): Unit {
    let root = canonicalize(request.projectRoot).toString()
    let rootOptions = if (request.i18n.isSome()) { request.i18n } else { loadDocumentationLanguages(root) }
    let profiles = HashMap<String, ?public_model.DocumentationLanguageOptions>()
    let roots = HashMap<String, String>()
    for (origin in documentation.sourceFileOrigins) { roots[origin.moduleId] = origin.actualRoot }
    for (module in documentation.modules) {
        let inputRoot = roots.get(module.id).getOrDefault({ => root })
        var profile = if (inputRoot == root) { rootOptions } else { loadDocumentationLanguages(inputRoot) }
        if (profile.isNone() && module.role == "workspace") { profile = rootOptions }
        profiles[module.id] = profile
    }
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            validateDeclarationGroup(documentation, symbol, comment)
            validateDeclarationTags(documentation, symbol, comment)
            let noOptions: ?public_model.DocumentationLanguageOptions = None
            let options = profiles.get(symbol.moduleId).getOrDefault({ => noOptions })
            let hasAdmonitions = hasTopLevelAdmonitionTag(comment.raw)
            let hasOtherLocalizedFields = requiresNonAdmonitionLocalizedComment(comment.raw)
            if (options.isNone() && !hasAdmonitions && !hasOtherLocalizedFields) { continue }
            let language: ?String = match (options) { case Some(value) => Some(value.defaultLanguage); case None => None }
            let admonitionsOnly = options.isNone() && hasAdmonitions && !hasOtherLocalizedFields
            let localized = if (admonitionsOnly) {
                parseAdmonitionsOnlyComment(comment, documentation.diagnostics, symbol.id)
            } else {
                parseLocalizedComment(comment, language, documentation.diagnostics, symbol.id)
            }
            if (let Some(profile) <- options) {
                for (item in localized.languageItems) {
                    if (let Some(selected) <- item.language) {
                        if (!profile.languages.toArray().contains(selected)) {
                            item.highlightEligible = false
                            documentation.diagnostics.add(Diagnostic("warning", "CJDOC3104",
                                "language " + selected + " is not configured for this input; author text retained",
                                source: item.source, symbolId: Some(symbol.id)))
                        }
                    }
                }
            }
            if (language.isNone() && localized.localizationScope != "admonitions") {
                for (item in localized.languageItems) {
                    if (item.language.isNone() && !item.tag.description.isEmpty()) {
                        documentation.diagnostics.add(Diagnostic("error", "CJDOC3105",
                            "unqualified documentation requires an explicit default-language",
                            source: item.source, symbolId: Some(symbol.id)))
                        break
                    }
                }
            }
            validateLocalizedItems(documentation, symbol, localized)
            symbol.documentation = Some(localizedDefaultView(localized))
        }
    }
    validateDeclarationGroupTitles(documentation)
}

internal func publicLocalizedTexts(value: DocComment, assetCollector: LocalAssetCollector,
    sourcePath: String, moduleId: String, declarationSource: public_model.SourceRange, symbolId: String,
    context: MarkdownGenerationContext, renderableIds: HashSet<String>,
    sourceMapper: PublicSourceMapper): Array<public_model.DocumentationText> {
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
            case Some(location) => sourceMapper.capturedRange(moduleId, location)
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

private func localizedDefaultView(value: DocComment): DocComment {
    var summary = ""
    var description = ""
    if (value.localizationScope == "admonitions") {
        // Prompt-only localization leaves the original body outside language
        // selection; preserve it when rebuilding the compatibility view.
        summary = value.summaryMarkdown
        description = value.descriptionMarkdown
    } else {
        for (item in value.languageItems) {
            if (item.language != value.defaultLanguage || item.state != "valid") { continue }
            if (item.tag.name == "summary") { summary = item.tag.description }
            if (item.tag.name == "description") { description = item.tag.description }
        }
    }
    let result = DocComment(value.raw, summary, description)
    result.defaultLanguage = value.defaultLanguage; result.commentSource = value.commentSource
    result.localizationScope = value.localizationScope
    result.languageItems.add(all: value.languageItems)
    result.params.add(all: value.params); result.examples.add(all: value.examples)
    result.admonitions.add(all: value.admonitions)
    result.returns = value.returns; result.returnTagCount = value.returnTagCount
    result.throwsTags.add(all: value.throwsTags); result.see.add(all: value.see)
    result.contracts.add(all: value.contracts)
    result.since = value.since; result.version = value.version; result.deprecated = value.deprecated
    result.authors.add(all: value.authors)
    result
}
