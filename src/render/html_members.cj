package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal class HtmlMemberEntry {
    let symbol: SymbolDoc
    let origin: String
    let declaredBy: ?SymbolDoc
    init(symbol: SymbolDoc, origin: String, declaredBy: ?SymbolDoc) {
        this.symbol = symbol; this.origin = origin; this.declaredBy = declaredBy
    }
    prop groupKey: String { get() {
        let owner = match (declaredBy) { case Some(value) => value.id case None => "" }
        "${origin}:${owner}:${memberSectionTitle(symbol)}"
    } }
}

// Only existing, visible identities contribute members. In particular, a base
// type with a similarly named method is not proof of inheritance or override.
internal class HtmlMemberBrowser {
    let entries = ArrayList<HtmlMemberEntry>()
    private let seen = HashSet<String>()

    init(owner: SymbolDoc, projection: RenderProjection) {
        addOwner(owner, "declared", projection)
        for (relation in owner.symbolRelationships) {
            if (relation.state != "resolved") { continue }
            let id = match (relation.targetSymbolId) { case Some(value) => value case None => continue }
            let target = match (projection.visibleIndex.get(id)) { case Some(value) => value case None => continue }
            if (relation.kind == "extendedBy" && target.kind == "extend") {
                addOwner(target, "extension", projection)
            } else if (relation.kind == "inheritedMember" || relation.kind == "inherits-member") {
                let parent = match (target.ownerId) {
                    case Some(ownerId) => projection.visibleIndex.get(ownerId)
                    case None => None
                }
                add(target, "inherited", parent)
            }
        }
        sort(entries, lessThan: { left, right =>
            let leftKey = "${left.groupKey}:${left.symbol.name}:${left.symbol.headerSpelling}:${left.symbol.id}"
            let rightKey = "${right.groupKey}:${right.symbol.name}:${right.symbol.headerSpelling}:${right.symbol.id}"
            leftKey < rightKey
        }, stable: true)
    }

    private func add(symbol: SymbolDoc, origin: String, owner: ?SymbolDoc): Unit {
        if (seen.add(symbol.id)) { entries.add(HtmlMemberEntry(symbol, origin, owner)) }
    }

    private func addOwner(owner: SymbolDoc, origin: String, projection: RenderProjection): Unit {
        match (projection.membersByOwner.get(owner.id)) {
            case Some(values) => for (symbol in values) { add(symbol, origin, Some(owner)) }
            case None => ()
        }
    }
}

internal func memberOriginLabel(origin: String, locale: String): String {
    match (origin) {
        case "declared" => label(locale, "Declared members", "直接声明的成员")
        case "extension" => label(locale, "Extension declarations", "扩展提供的成员")
        case _ => label(locale, "Inherited members", "继承成员")
    }
}

internal func appendSourceAction(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, symbol: SymbolDoc, locale: String): Unit {
    match (findProjectedModule(projection, symbol.moduleId)) {
        case Some(module) => match (sourceUrl(documentation.project, module, symbol.source)) {
            case Some(url) => out.append("<p class=\"source-action\"><a href=\"" + escapeHtml(url) +
                "\" rel=\"noreferrer\">" + label(locale, "View source", "查看源码") + "</a></p>\n")
            case None => ()
        }
        case None => ()
    }
}

// Used by both the complete standalone page and the type's native details.
// All internal IDs derive from the member identity, not its display name.
internal func appendMemberDetail(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, symbol: SymbolDoc, assetLookup: HashMap<String, String>,
    typeLinks: HtmlTypeLinkIndex, rootPrefix: String, locale: String,
    headingBase!: Int64 = 2, embedded!: Bool = false): Unit {
    out.append("<div class=\"member-detail\" data-cjdoc-detail=\"" + escapeHtml(symbol.id) + "\">")
    if (embedded) {
        out.append("<p class=\"member-actions\"><a class=\"member-permalink\" href=\"" +
            escapeHtml(rootPrefix + symbolPagePath(symbol)) + "\">" +
            label(locale, "Open standalone page / permalink", "打开独立页／永久链接") + "</a></p>")
    }
    appendSymbolMetadata(out, projection.visibleIndex, symbol, rootPrefix, assetLookup,
        typeLinks, locale: locale, headingBase: headingBase)
    appendSourceAction(out, documentation, projection, symbol, locale)
    appendDocumentationHtml(out, projection.visibleIndex, symbol, rootPrefix, assetLookup,
        typeLinks, headingBase: headingBase, locale: locale)
    out.append(htmlRelatedContentMarker(symbol.id, headingLevel: headingBase))
    out.append("</div>\n")
}

