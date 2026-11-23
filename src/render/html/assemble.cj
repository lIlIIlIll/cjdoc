protected package cjdoc.render.html

import cjdoc.model.*
import cjdoc.render.search.DocumentationSearchProjection
import cjdoc.render.foundation.RenderArtifactStore
import cjdoc.render.routes.{
    historicalPackagePagePath, selectedDocumentationPages, symbolPagePath, symbolReadablePagePath}
import cjdoc.render.browser.{HTML_THEME_BOOTSTRAP_SCRIPT, HTML_READER_BUNDLE}

protected func appendHtmlArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, buildSearch: () -> DocumentationSearchProjection, projection: RenderProjection,
    locale!: String = "en", docVersion!: ?String = None,
    htmlFonts!: HtmlFontOptions = HtmlFontOptions(), mountPage!: Option<(String, String) -> Unit> = None): Unit {
        let index = projection.visibleIndex
        let typeLinkIndex = HtmlTypeLinkIndex(documentation, projection)
        let projectedAssets = projectAssets(documentation, projection,
            pages: selectedDocumentationPages(documentation, locale))
        let assetLookup = buildAssetLookup(projectedAssets)
        validateHtmlRouting(projection, projectedAssets)
        let searchIndex = renderSearchIndex(buildSearch())
        let searchSignatures = renderSearchSignatureIndex(documentation, projection)
        let _ = artifacts.addText("html/index.html", "text/html; charset=utf-8",
            renderHtmlIndex(documentation, projection, locale: locale, docVersion: docVersion))
        let _ = artifacts.addText("html/search-index.json", "application/json", searchIndex)
        let _ = artifacts.addText("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex, searchSignatures))
        let _ = artifacts.addText("html/sidebar-index.js", "text/javascript; charset=utf-8",
            renderSidebarIndexScript(projection, locale))
        let _ = artifacts.addText("html/theme-bootstrap.js", "text/javascript; charset=utf-8",
            HTML_THEME_BOOTSTRAP_SCRIPT)
        let _ = artifacts.addText("html/search.js", "text/javascript; charset=utf-8",
            HTML_READER_BUNDLE)
        let _ = artifacts.addText("html/symbol-alias.js", "text/javascript; charset=utf-8",
            HTML_SYMBOL_ALIAS_SCRIPT)
        let _ = artifacts.addText("html/style.css", "text/css; charset=utf-8",
            renderHtmlStylesheet(htmlFonts))
        for (pkg in projection.packages) {
            let canonical = projection.packageFile(pkg.source.moduleId, pkg.source.name)
            let legacy = historicalPackagePagePath(pkg.source.moduleId, pkg.source.name)
            for (file in [canonical, legacy]) {
                let _ = artifacts.addText("html/" + file, "text/html; charset=utf-8",
                    renderPackagePage(documentation, projection, pkg, file, locale: locale, docVersion: docVersion))
            }
        }
        let routes = projection.apiRoutes.getOrThrow()
        for (symbol in projection.visibleSymbols) {
            let pageFile = routes.filePath(symbol.id).getOrThrow()
            for (alias in [symbolPagePath(symbol), symbolReadablePagePath(symbol)]) {
                let _ = artifacts.addText("html/" + alias, "text/html; charset=utf-8",
                    renderSymbolAlias(symbol, locale, alias, pageFile, projection.unprefixedApiLocale))
            }
            let _ = artifacts.addText("html/" + pageFile, "text/html; charset=utf-8",
                renderSymbolPage(documentation, projection, index, symbol, assetLookup,
                    typeLinkIndex, locale: locale, docVersion: docVersion))
            if (let Some(mount) <- mountPage) {
                mount(pageFile, renderSymbolPage(documentation, projection, index, symbol,
                    assetLookup, typeLinkIndex, locale: locale, docVersion: docVersion, mounted: true))
            }
        }
        for (choice in routes.selectionPages) {
            let _ = artifacts.addText("html/" + choice.file, "text/html; charset=utf-8",
                renderApiSelectionPage(documentation, projection, choice, locale, docVersion))
            if (let Some(mount) <- mountPage) {
                mount(choice.file,
                    renderApiSelectionPage(documentation, projection, choice, locale, docVersion, mounted: true))
            }
        }
        appendAssetArtifacts(artifacts, projectedAssets, "html")
}
