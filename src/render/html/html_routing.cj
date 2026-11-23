protected package cjdoc.render.html

import cjdoc.render.routes.{ApiHtmlRoutes, agentDeclarationMarkdownPath, apiHtmlFileHref, apiHtmlWebPath}
import cjdoc.render.publication.{
    DeclarationGroupCatalog, SourceReferenceProjection, indexSymbols, isTypeDeclaration,
    renderabilityIndex}
import cjdoc.render.routes.{
    ApiRouteProjection, boundedHtmlSlug, routeKey, historicalPackagePagePath, symbolPagePath,
    symbolReadablePagePath, navigationHref, isCapturedLocalApiLink, publicApiRootPrefix, label,
    pageRootPrefix}
import cjdoc.render.codec.{assetMediaExtension, decodeAssetBase64}
import cjdoc.render.foundation.RenderArtifactStore
import cjdoc.model.*
import std.collection.*
import std.sort.*

protected func renderSymbolAlias(symbol: SymbolDoc, locale: String, aliasFile: String,
    targetFile: String, unprefixedLocale: String): String {
    let prefix = pageRootPrefix(aliasFile)
    let targetPrefix = publicApiRootPrefix(prefix, unprefixedLocale)
    let target = targetPrefix + apiHtmlFileHref(targetFile)
    let w = HtmlWriter()
    w.doctype()
    w.open("html", attrs: [htmlAttr("lang", locale)])
    w.open("head")
    w.void("meta", attrs: [htmlAttr("charset", "utf-8")])
    w.void("meta", attrs: [htmlAttr("name", "viewport"),
        htmlAttr("content", "width=device-width,initial-scale=1")])
    w.void("meta", attrs: [htmlAttr("http-equiv", "Content-Security-Policy"),
        htmlAttr("content", HTML_PAGE_CSP)])
    w.textElement("title", readerQualifiedName(symbol))
    w.void("link", attrs: [htmlAttr("rel", "canonical"),
        htmlHref(SafeUrl.siteRoute(targetPrefix + apiHtmlWebPath(targetFile)))])
    w.void("link", attrs: [htmlAttr("rel", "describedby"), htmlAttr("type", "text/plain"),
        htmlHref(SafeUrl.siteRoute(prefix + "llms.txt"))])
    w.void("link", attrs: [htmlAttr("rel", "alternate"), htmlAttr("type", "text/markdown"),
        htmlHref(SafeUrl.siteRoute(prefix + agentDeclarationMarkdownPath(symbol)))])
    w.close("head")
    w.open("body", attrs: [htmlAttr("data-cjdoc-route", "symbol-alias")])
    w.open("main")
    w.element("a", [htmlFlag("data-cjdoc-alias-target"),
        htmlHref(SafeUrl.siteRoute(target))], { link =>
        link.text(label(locale, "Open API documentation", "打开 API 文档") + ": " +
            readerQualifiedName(symbol))
    })
    w.close("main")
    w.open("script", attrs: [htmlSrc(SafeUrl.siteRoute(prefix + "symbol-alias.js")),
        htmlFlag("defer")])
    w.close("script")
    w.close("body")
    w.close("html")
    w.toString()
}

protected let HTML_SYMBOL_ALIAS_SCRIPT = #"
(function () {
  'use strict';
  var link = document.querySelector('[data-cjdoc-alias-target]');
  if (!link) return;
  var target = new URL(link.getAttribute('href'), location.href);
  if (target.protocol === 'http:' || target.protocol === 'https:') {
    target.pathname = target.pathname.slice(0, -'index.html'.length);
  }
  target.search = location.search;
  target.hash = location.hash;
  link.href = target.href;
  location.replace(target.href);
}());
"#

protected func assetOutputPath(asset: AssetDoc): String {
    "assets/asset-${boundedHtmlSlug(asset.id)}.${assetMediaExtension(asset.mediaType)}"
}

protected class ProjectedPackage {
    protected let source: PackageDoc
    protected let sourceFiles = ArrayList<String>()
    protected let symbols = ArrayList<SymbolDoc>()
    private let sourceFileSet = HashSet<String>()

    init(source: PackageDoc) { this.source = source }

    func addSymbol(symbol: SymbolDoc): Unit {
        symbols.add(symbol)
        if (sourceFileSet.add(symbol.source.path)) { sourceFiles.add(symbol.source.path) }
    }
}

protected class ProjectedModule {
    protected let source: ModuleDoc
    protected let packages = ArrayList<ProjectedPackage>()

    init(source: ModuleDoc) { this.source = source }
}

