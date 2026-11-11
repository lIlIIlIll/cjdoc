package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal let HTML_PAGE_CSP = "default-src 'none'; script-src 'self' file:; style-src 'self' file:; " +
    "img-src 'self' file:; base-uri 'none'; form-action 'none'"

// Every page repeats its server-rendered branch, so a branch is a fixed window
// around the active entry: total output stays linear in the declaration count.
// The tree script replaces a partial branch with the complete index.
private let SIDEBAR_SERVER_WINDOW: Int64 = 12

private func sidebarWindow(size: Int64, activeIndex: Int64): (Int64, Int64) {
    if (size <= SIDEBAR_SERVER_WINDOW) { return (0, size) }
    var start = if (activeIndex < 0) { 0 } else { activeIndex - SIDEBAR_SERVER_WINDOW / 2 }
    if (start < 0) { start = 0 }
    if (start > size - SIDEBAR_SERVER_WINDOW) { start = size - SIDEBAR_SERVER_WINDOW }
    (start, start + SIDEBAR_SERVER_WINDOW)
}

private func sidebarChildrenAttrs(id: String, partial: Bool): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-tree__children"), htmlAttr("id", id),
        htmlFlag("data-cjdoc-tree-children")])
    if (partial) { attrs.add(htmlFlag("data-cjdoc-tree-partial")) }
    attrs.toArray()
}

private func appendSidebarMore(w: HtmlWriter, url: String, text: String): Unit {
    w.open("li", attrs: [htmlClass("cj-tree__item cj-tree__item--more")])
    w.open("a", attrs: [htmlClass("cj-tree__more"), htmlFlag("data-cjdoc-sidebar-more"),
        htmlHref(SafeUrl.siteRoute(url))])
    w.text(text)
    w.close("a")
    w.close("li")
}

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

private func sidebarTopLevelContext(projection: RenderProjection,
    symbol: SymbolDoc): SymbolDoc {
    let context = memberContextOwner(projection, symbol).getOrDefault({ => symbol })
    var current = context
    // A valid owner chain cannot exceed the visible declaration inventory.
    var remaining = projection.visibleIndex.size
    while (current.ownerId.isSome()) {
        if (remaining == 0) { return context }
        remaining -= 1
        let ownerId = current.ownerId.getOrThrow()
        match (projection.visibleIndex.get(ownerId)) {
            case Some(owner) =>
                if (!isDocIrContainerKind(owner.kind) ||
                    owner.moduleId != context.moduleId ||
                    owner.packageName != context.packageName) {
                    return context
                }
                current = owner
            case None => return context
        }
    }
    current
}

internal func sidebarPageIsCurrent(targetPath: String, currentPagePath: ?String): Bool {
    if (targetPath.isEmpty() || targetPath.contains("#") || !targetPath.endsWith(".html")) { return false }
    match (currentPagePath) {
        case Some(path) => path == targetPath
        case None => false
    }
}

// Ids pair a bounded readable slug with the full key so a deep tree never
// produces an unbounded id or a collision between two keys.
private func treeChildrenId(key: String): String {
    "cjdoc-tree-${boundedHtmlSlug(key)}"
}

private func treeLinkAttrs(linkClass: String, isCurrent: Bool,
    url: String): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>([htmlClass(linkClass), htmlFlag("data-cjdoc-nav-link")])
    if (isCurrent) { attrs.add(htmlAttr("aria-current", "page")) }
    attrs.add(htmlHref(SafeUrl.siteRoute(url)))
    attrs.toArray()
}

private func treeLinkClass(isAncestor: Bool): String {
    if (isAncestor) { "cj-tree__link cj-tree__link--ancestor" } else { "cj-tree__link" }
}

private func appendScriptElement(w: HtmlWriter, url: String, deferred!: Bool): Unit {
    let attrs = ArrayList<HtmlAttr>()
    if (deferred) { attrs.add(htmlFlag("defer")) }
    attrs.add(htmlSrc(SafeUrl.siteRoute(url)))
    w.open("script", attrs: attrs.toArray())
    w.close("script")
}

