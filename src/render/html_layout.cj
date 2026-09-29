package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

internal func appendHtmlSidebar(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, rootPrefix: String, locale: String,
    currentPackagePath!: ?String = None, currentRoute!: String = "overview",
    currentSymbol!: ?SymbolDoc = None): Unit {
    out.append("<aside id=\"cjdoc-sidebar\" class=\"docs-sidebar\" aria-label=\"${label(locale, "Documentation navigation", "文档导航")}\" tabindex=\"-1\">")
    out.append("<button class=\"sidebar-close\" type=\"button\" data-cjdoc-sidebar-close aria-label=\"${label(locale, "Close navigation", "关闭导航")}\">${label(locale, "Close", "关闭")}</button>")
    out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Documentation", "文档")}</p>")
    let overviewClass = if (currentRoute == "overview") { " is-current" } else { "" }
    let overviewCurrent = if (currentRoute == "overview") { " aria-current=\"page\"" } else { "" }
    let apiClass = if (currentRoute == "api") { " is-current" } else { "" }
    let apiCurrent = if (currentRoute == "api") { " aria-current=\"page\"" } else { "" }
    out.append("<a class=\"sidebar-link${overviewClass}\" data-cjdoc-nav-link${overviewCurrent} href=\"${rootPrefix}index.html\">${label(locale, "Overview", "总览")}</a>")
    out.append("<a class=\"sidebar-link${apiClass}\" data-cjdoc-nav-link${apiCurrent} href=\"${rootPrefix}index.html#packages\">${label(locale, "API Reference", "API 参考")}</a></div>")
    appendContextSidebar(out, projection, rootPrefix, locale, currentPackagePath, currentSymbol)
    if (!projection.modules.isEmpty()) {
        out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Package reference", "包参考")}</p>")
        out.append("<label class=\"sidebar-filter-label\"><span class=\"sr-only\">${label(locale, "Filter packages", "筛选包")}</span><input class=\"sidebar-filter\" type=\"search\" placeholder=\"${label(locale, "Filter packages", "筛选包")}\" data-cjdoc-sidebar-filter></label>")
        out.append("<p class=\"sidebar-no-results\" data-cjdoc-sidebar-no-results role=\"status\" hidden>${label(locale, "No matching packages.", "没有匹配的包。")}</p>")
        for (projected in projection.modules) {
            let module = projected.source
            var isCurrentModule = false
            for (candidate in projected.packages) {
                if (currentPackagePath.isSome() && currentPackagePath.getOrThrow() ==
                    packagePagePath(candidate.source.moduleId, candidate.source.name)) { isCurrentModule = true }
            }
            let openAttribute = if (isCurrentModule) { " open" } else { "" }
            out.append("<details class=\"sidebar-group\"${openAttribute}><summary><span>${escapeHtml(module.name)}</span><span class=\"sidebar-count\">${projected.packages.size}</span></summary><div class=\"sidebar-packages\">")
            for (pkg in projected.packages) {
                let packagePath = packagePagePath(pkg.source.moduleId, pkg.source.name)
                let isCurrent = match (currentPackagePath) {
                    case Some(currentPath) => currentPath == packagePath
                    case None => false
                }
                let currentClass = if (isCurrent) { " is-current" } else { "" }
                let currentAttribute = if (isCurrent) { " aria-current=\"page\"" } else { "" }
                out.append("<a class=\"sidebar-package${currentClass}\" data-cjdoc-nav-link${currentAttribute} href=\"${rootPrefix}${escapeHtml(packagePath)}\"><span>${escapeHtml(pkg.source.name)}</span><span class=\"sidebar-package-count\">${pkg.symbols.size}</span></a>")
            }
            out.append("</div></details>")
        }
        out.append("</div>")
    }
    out.append("<p class=\"sidebar-note\">${label(locale, "Generated from", "生成自")}<code>${escapeHtml(documentation.schemaVersion)}</code></p></aside>")
}

