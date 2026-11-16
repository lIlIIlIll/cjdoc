package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func visibleOwnerChain(index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc): ArrayList<SymbolDoc> {
    let owners = ArrayList<SymbolDoc>()
    if (symbol.ownerId.isNone()) { return owners }
    let visited = HashSet<String>()
    let _ = visited.add(symbol.id)
    var current = symbol.ownerId
    while (let Some(ownerId) <- current) {
        if (!visited.add(ownerId)) { break }
        match (findSymbol(index, ownerId)) {
            case Some(owner) => owners.add(owner); current = owner.ownerId
            case None => current = None
        }
    }
    owners
}

internal func appendOwnerBreadcrumbs(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    owners: ArrayList<SymbolDoc>, rootPrefix: String, locale: String): Unit {
    var position = owners.size
    while (position > 0) {
        position--
        let owner = owners[position]
        w.element("li", [htmlClass("cj-breadcrumbs__item")], { item =>
            item.open("a", attrs: [htmlHref(SafeUrl.siteRoute(
                rootPrefix + symbolUrl(index, owner)))])
            item.textElement("code", readerSymbolTitle(owner, locale))
            item.close("a")
        })
    }
}

private func appendOwnerContextSource(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, source: SymbolDoc,
    assetLookup: HashMap<String, String>, rootPrefix: String, locale: String,
    contextRole: String): Unit {
    let sourcePrefix = "owner-context-${contractFingerprint(source.id)}"
    let sourceFieldNamespace = sourcePrefix + ":"
    let headingId = "${sourcePrefix}-heading"
    let targetContext = contextRole == "extension-target"
    let headingTag = if (targetContext) { "h4" } else { "h3" }
    w.open("section", attrs: [htmlClass("cj-owner-context__source"),
        htmlAttr("data-cjdoc-owner-context-source", source.id),
        htmlAttr("data-context-role", contextRole)])
    w.open(headingTag, attrs: [htmlAttr("id", headingId),
        htmlClass("cj-owner-context__heading")])
    if (targetContext) {
        w.text(label(locale, "Resolved extension target: ", "已解析的扩展目标："))
    }
    w.open("a", attrs: [htmlHref(SafeUrl.siteRoute(rootPrefix + symbolUrl(index, source)))])
    w.textElement("code", readerSymbolTitle(source, locale))
    w.close("a")
    w.close(headingTag)
    w.textElement("p", ownerContextResponsibilityNote(targetContext, locale),
        attrs: [htmlClass("cj-owner-context__provenance")])
    if (!targetContext && source.kind == "extend" && !source.headerSpelling.trimAscii().isEmpty()) {
        w.element("div", [htmlClass("cj-owner-context__signature")], { signature =>
            signature.textElement("p", label(locale, "Extension declaration", "扩展声明"))
            signature.open("pre", attrs: [htmlClass("cj-signature")])
            signature.textElement("code", source.headerSpelling.trimAscii())
            signature.close("pre")
        })
    }
    appendOwnerContextDocumentation(w, source, assetLookup, rootPrefix, locale, targetContext,
        sourceFieldNamespace)
    w.close("section")
}

private func ownerContextResponsibilityNote(targetContext: Bool, locale: String): String {
    if (targetContext) {
        return label(locale,
            "This is documentation for the explicitly resolved target type, not an additional guarantee for the extension member.",
            "这是显式解析的目标类型文档，并非扩展成员的额外保证。")
    }
    label(locale,
        "This is documentation from the owning declaration's author, not a separate guarantee for this member.",
        "这是所属声明作者提供的文档上下文，并非该成员单独声明的保证。")
}

private func appendOwnerContextDocumentation(w: HtmlWriter, source: SymbolDoc,
    assetLookup: HashMap<String, String>, rootPrefix: String, locale: String,
    targetContext: Bool, sourceFieldNamespace: String): Unit {
    match (source.documentation) {
        case Some(comment) =>
            let markdownContext = markdownHtmlContext(comment, source, 4, locale: locale,
                fieldAnchorNamespace: sourceFieldNamespace)
            appendSummaryHtml(w, comment, source, assetLookup, rootPrefix,
                locale: locale, fieldAnchorNamespace: sourceFieldNamespace)
            appendDocumentationIntroductionHtml(w, source, rootPrefix,
                assetLookup, 4, locale, context: Some(markdownContext))
            appendDocumentationContractsHtml(w, comment, locale, symbolAnchor(source),
                assetLookup: assetLookup, rootPrefix: rootPrefix,
                markdownContext: markdownContext, headingLevel: 4)
        case None =>
            w.textElement("p", ownerContextMissingText(targetContext, locale),
                attrs: [htmlClass("cj-empty cj-owner-context__empty")])
    }
}

private func ownerContextMissingText(targetContext: Bool, locale: String): String {
    if (targetContext) {
        return label(locale, "No documentation is available for this resolved target type.",
            "此已解析目标类型暂无文档。")
    }
    label(locale,
        "No documentation is available for this owner; that does not imply the member has no usage responsibilities.",
        "所属声明暂无文档；这并不表示该成员没有使用责任。")
}

internal func appendOwnerDocumentationContext(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, owners: ArrayList<SymbolDoc>,
    assetLookup: HashMap<String, String>, rootPrefix: String, locale: String): Unit {
    if (owners.isEmpty()) { return }
    w.open("section", attrs: [htmlClass("cj-owner-context"), htmlFlag("data-cjdoc-owner-context")])
    w.textElement("h2", label(locale, "Documentation context from owning declarations",
        "所属声明的文档上下文"), attrs: [htmlClass("cj-owner-context__title"),
        htmlAttr("id", "owner-context-heading")])
    w.open("ol", attrs: [htmlClass("cj-owner-context__list")])
    let sourceIds = HashSet<String>()
    let _ = sourceIds.add(symbol.id)
    var position = owners.size
    while (position > 0) {
        position--
        let owner = owners[position]
        if (!sourceIds.add(owner.id)) { continue }
        w.open("li", attrs: [htmlClass("cj-owner-context__item")])
        appendOwnerContextSource(w, index, owner, assetLookup, rootPrefix, locale, "owner")
        appendOwnerExtensionTargets(w, index, owner, sourceIds, assetLookup, rootPrefix, locale)
        w.close("li")
    }
    w.close("ol")
    w.close("section")
}

private func appendOwnerExtensionTargets(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    owner: SymbolDoc, sourceIds: HashSet<String>, assetLookup: HashMap<String, String>,
    rootPrefix: String, locale: String): Unit {
    if (owner.kind != "extend") { return }
    for (relationship in owner.symbolRelationships) {
        if (relationship.kind != "extensionTarget" || relationship.state != "resolved") { continue }
        match (relationship.targetSymbolId) {
            case Some(targetId) => match (index.get(targetId)) {
                case Some(target) =>
                    if (sourceIds.add(target.id)) {
                        appendOwnerContextSource(w, index, target,
                            assetLookup, rootPrefix, locale, "extension-target")
                    }
                case None => ()
            }
            case None => ()
        }
    }
}