private func appendTreeKind(w: HtmlWriter, kind: String): Unit {
    w.open("span", attrs: [htmlClass("cj-tree__kind"), htmlAttr("data-kind", kind),
        htmlAttr("aria-hidden", "true")])
    w.close("span")
}

// The chevron is drawn by CSS from aria-expanded; the button only needs an
// accessible name for readers who navigate by control list. Only a branch
// rendered on this page is named by aria-controls; the tree script binds lazy
// branches when it builds them.
private func appendTreeToggle(w: HtmlWriter, controlsId: String, name: String,
    expanded: Bool, locale: String): Unit {
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-tree__toggle"), htmlAttr("type", "button"),
        htmlFlag("data-cjdoc-tree-toggle"),
        htmlAttr("aria-expanded", if (expanded) { "true" } else { "false" })])
    if (expanded) { attrs.add(htmlAttr("aria-controls", controlsId)) }
    attrs.add(htmlAttr("aria-label", label(locale, "Toggle ", "展开或收起 ") + name))
    attrs.add(htmlFlag("hidden"))
    w.open("button", attrs: attrs.toArray())
    w.close("button")
}

private func appendSidebarMember(w: HtmlWriter, owner: SymbolDoc, member: SymbolDoc,
    rootPrefix: String): Unit {
    w.open("li", attrs: [htmlClass("cj-tree__item"),
        htmlAttr("data-cjdoc-tree-item", "member"),
        htmlAttr("data-cjdoc-tree-key", member.id)])
    w.element("div", [htmlClass("cj-tree__row")], { row =>
        row.open("a", attrs: [htmlClass("cj-tree__link"), htmlHref(SafeUrl.siteRoute(
            rootPrefix + symbolPagePath(owner) + "#" + symbolAnchor(member)))])
        appendTreeKind(row, member.kind)
        row.textElement("span", htmlContextLabel(member),
            attrs: [htmlClass("cj-tree__label")])
        row.close("a")
    })
    w.close("li")
}

private func appendSidebarMembers(w: HtmlWriter, projection: RenderProjection,
    owner: SymbolDoc, rootPrefix: String, locale: String, currentPagePath: ?String): Unit {
    let entries = projection.members(owner).entries
    if (entries.isEmpty()) { return }
    var active: Int64 = -1
    for (index in 0..entries.size) {
        if (sidebarPageIsCurrent(symbolPagePath(entries[index].symbol), currentPagePath)) {
            active = index
            break
        }
    }
    let (start, end) = sidebarWindow(entries.size, active)
    let partial = end - start < entries.size
    w.open("ul", attrs: sidebarChildrenAttrs(treeChildrenId(owner.id), partial))
    for (index in start..end) {
        appendSidebarMember(w, owner, entries[index].symbol, rootPrefix)
    }
    if (partial) {
        appendSidebarMore(w, rootPrefix + symbolPagePath(owner),
            label(locale, "All members", "全部成员"))
    }
    w.close("ul")
}

private func appendSidebarType(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, labels: HashMap<String, String>, rootPrefix: String,
    currentId: String, currentPagePath: ?String, locale: String): Unit {
    let path = symbolPagePath(symbol)
    let isCurrent = sidebarPageIsCurrent(path, currentPagePath)
    let isAncestor = !isCurrent && !currentId.isEmpty() && symbol.id == currentId
    let labelText = labels.get(symbol.id).getOrDefault({ => htmlContextLabel(symbol) })
    let hasMembers = !projection.members(symbol).entries.isEmpty()
    w.open("li", attrs: [htmlClass("cj-tree__item"),
        htmlAttr("data-cjdoc-tree-item", "type"),
        htmlAttr("data-cjdoc-tree-key", symbol.id)])
    w.element("div", [htmlClass("cj-tree__row")], { row =>
        // Children are server-rendered for the current type only, so the toggle
        // must not claim an expanded state for a branch it does not own yet.
        if (hasMembers) {
            appendTreeToggle(row, treeChildrenId(symbol.id), labelText, symbol.id == currentId,
                locale)
        }
        row.open("a", attrs: treeLinkAttrs(treeLinkClass(isAncestor), isCurrent,
            rootPrefix + path))
        appendTreeKind(row, symbol.kind)
        row.textElement("span", labelText, attrs: [htmlClass("cj-tree__label")])
        row.close("a")
    })
    if (symbol.id == currentId) {
        appendSidebarMembers(w, projection, symbol, rootPrefix, locale, currentPagePath)
    }
    w.close("li")
}