protected class RenderProjection {
    protected let allIndex: HashMap<String, SymbolDoc>
    protected let sourceReferences: SourceReferenceProjection
    protected let catalog: DeclarationGroupCatalog
    protected let snapshotId: String
    protected let apiRoutes: ?ApiHtmlRoutes
    protected let unprefixedApiLocale: String
    protected let visibleIndex = HashMap<String, SymbolDoc>()
    protected let visibleSymbols = ArrayList<SymbolDoc>()
    protected let packages = ArrayList<ProjectedPackage>()
    protected let modules = ArrayList<ProjectedModule>()
    protected let membersByOwner = HashMap<String, ArrayList<SymbolDoc>>()
    protected let topLevelByPackage = HashMap<String, ArrayList<SymbolDoc>>()
    let sidebarLabelsByPackage = HashMap<String, HashMap<String, String>>()
    private let memberBrowsers = HashMap<String, HtmlMemberBrowser>()
    private let documentation: DocumentationSet
    private var deprecationIndex: ?DeprecationProjection = None

    func deprecations(): DeprecationProjection {
        if (let Some(index) <- deprecationIndex) { return index }
        let index = DeprecationProjection(documentation, this)
        deprecationIndex = Some(index)
        index
    }

    private let apiGuideIndexes = HashMap<String, CapturedApiGuideIndex>()

    protected func symbolFileHref(symbolId: String): String {
        apiRoutes.getOrThrow().fileHref(symbolId)
    }

    protected func packageFile(moduleId: String, name: String): String {
        apiRoutes.getOrThrow().packageFile(moduleId, name)
    }

    protected func packageFileHref(moduleId: String, name: String): String {
        apiHtmlFileHref(packageFile(moduleId, name))
    }

    protected func publicApiPrefix(resourcePrefix: String): String {
        publicApiRootPrefix(resourcePrefix, unprefixedApiLocale)
    }

    protected func publicSymbolHref(resourcePrefix: String, symbolId: String): String {
        publicApiPrefix(resourcePrefix) + symbolFileHref(symbolId)
    }

    protected func apiPageResourcePrefix(file: String, mounted: Bool): String {
        let prefix = pageRootPrefix(file)
        if (mounted) { prefix + unprefixedApiLocale + "/" } else { prefix }
    }

    // Standalone and inline members share the same visible, locale-selected usages.
    func apiGuides(documentation: DocumentationSet, locale: String): CapturedApiGuideIndex {
        match (apiGuideIndexes.get(locale)) {
            case Some(value) => value
            case None =>
                let value = CapturedApiGuideIndex(documentation, this, locale)
                apiGuideIndexes[locale] = value
                value
        }
    }

    protected func members(owner: SymbolDoc): HtmlMemberBrowser {
        match (memberBrowsers.get(owner.id)) {
            case Some(value) => value
            case None =>
                let value = HtmlMemberBrowser(owner, this)
                memberBrowsers[owner.id] = value
                value
        }
    }

    protected init(documentation: DocumentationSet, snapshotId!: String = "",
        buildApiRoutes!: Bool = false, routeProjection!: ApiRouteProjection = ReadablePackages,
        apiRoutes!: ?ApiHtmlRoutes = None, unprefixedApiLocale!: String = "") {
        this.documentation = documentation
        this.snapshotId = snapshotId
        this.unprefixedApiLocale = unprefixedApiLocale
        this.sourceReferences = SourceReferenceProjection(documentation)
        allIndex = indexSymbols(documentation)
        let renderable = renderabilityIndex(documentation, allIndex)
        for (symbol in documentation.declarations) {
            if (renderable[symbol.id]) {
                visibleSymbols.add(symbol)
                visibleIndex[symbol.id] = symbol
            }
        }
        catalog = DeclarationGroupCatalog(documentation.metadata, visibleSymbols,
            documentation.readingLanguage.getOrDefault({ => "en" }))

        for (symbol in visibleSymbols) {
            let groups = if (symbol.ownerId.isSome()) { membersByOwner } else { topLevelByPackage }
            let key = if (symbol.ownerId.isSome()) {
                symbol.ownerId.getOrThrow()
            } else {
                routeKey(symbol.moduleId, symbol.packageName)
            }
            match (groups.get(key)) {
                case Some(values) => values.add(symbol)
                case None => groups[key] = ArrayList<SymbolDoc>([symbol])
            }
        }

        let packagesByRoute = HashMap<String, ProjectedPackage>()
        for (pkg in documentation.packages) {
            let projected = ProjectedPackage(pkg)
            packagesByRoute[routeKey(pkg.moduleId, pkg.name)] = projected
        }
        for (symbol in visibleSymbols) {
            match (packagesByRoute.get(routeKey(symbol.moduleId, symbol.packageName))) {
                case Some(projected) => projected.addSymbol(symbol)
                case None => () // Typed-domain validation reports the package mismatch first.
            }
        }
        for (pkg in documentation.packages) {
            let projected = packagesByRoute[routeKey(pkg.moduleId, pkg.name)]
            if (!projected.symbols.isEmpty() || !pkg.reExports.isEmpty()) {
                sort(projected.sourceFiles)
                packages.add(projected)
            }
        }
        this.apiRoutes = if (buildApiRoutes) {
            let packageSources = ArrayList<PackageDoc>()
            for (projected in packages) { packageSources.add(projected.source) }
            Some(ApiHtmlRoutes(documentation, visibleSymbols, membersByOwner,
                packageSources.toArray(), routeProjection))
        } else { apiRoutes }

        let modulesById = HashMap<String, ProjectedModule>()
        for (module in documentation.modules) {
            let projected = ProjectedModule(module)
            modulesById[module.id] = projected
        }
        for (pkg in packages) {
            match (modulesById.get(pkg.source.moduleId)) {
                case Some(projected) => projected.packages.add(pkg)
                case None => () // Typed-domain validation reports the module mismatch first.
            }
        }
        for (module in documentation.modules) {
            let projected = modulesById[module.id]
            if (!projected.packages.isEmpty()) { modules.add(projected) }
        }
    }
}