internal func appendMemberOrigin(out: RenderTextBuffer, entry: HtmlMemberEntry,
    rootPrefix: String, locale: String): Unit {
    if (entry.origin == "declared") { return }
    match (entry.declaredBy) {
        case Some(owner) =>
            out.append("<p class=\"member-origin\">" + memberOriginLabel(entry.origin, locale) +
                " · <a href=\"" + escapeHtml(rootPrefix + symbolPagePath(owner)) + "\"><code>" +
                escapeHtml(owner.qualifiedName) + "</code></a></p>")
            if (entry.origin == "extension") {
                out.append("<p class=\"extension-conditions\">" +
                    label(locale, "Subject to the extension's declared target and constraints; applicability is not inferred.",
                        "成员受扩展目标与约束限制；此处不推断对具体实例的适用性。") + "</p><pre class=\"extension-signature\"><code>" +
                    escapeHtml(owner.headerSpelling) + "</code></pre>")
            }
        case None => ()
    }
}

internal func appendMemberBrowser(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, owner: SymbolDoc, assetLookup: HashMap<String, String>,
    links: HtmlTypeLinkIndex, locale: String): Unit {
    let browser = projection.members(owner)
    if (browser.entries.isEmpty()) { return }
    out.append("<section class=\"member-browser\" data-cjdoc-member-browser aria-labelledby=\"members-heading\">")
    out.append("<h2 id=\"members-heading\">" + label(locale, "Members", "成员") + "</h2>")
    out.append("<div class=\"member-browser-toolbar\"><label for=\"cjdoc-member-filter\">" +
        label(locale, "Filter members", "筛选成员") + "</label><input id=\"cjdoc-member-filter\" type=\"search\" data-cjdoc-member-filter autocomplete=\"off\">")
    out.append("<label for=\"cjdoc-member-origin\">" + label(locale, "Origin", "来源") +
        "</label><select id=\"cjdoc-member-origin\" data-cjdoc-member-origin><option value=\"\">" +
        label(locale, "All origins", "所有来源") + "</option>")
    for (origin in ["declared", "inherited", "extension"]) {
        out.append("<option value=\"" + origin + "\">" + memberOriginLabel(origin, locale) + "</option>")
    }
    out.append("</select></div><p class=\"member-filter-status\" data-cjdoc-member-filter-status role=\"status\"></p>")
    let overloadCounts = HashMap<String, Int64>()
    for (entry in browser.entries) {
        let key = "${entry.groupKey}:${entry.symbol.name}"
        let count = match (overloadCounts.get(key)) { case Some(value) => value case None => 0 }
        overloadCounts[key] = count + 1
    }
    var group = ""
    var overload = ""
    for (entry in browser.entries) {
        let member = entry.symbol
        if (group != entry.groupKey) {
            if (!overload.isEmpty()) { out.append("</div>"); overload = "" }
            if (!group.isEmpty()) { out.append("</section>") }
            group = entry.groupKey
            out.append("<section class=\"member-group\" data-cjdoc-member-group><h3 class=\"member-group-title\">" +
                memberOriginLabel(entry.origin, locale) + " · " + memberSectionLabel(member, locale) + "</h3>")
            appendMemberOrigin(out, entry, "../", locale)
        }
        let overloadKey = "${entry.groupKey}:${member.name}"
        if (overloadKey != overload) {
            if (!overload.isEmpty()) { out.append("</div>") }
            overload = overloadKey
            out.append("<div class=\"overload-group\" data-cjdoc-overload-group>")
            let count = overloadCounts[overloadKey]
            if (count > 1) {
                out.append("<p class=\"overload-group-label\">" + escapeHtml(member.name) + " · " +
                    count.toString() + " " + label(locale, "overloads", "个重载") + "</p>")
            }
        }
        let signature = if (member.headerSpelling.isEmpty()) { "${member.kind} ${member.name}" }
            else { member.headerSpelling }
        out.append("<details class=\"member-entry\" id=\"" + symbolAnchor(member) +
            "\" data-cjdoc-member data-member-name=\"" + escapeHtml(member.name) +
            "\" data-member-kind=\"" + escapeHtml(member.kind) +
            "\" data-member-origin=\"" + entry.origin + "\">")
        out.append("<summary><span class=\"member-summary\"><code class=\"declaration-signature\">" +
            escapeHtml(signature) + "</code>")
        match (member.documentation) {
            case Some(comment) =>
                let summary = summaryPlainText(comment)
                if (!summary.isEmpty()) { out.append("<span class=\"member-summary-text\">" + escapeHtml(summary) + "</span>") }
            case None => ()
        }
        out.append("</span></summary>")
        appendMemberDetail(out, documentation, projection, member, assetLookup, links, "../", locale,
            headingBase: 4, embedded: true)
        out.append("</details>\n")
    }
    if (!overload.isEmpty()) { out.append("</div>") }
    if (!group.isEmpty()) { out.append("</section>") }
    out.append("</section>\n")
}

internal func memberSectionLabel(symbol: SymbolDoc, locale: String): String {
    let english = memberSectionTitle(symbol)
    if (locale != "zh-CN") { return english }
    match (symbol.kind) {
        case "constructor" => "构造器"
        case "property" => "属性"
        case "variable" => "变量"
        case "function" => "函数"
        case "enumCase" => "枚举项"
        case "class" => "嵌套类"
        case "struct" => "嵌套结构体"
        case "interface" => "嵌套接口"
        case "enum" => "嵌套枚举"
        case "extend" => "嵌套扩展"
        case _ => "其他成员"
    }
}
