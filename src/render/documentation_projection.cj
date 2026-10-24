package cjdoc.render

import cjdoc.model.*
import std.collection.*

// The nine behavior-contract tags are one published classification. Every
// reader surface (HTML, site Markdown, declaration Markdown) selects them
// through this predicate instead of keeping a private copy of the list.
public func isBehaviorContractTag(name: String): Bool {
    name == "precondition" || name == "postcondition" || name == "invariant" ||
        name == "performance" || name == "state" || name == "concurrency" ||
        name == "platform" || name == "compatibility" || name == "error"
}

// Calling context includes these published lifecycle/error/version conditions
// even when the descriptive narrative is not selected.
protected func isCallContractTag(name: String): Bool {
    isBehaviorContractTag(name) || name == "throws" || name == "deprecated" || name == "since"
}

protected let DECLARATION_MARKDOWN_SECTIONS: Array<String> = ["signature", "description",
    "parameters", "returns", "contracts", "examples", "relations", "source"]

internal func behaviorContractLabel(name: String, locale: String): String {
    if (locale != "zh-CN") { return name }
    match (name) {
        case "precondition" => "前置条件"
        case "postcondition" => "后置条件"
        case "invariant" => "不变量"
        case "performance" => "性能"
        case "state" => "状态"
        case "concurrency" => "并发"
        case "platform" => "平台"
        case "compatibility" => "兼容性"
        case "error" => "错误行为"
        case _ => name
    }
}

// A selected declaration is independently readable inside the published HTML
// document root. Links use its canonical pages, not aggregate Markdown siblings.
internal class DeclarationMarkdownProjection {
    private let documentation: DocumentationSet
    private let projection: RenderProjection
    private let locale: String
    private let assets: ArrayList<AssetDoc>
    private let rootAssets: HashMap<String, String>
    private let nestedAssets: HashMap<String, String>
    private let symbolIndex: HashMap<String, SymbolDoc>

    init(documentation: DocumentationSet, projection: RenderProjection, locale: String) {
        this.documentation = documentation
        this.projection = projection
        this.locale = if (locale == "zh-CN") { "zh-CN" } else { "en" }
        this.assets = projectAssets(documentation, projection,
            pages: selectedDocumentationPages(documentation, this.locale))
        this.symbolIndex = projection.visibleIndex
        rootAssets = buildAssetLookup(assets)
        nestedAssets = buildAssetLookup(assets, prefix: "../../")
    }

    // An empty section list returns the complete reference. Unknown names are
    // ignored because the query core composes its own diagnostic chapters.
    func renderSelected(symbol: SymbolDoc, pagePath: String, sections: Array<String>): String {
        let out = RenderTextBuffer()
        out.append("<a id=\"${symbolAnchor(symbol)}\"></a>\n")
        out.append("# ")
        appendMarkdownCodeSpan(out, symbol.qualifiedName)
        out.append("\n\n")
        appendSelectedSections(out, symbol, pagePath, sections)
        out.toString()
    }

    func renderSection(symbol: SymbolDoc, pagePath: String, section: String): String {
        let out = RenderTextBuffer()
        appendSelectedSections(out, symbol, pagePath, [section])
        out.toString()
    }

    private func appendSelectedSections(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String, sections: Array<String>): Unit {
        let allSections = sections.isEmpty()
        let selected = ArrayList<String>(sections)
        if (allSections || selected.contains("signature")) {
            appendSignature(out, symbol)
        }
        if (allSections || selected.contains("description")) {
            appendDocumentation(out, symbol, pagePath, ["description"])
        }
        if (allSections || selected.contains("parameters")) {
            appendParameters(out, symbol, pagePath)
        }
        if (allSections || selected.contains("returns")) {
            appendReturns(out, symbol, pagePath)
        }
        if (allSections || selected.contains("contracts")) {
            appendDocumentation(out, symbol, pagePath, ["contracts"])
        }
        if (allSections || selected.contains("examples")) {
            appendDocumentation(out, symbol, pagePath, ["examples"])
        }
        if (allSections || selected.contains("relations")) {
            appendRelations(out, symbol, pagePath)
            appendDocumentation(out, symbol, pagePath, ["relations"])
        }
        if (allSections || selected.contains("source")) {
            appendSource(out, symbol, pagePath)
        }
    }