private func appendSidebarPackageChildren(w: HtmlWriter, projection: RenderProjection,
    pkg: ProjectedPackage, rootPrefix: String, locale: String, currentId: String,
    currentPagePath: ?String): Unit {
    let symbols = match (projection.topLevelByPackage.get(
        routeKey(pkg.source.moduleId, pkg.source.name))) {
        case Some(values) => values
        case None => return
    }
    if (symbols.isEmpty()) { return }
    let labels = sidebarPackageLabels(projection, pkg.source.moduleId, pkg.source.name)
    let packagePath = packagePagePath(pkg.source.moduleId, pkg.source.name)
    w.open("ul", attrs: sidebarChildrenAttrs(treeChildrenId(packagePath),
        symbols.size > SIDEBAR_SERVER_WINDOW))
    var active: Int64 = -1
    for (index in 0..symbols.size) {
        if (symbols[index].id == currentId) {
            active = index
            break
        }
    }
    let (start, end) = sidebarWindow(symbols.size, active)
    for (index in start..end) {
        appendSidebarType(w, projection, symbols[index], labels, rootPrefix, currentId,
            currentPagePath, locale)
    }
    appendSidebarMore(w, rootPrefix + packagePath + "#declarations",
        label(locale, "Full package index", "查看完整包索引"))
    w.close("ul")
}

private func appendSidebarPackage(w: HtmlWriter, projection: RenderProjection,
    pkg: ProjectedPackage, rootPrefix: String, locale: String,
    currentPackagePath: ?String, currentId: String, currentPagePath: ?String): Unit {
    let packagePath = packagePagePath(pkg.source.moduleId, pkg.source.name)
    let isContext = match (currentPackagePath) {
        case Some(currentPath) => currentPath == packagePath
        case None => false
    }
    let isCurrent = sidebarPageIsCurrent(packagePath, currentPagePath)
    w.open("li", attrs: [htmlClass("cj-tree__item"),
        htmlAttr("data-cjdoc-tree-item", "package"),
        htmlAttr("data-cjdoc-tree-key", packagePath)])
    w.element("div", [htmlClass("cj-tree__row")], { row =>
        appendTreeToggle(row, treeChildrenId(packagePath), pkg.source.name, isContext, locale)
        row.open("a", attrs: treeLinkAttrs(treeLinkClass(isContext && !isCurrent),
            isCurrent, rootPrefix + packagePath))
        row.textElement("span", pkg.source.name, attrs: [htmlClass("cj-tree__label")])
        row.textElement("span", pkg.symbols.size.toString(),
            attrs: [htmlClass("cj-tree__count")])
        row.close("a")
    })
    if (isContext) {
        appendSidebarPackageChildren(w, projection, pkg, rootPrefix, locale, currentId,
            currentPagePath)
    }
    w.close("li")
}

internal func appendSidebarTree(w: HtmlWriter, projection: RenderProjection,
    rootPrefix: String, locale: String, currentPackagePath: ?String,
    currentSymbol: ?SymbolDoc, currentPagePath: ?String): Unit {
    let currentId = match (currentSymbol) {
        case Some(symbol) => symbol.id
        case None => ""
    }
    w.open("nav", attrs: [htmlClass("cj-tree"),
        htmlAttr("aria-label", label(locale, "Package reference", "包参考")),
        htmlFlag("data-cjdoc-sidebar-tree")])
    if (!projection.modules.isEmpty()) {
        let showModuleLabel = projection.modules.size > 1
        for (projected in projection.modules) {
            w.open("section", attrs: [htmlClass("cj-tree__module"),
                htmlFlag("data-cjdoc-tree-module")])
            if (showModuleLabel) {
                w.textElement("p", projected.source.name,
                    attrs: [htmlClass("cj-tree__module-label")])
            }
            w.open("ul", attrs: [htmlClass("cj-tree__list")])
            for (pkg in projected.packages) {
                appendSidebarPackage(w, projection, pkg, rootPrefix, locale,
                    currentPackagePath, currentId, currentPagePath)
            }
            w.close("ul")
            w.close("section")
        }
    }
    w.close("nav")
}

