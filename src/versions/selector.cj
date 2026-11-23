protected package cjdoc.versions

import cjdoc.render as public_render
import std.collection.*
import std.sort.*

private class VersionTextBuffer {
    let storage = StringBuilder()
    let limit: Int64
    var written: Int64 = 0

    init(limit: Int64) {
        if (limit < 0) { throw IllegalArgumentException("invalid version selector limit") }
        this.limit = limit
    }

    func append(value: String): Unit {
        if (value.size > limit - written) {
            throw IllegalArgumentException("version selector exceeds composition memory budget")
        }
        storage.append(value)
        written += value.size
    }

    func toString(): String { storage.toString() }
}

internal func versionSymbolTarget(current: VersionSite, id: String,
    target: VersionSite): VersionNavigationTarget {
    let identity = VersionLogicalIdentity(current.defaultLanguage, symbolId: Some(id))
    if (target.hasPath("site-manifest.json") || target.logicalRoutes.contains(identity.key()) ||
        target.logicalRoutes.contains(identity.withLanguage(target.defaultLanguage).key())) {
        return versionLanguageTarget(current, identity, target)
    }
    match (target.symbols.hrefById.get(id)) {
        case Some(href) => VersionNavigationTarget(href, VersionNavigationState.Exact)
        case None =>
            match (current.symbols.ownerById.get(id)) {
                case Some(owner) => match (target.symbols.hrefById.get(owner)) {
                    case Some(href) => return VersionNavigationTarget(href, VersionNavigationState.MissingSymbol)
                    case None => ()
                }
                case None => ()
            }
            VersionNavigationTarget("index.html", VersionNavigationState.MissingSymbol)
    }
}

internal func versionTargetRoute(current: VersionSite, relative: String,
    target: VersionSite): VersionNavigationTarget {
    if (let Some(identity) <- current.logicalIdentityByHref.get(relative)) {
        return versionLanguageTarget(current, identity, target)
    }
    match (current.symbols.idByHref.get(relative)) {
        case Some(id) => versionSymbolTarget(current, id, target)
        case None => if (target.hasPath(relative)) {
            VersionNavigationTarget(relative, VersionNavigationState.Exact)
        } else {
            VersionNavigationTarget("index.html", VersionNavigationState.MissingPage)
        }
    }
}

