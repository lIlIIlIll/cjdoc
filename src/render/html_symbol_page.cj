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
    let destination = projection.publicSymbolHref(rootPrefix, member.id)
    appendMemberStandaloneAction(w, destination, standaloneLabel, actionId, summaryId)
    appendMemberSourceAction(w, projection, member, sourceLabel, actionId, summaryId)
    appendMemberCopyAction(w, destination, copyLabel, actionId, summaryId)
    w.textElement("span", "", attrs: [htmlClass("cj-sr-only"),
        htmlFlag("data-cjdoc-copy-status"), htmlAttr("role", "status"),
        htmlAttr("aria-live", "polite")])
    w.close("div")
    w.close("div")
}

private func memberActionAttrs(cssClass: String, actionLabel: String,
    actionId: String, suffix: String, summaryId: String): Array<HtmlAttr> {
    let labelId = actionId + "-" + suffix + "-label"
    // A self-reference contributes aria-label before the full summary name.
    return [htmlClass("cj-member-actions__item " + cssClass), htmlAttr("id", labelId),
        htmlAttr("aria-label", actionLabel), htmlAttr("title", actionLabel),
        htmlAttr("aria-labelledby", labelId + " " + summaryId)]
}

private func appendMemberStandaloneAction(w: HtmlWriter, destination: String,
    actionLabel: String, actionId: String, summaryId: String): Unit {
    let attrs = ArrayList<HtmlAttr>(memberActionAttrs(
        "cj-member-actions__item--standalone", actionLabel, actionId, "standalone", summaryId))
    attrs.add(htmlHref(SafeUrl.siteRoute(destination)))
    w.open("a", attrs: attrs.toArray())
    w.icon("standalone")
    w.text(actionLabel)
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
                    w.text(actionLabel)
                    w.close("a")
                case None => ()
            }
        case None => ()
    }
}