internal func appendHtmlSidebar(w: HtmlWriter, projection: RenderProjection,
    rootPrefix: String, locale: String,
    currentPackagePath!: ?String = None, currentRoute!: String = "overview",
    currentSymbol!: ?SymbolDoc = None, currentPagePath!: ?String = None): Unit {
    let sidebarSymbol: ?SymbolDoc = match (currentSymbol) {
        case Some(symbol) => Some(sidebarTopLevelContext(projection, symbol))
        case None => None
    }
    let currentId = match (sidebarSymbol) {
        case Some(symbol) => symbol.id
        case None => ""
    }
    w.open("aside", attrs: [htmlAttr("id", "cjdoc-sidebar"), htmlClass("cj-sidebar"),
        htmlAttr("aria-label", label(locale, "Documentation navigation", "文档导航")),
        htmlAttr("tabindex", "-1"),
        htmlAttr("data-cjdoc-root-prefix", rootPrefix),
        htmlAttr("data-cjdoc-current-symbol", currentId),
        htmlAttr("data-cjdoc-current-page", currentPagePath.getOrDefault({ => "" }))])
    w.element("div", [htmlClass("cj-sidebar__head")], { head =>
        head.open("button", attrs: [htmlClass("cj-button cj-button--icon cj-sidebar__close"),
            htmlAttr("type", "button"), htmlFlag("data-cjdoc-sidebar-close"),
            htmlAttr("aria-label", label(locale, "Close navigation", "关闭导航"))])
        head.icon("close")
        head.close("button")
    })
    w.element("nav", [htmlClass("cj-sidebar__primary"),
        htmlAttr("aria-label", label(locale, "Documentation", "文档"))], { nav =>
        nav.open("a", attrs: treeLinkAttrs("cj-sidebar__link",
            sidebarPageIsCurrent("index.html", currentPagePath), rootPrefix + "index.html"))
        nav.text(label(locale, "Overview", "总览"))
        nav.close("a")
        let apiClass = if (currentRoute == "api") {
            "cj-sidebar__link cj-sidebar__link--ancestor"
        } else {
            "cj-sidebar__link"
        }
        nav.open("a", attrs: [htmlClass(apiClass), htmlFlag("data-cjdoc-nav-link"),
            htmlHref(SafeUrl.siteRoute(rootPrefix + "index.html#packages"))])
        nav.text(label(locale, "API Reference", "API 参考"))
        nav.close("a")
    })
    if (!projection.modules.isEmpty()) {
        w.element("div", [htmlClass("cj-sidebar__filter"),
            htmlFlag("data-cjdoc-sidebar-filter-wrap")], { filter =>
            filter.textElement("label", label(locale, "Filter API", "筛选 API"),
                attrs: [htmlClass("cj-sr-only"), htmlAttr("for", "cjdoc-sidebar-filter")])
            filter.void("input", attrs: [htmlAttr("id", "cjdoc-sidebar-filter"),
                htmlClass("cj-input cj-sidebar__filter-input"), htmlAttr("type", "search"),
                htmlAttr("placeholder", label(locale, "Filter API", "筛选 API")),
                htmlAttr("autocomplete", "off"), htmlFlag("data-cjdoc-sidebar-filter")])
        })
        w.textElement("p", label(locale, "No matches.", "没有匹配项。"),
            attrs: [htmlClass("cj-sidebar__empty"), htmlFlag("data-cjdoc-sidebar-no-results"),
                htmlAttr("role", "status"), htmlFlag("hidden")])
    }
    appendSidebarTree(w, projection, rootPrefix, locale, currentPackagePath,
        sidebarSymbol, currentPagePath)
    w.close("aside")
}