internal func versionSelector(current: VersionSite, currentOutputPath: String,
    relative: String, sites: ArrayList<VersionSite>, limit!: Int64 = VERSION_FILE_MAX_BYTES,
    chinese!: Bool = false): String {
    let out = VersionTextBuffer(limit)
    let versionLabel = if (chinese) { "文档版本" } else { "Documentation version" }
    out.append("<nav class=\"cj-version-select\" aria-label=\"${versionLabel}\"><span class=\"cj-version-select__label\">${versionLabel}</span>")
    for (target in sites) {
        let route = versionTargetRoute(current, relative, target)
        let href = versionRelativeHref(currentOutputPath, versionOutputPath(target, route.href))
        let state = versionNavigationStateName(route.state)
        let suffix = if (target.spec.id != current.spec.id) {
            versionNavigationMessage(route.state, chinese)
        } else {
            ""
        }
        let currentClass = if (target.spec.id == current.spec.id) { " aria-current=\"page\"" } else { "" }
        var routes = VersionTextBuffer(limit)
        routes.append("{")
        let apiAnchors = ArrayList<String>()
        var first = true
        match (current.symbols.idByHref.get(relative)) {
            case Some(ownerId) => match (current.symbols.membersByOwner.get(ownerId)) {
                case Some(ids) => for (id in ids) {
                    let memberRoute = versionSymbolTarget(current, id, target)
                    let memberHref = versionRelativeHref(currentOutputPath,
                        versionOutputPath(target, memberRoute.href))
                    if (!first) { routes.append(",") }; first = false
                    let anchor = versionSymbolAnchor(id)
                    routes.append("${versionJsonEscape(anchor)}:[${versionJsonEscape(memberHref)},${versionJsonEscape(versionNavigationStateName(memberRoute.state))}]")
                    if (target.hasApiDirectory(memberRoute.href)) { apiAnchors.add(anchor) }
                }
                case None => ()
            }
            case None => ()
        }
        routes.append("}")
        if (let Some(sections) <- current.sectionIdsByPage.get(relative)) {
            routes = VersionTextBuffer(limit)
            routes.append("{")
            apiAnchors.clear()
            var firstSection = true
            let anchors = ArrayList<String>()
            for ((anchor, _) in sections) { anchors.add(anchor) }
            sort(anchors, lessThan: { left, right => left < right }, stable: true)
            for (anchor in anchors) {
                let identity = sections[anchor]
                let sectionRoute = versionLanguageTarget(current, identity, target)
                if (target.hasApiDirectory(sectionRoute.href)) { apiAnchors.add(anchor) }
                if (!firstSection) { routes.append(",") }; firstSection = false
                routes.append("${versionJsonEscape(anchor)}:[${versionJsonEscape(versionRelativeHref(currentOutputPath, versionOutputPath(target, sectionRoute.href)))},${versionJsonEscape(versionNavigationStateName(sectionRoute.state))}]")
            }
            routes.append("}")
        }
        let apiBase = if (target.hasApiDirectory(route.href)) { " data-cjdoc-version-api-link" } else { "" }
        let apiSections = if (apiAnchors.isEmpty()) { "" } else {
            let encoded = VersionTextBuffer(limit)
            encoded.append("[")
            for (index in 0..apiAnchors.size) {
                if (index > 0) { encoded.append(",") }
                encoded.append(versionJsonEscape(apiAnchors[index]))
            }
            encoded.append("]")
            " data-cjdoc-version-api-anchors=\"" + public_render.escapeStandaloneHtml(encoded.toString()) + "\""
        }
        out.append("<a class=\"cj-version-select__option\" href=\"${public_render.escapeStandaloneHtml(href)}\"${currentClass}${apiBase}${apiSections} data-cjdoc-version-link data-cjdoc-version-label=\"${public_render.escapeStandaloneHtml(target.spec.label)}\" data-cjdoc-version-state=\"${state}\" data-cjdoc-version-routes=\"${public_render.escapeStandaloneHtml(routes.toString())}\">${public_render.escapeStandaloneHtml(target.spec.label + suffix)}</a>")
        match (target.spec.apiDiffSource) {
            case Some(_) =>
                let diffPath = versionOutputPath(target, "api-diff.json")
                let diffHref = versionRelativeHref(currentOutputPath, diffPath)
                let changesLabel = if (chinese) { "版本变化" } else { "Changes" }
                out.append(" <a class=\"cj-version-select__changes\" href=\"${public_render.escapeStandaloneHtml(diffHref)}\">${changesLabel}</a>")
            case None => ()
        }
    }
    out.append("</nav>\n")
    out.append("<script src=\"${public_render.escapeStandaloneHtml(versionRelativeHref(currentOutputPath, "version-navigation.js"))}\" defer></script>\n")
    out.toString()
}
private func versionNavigationStateName(state: VersionNavigationState): String {
    match (state) {
        case VersionNavigationState.Exact => "exact"
        case VersionNavigationState.MissingSymbol => "missing-symbol"
        case VersionNavigationState.MissingLanguage => "missing-language"
        case VersionNavigationState.MissingSection => "missing-section"
        case VersionNavigationState.MissingPage => "missing-page"
    }
}

internal func versionNavigationMessage(state: VersionNavigationState, chinese: Bool): String {
    match (state) {
        case VersionNavigationState.Exact => ""
        case VersionNavigationState.MissingSymbol =>
            if (chinese) { "（此版本没有该符号）" } else { " (symbol unavailable in this version)" }
        case VersionNavigationState.MissingLanguage =>
            if (chinese) { "（此版本无该语言 · 打开默认语言）" } else { " (language unavailable · open the default language)" }
        case VersionNavigationState.MissingSection =>
            if (chinese) { "（无对应章节或阅读位置 · 打开可用位置）" } else { " (section or reading position unavailable · open the available position)" }
        case VersionNavigationState.MissingPage =>
            if (chinese) { "（此版本无对应页面 · 前往版本首页）" } else { " (page unavailable in this version · go to version home)" }
    }
}

internal func versionNavigationMessages(chinese: Bool): String {
    let exact = versionJsonEscape(versionNavigationMessage(VersionNavigationState.Exact, chinese))
    let symbol = versionJsonEscape(versionNavigationMessage(VersionNavigationState.MissingSymbol, chinese))
    let language = versionJsonEscape(versionNavigationMessage(VersionNavigationState.MissingLanguage, chinese))
    let section = versionJsonEscape(versionNavigationMessage(VersionNavigationState.MissingSection, chinese))
    let page = versionJsonEscape(versionNavigationMessage(VersionNavigationState.MissingPage, chinese))
    "{\"exact\":${exact},\"missing-symbol\":${symbol},\"missing-language\":${language},\"missing-section\":${section},\"missing-page\":${page}}"
}