internal func appendContextSidebar(out: RenderTextBuffer, projection: RenderProjection,
    rootPrefix: String, locale: String, currentPackagePath: ?String,
    currentSymbol: ?SymbolDoc): Unit {
    var owner: ?SymbolDoc = None
    match (currentSymbol) {
        case Some(symbol) => owner = memberContextOwner(projection, symbol)
        case None => ()
    }

    let targets = ArrayList<SymbolDoc>()
    var localMembers = false
    var contextTitle = label(locale, "In this package", "当前包")
    var moreHref = ""
    match (owner) {
        case Some(value) =>
            contextTitle = value.name
            localMembers = match (currentSymbol) {
                case Some(symbol) => symbol.id == value.id
                case None => false
            }
            for (entry in projection.members(value).entries) { targets.add(entry.symbol) }
            moreHref = rootPrefix + symbolPagePath(value)
        case None => match (currentPackagePath) {
            case Some(route) =>
                for (pkg in projection.packages) {
                    if (packagePagePath(pkg.source.moduleId, pkg.source.name) != route) { continue }
                    match (projection.topLevelByPackage.get(
                        routeKey(pkg.source.moduleId, pkg.source.name))) {
                        case Some(values) => targets.add(all: values)
                        case None => ()
                    }
                    moreHref = rootPrefix + route
                }
            case None => ()
        }
    }
    if (targets.isEmpty()) { return }

    out.append("<section class=\"sidebar-section sidebar-context\" aria-label=\"" +
        escapeHtml(contextTitle) + "\"><p class=\"sidebar-label\">" +
        escapeHtml(contextTitle) + "</p>")
    out.append("<label class=\"sidebar-filter-label\"><span class=\"sr-only\">" +
        label(locale, "Filter this context", "筛选当前条目") +
        "</span><input type=\"search\" class=\"sidebar-filter\" data-cjdoc-context-filter placeholder=\"" +
        label(locale, "Filter declarations", "筛选声明") + "\"></label>")
    out.append("<nav class=\"context-links\">")
    let maximum: Int64 = 256
    var shown: Int64 = 0
    for (symbol in targets) {
        if (shown >= maximum) { break }
        let href = if (localMembers) {
            "#" + symbolAnchor(symbol)
        } else {
            rootPrefix + symbolPagePath(symbol)
        }
        let active = match (currentSymbol) {
            case Some(value) => value.id == symbol.id
            case None => false
        }
        out.append("<a class=\"context-item")
        if (active) { out.append(" is-current") }
        out.append("\" data-cjdoc-context-item href=\"" + escapeHtml(href) + "\"")
        if (active) { out.append(" aria-current=\"page\"") }
        let text = if (symbol.headerSpelling.isEmpty()) { symbol.name } else {
            htmlTocLabel(symbol)
        }
        out.append("><code>" + escapeHtml(text) + "</code></a>")
        shown++
    }
    out.append("</nav><p class=\"sidebar-no-results\" data-cjdoc-context-empty role=\"status\" hidden>" +
        label(locale, "No matching declarations.", "没有匹配的声明。") + "</p>")
    if (targets.size > maximum) {
        out.append("<p class=\"sidebar-limit\">" +
            label(locale, "Showing the first 256 entries.", "显示前 256 个条目。") +
            " <a href=\"" + escapeHtml(moreHref) + "\">" +
            label(locale, "Full index", "完整索引") + "</a></p>")
    }
    out.append("</section>")
}