private func appendShellHeader(w: HtmlWriter, documentation: DocumentationSet,
    rootPrefix: String, locale: String, docVersion: ?String): Unit {
    w.open("header", attrs: [htmlClass("cj-header")])
    w.open("div", attrs: [htmlClass("cj-header__inner")])
    w.open("button", attrs: [htmlClass("cj-button cj-button--icon cj-header__menu"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-menu"),
        htmlAttr("aria-controls", "cjdoc-sidebar"), htmlAttr("aria-expanded", "false"),
        htmlAttr("aria-label", label(locale, "Open navigation", "打开导航"))])
    w.icon("menu")
    w.close("button")
    w.element("a", [htmlClass("cj-header__brand"),
        htmlHref(SafeUrl.siteRoute(rootPrefix + "index.html"))], { brand =>
        brand.textElement("span", documentation.project.name,
            attrs: [htmlClass("cj-header__project")])
    })
    w.open("button", attrs: [htmlClass("cj-search-trigger"), htmlAttr("type", "button"),
        htmlFlag("data-cjdoc-search-trigger"), htmlAttr("aria-haspopup", "dialog"),
        htmlAttr("aria-controls", "cjdoc-search-dialog"), htmlAttr("aria-expanded", "false"),
        htmlFlag("hidden")])
    w.icon("search")
    w.textElement("span", label(locale, "Search docs", "搜索文档"),
        attrs: [htmlClass("cj-search-trigger__label")])
    w.textElement("kbd", "Ctrl K", attrs: [htmlClass("cj-kbd"),
        htmlFlag("data-cjdoc-search-shortcut")])
    w.close("button")
    w.open("div", attrs: [htmlClass("cj-header__actions")])
    match (docVersion) {
        case Some(value) => w.textElement("span", value, attrs: [htmlClass("cj-header__version")])
        case None => ()
    }
    // Byte-exact replacement marker: site_languages.cj swaps this span for the
    // finished language toggle, and single-language pages keep it as a label.
    w.open("span", attrs: [htmlClass("language-label"), htmlAttr("lang", locale)])
    w.text(label(locale, "English", "中文"))
    w.close("span")
    w.open("button", attrs: [htmlClass("cj-button cj-button--icon cj-header__settings"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-theme-toggle"),
        htmlAttr("aria-haspopup", "dialog"), htmlAttr("aria-controls", "cjdoc-theme-popover"),
        htmlAttr("aria-expanded", "false"),
        htmlAttr("aria-label", label(locale, "Display settings", "显示设置")),
        htmlFlag("hidden")])
    w.icon("settings")
    w.textElement("span", label(locale, "Theme: System", "主题：跟随系统"),
        attrs: [htmlClass("cj-sr-only"), htmlFlag("data-cjdoc-theme-label")])
    w.close("button")
    w.close("div")
    w.close("div")
    w.close("header")
}

private func appendSearchFilter(w: HtmlWriter, attribute: String,
    labelText: String, allLabel: String): Unit {
    w.element("label", [htmlClass("cj-search__filter")], { field =>
        field.textElement("span", labelText, attrs: [htmlClass("cj-sr-only")])
        field.open("select", attrs: [htmlClass("cj-select"), htmlFlag(attribute),
            htmlAttr("aria-label", labelText)])
        field.textElement("option", allLabel, attrs: [htmlAttr("value", "")])
        field.close("select")
    })
}

private func appendSearchDialog(w: HtmlWriter, rootPrefix: String, locale: String): Unit {
    w.open("dialog", attrs: [htmlAttr("id", "cjdoc-search-dialog"), htmlClass("cj-search"),
        htmlFlag("data-cjdoc-search-dialog"),
        htmlAttr("aria-label", label(locale, "Search documentation", "搜索文档"))])
    w.open("div", attrs: [htmlClass("cj-search__bar")])
    w.icon("search")
    w.textElement("label", label(locale, "Search API", "搜索 API"),
        attrs: [htmlClass("cj-sr-only"), htmlAttr("for", "cjdoc-search-input")])
    w.void("input", attrs: [htmlAttr("id", "cjdoc-search-input"),
        htmlClass("cj-search__input"), htmlAttr("type", "search"),
        htmlAttr("placeholder", label(locale, "Search docs", "搜索文档")),
        htmlAttr("autocomplete", "off"), htmlAttr("role", "combobox"),
        htmlAttr("aria-autocomplete", "list"),
        htmlAttr("aria-controls", "cjdoc-search-results"),
        htmlAttr("aria-expanded", "false"), htmlFlag("data-cjdoc-search"),
        htmlAttr("data-root", rootPrefix)])
    w.open("button", attrs: [htmlClass("cj-button cj-button--quiet cj-search__close"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-search-close"),
        htmlAttr("aria-label", label(locale, "Close search", "关闭搜索"))])
    w.textElement("kbd", "Esc", attrs: [htmlClass("cj-kbd")])
    w.close("button")
    w.close("div")
    w.open("div", attrs: [htmlAttr("id", "cjdoc-search-filters"),
        htmlClass("cj-search__filters")])
    appendSearchFilter(w, "data-cjdoc-kind", label(locale, "Filter by kind", "按类别筛选"),
        label(locale, "All kinds", "全部类别"))
    appendSearchFilter(w, "data-cjdoc-package", label(locale, "Filter by package", "按包筛选"),
        label(locale, "All packages", "全部包"))
    w.close("div")
    w.open("div", attrs: [htmlClass("cj-search__facets"),
        htmlFlag("data-cjdoc-search-facets"), htmlAttr("role", "group"),
        htmlAttr("aria-label", label(locale, "Tag filters", "标签筛选")), htmlFlag("hidden")])
    w.close("div")
    w.open("ul", attrs: [htmlAttr("id", "cjdoc-search-results"),
        htmlClass("cj-search__results"), htmlAttr("role", "listbox"),
        htmlFlag("data-cjdoc-results"), htmlAttr("aria-live", "polite")])
    w.close("ul")
    w.open("p", attrs: [htmlClass("cj-search__status"), htmlFlag("data-cjdoc-search-status"),
        htmlAttr("role", "status"), htmlFlag("hidden")])
    w.close("p")
    w.open("div", attrs: [htmlClass("cj-search__pages"), htmlFlag("data-cjdoc-search-pages"),
        htmlFlag("hidden")])
    w.open("button", attrs: [htmlClass("cj-button"), htmlAttr("type", "button"),
        htmlFlag("data-cjdoc-search-previous")])
    w.text(label(locale, "Previous", "上一页"))
    w.close("button")
    w.open("button", attrs: [htmlClass("cj-button"), htmlAttr("type", "button"),
        htmlFlag("data-cjdoc-search-next")])
    w.text(label(locale, "Next", "下一页"))
    w.close("button")
    w.close("div")
    w.textElement("p", label(locale,
        "Search covers names, structured fields and up to 2,000 characters of body text " +
            "per entry. No match does not prove absence from the full documentation.",
        "检索覆盖名称、结构化字段及每项最多 2,000 字符的正文摘录；没有命中不代表完整文档中不存在。"),
        attrs: [htmlClass("cj-search__note")])
    w.close("dialog")
}

private let SETTINGS_THEMES: Array<(String, String, String)> = [
    ("system", "System", "跟随系统"), ("light", "Light", "浅色"), ("dark", "Dark", "深色"),
    ("paper", "Paper", "纸色"), ("ocean", "Ocean", "海洋"), ("forest", "Forest", "森林"),
    ("terminal", "Terminal", "终端"), ("violet", "Violet", "紫罗兰")
]

private let SETTINGS_FONTS: Array<(String, String, String)> = [
    ("system", "System", "系统"), ("serif", "Serif", "衬线"), ("mono-ui", "Monospace", "等宽")
]

private let SETTINGS_SIZES: Array<(String, String, String)> = [
    ("s", "S", "S"), ("m", "M", "M"), ("l", "L", "L")
]

private func appendSettingsGroup(w: HtmlWriter, locale: String, legend: String,
    options: Array<(String, String, String)>, attribute: String, themed!: Bool = false): Unit {
    w.open("fieldset", attrs: [htmlClass("cj-settings__group")])
    w.textElement("legend", legend, attrs: [htmlClass("cj-settings__legend")])
    let groupClass = if (themed) {
        "cj-settings__options cj-settings__options--themes"
    } else {
        "cj-settings__options"
    }
    w.open("div", attrs: [htmlClass(groupClass)])
    for ((value, english, chinese) in options) {
        w.open("button", attrs: [htmlClass("cj-settings__option"), htmlAttr("type", "button"),
            htmlAttr(attribute, value), htmlAttr("aria-pressed", "false")])
        if (themed) {
            w.open("span", attrs: [htmlClass("cj-settings__swatch"),
                htmlAttr("data-cjdoc-swatch", value), htmlAttr("aria-hidden", "true")])
            w.close("span")
        }
        w.textElement("span", label(locale, english, chinese))
        w.close("button")
    }
    w.close("div")
    w.close("fieldset")
}

private func appendSettingsDialog(w: HtmlWriter, locale: String): Unit {
    w.open("dialog", attrs: [htmlAttr("id", "cjdoc-theme-popover"), htmlClass("cj-settings"),
        htmlFlag("data-cjdoc-theme-popover"),
        htmlAttr("aria-labelledby", "cjdoc-settings-title")])
    w.open("div", attrs: [htmlClass("cj-settings__head")])
    w.textElement("h2", label(locale, "Display", "显示"),
        attrs: [htmlAttr("id", "cjdoc-settings-title"), htmlClass("cj-settings__title")])
    w.open("button", attrs: [htmlClass("cj-button cj-button--icon"),
        htmlAttr("type", "button"), htmlFlag("data-cjdoc-theme-close"),
        htmlAttr("aria-label", label(locale, "Close", "关闭"))])
    w.icon("close")
    w.close("button")
    w.close("div")
    appendSettingsGroup(w, locale, label(locale, "Theme", "主题"), SETTINGS_THEMES,
        "data-cjdoc-theme-value", themed: true)
    appendSettingsGroup(w, locale, label(locale, "Font", "字体"), SETTINGS_FONTS,
        "data-cjdoc-font-value")
    appendSettingsGroup(w, locale, label(locale, "Text size", "字号"), SETTINGS_SIZES,
        "data-cjdoc-size-value")
    w.textElement("p", label(locale, "System follows your device appearance.",
        "跟随系统会采用设备的外观设置。"), attrs: [htmlClass("cj-settings__hint")])
    w.close("dialog")
}

private func pageRole(currentRoute: String, currentSymbol: ?SymbolDoc): String {
    if (currentSymbol.isSome()) { return "symbol" }
    match (currentRoute) {
        case "overview" => "home"
        case "concept" => "guide"
        case "api" => "package"
        case _ => "utility"
    }
}

private func appendHeadLinks(w: HtmlWriter, rootPrefix: String, title: String,
    agentReadable: Bool, alternateMarkdown: ?String): Unit {
    w.void("meta", attrs: [htmlAttr("charset", "utf-8")])
    w.void("meta", attrs: [htmlAttr("name", "viewport"),
        htmlAttr("content", "width=device-width,initial-scale=1")])
    w.void("meta", attrs: [htmlAttr("http-equiv", "Content-Security-Policy"),
        htmlAttr("content", HTML_PAGE_CSP)])
    w.textElement("title", title)
    appendScriptElement(w, rootPrefix + "theme-bootstrap.js", deferred: false)
    w.void("link", attrs: [htmlAttr("rel", "stylesheet"),
        htmlHref(SafeUrl.siteRoute(rootPrefix + "style.css"))])
    if (agentReadable) {
        w.void("link", attrs: [htmlAttr("rel", "describedby"), htmlAttr("type", "text/plain"),
            htmlHref(SafeUrl.siteRoute(rootPrefix + "llms.txt"))])
        w.void("link", attrs: [htmlAttr("rel", "describedby"),
            htmlAttr("type", "application/json"),
            htmlHref(SafeUrl.siteRoute(rootPrefix + "agent/manifest.json"))])
        match (alternateMarkdown) {
            case Some(path) =>
                w.void("link", attrs: [htmlAttr("rel", "alternate"),
                    htmlAttr("type", "text/markdown"),
                    htmlHref(SafeUrl.siteRoute(rootPrefix + path))])
            case None => ()
        }
    }
}

internal func appendPageStart(w: HtmlWriter, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", currentPackagePath!: ?String = None,
    currentRoute!: String = "overview", docVersion!: ?String = None,
    currentSymbol!: ?SymbolDoc = None, agentReadable!: Bool = false,
    alternateMarkdown!: ?String = None, currentPagePath!: ?String = None): Unit {
    w.doctype()
    w.open("html", attrs: [htmlAttr("lang", locale)])
    w.open("head")
    appendHeadLinks(w, rootPrefix, title, agentReadable, alternateMarkdown)
    appendScriptElement(w, rootPrefix + "search-index.js", deferred: true)
    appendScriptElement(w, rootPrefix + "sidebar-index.js", deferred: true)
    appendScriptElement(w, rootPrefix + "search.js", deferred: true)
    w.close("head")
    let bodyAttrs = ArrayList<HtmlAttr>([htmlClass("cj-page"),
        htmlAttr("data-cjdoc-route", currentRoute)])
    match (docVersion) {
        case Some(value) => bodyAttrs.add(htmlAttr("data-cjdoc-doc-version", value))
        case None => ()
    }
    bodyAttrs.add(htmlAttr("data-cjdoc-page", pageRole(currentRoute, currentSymbol)))
    w.open("body", attrs: bodyAttrs.toArray())
    w.element("a", [htmlClass("cj-skip-link"), htmlHref(SafeUrl.fragment("cjdoc-main"))],
        { skip => skip.text(label(locale, "Skip to content", "跳到正文")) })
    appendShellHeader(w, documentation, rootPrefix, locale, docVersion)
    appendSearchDialog(w, rootPrefix, locale)
    appendSettingsDialog(w, locale)
    w.open("div", attrs: [htmlClass("cj-layout")])
    w.open("button", attrs: [htmlClass("cj-drawer-backdrop"), htmlAttr("type", "button"),
        htmlFlag("data-cjdoc-menu-backdrop"), htmlFlag("hidden"),
        htmlAttr("aria-label", label(locale, "Close navigation", "关闭导航"))])
    w.close("button")
    appendHtmlSidebar(w, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath, currentRoute: currentRoute,
        currentSymbol: currentSymbol, currentPagePath: currentPagePath)
    w.open("main", attrs: [htmlAttr("id", "cjdoc-main"), htmlClass("cj-main"),
        htmlFlag("data-cjdoc-content"), htmlAttr("tabindex", "-1")])
    w.open("div", attrs: [htmlClass("cj-content")])
    w.open("details", attrs: [htmlClass("cj-toc-mobile"),
        htmlFlag("data-cjdoc-mobile-toc"), htmlFlag("hidden")])
    w.textElement("summary", label(locale, "On this page", "本页目录"),
        attrs: [htmlClass("cj-toc-mobile__summary")])
    w.open("ol", attrs: [htmlClass("cj-toc__list")])
    w.close("ol")
    w.close("details")
}

internal func appendPageEnd(w: HtmlWriter, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    w.close("div")
    w.close("main")
    w.open("aside", attrs: [htmlClass("cj-toc"), htmlFlag("data-cjdoc-toc"),
        htmlAttr("aria-label", label(locale, "On this page", "本页目录")), htmlFlag("hidden")])
    w.textElement("p", label(locale, "On this page", "本页目录"),
        attrs: [htmlClass("cj-toc__title")])
    w.open("nav")
    w.open("ol", attrs: [htmlClass("cj-toc__list")])
    w.close("ol")
    w.close("nav")
    w.close("aside")
    w.close("div")
    w.open("footer", attrs: [htmlClass("cj-footer")])
    w.open("div", attrs: [htmlClass("cj-footer__inner")])
    w.open("span")
    w.textElement("span", "cjdoc", attrs: [htmlClass("cj-footer__mark")])
    w.text(" · " + label(locale, "Generated from Doc IR", "由 Doc IR 生成"))
    w.close("span")
    w.textElement("span", "${documentation.generator.version} · ${documentation.schemaVersion}")
    w.close("div")
    w.close("footer")
    w.close("body")
    w.close("html")
    w.newline()
}
