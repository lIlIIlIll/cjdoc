package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

internal func appendHtmlSidebar(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, rootPrefix: String, locale: String,
    currentPackagePath!: ?String = None): Unit {
    out.append("<aside class=\"docs-sidebar\" aria-label=\"${label(locale, "Documentation navigation", "文档导航")}\">")
    out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Documentation", "文档")}</p>")
    let overviewCurrent = if (currentPackagePath.isNone()) { " aria-current=\"page\"" } else { "" }
    out.append("<a class=\"sidebar-link\" data-cjdoc-nav-link${overviewCurrent} href=\"${rootPrefix}index.html\">${label(locale, "Overview", "总览")}</a>")
    out.append("<a class=\"sidebar-link\" data-cjdoc-nav-link href=\"${rootPrefix}index.html#packages\">${label(locale, "API Reference", "API 参考")}</a></div>")
    if (!projection.modules.isEmpty()) {
        out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Package reference", "包参考")}</p>")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<details class=\"sidebar-group\" open><summary><span>${escapeHtml(module.name)}</span><span class=\"sidebar-count\">${projected.packages.size}</span></summary><div class=\"sidebar-packages\">")
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

internal func appendPageStart(out: RenderTextBuffer, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", currentPackagePath!: ?String = None): Unit {
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><script src=\"${rootPrefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body>\n")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<a class=\"brand\" href=\"${rootPrefix}index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span>cjdoc<span class=\"brand-subtitle\">${label(locale, "API docs", "API 文档")}</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><svg width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"></circle><path d=\"m20 20-4-4\"></path></svg><label class=\"sr-only\" for=\"cjdoc-search-input\">${label(locale, "Search API", "搜索 API")}</label>")
    out.append("<input id=\"cjdoc-search-input\" type=\"search\" placeholder=\"${label(locale, "Search docs", "搜索文档")}\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"${rootPrefix}\"><kbd>Ctrl K</kbd></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul></div>")
    out.append("<div class=\"search-filters\"><label><span class=\"sr-only\">${label(locale, "Filter by kind", "按类别筛选")}</span><select data-cjdoc-kind aria-label=\"${label(locale, "Filter by kind", "按类别筛选")}\"><option value=\"\">${label(locale, "All kinds", "全部类别")}</option></select></label><label><span class=\"sr-only\">${label(locale, "Filter by package", "按包筛选")}</span><select data-cjdoc-package aria-label=\"${label(locale, "Filter by package", "按包筛选")}\"><option value=\"\">${label(locale, "All packages", "全部包")}</option></select></label></div></div>")
    out.append("<div class=\"top-actions\"><span class=\"version-label\" title=\"${label(locale, "Generated by cjdoc", "由 cjdoc 生成")}\">cjdoc ${escapeHtml(documentation.generator.version)}</span><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-label=\"${label(locale, "Switch theme", "切换主题")}\" aria-pressed=\"false\"><svg class=\"icon-sun\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><circle cx=\"12\" cy=\"12\" r=\"4\"></circle><path d=\"M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42\"></path></svg><svg class=\"icon-moon\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><path d=\"M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5 8.5 8.5 0 1 0 20.5 14.7Z\"></path></svg></button></div>")
    out.append("</div></header>\n<div class=\"docs-layout\">")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath)
    out.append("<main class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\">\n")
}

internal func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"${label(locale, "On this page", "本页目录")}\" hidden><p class=\"toc-title\">${label(locale, "On this page", "本页目录")}</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><span><span class=\"footer-mark\">cjdoc</span> · ${label(locale, "Generated from Doc IR", "由 Doc IR 生成")}</span><span>${escapeHtml(documentation.generator.version)} · ${escapeHtml(documentation.schemaVersion)}</span></div></footer></body></html>\n")
}