internal func appendPageStart(out: RenderTextBuffer, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", currentPackagePath!: ?String = None,
    currentRoute!: String = "overview", docVersion!: ?String = None,
    currentSymbol!: ?SymbolDoc = None): Unit {
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><script src=\"${rootPrefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body data-cjdoc-route=\"${escapeHtml(currentRoute)}\"")
    match (docVersion) {
        case Some(value) => out.append(" data-cjdoc-doc-version=\"${escapeHtml(value)}\"")
        case None => ()
    }
    out.append(">\n")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<button class=\"nav-menu\" type=\"button\" data-cjdoc-menu aria-controls=\"cjdoc-sidebar\" aria-expanded=\"false\" aria-label=\"${label(locale, "Open navigation", "打开导航")}\">${label(locale, "Menu", "菜单")}</button>")
    out.append("<a class=\"brand\" href=\"${rootPrefix}index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span>cjdoc<span class=\"brand-subtitle\">${label(locale, "API docs", "API 文档")}</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><svg width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"></circle><path d=\"m20 20-4-4\"></path></svg><label class=\"sr-only\" for=\"cjdoc-search-input\">${label(locale, "Search API", "搜索 API")}</label>")
    out.append("<input id=\"cjdoc-search-input\" type=\"search\" placeholder=\"${label(locale, "Search docs", "搜索文档")}\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"${rootPrefix}\"><kbd>Ctrl K</kbd></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul><p class=\"search-status-note\" data-cjdoc-search-status role=\"status\" hidden></p></div>")
    out.append("<button type=\"button\" class=\"search-filter-toggle\" data-cjdoc-filter-toggle aria-controls=\"cjdoc-search-filters\" aria-expanded=\"false\">${label(locale, "Filters", "筛选")}</button>")
    out.append("<div id=\"cjdoc-search-filters\" class=\"search-filters\"><label><span class=\"sr-only\">${label(locale, "Filter by kind", "按类别筛选")}</span><select data-cjdoc-kind aria-label=\"${label(locale, "Filter by kind", "按类别筛选")}\"><option value=\"\">${label(locale, "All kinds", "全部类别")}</option></select></label>")
    out.append("<label><span class=\"sr-only\">${label(locale, "Filter by package", "按包筛选")}</span><select data-cjdoc-package aria-label=\"${label(locale, "Filter by package", "按包筛选")}\"><option value=\"\">${label(locale, "All packages", "全部包")}</option></select></label></div></div>")
    out.append("<div class=\"top-actions\"><span class=\"version-label\" title=\"${label(locale, "Generated by cjdoc", "由 cjdoc 生成")}\">cjdoc ${escapeHtml(documentation.generator.version)}</span><div class=\"theme-control\"><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-controls=\"cjdoc-theme-popover\" aria-expanded=\"false\" aria-label=\"${label(locale, "Switch theme", "切换主题")}\"><svg class=\"icon-sun\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><circle cx=\"12\" cy=\"12\" r=\"4\"></circle><path d=\"M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42\"></path></svg><svg class=\"icon-moon\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><path d=\"M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5 8.5 8.5 0 1 0 20.5 14.7Z\"></path></svg></button><div id=\"cjdoc-theme-popover\" class=\"theme-popover\" data-cjdoc-theme-popover role=\"group\" aria-label=\"${label(locale, "Theme", "主题")}\" hidden><button type=\"button\" data-cjdoc-theme-value=\"system\" aria-pressed=\"false\">${label(locale, "System", "跟随系统")}</button><button type=\"button\" data-cjdoc-theme-value=\"light\" aria-pressed=\"false\">${label(locale, "Light", "浅色")}</button><button type=\"button\" data-cjdoc-theme-value=\"dark\" aria-pressed=\"false\">${label(locale, "Dark", "深色")}</button><button type=\"button\" data-cjdoc-theme-value=\"paper\" aria-pressed=\"false\">${label(locale, "Paper", "纸色")}</button><button type=\"button\" data-cjdoc-theme-value=\"ocean\" aria-pressed=\"false\">${label(locale, "Ocean", "海洋")}</button><button type=\"button\" data-cjdoc-theme-value=\"forest\" aria-pressed=\"false\">${label(locale, "Forest", "森林")}</button><button type=\"button\" data-cjdoc-theme-value=\"terminal\" aria-pressed=\"false\">${label(locale, "Terminal", "终端")}</button><button type=\"button\" data-cjdoc-theme-value=\"violet\" aria-pressed=\"false\">${label(locale, "Violet", "紫罗兰")}</button></div></div></div>")
    out.append("<span class=\"sr-only\" aria-label=\"${label(locale, "Theme", "主题")}\"></span>")
    out.append("</div></header>\n<div class=\"docs-layout\"><button class=\"nav-backdrop\" type=\"button\" data-cjdoc-menu-backdrop hidden aria-label=\"${label(locale, "Close navigation", "关闭导航")}\"></button>")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath, currentRoute: currentRoute,
        currentSymbol: currentSymbol)
    out.append("<main class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\"><details class=\"mobile-toc\" data-cjdoc-mobile-toc hidden><summary>${label(locale, "On this page", "本页目录")}</summary><ol></ol></details>\n")
}

internal func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"${label(locale, "On this page", "本页目录")}\" hidden><p class=\"toc-title\">${label(locale, "On this page", "本页目录")}</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><span><span class=\"footer-mark\">cjdoc</span> · ${label(locale, "Generated from Doc IR", "由 Doc IR 生成")}</span><span>${escapeHtml(documentation.generator.version)} · ${escapeHtml(documentation.schemaVersion)}</span></div></footer></body></html>\n")
}

