package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func appendReExportSourceAnchor(w: HtmlWriter, href: SafeUrl, locale: String): Unit {
    w.text(" ")
    w.element("a", [htmlClass("cj-reexports__source"), htmlHref(href),
        htmlAttr("rel", "noreferrer")]) { link =>
        link.text(label(locale, "Exposure source", "暴露位置"))
    }
}

private func appendReExportSourceLink(w: HtmlWriter,
    sourceReferences: SourceReferenceProjection, moduleId: String,
    source: SourceRange, locale: String): Unit {
    match (sourceReferences.project(moduleId, source).url) {
        case Some(url) => match (SafeUrl.external(url)) {
            case Some(href) => appendReExportSourceAnchor(w, href, locale)
            case None => ()
        }
        case None => ()
    }
}

private func appendBadge(w: HtmlWriter, value: String, className: String,
    dataName: String, dataValue: String): Unit {
    w.text(" ")
    w.textElement("span", value, attrs: [htmlClass(className), htmlAttr(dataName, dataValue)])
}

private func appendReExportStateBadges(w: HtmlWriter, reExport: ReExportDoc, locale: String,
    includeKind!: Bool): Unit {
    if (includeKind) {
        appendBadge(w, htmlKindLabel(reExport.kind, locale), "cj-badge", "data-kind", reExport.kind)
    }
    appendBadge(w, htmlStateLabel(reExport.state, locale), "cj-badge cj-badge--state",
        "data-state", reExport.state)
}

private func appendReExportTargetLink(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    targetId: String, locale: String): Unit {
    match (findSymbol(index, targetId)) {
        case Some(target) => match (documentationLinkHref("../" + symbolUrl(index, target))) {
            case Some(href) => w.element("a", [htmlHref(href)]) { link =>
                link.textElement("code", target.qualifiedName)
            }
            case None => w.textElement("code", target.qualifiedName)
        }
        case None => w.text(label(locale, "Target not present in this documentation",
            "目标未包含在当前文档中"))
    }
}

// A package alias or an unbound import: the target package name carries the row.
private func appendReExportPackageEntry(w: HtmlWriter, reExport: ReExportDoc,
    locale: String, sourceReferences: SourceReferenceProjection, moduleId: String): Unit {
    w.open("li")
    if (reExport.kind == "packageAlias") {
        w.textElement("code", reExport.alias.getOrThrow())
        if (reExport.state == "resolved") { w.text(" → " + label(locale, "package", "包")) }
        w.text(" ")
    }
    w.textElement("code", reExport.targetPackageName)
    appendReExportStateBadges(w, reExport, locale, includeKind: true)
    appendReExportSourceLink(w, sourceReferences, moduleId, reExport.source, locale)
    w.close("li")
    w.newline()
}

// One imported name: each visible target is a separate link, never nested.
private func appendReExportBindingEntry(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    reExport: ReExportDoc, binding: ReExportBinding, locale: String,
    sourceReferences: SourceReferenceProjection, moduleId: String): Unit {
    w.open("li")
    w.textElement("code", binding.exposedName)
    w.text(" → ")
    var firstTarget = true
    for (targetId in binding.targetSymbolIds) {
        if (!firstTarget) { w.text(", ") }
        firstTarget = false
        appendReExportTargetLink(w, index, targetId, locale)
    }
    appendReExportStateBadges(w, reExport, locale, includeKind: false)
    appendReExportSourceLink(w, sourceReferences, moduleId, reExport.source, locale)
    w.close("li")
    w.newline()
}

private func appendReExportRows(w: HtmlWriter, pkg: ProjectedPackage,
    index: HashMap<String, SymbolDoc>, locale: String,
    sourceReferences: SourceReferenceProjection): Unit {
    for (reExport in pkg.source.reExports) {
        if (reExport.kind != "packageAlias" && !reExport.bindings.isEmpty()) {
            for (binding in reExport.bindings) {
                appendReExportBindingEntry(w, index, reExport, binding, locale, sourceReferences,
                    pkg.source.moduleId)
            }
            continue
        }
        appendReExportPackageEntry(w, reExport, locale, sourceReferences, pkg.source.moduleId)
    }
}

internal func appendPackageMetadata(w: HtmlWriter, pkg: ProjectedPackage,
    index: HashMap<String, SymbolDoc>, locale: String,
    sourceReferences: SourceReferenceProjection): Unit {
    let packageDoc = pkg.source
    if (!packageDoc.reExports.isEmpty()) {
        w.open("details", attrs: [htmlClass("cj-reexports cj-disclosure")])
        w.open("summary", attrs: [htmlAttr("id", "re-exports"), htmlClass("cj-disclosure__summary")])
        w.text(label(locale, "Re-exports", "公开重导出") +
            " (${packageDoc.reExports.size} ${label(locale, "imports", "条导入")})")
        w.close("summary")
        w.open("ul", attrs: [htmlClass("cj-record-list")])
        appendReExportRows(w, pkg, index, locale, sourceReferences)
        w.close("ul")
        w.close("details")
        w.newline()
    }
    if (!pkg.sourceFiles.isEmpty()) {
        w.open("details", attrs: [htmlClass("cj-package-sources cj-disclosure")])
        w.open("summary", attrs: [htmlAttr("id", "sources"), htmlClass("cj-disclosure__summary")])
        w.text(label(locale, "Source files", "源文件") + " (${pkg.sourceFiles.size})")
        w.close("summary")
        w.open("ul", attrs: [htmlClass("cj-record-list")])
        for (path in pkg.sourceFiles) {
            w.element("li", []) { item => item.textElement("code", path) }
        }
        w.close("ul")
        w.close("details")
        w.newline()
    }
}