    // The two emitted layouts are cached immutably. Unusual caller paths get
    // their own map without mutating a snapshot shared by concurrent readers.
    private func assetLookup(pagePath: String): HashMap<String, String> {
        let prefix = markdownOutputRootPrefix(pagePath)
        if (prefix.isEmpty()) { return rootAssets }
        if (prefix == "../../") { return nestedAssets }
        buildAssetLookup(assets, prefix: prefix)
    }

    private func appendDocumentation(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String, sections: Array<String>): Unit {
        match (symbol.documentation) {
            case Some(comment) =>
                appendDocumentationMarkdown(out, comment, assetLookup(pagePath), locale: locale,
                    pagePath: pagePath, symbolIndex: Some(symbolIndex), canonicalHtml: true,
                    sections: Some(sections), headingPrefix: "##", headingBase: 3)
            case None => if (sections.contains("description")) {
                // The Doc IR has no comment at all. Keep that fact visible
                // instead of presenting an undocumented declaration as complete.
                out.append("## ${label(locale, "Description", "说明")}\n\n")
                appendEscapedMarkdownText(out,
                    label(locale, "No documentation is available for this declaration.",
                        "此声明暂无文档。"))
                out.append("\n\n")
            }
        }
    }

    private func appendSignature(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
        out.append("## ${label(locale, "Signature", "签名")}\n\n")
        // The source spelling is the only copyable signature. Tokens are a
        // separate structured fact and must not be rebuilt into source text.
        if (symbol.headerSpelling.trimAscii().isEmpty()) {
            appendEscapedMarkdownText(out,
                label(locale, "The source signature is not available.",
                    "源码签名不可用。"))
            out.append("\n\n")
        } else {
            appendMarkdownCodeBlock(out, symbol.headerSpelling, "cangjie", "`", 3)
        }
        out.append("- ${label(locale, "Kind", "类别")}: ")
        appendMarkdownCodeSpan(out, symbol.kind)
        out.append("\n- ${label(locale, "Visibility", "可见性")}: ")
        appendMarkdownCodeSpan(out, symbol.visibility)
        out.append("\n- ${label(locale, "Source API signature", "源码 API 签名")}: ")
        appendMarkdownCodeSpan(out, symbol.sourceApiSignature.state)
        out.append("\n")
        if (!symbol.genericParameters.isEmpty()) {
            out.append("- ${label(locale, "Generic parameters", "泛型参数")}: ")
            var first = true
            for (parameter in symbol.genericParameters) {
                if (!first) { out.append(", ") }
                first = false
                appendMarkdownCodeSpan(out, parameter)
            }
            out.append("\n")
        }
        out.append("\n")
    }

