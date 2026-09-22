package cjdoc.render

import cjdoc.model.*
import std.collection.*

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
    out.append("</aside>")
}


internal func appendContextSidebar(out: RenderTextBuffer, projection: RenderProjection,
    rootPrefix: String, locale: String, currentPackagePath: ?String,
    currentSymbol: ?SymbolDoc): Unit {
    var owner: ?SymbolDoc = None
    match (currentSymbol) {
        case Some(symbol) =>
            if (isContainerDeclaration(symbol)) { owner = Some(symbol) }
            else { match (symbol.ownerId) {
                case Some(id) => owner = projection.visibleIndex.get(id)
                case None => ()
            } }
        case None => ()
    }
    let targets = ArrayList<SymbolDoc>()
    var localMembers = false
    var moreHref = ""
    var contextTitle = label(locale, "In this package", "当前包")
    match (owner) {
        case Some(value) =>
            contextTitle = value.name
            localMembers = match (currentSymbol) { case Some(symbol) => symbol.id == value.id case None => false }
            for (entry in projection.members(value).entries) { targets.add(entry.symbol) }
            moreHref = rootPrefix + symbolPagePath(value) + "#members-heading"
        case None => match (currentPackagePath) {
            case Some(route) => for (pkg in projection.packages) {
                if (packagePagePath(pkg.source.moduleId, pkg.source.name) != route) { continue }
                match (projection.topLevelByPackage.get(routeKey(pkg.source.moduleId, pkg.source.name))) {
                    case Some(values) => targets.add(all: values)
                    case None => ()
                }
                moreHref = rootPrefix + route
            }
            case None => ()
        }
    }
    if (targets.isEmpty()) { return }
    out.append("<section class=\"sidebar-section sidebar-context\" aria-label=\"" + escapeHtml(contextTitle) + "\">")
    out.append("<p class=\"sidebar-label\">" + escapeHtml(contextTitle) + "</p>")
    out.append("<label class=\"sidebar-filter-label\"><span class=\"sr-only\">" +
        label(locale, "Filter this context", "筛选当前条目") +
        "</span><input type=\"search\" class=\"sidebar-filter\" data-cjdoc-context-filter placeholder=\"" +
        label(locale, "Filter declarations", "筛选声明") + "\"></label><nav class=\"context-links\">")
    let maximum: Int64 = 256
    var count: Int64 = 0
    for (symbol in targets) {
        if (count >= maximum) { break }
        let href = if (localMembers) { "#" + symbolAnchor(symbol) } else { rootPrefix + symbolPagePath(symbol) }
        let active = match (currentSymbol) { case Some(value) => value.id == symbol.id case None => false }
        out.append("<a class=\"context-item")
        if (active) { out.append(" is-current") }
        out.append("\" data-cjdoc-nav-link href=\"" + escapeHtml(href) + "\"")
        if (active) { out.append(" aria-current=\"page\"") }
        let text = if (symbol.headerSpelling.isEmpty()) { symbol.name } else { htmlTocLabel(symbol) }
        out.append("><code>" + escapeHtml(text) + "</code></a>")
        count++
    }
    out.append("</nav><p class=\"sidebar-no-results\" data-cjdoc-context-empty role=\"status\" hidden>" +
        label(locale, "No matching declarations.", "没有匹配的声明。") + "</p>")
    if (targets.size > maximum) {
        out.append("<p class=\"sidebar-limit\">" + label(locale, "Showing the first 256 entries.", "显示前 256 个条目。") +
            " <a href=\"" + escapeHtml(moreHref) + "\">" + label(locale, "Full index", "完整索引") + "</a></p>")
    }
    out.append("</section>")
}