private func appendMemberCopyAction(w: HtmlWriter, destination: String,
    actionLabel: String, actionId: String, summaryId: String): Unit {
    let attrs = ArrayList<HtmlAttr>(memberActionAttrs(
        "cj-member-actions__item--copy", actionLabel, actionId, "copy", summaryId))
    attrs.add(htmlAttr("type", "button"))
    attrs.add(htmlAttr("data-cjdoc-copy-link", destination))
    w.open("button", attrs: attrs.toArray())
    w.icon("copy")
    w.text(actionLabel)
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
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String, deprecated: Bool): Unit {
    if (deprecated) { w.open("span", attrs: [htmlClass("cj-member__signature cj-member__signature--deprecated")]) }
    appendInlineMemberSignature(w, member, typeLinkIndex, rootPrefix)
    if (deprecated) {
        w.text(" ")
        appendDeprecationBadge(w, locale)
        w.close("span")
    }
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

private func appendMemberOriginContext(w: HtmlWriter, projection: RenderProjection, entry: HtmlMemberEntry,
    rootPrefix: String, locale: String): Unit {
    if (entry.origin == "declared") { return }
    match (entry.declaredBy) {
        case Some(declaredBy) =>
            w.open("p", attrs: [htmlClass("cj-member__origin")])
            w.text(memberOriginLabel(entry.origin, locale) + " · ")
            w.open("a", attrs: [htmlHref(SafeUrl.siteRoute(projection.publicSymbolHref(rootPrefix, declaredBy.id)))])
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
    let deprecations = projection.deprecations()
    let deprecated = deprecations.contains(member.id)
    let replacement = deprecations.action(member.id)
    w.open("div", attrs: [htmlClass(if (replacement.isSome()) {
        "cj-member-row cj-member-row--replacement"
    } else { "cj-member-row" })])
    w.open("details", attrs: [htmlClass("cj-member"), htmlAttr("id", anchor),
        htmlFlag("data-cjdoc-member"), htmlAttr("data-member-name", member.name),
        htmlAttr("data-member-kind", member.kind),
        htmlAttr("data-member-origin", entry.origin),
        htmlAttr("data-member-symbol-id", member.id)])
    w.open("summary", attrs: [htmlClass("cj-member__summary"),
        htmlAttr("id", anchor + "-summary"), htmlAttr("data-cjdoc-toc-role", "member"),
        htmlAttr("data-cjdoc-toc-depth", sectionHeadingLevel.toString()),
        htmlAttr("data-cjdoc-toc-label", htmlContextLabel(member))])
    appendMemberSummary(w, member, entry.origin, typeLinkIndex, rootPrefix, locale, deprecated)
    w.close("summary")
    w.open("div", attrs: [htmlClass("cj-member__body")])
    if (deprecated) {
        appendApiDeprecationNote(w, projection, member, deprecationExplanation(member, locale),
            rootPrefix, locale, assetLookup)
    }
    appendMemberOriginContext(w, projection, entry, rootPrefix, locale)
    appendDocumentationHtml(w, index, member, rootPrefix, assetLookup, typeLinkIndex,
        headingBase: sectionHeadingLevel, locale: locale, sectionHeadingLevel: sectionHeadingLevel)
    let headingTag = "h${min(6, sectionHeadingLevel)}"
    appendReaderRelationships(w, index, member, rootPrefix, typeLinkIndex, locale,
        headingTag: headingTag)
    appendReverseTypeUsages(w, typeLinkIndex, member, rootPrefix, locale)
    projection.apiGuides(documentation, locale).append(w, member, locale, rootPrefix,
        headingTag: headingTag, headingSuffix: "-inline-" + htmlStableSlug(member.id))
    appendExternalDocumentationHtml(w, documentation, member, rootPrefix, locale, compactUnavailable: true,
        headingLevel: sectionHeadingLevel)
    w.close("div")
    w.close("details")
    if (let Some(action) <- replacement) { appendReplacementLink(w, action, projection, rootPrefix, locale) }
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

private func overloadCountsOf(entries: ArrayList<HtmlMemberEntry>, deprecations: DeprecationProjection):
    (HashMap<String, (Int64, Int64)>, Bool) {
    let overloadCounts = HashMap<String, (Int64, Int64)>()
    var hasOverloads = false
    for (entry in entries) {
        let key = "${entry.groupKey}:${entry.symbol.name}"
        let (total, deprecated) = overloadCounts.get(key).getOrDefault({ => (0i64, 0i64) })
        let step: Int64 = if (deprecations.contains(entry.symbol.id)) { 1 } else { 0 }
        overloadCounts[key] = (total + 1, deprecated + step)
        if (total == 1) { hasOverloads = true }
    }
    (overloadCounts, hasOverloads)
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
    headingLevel: Int64, locale: String, deprecatedCount: Int64): Unit {
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
    if (deprecatedCount > 0) { appendDeprecationBadge(w, locale, partial: deprecatedCount < count) }
    w.close(heading)
    w.newline()
}

private let LARGE_MEMBER_BROWSER_ROWS = 256
private let MEMBER_SLICE_ROWS = 12

internal func appendMemberSection(w: HtmlWriter,
    documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, entries: ArrayList<HtmlMemberEntry>,
    title: String, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    layout: DeclarationGroupLayout, kindAnchor: String, rootPrefix: String): Unit {
    if (entries.isEmpty()) { return }
    let (overloadCounts, hasOverloads) = overloadCountsOf(entries, projection.deprecations())
    let overloadHeadingLevel = min(6, layout.entryParentLevel + 1)
    let sliced = entries.size > LARGE_MEMBER_BROWSER_ROWS && !hasOverloads
    w.open("section", attrs: [htmlClass(if (layout.showKindHeading) {
        "cj-member-group"
    } else { "cj-member-group cj-member-group--plain" }), htmlFlag("data-cjdoc-member-group")])
    appendMemberGroupHead(w, title, kindAnchor, entries.size, layout, locale)
    var activeOverloadKey = ""
    var remainingInSlice: Int64 = 0
    for (i in 0..entries.size) {
        if (sliced && remainingInSlice == 0 && entries.size - i >= MEMBER_SLICE_ROWS) {
            w.open("div", attrs: [htmlClass("cj-member-slice")])
            remainingInSlice = MEMBER_SLICE_ROWS
        }
        activeOverloadKey = appendMemberEntry(w, documentation, projection, index, entries[i],
            assetLookup, typeLinkIndex, overloadCounts, overloadHeadingLevel, layout, locale,
            activeOverloadKey, rootPrefix)
        if (remainingInSlice > 0) {
            remainingInSlice--
            if (remainingInSlice == 0) { w.close("div"); w.newline() }
        }
    }
    if (!activeOverloadKey.isEmpty()) {
        w.close("div")
        w.newline()
    }
    w.close("section")
    w.newline()
}

// Returns the overload family that is still open, so the caller can close it
// before starting a different family.
private func appendMemberEntry(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>, entry: HtmlMemberEntry,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    overloadCounts: HashMap<String, (Int64, Int64)>, overloadHeadingLevel: Int64,
    layout: DeclarationGroupLayout, locale: String, activeOverloadKey: String, rootPrefix: String): String {
    let member = entry.symbol
    var active = activeOverloadKey
    let overloadKey = "${entry.groupKey}:${member.name}"
    let (count, deprecatedCount) = overloadCounts[overloadKey]
    if (!active.isEmpty() && active != overloadKey) {
        w.close("div")
        w.newline()
        active = ""
    }
    if (count > 1 && active.isEmpty()) {
        appendOverloadHeading(w, member, count, overloadHeadingLevel, locale, deprecatedCount)
        active = overloadKey
    }
    let parentLevel = if (count > 1) { overloadHeadingLevel } else { layout.entryParentLevel }
    appendInlineMemberDetail(w, documentation, projection, index, entry, assetLookup,
        typeLinkIndex, rootPrefix, locale, sectionHeadingLevel: min(6, parentLevel + 1))
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

private func appendSymbolBreadcrumbs(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, owners: ArrayList<SymbolDoc>, rootPrefix: String, locale: String): Unit {
    w.open("nav", attrs: [htmlClass("cj-breadcrumbs"),
        htmlAttr("aria-label", label(locale, "Breadcrumb", "面包屑导航"))])
    w.open("ol", attrs: [htmlClass("cj-breadcrumbs__list")])
    w.element("li", [htmlClass("cj-breadcrumbs__item")], { item =>
        item.open("a", attrs: [htmlHref(SafeUrl.siteRoute(rootPrefix + "index.html"))])
        item.text(label(locale, "Home", "首页"))
        item.close("a")
    })
    w.element("li", [htmlClass("cj-breadcrumbs__item")], { item =>
        item.open("a", attrs: [htmlHref(SafeUrl.siteRoute(
            rootPrefix + packagePagePath(symbol.moduleId, symbol.packageName)))])
        item.text(label(locale, "Package", "包") + " ")
        item.textElement("code", symbol.packageName)
        item.close("a")
    })
    appendOwnerBreadcrumbs(w, projection, owners, rootPrefix, locale)
    w.element("li", [htmlClass("cj-breadcrumbs__item"), htmlAttr("aria-current", "page")],
        { item =>
        item.textElement("code", readerSymbolTitle(symbol, locale))
    })
    w.close("ol")
    w.close("nav")
    w.newline()
}

private func appendSymbolHeaderTitle(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, rootPrefix: String, locale: String,
    statusOnly: Bool): Unit {
    w.open("div", attrs: [htmlClass("cj-page-header__title-row")])
    w.open("h1", attrs: [htmlClass("cj-page-header__title"),
        htmlAttr("data-cjdoc-toc-role", "api-root"),
        htmlAttr("data-cjdoc-toc-label", htmlTocLabel(symbol))])
    w.textElement("code", readerSymbolTitle(symbol, locale))
    w.close("h1")
    if (statusOnly) { appendDeprecationBadge(w, locale) }
    w.textElement("span", htmlKindLabel(symbol.kind, locale),
        attrs: [htmlClass("cj-kind"), htmlAttr("data-kind", symbol.kind)])
    w.element("div", [htmlClass("cj-page-header__badges")], { badges =>
        appendDeclarationClassificationBadges(badges, projection.catalog, projection.snapshotId,
            symbol, rootPrefix)
    })
    w.open("div", attrs: [htmlClass("cj-page-header__actions")])
    appendSymbolSourceAction(w, projection, symbol, locale)
    w.open("button", attrs: [htmlClass("cj-button cj-button--quiet cj-page-header__copy"),
        htmlAttr("type", "button"),
        htmlAttr("data-cjdoc-copy-link", projection.publicSymbolHref(rootPrefix, symbol.id))])
    w.icon("link")
    w.textElement("span", label(locale, "Copy link", "复制链接"))
    w.close("button")
    w.close("div")
    w.close("div")
    match (symbol.documentation) {
        case Some(comment) => appendSummaryHtml(w, comment, symbol, assetLookup, rootPrefix, locale: locale)
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
    assetLookup: HashMap<String, String>, rootPrefix: String, locale: String): Unit {
    let hasIntroduction = symbolHasIntroduction(symbol)
    if (hasIntroduction) {
        w.open("div", attrs: [htmlAttr("id", "overview"),
            htmlClass("cj-introduction cj-prose")])
    }
    appendDocumentationIntroductionHtml(w, symbol, rootPrefix, assetLookup, 4, locale)
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
                    w.open("a", attrs: [htmlClass("cj-button cj-button--quiet cj-page-header__source"),
                        htmlHref(external), htmlAttr("rel", "noreferrer")])
                    w.icon("source")
                    w.textElement("span", label(locale, "View source", "查看源码"))
                    w.close("a")
                case None => ()
            }
        case None => ()
    }
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
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String): Unit {
    let browser = projection.members(symbol)
    if (browser.entries.isEmpty()) { return }
    // The stylesheet needs this boundary before any script can force the first layout.
    let browserClass = if (browser.entries.size > LARGE_MEMBER_BROWSER_ROWS) {
        "cj-members cj-members--large"
    } else { "cj-members" }
    w.open("section", attrs: [htmlClass(browserClass), htmlFlag("data-cjdoc-member-browser"),
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
        kindIdsByGroup, assetLookup, typeLinkIndex, rootPrefix, locale)
    w.close("section")
    w.newline()
}

private func appendSymbolMemberRoles(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>,
    sections: HtmlMemberSections, roles: ArrayList<DeclarationGroup>, grouped: Bool,
    kindIdsByGroup: HashMap<String, HashSet<String>>,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    rootPrefix: String, locale: String): Unit {
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
                locale, layout, kindAnchor, rootPrefix)
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
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String): Unit {
    if (!hasMemberPage) { return }
    appendReaderRelationships(w, index, symbol, rootPrefix, typeLinkIndex, locale)
    if (!projection.members(symbol).entries.isEmpty()) {
        appendMemberBrowser(w, documentation, projection, index, symbol, assetLookup,
            typeLinkIndex, rootPrefix, locale)
    } else if (symbol.kind == "extend") {
        w.textElement("p", label(locale, "No visible members for this audience.",
            "当前受众范围内没有可展示的成员。"), attrs: [htmlClass("cj-empty")])
        w.newline()
    }
}

private func appendSymbolPageBody(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    hasMemberPage: Bool, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String): Unit {
    appendDocumentationHtml(w, index, symbol, rootPrefix, assetLookup,
        typeLinkIndex, headingBase: 4, locale: locale, includeContracts: !hasMemberPage,
        includeIntroduction: !hasMemberPage)
    if (!hasMemberPage) {
        appendReaderRelationships(w, index, symbol, rootPrefix, typeLinkIndex, locale)
    }
    appendReverseTypeUsages(w, typeLinkIndex, symbol, rootPrefix, locale)
    projection.apiGuides(documentation, locale).append(w, symbol, locale, rootPrefix)
    let related = HashSet<String>()
    if (hasMemberPage) {
        for (entry in projection.members(symbol).entries) { let _ = related.add(entry.symbol.id) }
    }
    appendExternalDocumentationHtml(w, documentation, symbol, rootPrefix, locale, relatedSymbolIds: related)
}

internal func renderSymbolPage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", docVersion!: ?String = None, mounted!: Bool = false): String {
    let routes = projection.apiRoutes.getOrThrow()
    let pageFile = routes.filePath(symbol.id).getOrThrow()
    let rootPrefix = projection.apiPageResourcePrefix(pageFile, mounted)
    let w = HtmlWriter(apiRoutes: projection.apiRoutes, unprefixedApiLocale: projection.unprefixedApiLocale)
    let pageTitle = if (symbol.kind == "extend") {
        "${label(locale, "Extension", "扩展")} ${readerQualifiedName(symbol)}"
    } else { symbol.qualifiedName }
    let hasMemberPage = isTypeDeclaration(symbol) || symbol.kind == "extend"
    let owners = visibleOwnerChain(index, symbol)
    appendPageStart(w, pageTitle, rootPrefix, documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(symbol.moduleId, symbol.packageName)),
        currentRoute: "api", docVersion: docVersion, currentSymbol: Some(symbol),
        currentPagePath: Some(apiHtmlFileHref(pageFile)),
        agentReadable: true, alternateMarkdown: Some(agentDeclarationMarkdownPath(symbol)),
        canonical: Some(projection.publicApiPrefix(rootPrefix) + routes.webPath(symbol.id)))
    appendSymbolBreadcrumbs(w, projection, symbol, owners, rootPrefix, locale)
    w.open("header", attrs: [htmlClass(if (symbol.kind == "extend") {
        "cj-page-header cj-page-header--api cj-page-header--extension"
    } else { "cj-page-header cj-page-header--api" })])
    let deprecations = projection.deprecations()
    let deprecated = deprecations.contains(symbol.id)
    let explanation: ?DocTag = if (deprecated) { deprecationExplanation(symbol, locale) } else { None }
    appendSymbolHeaderTitle(w, projection, symbol, assetLookup, rootPrefix, locale,
        deprecated && explanation.isNone() && deprecations.action(symbol.id).isNone())
    if (hasMemberPage) {
        appendSymbolOverview(w, symbol, assetLookup, rootPrefix, locale)
    }
    appendSymbolMetadata(w, index, symbol, rootPrefix, assetLookup, typeLinkIndex,
        locale: locale, includeSummary: false, pagePresentation: true)
    if (deprecated) {
        appendApiDeprecationNote(w, projection, symbol, explanation, rootPrefix, locale, assetLookup,
            standalone: true)
    }
    appendTypeGuideEntry(w, documentation, projection, symbol, rootPrefix, locale)
    w.close("header")
    w.newline()
    appendOwnerDocumentationContext(w, projection, symbol, owners, assetLookup, rootPrefix, locale)
    appendSymbolMemberArea(w, documentation, projection, index, symbol,
        hasMemberPage, assetLookup, typeLinkIndex, rootPrefix, locale)
    appendSymbolPageBody(w, documentation, projection, index, symbol,
        hasMemberPage, assetLookup, typeLinkIndex, rootPrefix, locale)
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}
