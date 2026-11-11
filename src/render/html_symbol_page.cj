package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Member controls are siblings of <details>: closed native details must not
// hide their actions, and no interactive control nests inside <summary>.
private func appendInlineMemberActions(w: HtmlWriter,
    projection: RenderProjection,
    member: SymbolDoc, rootPrefix: String, locale: String): Unit {
    let actionId = symbolAnchor(member) + "-actions"
    let summaryId = symbolAnchor(member) + "-summary"
    let groupLabelId = actionId + "-group-label"
    let standaloneLabel = label(locale, "Open standalone API page", "打开独立 API 页面")
    let sourceLabel = label(locale, "View source code", "查看源码")
    let copyLabel = label(locale, "Copy link", "复制链接")
    // Name controls through the unique summary rather than duplicating its
    // full signature in HTML attributes (which also differentiates overloads).
    let moreLabel = label(locale, "More actions for", "更多操作：") + " " + member.name
    w.open("div", attrs: [htmlClass("cj-member-actions"), htmlAttr("role", "group"),
        htmlAttr("aria-label", label(locale, "Member actions", "成员操作")),
        htmlAttr("aria-labelledby", groupLabelId + " " + summaryId),
        htmlFlag("data-cjdoc-member-actions")])
    w.textElement("span", label(locale, "Member actions for", "成员操作："),
        attrs: [htmlClass("cj-sr-only"), htmlAttr("id", groupLabelId)])
    w.open("button", attrs: [htmlClass("cj-button cj-button--icon cj-member-actions__toggle"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-member-actions-toggle"),
        htmlAttr("aria-expanded", "false"), htmlAttr("aria-controls", actionId),
        htmlAttr("aria-label", moreLabel), htmlAttr("title", moreLabel),
        htmlAttr("aria-labelledby", actionId + "-more-label " + summaryId)])
    w.icon("more")
    w.textElement("span", label(locale, "More actions for", "更多操作："),
        attrs: [htmlClass("cj-sr-only"), htmlAttr("id", actionId + "-more-label")])
    w.close("button")
    w.open("div", attrs: [htmlClass("cj-member-actions__list"), htmlAttr("id", actionId)])
    appendMemberStandaloneAction(w, member, rootPrefix, standaloneLabel, actionId, summaryId)
    appendMemberSourceAction(w, projection, member, sourceLabel, actionId, summaryId)
    appendMemberCopyAction(w, member, rootPrefix, copyLabel, actionId, summaryId)
    w.textElement("span", "", attrs: [htmlClass("cj-sr-only"),
        htmlFlag("data-cjdoc-copy-status"), htmlAttr("role", "status"),
        htmlAttr("aria-live", "polite")])
    w.close("div")
    w.close("div")
}

private func memberActionAttrs(cssClass: String, actionLabel: String,
    actionId: String, suffix: String, summaryId: String): Array<HtmlAttr> {
    let labelId = actionId + "-" + suffix + "-label"
    return [htmlClass("cj-member-actions__item " + cssClass),
        htmlAttr("aria-label", actionLabel), htmlAttr("title", actionLabel),
        htmlAttr("aria-labelledby", labelId + " " + summaryId)]
}

private func appendMemberStandaloneAction(w: HtmlWriter, member: SymbolDoc,
    rootPrefix: String, actionLabel: String, actionId: String, summaryId: String): Unit {
    let attrs = ArrayList<HtmlAttr>(memberActionAttrs(
        "cj-member-actions__item--standalone", actionLabel, actionId, "standalone", summaryId))
    attrs.add(htmlHref(SafeUrl.siteRoute(rootPrefix + symbolPagePath(member))))
    w.open("a", attrs: attrs.toArray())
    w.icon("standalone")
    w.textElement("span", actionLabel, attrs: [htmlClass("cj-member-actions__label"),
        htmlAttr("id", actionId + "-standalone-label")])
    w.close("a")
}

private func appendMemberSourceAction(w: HtmlWriter, projection: RenderProjection,
    member: SymbolDoc, actionLabel: String, actionId: String, summaryId: String): Unit {
    match (projection.sourceReferences.project(member.moduleId, member.source).url) {
        case Some(url) =>
            // An unsafe provider URL keeps the action out of the page, the same
            // way the previous renderer dropped it.
            match (SafeUrl.external(url)) {
                case Some(external) =>
                    let attrs = ArrayList<HtmlAttr>(memberActionAttrs(
                        "cj-member-actions__item--source", actionLabel, actionId, "source", summaryId))
                    attrs.add(htmlHref(external))
                    attrs.add(htmlAttr("rel", "noreferrer"))
                    w.open("a", attrs: attrs.toArray())
                    w.icon("source")
                    w.textElement("span", actionLabel,
                        attrs: [htmlClass("cj-member-actions__label"),
                            htmlAttr("id", actionId + "-source-label")])
                    w.close("a")
                case None => ()
            }
        case None => ()
    }
}

private func appendMemberCopyAction(w: HtmlWriter, member: SymbolDoc, rootPrefix: String,
    actionLabel: String, actionId: String, summaryId: String): Unit {
    let attrs = ArrayList<HtmlAttr>(memberActionAttrs(
        "cj-member-actions__item--copy", actionLabel, actionId, "copy", summaryId))
    attrs.add(htmlAttr("type", "button"))
    attrs.add(htmlAttr("data-cjdoc-copy-link", rootPrefix + symbolReadablePagePath(member)))
    w.open("button", attrs: attrs.toArray())
    w.icon("copy")
    w.textElement("span", actionLabel, attrs: [htmlClass("cj-member-actions__label"),
        htmlAttr("id", actionId + "-copy-label")])
    w.close("button")
}

// A member without classification renders no empty badge container.
private func appendMemberClassificationBadges(w: HtmlWriter, projection: RenderProjection,
    member: SymbolDoc, rootPrefix: String): Unit {
    let badges = TrustedHtml.capture({ captured =>
        appendDeclarationClassificationBadges(captured, projection.catalog, projection.snapshotId,
            member, rootPrefix, includeGroup: false)
    })
    if (badges.value.isEmpty()) { return }
    w.element("div", [htmlClass("cj-member-row__badges")], { row => row.trusted(badges) })
}

private func appendInlineMemberSignature(w: HtmlWriter, member: SymbolDoc,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    w.open("code", attrs: [htmlClass("cj-signature-inline cj-member__signature")])
    if (!member.headerSpelling.isEmpty()) {
        appendLinkedSignatureHtml(w, member, typeLinkIndex, rootPrefix)
    } else {
        w.text(member.name)
    }
    w.close("code")
}

private func appendMemberSummary(w: HtmlWriter, member: SymbolDoc, origin: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    appendInlineMemberSignature(w, member, typeLinkIndex, "../")
    if (origin != "declared") {
        w.textElement("span", memberOriginLabel(origin, locale),
            attrs: [htmlClass("cj-badge cj-badge--origin")])
    }
    match (member.documentation) {
        case Some(comment) =>
            let summary = summaryPlainText(comment)
            if (!summary.isEmpty()) {
                w.textElement("span", summary, attrs: [htmlClass("cj-member__description")])
            }
        case None => ()
    }
    appendAdmonitionRiskBadges(w, member, locale)
}

private func appendMemberOriginContext(w: HtmlWriter, entry: HtmlMemberEntry,
    rootPrefix: String, locale: String): Unit {
    if (entry.origin == "declared") { return }
    match (entry.declaredBy) {
        case Some(declaredBy) =>
            w.open("p", attrs: [htmlClass("cj-member__origin")])
            w.text(memberOriginLabel(entry.origin, locale) + " · ")
            w.open("a", attrs: [htmlHref(SafeUrl.siteRoute(rootPrefix + symbolPagePath(declaredBy)))])
            w.textElement("code", readerQualifiedName(declaredBy))
            w.close("a")
            w.close("p")
            if (entry.origin == "extension") {
                w.textElement("p", label(locale,
                    "Subject to the extension target and constraints; applicability is not inferred.",
                    "成员受扩展目标与约束限制；此处不推断对具体实例的适用性。"),
                    attrs: [htmlClass("cj-member__conditions")])
                if (!declaredBy.headerSpelling.isEmpty()) {
                    w.open("pre", attrs: [htmlClass("cj-member__extension")])
                    w.open("code", attrs: [codeSourceAttr(declaredBy.headerSpelling)])
                    appendSignatureTextHtml(w, declaredBy)
                    w.close("code")
                    w.close("pre")
                }
            }
        case None => ()
    }
}

internal func appendInlineMemberDetail(w: HtmlWriter,
    documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, entry: HtmlMemberEntry,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    rootPrefix: String, locale: String, sectionHeadingLevel!: Int64 = 3): Unit {
    let member = entry.symbol
    let anchor = symbolAnchor(member)
    w.open("div", attrs: [htmlClass("cj-member-row")])
    w.open("details", attrs: [htmlClass("cj-member"), htmlAttr("id", anchor),
        htmlFlag("data-cjdoc-member"), htmlAttr("data-member-name", member.name),
        htmlAttr("data-member-kind", member.kind),
        htmlAttr("data-member-origin", entry.origin),
        htmlAttr("data-member-symbol-id", member.id)])
    w.open("summary", attrs: [htmlClass("cj-member__summary"),
        htmlAttr("id", anchor + "-summary"), htmlAttr("data-cjdoc-toc-role", "member"),
        htmlAttr("data-cjdoc-toc-depth", sectionHeadingLevel.toString()),
        htmlAttr("data-cjdoc-toc-label", htmlContextLabel(member))])
    appendMemberSummary(w, member, entry.origin, typeLinkIndex, locale)
    w.close("summary")
    w.open("div", attrs: [htmlClass("cj-member__body")])
    appendMemberOriginContext(w, entry, rootPrefix, locale)
    appendDocumentationHtml(w, index, member, rootPrefix, assetLookup, typeLinkIndex,
        headingBase: sectionHeadingLevel, locale: locale, sectionHeadingLevel: sectionHeadingLevel)
    let headingTag = "h${min(6, sectionHeadingLevel)}"
    appendReaderRelationships(w, index, member, rootPrefix, typeLinkIndex, locale,
        headingTag: headingTag)
    appendReverseTypeUsages(w, index, typeLinkIndex, member, rootPrefix, locale)
    projection.apiGuides(documentation, locale).append(w, member, locale,
        headingTag: headingTag, headingSuffix: "-inline-" + htmlStableSlug(member.id))
    appendExternalDocumentationHtml(w, documentation, member, locale, compactUnavailable: true,
        headingLevel: sectionHeadingLevel)
    w.close("div")
    w.close("details")
    appendMemberClassificationBadges(w, projection, member, rootPrefix)
    appendInlineMemberActions(w, projection, member, rootPrefix, locale)
    w.close("div")
    w.newline()
}

internal func memberSectionTitle(symbol: SymbolDoc): String {
    match (symbol.kind) {
        case "constructor" => "Constructors"
        case "property" => "Properties"
        case "variable" => "Variables"
        case "function" => "Functions"
        case "macro" => "Macros"
        case "enumCase" => "Enum cases"
        case "class" => "Nested classes"
        case "struct" => "Nested structs"
        case "interface" => "Nested interfaces"
        case "enum" => "Nested enums"
        case "extend" => "Nested extensions"
        case _ => "Other members"
    }
}

/** Localized label of one member kind section, shared by HTML and Markdown. */
internal func memberSectionLabel(title: String, locale: String): String {
    let sectionLabel = match (title) {
        case "Constructors" => "构造器"
        case "Properties" => "属性"
        case "Variables" => "变量"
        case "Functions" => "函数"
        case "Enum cases" => "枚举项"
        case "Nested classes" => "嵌套类"
        case "Nested structs" => "嵌套结构体"
        case "Nested interfaces" => "嵌套接口"
        case "Nested enums" => "嵌套枚举"
        case "Nested extensions" => "嵌套扩展"
        case _ => "其他成员"
    }
    label(locale, title, sectionLabel)
}

internal func memberSectionAnchor(title: String): String {
    match (title) {
        case "Constructors" => "constructors"
        case "Properties" => "properties"
        case "Variables" => "variables"
        case "Functions" => "functions"
        case "Enum cases" => "enum-cases"
        case "Nested classes" => "nested-classes"
        case "Nested structs" => "nested-structs"
        case "Nested interfaces" => "nested-interfaces"
        case "Nested enums" => "nested-enums"
        case "Nested extensions" => "nested-extensions"
        case _ => "other-members"
    }
}

private func overloadCountsOf(entries: ArrayList<HtmlMemberEntry>): HashMap<String, Int64> {
    let overloadCounts = HashMap<String, Int64>()
    for (entry in entries) {
        let key = "${entry.groupKey}:${entry.symbol.name}"
        overloadCounts[key] = match (overloadCounts.get(key)) {
            case Some(value) => value + 1
            case None => 1
        }
    }
    overloadCounts
}

// An omitted kind heading keeps the filterable container and its members but
// never renders an empty heading shell, a duplicate count row or a TOC node,
// and leaves behind none of the heading's margins.
private func appendMemberGroupHead(w: HtmlWriter, title: String, kindAnchor: String,
    count: Int64, layout: DeclarationGroupLayout, locale: String): Unit {
    if (!layout.showKindHeading) {
        w.open("span", attrs: [htmlClass("cj-anchor-alias"), htmlAttr("id", kindAnchor),
            htmlAttr("aria-hidden", "true")])
        w.close("span")
        w.newline()
        return
    }
    let heading = "h${min(6, layout.kindHeadingLevel)}"
    w.element("div", [htmlClass("cj-member-group__head")], { head =>
        head.open(heading, attrs: [htmlAttr("id", kindAnchor),
            htmlAttr("data-cjdoc-toc-role", "group"), htmlClass("cj-member-group__title")])
        head.text(memberSectionLabel(title, locale))
        head.close(heading)
        let noun = if (count == 1) { label(locale, "member", "个成员") } else { label(locale, "members", "个成员") }
        head.textElement("span", count.toString() + " " + noun,
            attrs: [htmlClass("cj-member-group__count")])
    })
    w.newline()
}

private func appendOverloadHeading(w: HtmlWriter, member: SymbolDoc, count: Int64,
    headingLevel: Int64, locale: String): Unit {
    let groupTitleId = "overloads-" + symbolAnchor(member)
    let heading = "h${headingLevel}"
    w.open("div", attrs: [htmlClass("cj-overloads"), htmlAttr("role", "group"),
        htmlAttr("aria-labelledby", groupTitleId), htmlFlag("data-cjdoc-overload-group"),
        htmlAttr("data-overload-total", count.toString())])
    w.open(heading, attrs: [htmlClass("cj-overloads__title"), htmlAttr("id", groupTitleId),
        htmlAttr("data-cjdoc-toc-role", "overload"),
        htmlAttr("data-cjdoc-toc-label", member.name)])
    w.textElement("code", member.name)
    w.textElement("span", count.toString() + " " + label(locale, "overloads", "个重载"),
        attrs: [htmlClass("cj-overloads__count"), htmlFlag("data-cjdoc-overload-count")])
    w.close(heading)
    w.newline()
}

internal func appendMemberSection(w: HtmlWriter,
    documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, entries: ArrayList<HtmlMemberEntry>,
    title: String, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    layout: DeclarationGroupLayout, kindAnchor: String): Unit {
    if (entries.isEmpty()) { return }
    let overloadCounts = overloadCountsOf(entries)
    let overloadHeadingLevel = min(6, layout.entryParentLevel + 1)
    var opened = false
    var activeOverloadKey = ""
    for (entry in entries) {
        let member = entry.symbol
        if (!opened) {
            w.open("section", attrs: [htmlClass(if (layout.showKindHeading) {
                "cj-member-group"
            } else { "cj-member-group cj-member-group--plain" }), htmlFlag("data-cjdoc-member-group")])
            appendMemberGroupHead(w, title, kindAnchor, entries.size, layout, locale)
            opened = true
        }
        activeOverloadKey = appendMemberEntry(w, documentation, projection, index, entry,
            assetLookup, typeLinkIndex, overloadCounts, overloadHeadingLevel, layout, locale,
            activeOverloadKey)
    }
    if (!activeOverloadKey.isEmpty()) {
        w.close("div")
        w.newline()
    }
    if (opened) {
        w.close("section")
        w.newline()
    }
}

// Returns the overload family that is still open, so the caller can close it
// before starting a different family.
private func appendMemberEntry(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>, entry: HtmlMemberEntry,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    overloadCounts: HashMap<String, Int64>, overloadHeadingLevel: Int64,
    layout: DeclarationGroupLayout, locale: String, activeOverloadKey: String): String {
    let member = entry.symbol
    var active = activeOverloadKey
    let overloadKey = "${entry.groupKey}:${member.name}"
    let count = overloadCounts.get(overloadKey).getOrDefault({ => 0 })
    if (!active.isEmpty() && active != overloadKey) {
        w.close("div")
        w.newline()
        active = ""
    }
    if (count > 1 && active.isEmpty()) {
        appendOverloadHeading(w, member, count, overloadHeadingLevel, locale)
        active = overloadKey
    }
    let parentLevel = if (count > 1) { overloadHeadingLevel } else { layout.entryParentLevel }
    appendInlineMemberDetail(w, documentation, projection, index, entry, assetLookup,
        typeLinkIndex, "../", locale, sectionHeadingLevel: min(6, parentLevel + 1))
    active
}

private func appendMemberBrowserToolbar(w: HtmlWriter,
    browser: HtmlMemberBrowser, locale: String): Unit {
    if (browser.entries.size < 2) { return }
    let filterLabel = label(locale, "Filter members", "筛选成员")
    w.open("div", attrs: [htmlClass("cj-members__toolbar")])
    w.open("button", attrs: [htmlClass("cj-button cj-button--quiet cj-members__filter-toggle"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-member-filter-toggle"),
        htmlAttr("aria-controls", "cjdoc-member-filter-fields"),
        htmlAttr("aria-expanded", "false"), htmlFlag("hidden")])
    w.text(filterLabel)
    w.close("button")
    w.open("div", attrs: [htmlClass("cj-members__filters"),
        htmlAttr("id", "cjdoc-member-filter-fields")])
    w.textElement("label", filterLabel, attrs: [htmlAttr("for", "cjdoc-member-filter")])
    w.void("input", attrs: [htmlClass("cj-input"), htmlAttr("id", "cjdoc-member-filter"),
        htmlAttr("type", "search"), htmlFlag("data-cjdoc-member-filter"),
        htmlAttr("placeholder", filterLabel), htmlAttr("autocomplete", "off")])
    appendMemberOriginFilter(w, browser, locale)
    w.close("div")
    w.element("div", [htmlClass("cj-members__actions")], { actions =>
        actions.open("button", attrs: [htmlClass("cj-button cj-button--quiet"),
            htmlAttr("type", "button"), htmlFlag("data-cjdoc-members-expand")])
        actions.text(label(locale, "Expand all", "全部展开"))
        actions.close("button")
        actions.open("button", attrs: [htmlClass("cj-button cj-button--quiet"),
            htmlAttr("type", "button"), htmlFlag("data-cjdoc-members-collapse")])
        actions.text(label(locale, "Collapse all", "全部收起"))
        actions.close("button")
    })
    w.close("div")
    w.open("p", attrs: [htmlClass("cj-members__status"),
        htmlFlag("data-cjdoc-member-filter-status"), htmlAttr("role", "status"),
        htmlFlag("hidden")])
    w.text(label(locale, "No matching members.", "没有匹配的成员。"))
    w.close("p")
}

private func appendMemberOriginFilter(w: HtmlWriter, browser: HtmlMemberBrowser,
    locale: String): Unit {
    if (browser.origins.size <= 1) { return }
    w.textElement("label", label(locale, "Origin", "来源"),
        attrs: [htmlAttr("for", "cjdoc-member-origin")])
    w.open("select", attrs: [htmlClass("cj-select"), htmlAttr("id", "cjdoc-member-origin"),
        htmlFlag("data-cjdoc-member-origin")])
    w.textElement("option", label(locale, "All origins", "所有来源"),
        attrs: [htmlAttr("value", "")])
    for (origin in browser.origins) {
        w.textElement("option", memberOriginLabel(origin, locale),
            attrs: [htmlAttr("value", origin)])
    }
    w.close("select")
}

private func appendSymbolBreadcrumbs(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, owners: ArrayList<SymbolDoc>, locale: String): Unit {
    w.open("nav", attrs: [htmlClass("cj-breadcrumbs"),
        htmlAttr("aria-label", label(locale, "Breadcrumb", "面包屑导航"))])
    w.open("ol", attrs: [htmlClass("cj-breadcrumbs__list")])
    w.element("li", [htmlClass("cj-breadcrumbs__item")], { item =>
        item.open("a", attrs: [htmlHref(SafeUrl.siteRoute("../index.html"))])
        item.text(label(locale, "Home", "首页"))
        item.close("a")
    })
    w.element("li", [htmlClass("cj-breadcrumbs__item")], { item =>
        item.open("a", attrs: [htmlHref(SafeUrl.siteRoute(
            "../" + packagePagePath(symbol.moduleId, symbol.packageName)))])
        item.text(label(locale, "Package", "包") + " ")
        item.textElement("code", symbol.packageName)
        item.close("a")
    })
    appendOwnerBreadcrumbs(w, index, owners, "../", locale)
    w.element("li", [htmlClass("cj-breadcrumbs__item"), htmlAttr("aria-current", "page")],
        { item =>
        item.textElement("code", readerSymbolTitle(symbol, locale))
    })
    w.close("ol")
    w.close("nav")
    w.newline()
}

private func appendSymbolHeaderTitle(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, locale: String): Unit {
    w.open("div", attrs: [htmlClass("cj-page-header__title-row")])
    w.open("h1", attrs: [htmlClass("cj-page-header__title"),
        htmlAttr("data-cjdoc-toc-role", "api-root"),
        htmlAttr("data-cjdoc-toc-label", htmlTocLabel(symbol))])
    w.textElement("code", readerSymbolTitle(symbol, locale))
    w.close("h1")
    w.textElement("span", htmlKindLabel(symbol.kind, locale),
        attrs: [htmlClass("cj-kind"), htmlAttr("data-kind", symbol.kind)])
    w.element("div", [htmlClass("cj-page-header__badges")], { badges =>
        appendDeclarationClassificationBadges(badges, projection.catalog, projection.snapshotId,
            symbol, "../")
    })
    w.open("button", attrs: [htmlClass("cj-button cj-button--quiet cj-page-header__copy"),
        htmlAttr("type", "button"),
        htmlAttr("data-cjdoc-copy-link", "../" + symbolReadablePagePath(symbol))])
    w.icon("link")
    w.textElement("span", label(locale, "Copy link", "复制链接"))
    w.close("button")
    w.close("div")
    match (symbol.documentation) {
        case Some(comment) => appendSummaryHtml(w, comment, symbol, assetLookup, "../", locale: locale)
        case None => ()
    }
}

// Localized summaries may span paragraphs. The selected description tag
// determines whether an Overview is rendered for localized comments.
private func symbolHasIntroduction(symbol: SymbolDoc): Bool {
    match (symbol.documentation) {
        case Some(comment) =>
            if (comment.localizationScope != "admonitions" && !comment.localizedTexts.isEmpty()) {
                return findTag(comment, "description").isSome()
            }
            let summaryIndex = topLevelParagraphIndex(comment)
            comment.markdown.kind != "paragraph" &&
                !comment.markdown.children.isEmpty() &&
                !(comment.markdown.children.size == 1 && summaryIndex == 0)
        case None => false
    }
}

private func appendSymbolOverview(w: HtmlWriter, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, locale: String): Unit {
    let hasIntroduction = symbolHasIntroduction(symbol)
    if (hasIntroduction) {
        w.open("div", attrs: [htmlAttr("id", "overview"),
            htmlClass("cj-introduction cj-prose")])
    }
    appendDocumentationIntroductionHtml(w, symbol, "../", assetLookup, 4, locale)
    if (hasIntroduction) { w.close("div") }
    match (symbol.documentation) {
        case Some(comment) =>
            appendDocumentationContractsHtml(w, comment, locale, symbolAnchor(symbol))
        case None => ()
    }
}

private func appendSymbolSourceAction(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, locale: String): Unit {
    match (projection.sourceReferences.project(symbol.moduleId, symbol.source).url) {
        case Some(url) =>
            match (SafeUrl.external(url)) {
                case Some(external) =>
                    w.element("p", [htmlClass("cj-page-header__source")], { action =>
                        action.open("a", attrs: [htmlClass("cj-button cj-button--quiet"),
                            htmlHref(external), htmlAttr("rel", "noreferrer")])
                        action.icon("source")
                        action.textElement("span", label(locale, "View source", "查看源码"))
                        action.close("a")
                    })
                    w.newline()
                case None => ()
            }
        case None => ()
    }
}

private func appendSymbolTypeRelationships(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    // Relations explain the type before readers browse its members.
    appendReaderRelationships(w, index, symbol, "../", typeLinkIndex, locale)
}

private func appendKindAliasesForRole(w: HtmlWriter, sections: HtmlMemberSections,
    role: DeclarationGroup, kindIdsByGroup: HashMap<String, HashSet<String>>,
    kindAliases: HashSet<String>): Unit {
    let kinds = sections.kinds(role)
    if (kinds.isEmpty()) { return }
    if (!role.isPrimary && !role.id.isEmpty()) { return }
    let ownKindIds = HashSet<String>()
    for (title in kinds) { let _ = ownKindIds.add(memberSectionAnchor(title)) }
    match (kindIdsByGroup.get(role.id)) {
        case Some(values) =>
            for (title in MEMBER_SECTION_TITLES) {
                let kindId = memberSectionAnchor(title)
                if (!values.contains(kindId)) { continue }
                if (role.isPrimary && !ownKindIds.contains(kindId)) {
                    appendAnchorAlias(w, role.kindPrefix + kindId)
                }
                if (kindAliases.add(kindId)) { appendAnchorAlias(w, kindId) }
            }
        case None => ()
    }
}

private func appendSymbolKindAliases(w: HtmlWriter, sections: HtmlMemberSections,
    roles: ArrayList<DeclarationGroup>, kindIdsByGroup: HashMap<String, HashSet<String>>,
    grouped: Bool): Unit {
    if (!grouped) { return }
    let kindAliases = HashSet<String>()
    for (role in roles) {
        appendKindAliasesForRole(w, sections, role, kindIdsByGroup, kindAliases)
    }
}

private func appendAnchorAlias(w: HtmlWriter, id: String): Unit {
    w.open("span", attrs: [htmlClass("cj-anchor-alias"), htmlAttr("id", id),
        htmlAttr("aria-hidden", "true")])
    w.close("span")
}

private func appendGroupHeading(w: HtmlWriter, role: DeclarationGroup, locale: String): Unit {
    w.open("h2", attrs: [htmlAttr("id", role.anchor), htmlClass("cj-api-group__title")])
    w.text(declarationGroupDisplayTitle(role, locale))
    w.textElement("span", label(locale, " (${role.symbols.size})", "（${role.symbols.size}）"),
        attrs: [htmlFlag("data-cjdoc-group-count"),
            htmlAttr("data-group-total", role.symbols.size.toString())])
    w.close("h2")
}

internal func appendMemberBrowser(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    let browser = projection.members(symbol)
    if (browser.entries.isEmpty()) { return }
    w.open("section", attrs: [htmlClass("cj-members"), htmlFlag("data-cjdoc-member-browser"),
        htmlAttr("aria-label", label(locale, "Members", "成员"))])
    appendMemberBrowserToolbar(w, browser, locale)
    let sections = HtmlMemberSections(browser.entries, projection.catalog)
    let roles = sections.roles
    let grouped = hasGroupedDeclarations(roles)
    if (grouped) {
        prepareDeclarationGroupAnchors(roles, symbol.moduleId, symbol.packageName, Some(symbol.id))
    }
    let kindIdsByGroup = HashMap<String, HashSet<String>>()
    for (role in roles) {
        for (title in sections.kinds(role)) {
            let kindId = memberSectionAnchor(title)
            match (kindIdsByGroup.get(role.id)) {
                case Some(values) => let _ = values.add(kindId)
                case None =>
                    let values = HashSet<String>()
                    let _ = values.add(kindId)
                    kindIdsByGroup[role.id] = values
            }
        }
    }
    appendSymbolMemberRoles(w, documentation, projection, index, sections, roles, grouped,
        kindIdsByGroup, assetLookup, typeLinkIndex, locale)
    w.close("section")
    w.newline()
}

private func appendSymbolMemberRoles(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>,
    sections: HtmlMemberSections, roles: ArrayList<DeclarationGroup>, grouped: Bool,
    kindIdsByGroup: HashMap<String, HashSet<String>>,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale: String): Unit {
    appendSymbolKindAliases(w, sections, roles, kindIdsByGroup, grouped)
    for (role in roles) {
        let kinds = sections.kinds(role)
        if (kinds.isEmpty()) { continue }
        if (grouped) {
            w.open("section", attrs: [htmlClass("cj-api-group"),
                htmlAttr("data-cjdoc-declaration-group", role.id)])
            appendGroupHeading(w, role, locale)
        }
        let layout = if (grouped) { declarationGroupLayout(kinds.size, 2) }
            else { DeclarationGroupLayout(true, 2, 2) }
        for (title in kinds) {
            let kindId = memberSectionAnchor(title)
            let kindAnchor = if (grouped) { role.kindPrefix + kindId } else { kindId }
            appendMemberSection(w, documentation, projection, index,
                sections.entries(role, title), title, assetLookup, typeLinkIndex,
                locale, layout, kindAnchor)
        }
        if (grouped) {
            w.close("section")
            w.newline()
        }
    }
}

private func appendSymbolMemberArea(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    hasMemberPage: Bool, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    if (!hasMemberPage) { return }
    appendReaderRelationships(w, index, symbol, "../", typeLinkIndex, locale)
    if (!projection.members(symbol).entries.isEmpty()) {
        appendMemberBrowser(w, documentation, projection, index, symbol, assetLookup,
            typeLinkIndex, locale)
    } else if (symbol.kind == "extend") {
        w.textElement("p", label(locale, "No visible members for this audience.",
            "当前受众范围内没有可展示的成员。"), attrs: [htmlClass("cj-empty")])
        w.newline()
    }
}

private func appendSymbolPageBody(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    hasMemberPage: Bool, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    appendDocumentationHtml(w, index, symbol, "../", assetLookup,
        typeLinkIndex, headingBase: 4, locale: locale, includeContracts: !hasMemberPage,
        includeIntroduction: !hasMemberPage)
    if (!hasMemberPage) {
        appendSymbolTypeRelationships(w, index, symbol, typeLinkIndex, locale)
    }
    appendReverseTypeUsages(w, index, typeLinkIndex, symbol, "../", locale)
    projection.apiGuides(documentation, locale).append(w, symbol, locale)
    let related = HashSet<String>()
    if (hasMemberPage) {
        for (entry in projection.members(symbol).entries) { let _ = related.add(entry.symbol.id) }
    }
    appendExternalDocumentationHtml(w, documentation, symbol, locale, relatedSymbolIds: related)
}

internal func renderSymbolPage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", docVersion!: ?String = None): String {
    let w = HtmlWriter()
    let pageTitle = if (symbol.kind == "extend") {
        "${label(locale, "Extension", "扩展")} ${readerQualifiedName(symbol)}"
    } else { symbol.qualifiedName }
    let hasMemberPage = isTypeDeclaration(symbol) || symbol.kind == "extend"
    let owners = visibleOwnerChain(index, symbol)
    appendPageStart(w, pageTitle, "../", documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(symbol.moduleId, symbol.packageName)),
        currentRoute: "api", docVersion: docVersion, currentSymbol: Some(symbol),
        currentPagePath: Some(symbolPagePath(symbol)),
        agentReadable: true, alternateMarkdown: Some(agentDeclarationMarkdownPath(symbol)))
    appendSymbolBreadcrumbs(w, index, symbol, owners, locale)
    w.open("header", attrs: [htmlClass(if (symbol.kind == "extend") {
        "cj-page-header cj-page-header--api cj-page-header--extension"
    } else { "cj-page-header cj-page-header--api" })])
    appendSymbolHeaderTitle(w, projection, symbol, assetLookup, locale)
    if (hasMemberPage) {
        appendSymbolOverview(w, symbol, assetLookup, locale)
    }
    appendSymbolMetadata(w, index, symbol, "../", assetLookup, typeLinkIndex,
        locale: locale, includeSummary: false, pagePresentation: true)
    appendSymbolSourceAction(w, projection, symbol, locale)
    appendTypeGuideEntry(w, documentation, projection, symbol, locale)
    w.close("header")
    w.newline()
    appendOwnerDocumentationContext(w, index, symbol, owners, assetLookup, "../", locale)
    appendSymbolMemberArea(w, documentation, projection, index, symbol,
        hasMemberPage, assetLookup, typeLinkIndex, locale)
    appendSymbolPageBody(w, documentation, projection, index, symbol,
        hasMemberPage, assetLookup, typeLinkIndex, locale)
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}