protected func groupTopLevelByPackage(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    projection.topLevelByPackage
}

protected func groupMembersByOwner(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    projection.membersByOwner
}

internal func findProjectedModule(projection: RenderProjection, id: String): ?ModuleDoc {
    for (module in projection.modules) {
        if (module.source.id == id) { return Some(module.source) }
    }
    None
}

internal func findSymbol(index: HashMap<String, SymbolDoc>, id: String): ?SymbolDoc {
    index.get(id)
}

internal func registerTypeLinkKey(index: HashMap<String, String>, key: String,
    symbolId: String): Unit {
    if (key.isEmpty()) { return }
    match (index.get(key)) {
        case Some(existing) =>
            if (existing != symbolId) { index[key] = "" }
        case None => index[key] = symbolId
    }
}

internal func packageRelativeTypeName(symbol: SymbolDoc): String {
    if (symbol.qualifiedName == symbol.packageName) { return "" }
    let prefix = symbol.packageName + "."
    if (symbol.qualifiedName.startsWith(prefix)) {
        return symbol.qualifiedName[prefix.size..]
    }
    ""
}

// Use the same identity keys for reader relationship reconciliation and
// public type navigation. Only the visible index may supply published URLs.
private func registerTypeLinkKeys(index: HashMap<String, String>, symbol: SymbolDoc,
    moduleNameById: HashMap<String, String>): Unit {
    registerTypeLinkKey(index, symbol.id, symbol.id)
    registerTypeLinkKey(index, symbol.qualifiedName, symbol.id)
    match (moduleNameById.get(symbol.moduleId)) {
        case Some(moduleName) =>
            registerTypeLinkKey(index, "${moduleName}.${symbol.qualifiedName}", symbol.id)
            let relative = packageRelativeTypeName(symbol)
            if (!relative.isEmpty()) {
                registerTypeLinkKey(index, "${moduleName}.${relative}", symbol.id)
            }
        case None => ()
    }
}

protected class HtmlTypeUsage {
    protected let source: SymbolDoc
    protected let kind: String

    init(source: SymbolDoc, kind: String) {
        this.source = source
        this.kind = kind
    }
}

protected class HtmlTypeLinkIndex {
    // Prebound navigation decisions take precedence; canonical semantic names
    // remain a legacy-input fallback only when no navigation fact is present.
    private let symbolIdByCanonical = HashMap<String, String>()
    // Only for comparing identities during rendering; never used for public links.
    // Ambiguous canonical keys map to the empty sentinel, not an arbitrary target.
    private let unfilteredSymbolIdByCanonical = HashMap<String, String>()
    protected let projection: RenderProjection
    private let reverseUsagesByTarget = HashMap<String, ArrayList<HtmlTypeUsage>>()