    private func appendSource(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String): Unit {
        out.append("## ${label(locale, "Source", "源码")}\n\n")
        out.append("- ${label(locale, "Location", "位置")}: ")
        appendMarkdownCodeSpan(out, "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
        out.append("\n- ${label(locale, "HTML page", "HTML 页面")}: ")
        appendCanonicalSymbolLink(out, symbol, pagePath)
        out.append("\n")
        match (findProjectedModule(projection, symbol.moduleId)) {
            case Some(module) => match (sourceUrl(documentation.project, module, symbol.source)) {
                case Some(url) =>
                    out.append("- ${label(locale, "Repository source", "仓库源码")}: ")
                    match (markdownLinkDestination(url)) {
                        case Some(destination) =>
                            out.append("[" + label(locale, "Open source", "打开源码") + "](" +
                                destination + ")\n")
                        case None => appendMarkdownCodeSpan(out, url); out.append("\n")
                    }
                case None => ()
            }
            case None => ()
        }
        out.append("\n")
    }

    private func appendParameters(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String): Unit {
        let comment = symbol.documentation
        let documentedSubjects = HashSet<String>()
        if (symbol.parameters.isEmpty()) {
            var hasParameterTag = false
            if (let Some(value) <- comment) {
                for (tag in value.tags) { if (tag.name == "param") { hasParameterTag = true; break } }
            }
            if (hasParameterTag) {
                out.append("## ${label(locale, "Parameters", "参数")}\n\n")
                appendTagParameters(out, comment.getOrThrow(), pagePath, documentedSubjects)
                out.append("\n")
            }
            return
        }
        out.append("## ${label(locale, "Parameters", "参数")}\n\n")
        for (parameter in symbol.parameters) {
            out.append("- ")
            appendMarkdownCodeSpan(out, parameter.name)
            out.append(": ")
            appendTypeRefMarkdown(out, parameter.typeRef, pagePath, symbolIndex,
                canonicalHtml: true)
            if (let Some(defaultExpression) <- parameter.defaultExpression) {
                out.append(" = ")
                appendMarkdownCodeSpan(out, defaultExpression)
            }
            let tag: ?DocTag = match (comment) {
                case Some(value) => findTag(value, "param", subject: Some(parameter.name))
                case None => None
            }
            match (tag) {
                case Some(value) =>
                    let _ = documentedSubjects.add(parameter.name)
                    out.append(" — ")
                    appendDocumentationListTagMarkdown(out, value, assetLookup(pagePath), locale,
                        pagePath, Some(symbolIndex), canonicalHtml: true)
                case None => match (parameter.documentation) {
                    case Some(value) => appendStructuredTagText(out, value)
                    case None => out.append("\n")
                }
            }
        }
        if (let Some(value) <- comment) {
            appendTagParameters(out, value, pagePath, documentedSubjects)
        }
        out.append("\n")
    }

    // Authored @param text for names the structured model did not contain is
    // still an author fact and must not disappear from the reference.
    private func appendTagParameters(out: RenderTextBuffer, comment: DocComment,
        pagePath: String, documentedSubjects: HashSet<String>): Unit {
        for (tag in comment.tags) {
            if (tag.name != "param" || documentedSubjects.contains(tag.subject)) { continue }
            let _ = documentedSubjects.add(tag.subject)
            out.append("- ")
            appendMarkdownCodeSpan(out, tag.subject)
            out.append(" — ")
            appendDocumentationListTagMarkdown(out, tag, assetLookup(pagePath), locale, pagePath,
                Some(symbolIndex), canonicalHtml: true)
        }
    }

    private func appendReturns(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String): Unit {
        let comment = symbol.documentation
        let returnType: ?TypeRef = match (symbol.returnType) {
            case Some(value) => if (isUnitType(value)) { None } else { Some(value) }
            case None => None
        }
        var hasReturnDocumentation = false
        var hasThrows = false
        if (let Some(value) <- comment) {
            for (tag in value.tags) {
                if (tag.name == "return" || tag.name == "returns") { hasReturnDocumentation = true }
                if (tag.name == "throws") { hasThrows = true }
            }
        }
        if (returnType.isSome() || hasReturnDocumentation) {
            out.append("## ${label(locale, "Returns", "返回值")}\n\n")
            if (let Some(value) <- returnType) {
                out.append("- ")
                appendTypeRefMarkdown(out, value, pagePath, symbolIndex, canonicalHtml: true)
                out.append("\n")
            }
            if (hasReturnDocumentation) {
                if (returnType.isSome()) { out.append("\n") }
                for (tag in comment.getOrThrow().tags) {
                    if (tag.name != "return" && tag.name != "returns") { continue }
                    appendDocumentationTagMarkdown(out, tag, assetLookup(pagePath), locale, pagePath,
                        Some(symbolIndex), canonicalHtml: true)
                    out.append("\n")
                }
            }
        }
        if (hasThrows) {
            out.append("## ${label(locale, "Throws", "异常")}\n\n")
            for (tag in comment.getOrThrow().tags) {
                if (tag.name != "throws") { continue }
                out.append("- ")
                appendTagSubjectMarkdown(out, tag, pagePath, Some(symbolIndex),
                    canonicalHtml: true)
                out.append(" — ")
                appendDocumentationListTagMarkdown(out, tag, assetLookup(pagePath), locale, pagePath,
                    Some(symbolIndex), canonicalHtml: true)
            }
            out.append("\n")
        }
    }

    private func appendCanonicalSymbolLink(out: RenderTextBuffer, target: SymbolDoc,
        pagePath: String): Unit {
        match (markdownCanonicalSymbolDestination(target, pagePath)) {
            case Some(destination) =>
                out.append("[")
                appendMarkdownCodeSpan(out, target.qualifiedName)
                out.append("](" + destination + ")")
            case None => appendMarkdownCodeSpan(out, target.qualifiedName)
        }
    }

    private func appendRelations(out: RenderTextBuffer, symbol: SymbolDoc,
        pagePath: String): Unit {
        if (symbol.typeRelationships.isEmpty() && symbol.symbolRelationships.isEmpty() &&
            symbol.ownerId.isNone()) { return }
        out.append("## ${label(locale, "Relationships", "关系")}\n\n")
        if (let Some(ownerId) <- symbol.ownerId) {
            match (symbolIndex.get(ownerId)) {
                case Some(owner) =>
                    out.append("- ${label(locale, "Member of", "所属")}: ")
                    appendSymbolReference(out, owner, pagePath)
                    out.append("\n")
                case None => ()
            }
        }
        for (relationship in symbol.typeRelationships) {
            out.append("- "); appendEscapedMarkdownText(out,
                readerRelationshipLabel(relationship.kind, locale)); out.append(": ")
            appendTypeRefMarkdown(out, relationship.target, pagePath, symbolIndex,
                canonicalHtml: true)
            if (relationship.target.semantic.state != "resolved") {
                out.append(" — " + label(locale, "semantic state", "语义状态") + ": ")
                appendMarkdownCodeSpan(out, relationship.target.semantic.state)
            }
            out.append("\n")
        }
        for (relationship in symbol.symbolRelationships) {
            // Audience-hidden targets stay hidden: an agent must not recover a
            // declaration the site projection removed.
            if (let Some(targetId) <- relationship.targetSymbolId) {
                if (!symbolIndex.contains(targetId)) { continue }
            }
            out.append("- "); appendEscapedMarkdownText(out,
                readerRelationshipLabel(relationship.kind, locale)); out.append(": ")
            let display = if (relationship.kind == "extensionTarget") {
                genericTypeDisplaySpelling(relationship.targetDisplay)
            } else { relationship.targetDisplay }
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (symbolIndex.get(targetId)) {
                    case Some(target) => appendSymbolReference(out, target, pagePath)
                    case None => appendMarkdownCodeSpan(out, display)
                }
                case None => appendMarkdownCodeSpan(out, display)
            }
            if (relationship.state != "resolved") {
                out.append(" — " + label(locale, "relationship state", "关系状态") + ": ")
                appendMarkdownCodeSpan(out, relationship.state)
            }
            out.append("\n")
        }
        out.append("\n")
    }

    private func appendSymbolReference(out: RenderTextBuffer, target: SymbolDoc,
        pagePath: String): Unit {
        appendCanonicalSymbolLink(out, target, pagePath)
    }

    private func appendStructuredTagText(out: RenderTextBuffer, value: String): Unit {
        let content = trimExampleBlankLines(value)
        if (content.isEmpty()) { out.append("\n"); return }
        out.append(" — ")
        appendEscapedMarkdownText(out, content)
        out.append("\n")
    }
}
