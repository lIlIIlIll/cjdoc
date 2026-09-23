package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendPackageMetadata(out: RenderTextBuffer, pkg: ProjectedPackage,
    index: HashMap<String, SymbolDoc>, locale: String): Unit {
    let packageDoc = pkg.source
    if (!packageDoc.reExports.isEmpty()) {
        out.append("<details class=\"reexports\"><summary id=\"re-exports\">${label(locale, "Re-exports", "公开重导出")} (${packageDoc.reExports.size} ${label(locale, "imports", "条导入")})</summary><ul class=\"record-list\">\n")
        for (reExport in packageDoc.reExports) {
            if (reExport.kind == "packageAlias") {
                out.append("<li><code>${escapeHtml(reExport.alias.getOrThrow())}</code>")
                if (reExport.state == "resolved") { out.append(" → package") }
                out.append(" <code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            if (reExport.bindings.isEmpty()) {
                out.append("<li><code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            for (binding in reExport.bindings) {
                out.append("<li><code>${escapeHtml(binding.exposedName)}</code> → ")
                var firstTarget = true
                for (targetId in binding.targetSymbolIds) {
                    if (!firstTarget) { out.append(", ") }; firstTarget = false
                    match (findSymbol(index, targetId)) {
                        case Some(target) => out.append("<a href=\"../${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(target.qualifiedName)}</code></a>")
                        case None => out.append("<code>${escapeHtml(targetId)}</code>")
                    }
                }
                out.append(" <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
            }
        }
        out.append("</ul></details>\n")
    }
    if (!pkg.sourceFiles.isEmpty()) {
        out.append("<details class=\"package-sources\"><summary id=\"sources\">${label(locale, "Source files", "源文件")} (${pkg.sourceFiles.size})</summary><ul class=\"record-list\">\n")
        for (path in pkg.sourceFiles) { out.append("<li><code>${escapeHtml(path)}</code></li>\n") }
        out.append("</ul></details>\n")
    }
}

internal func appendPackageDeclarationMetadata(out: RenderTextBuffer, symbol: SymbolDoc,
    locale: String): Unit {
    if (symbol.semantic.state == "resolved") { return }
    out.append("<details class=\"declaration-metadata\"><summary>${label(locale, "Declaration metadata", "声明元数据")}</summary><p class=\"meta\">semantic: ${escapeHtml(symbol.semantic.state)}</p></details>\n")
}