    protected init(documentation: DocumentationSet, projection: RenderProjection) {
        this.projection = projection
        let moduleNameById = HashMap<String, String>()
        for (module in documentation.modules) { moduleNameById[module.id] = module.name }
        for (symbol in projection.allIndex.values()) {
            if (isTypeDeclaration(symbol)) {
                registerTypeLinkKeys(unfilteredSymbolIdByCanonical, symbol, moduleNameById)
            }
        }
        for (symbol in projection.visibleSymbols) {
            if (!isTypeDeclaration(symbol)) { continue }
            registerTypeLinkKeys(symbolIdByCanonical, symbol, moduleNameById)
        }
        for (symbol in projection.visibleSymbols) {
            for (parameter in symbol.parameters) {
                registerTypeUsage(symbol, parameter.typeRef, "parameter")
            }
            match (symbol.returnType) {
                case Some(returnType) =>
                    let kind = if (symbol.kind == "property" || symbol.kind == "variable") {
                        "field"
                    } else { "return" }
                    registerTypeUsage(symbol, returnType, kind)
                case None => ()
            }
            for (relationship in symbol.typeRelationships) {
                registerTypeUsage(symbol, relationship.target, relationship.kind)
            }
        }
        for (usages in reverseUsagesByTarget.values()) {
            sort(usages, lessThan: { left, right =>
                let leftKey = "${left.source.qualifiedName}|${left.source.id}|${left.kind}"
                let rightKey = "${right.source.qualifiedName}|${right.source.id}|${right.kind}"
                leftKey < rightKey
            }, stable: true)
        }
    }

    // Private declarations can be matched without exposing their identity.
    // Reconcile exactly the same canonical forms accepted by visible links.
    protected func sameUnfilteredTarget(typeRef: TypeRef, symbolId: String): Bool {
        if (typeRef.semantic.state != "resolved") { return false }
        match (typeRef.semantic.canonical) {
            case Some(canonical) => match (unfilteredSymbolIdByCanonical.get(canonical)) {
                case Some(id) => !id.isEmpty() && id == symbolId
                case None => false
            }
            case None => false
        }
    }

    private func targetSymbolId(typeRef: TypeRef): ?String {
        if (let Some(navigation) <- typeRef.navigation) {
            if (!isCapturedLocalApiLink(navigation) || !projection.visibleIndex.contains(navigation.symbolKey)) {
                return None
            }
            return Some(navigation.symbolKey)
        }
        if (typeRef.kind == "typeParameter") { return None }
        if (typeRef.kind == "primitive" || typeRef.kind == "optional" ||
            typeRef.kind == "tuple" || typeRef.kind == "function") {
            let provider = typeRef.semantic.provider.getOrDefault({ => "" })
            if (provider.isEmpty() || provider == "ast" || provider == "source") { return None }
        }
        if (typeRef.semantic.state != "resolved") { return None }
        match (typeRef.semantic.canonical) {
            case Some(canonical) => match (symbolIdByCanonical.get(canonical)) {
                case Some(symbolId) => if (symbolId.isEmpty()) { None } else { Some(symbolId) }
                case None => None
            }
            case None => None
        }
    }

    private func registerTypeUsage(source: SymbolDoc, typeRef: TypeRef, kind: String): Unit {
        match (targetSymbolId(typeRef)) {
            case Some(targetId) =>
                if (targetId != source.id) {
                    match (reverseUsagesByTarget.get(targetId)) {
                        case Some(usages) =>
                            var duplicate = false
                            for (existing in usages) {
                                if (existing.source.id == source.id && existing.kind == kind) {
                                    duplicate = true
                                    break
                                }
                            }
                            if (!duplicate) { usages.add(HtmlTypeUsage(source, kind)) }
                        case None =>
                            reverseUsagesByTarget[targetId] = ArrayList<HtmlTypeUsage>([HtmlTypeUsage(source, kind)])
                    }
                }
            case None => ()
        }
        for (argument in typeRef.arguments) { registerTypeUsage(source, argument, kind) }
    }

    protected func targetUrl(typeRef: TypeRef): ?String {
        if (let Some(navigation) <- typeRef.navigation) {
            return projectedNavigationHref("", navigation, projection.apiRoutes)
        }
        match (targetSymbolId(typeRef)) {
            case Some(symbolId) => targetUrlForSymbolId(symbolId)
            case None => None
        }
    }

    func targetUrlForSymbolId(symbolId: String): ?String {
        if (!projection.visibleIndex.contains(symbolId)) { return None }
        Some(projection.symbolFileHref(symbolId))
    }

    func targetHref(rootPrefix: String, url: String, navigation: ?TypeNavigation): ?String {
        let isLocal = navigation.map(isCapturedLocalApiLink).getOrDefault({ => true })
        let prefix = if (isLocal) { projection.publicApiPrefix(rootPrefix) } else { rootPrefix }
        navigationHref(prefix, url)
    }