internal func appendPageStart(out: RenderTextBuffer, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", currentPackagePath!: ?String = None,
    currentRoute!: String = "overview", docVersion!: ?String = None,
    currentSymbol!: ?SymbolDoc = None): Unit {
    let project = escapeHtml(documentation.project.name)
    let subtitle = match (docVersion) {
        case Some(version) => escapeHtml(version)
        case None => label(locale, "API reference", "API 参考")
    }
    out.append("<!doctype html>\n<html lang=\"" + escapeHtml(locale) + "\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'\">")
    out.append("<title>" + project + " · " + escapeHtml(title) + "</title>")
    out.append("<script src=\"" + rootPrefix + "theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"" + rootPrefix + "style.css\">")
    out.append("<script defer src=\"" + rootPrefix + "search-index.js\"></script><script defer src=\"" + rootPrefix + "search.js\"></script></head>")
    out.append("<body data-cjdoc-route=\"" + escapeHtml(currentRoute) + "\" data-cjdoc-project=\"" + project + "\"")
    match (docVersion) { case Some(version) => out.append(" data-cjdoc-doc-version=\"" + escapeHtml(version) + "\"") case None => () }
    out.append(" data-cjdoc-audience=\"" + escapeHtml(documentation.configuration.audience) +
        "\" data-cjdoc-cfg=\"" + escapeHtml(documentation.configuration.cfgProfile) + "\">")
    out.append("<a class=\"skip-link\" href=\"#cjdoc-content\">" + label(locale, "Skip to content", "跳到正文") + "</a>")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<button class=\"nav-menu\" type=\"button\" data-cjdoc-menu aria-expanded=\"false\" aria-controls=\"cjdoc-sidebar\" aria-label=\"" +
        label(locale, "Open navigation", "打开导航") + "\"><svg width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" aria-hidden=\"true\"><path d=\"M4 7h16M4 12h16M4 17h16\"></path></svg></button>")
    out.append("<a class=\"brand\" href=\"" + rootPrefix + "index.html\"><span class=\"brand-copy\"><strong class=\"brand-project\">" +
        project + "</strong><span class=\"brand-subtitle\">" + subtitle + "</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><label class=\"sr-only\" for=\"cjdoc-search-input\">" +
        label(locale, "Search API", "搜索 API") + "</label><input id=\"cjdoc-search-input\" type=\"search\" placeholder=\"" +
        label(locale, "Search docs", "搜索文档") + "\" autocomplete=\"off\" aria-describedby=\"search-help\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"" + rootPrefix + "\"><kbd>Ctrl K</kbd></div>")
    out.append("<span class=\"sr-only\" id=\"search-help\">" + label(locale,
        "Filters: name:, owner:, param:, return:, package:, kind:", "筛选：name:、owner:、param:、return:、package:、kind:") + "</span>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul><p class=\"search-status\" data-cjdoc-search-status role=\"status\" hidden></p></div>")
    out.append("<button class=\"search-filter-toggle\" type=\"button\" data-cjdoc-filter-toggle aria-expanded=\"false\" aria-controls=\"cjdoc-search-filters\">" +
        label(locale, "Filters", "筛选") + "</button><div id=\"cjdoc-search-filters\" class=\"search-filters\"><div class=\"search-tabs\" role=\"group\" aria-label=\"" +
        label(locale, "Search categories", "搜索类别") + "\">")
    for (category in ["all", "classes", "functions", "other"]) {
        let text = match (category) {
            case "all" => label(locale, "All", "全部")
            case "classes" => label(locale, "Types", "类型")
            case "functions" => label(locale, "Functions", "函数")
            case _ => label(locale, "Other", "其他")
        }
        let pressed = if (category == "all") { "true" } else { "false" }
        out.append("<button type=\"button\" aria-pressed=\"" + pressed + "\" data-cjdoc-category=\"" + category + "\">" + text + "</button>")
    }
    out.append("</div><label><span class=\"sr-only\">" + label(locale, "Filter by package", "按包筛选") +
        "</span><select data-cjdoc-package aria-label=\"" + label(locale, "Filter by package", "按包筛选") +
        "\"><option value=\"\">" + label(locale, "All packages", "全部包") + "</option></select></label></div></div>")
    out.append("<div class=\"top-actions\"><div class=\"theme-control\" data-cjdoc-theme-control><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-haspopup=\"dialog\" aria-expanded=\"false\" aria-label=\"" +
        label(locale, "Choose theme", "切换主题") + "\">" + label(locale, "Theme", "主题") +
        "</button><div class=\"theme-popover\" data-cjdoc-theme-popover role=\"dialog\" aria-label=\"" + label(locale, "Theme", "主题") + "\" hidden><div class=\"theme-options\" role=\"group\">")
    for (theme in ["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]) {
        let text = match (theme) {
            case "system" => label(locale, "System", "系统")
            case "light" => label(locale, "Light", "浅色")
            case "dark" => label(locale, "Dark", "深色")
            case "paper" => label(locale, "Paper", "纸张")
            case "ocean" => label(locale, "Ocean", "深海")
            case "forest" => label(locale, "Forest", "松林")
            case "terminal" => label(locale, "Terminal", "终端")
            case _ => label(locale, "Violet", "紫墨")
        }
        out.append("<button type=\"button\" data-cjdoc-theme-value=\"" + theme + "\">" + text + "</button>")
    }
    out.append("</div></div></div></div></div></header>\n<div class=\"docs-layout\">")
    out.append("<button class=\"nav-backdrop\" type=\"button\" data-cjdoc-menu-backdrop aria-label=\"" +
        label(locale, "Close navigation", "关闭导航") + "\" hidden></button>")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath, currentRoute: currentRoute, currentSymbol: currentSymbol)
    out.append("<main id=\"cjdoc-content\" class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\"><details class=\"mobile-toc\" data-cjdoc-mobile-toc hidden><summary>" +
        label(locale, "On this page", "本页目录") + "</summary><nav><ol></ol></nav></details>\n")
}

internal func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"" + label(locale, "On this page", "本页目录") +
        "\" hidden><p class=\"toc-title\">" + label(locale, "On this page", "本页目录") + "</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><details class=\"build-details\"><summary>" +
        label(locale, "Build details", "构建信息") + "</summary><dl><dt>" + label(locale, "Generator", "生成器") +
        "</dt><dd class=\"version-label\">" + escapeHtml(documentation.generator.name) + " " + escapeHtml(documentation.generator.version) +
        "</dd><dt>Doc IR</dt><dd>" + escapeHtml(documentation.schemaVersion) + "</dd><dt>" + label(locale, "Audience", "受众") +
        "</dt><dd>" + escapeHtml(documentation.configuration.audience) + "</dd><dt>" + label(locale, "Configuration", "配置") +
        "</dt><dd>" + escapeHtml(documentation.configuration.cfgProfile) + "</dd></dl></details><span class=\"footer-mark\">cjdoc</span></div></footer></body></html>\n")
}