    protected func reverseUsages(symbolId: String): ArrayList<HtmlTypeUsage> {
        match (reverseUsagesByTarget.get(symbolId)) {
            case Some(usages) => usages
            case None => ArrayList<HtmlTypeUsage>()
        }
    }

    func shouldShowUnavailableTitle(typeRef: TypeRef): Bool {
        if (typeRef.navigation.isSome()) { return targetUrl(typeRef).isNone() }
        if (typeRef.semantic.state == "unavailable") { return true }
        if (typeRef.semantic.state != "resolved") { return false }
        match (targetUrl(typeRef)) {
            case Some(_) => false
            case None => true
        }
    }
}

internal func projectedNavigationHref(rootPrefix: String, value: TypeNavigation,
    routes: ?ApiHtmlRoutes, unprefixedLocale!: String = ""): ?String {
    if (value.state != "resolved") { return None }
    if (isCapturedLocalApiLink(value)) {
        match (routes) {
            case Some(index) => return index.filePath(value.symbolKey)
                .map({ path => publicApiRootPrefix(rootPrefix, unprefixedLocale) + apiHtmlFileHref(path) })
            case None => return None
        }
    }
    navigationHref(rootPrefix, value.url)
}

protected func buildAssetLookup(assets: ArrayList<AssetDoc>,
    prefix!: String = ""): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in assets) {
        let path = prefix + assetOutputPath(asset)
        lookup["id:${asset.id}"] = path
        lookup["path:${asset.sourcePath}"] = path
    }
    lookup
}

internal func selectAsset(selected: HashSet<String>, assetId: String): Unit {
    let _ = selected.add(assetId)
}

internal func collectReferencedAssets(node: MarkdownNode,
    references: HashMap<String, String>, selected: HashSet<String>): Unit {
    if (node.kind == "image") {
        var destination = node.literal
        if (destination.startsWith("./")) { destination = destination[2..] }
        match (references.get(destination)) {
            case Some(assetId) => selectAsset(selected, assetId)
            case None => ()
        }
    }
    for (child in node.children) {
        collectReferencedAssets(child, references, selected)
    }
}

protected func projectAssets(documentation: DocumentationSet,
    projection: RenderProjection, pages!: Array<DocumentationPage> = []): ArrayList<AssetDoc> {
    let references = HashMap<String, String>()
    for (asset in documentation.assets) {
        references[asset.id] = asset.id
        references[asset.sourcePath] = asset.id
    }
    let selected = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.documentation) {
            case Some(comment) =>
                collectReferencedAssets(comment.markdown, references, selected)
                for (tag in comment.tags) {
                    if (let Some(tree) <- tag.descriptionMarkdown) {
                        collectReferencedAssets(tree, references, selected)
                    }
                    if (tag.name != "example") { continue }
                    if (let Some(tree) <- tag.exampleMarkdown) {
                        collectReferencedAssets(tree, references, selected)
                    }
                }
            case None => ()
        }
    }
    for (page in pages) { collectReferencedAssets(page.markdown, references, selected) }
    let assets = ArrayList<AssetDoc>()
    for (asset in documentation.assets) {
        if (selected.contains(asset.id)) { assets.add(asset) }
    }
    assets
}

protected func appendAssetArtifacts(artifacts: RenderArtifactStore,
    assets: ArrayList<AssetDoc>, formatRoot: String): Unit {
    for (asset in assets) {
        let _ = artifacts.addOwnedBytes("${formatRoot}/${assetOutputPath(asset)}",
            asset.mediaType, decodeAssetBase64(asset.base64))
    }
}

protected func validateHtmlRouting(projection: RenderProjection, assets: ArrayList<AssetDoc>): Unit {
    let paths = HashSet<String>()
    for (path in ["index.html", "search-index.json", "search-index.js", "sidebar-index.js", "search.js", "theme-bootstrap.js", "symbol-alias.js", "style.css"]) {
        let _ = paths.add(path)
    }
    for (pkg in projection.packages) {
        let path = historicalPackagePagePath(pkg.source.moduleId, pkg.source.name)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for package '${pkg.source.name}'")
        }
    }
    for (symbol in projection.visibleSymbols) {
        let path = symbolPagePath(symbol)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for SymbolId '${symbol.id}'")
        }
        if (!paths.add(symbolReadablePagePath(symbol))) {
            throw IllegalArgumentException("HTML alias collision for SymbolId '${symbol.id}'")
        }
    }
    for (asset in assets) {
        let path = assetOutputPath(asset)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for asset '${asset.id}'")
        }
    }
}
