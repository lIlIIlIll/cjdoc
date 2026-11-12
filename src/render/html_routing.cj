package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal func appendSlugByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789abcdef"
    let high = Int64((byte >> 4) & 0x0F)
    let low = Int64(byte & 0x0F)
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

internal func htmlStableSlug(value: String): String {
    if (value.isEmpty()) { return "root" }
    let out = StringBuilder()
    for (byte in value.toArray()) { appendSlugByte(out, byte) }
    out.toString()
}

internal func stableFileHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

internal func boundedHtmlSlug(value: String): String {
    // Keep staged Windows paths below MAX_PATH after the transaction prefix.
    let slug = htmlStableSlug(value)
    if (slug.size <= 96) { return slug }
    slug[..64] + "--" + stableFileHash(value)
}

internal func routeKey(moduleId: String, packageName: String): String {
    "${moduleId.size}:${moduleId}${packageName}"
}

internal func packagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.html"
}

protected func symbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.html"
}

// Human-readable aliases do not replace the stable SymbolId routes. Restrict
// the label to portable ASCII and disambiguate overloads/modules by identity.
internal func symbolReadablePagePath(symbol: SymbolDoc): String {
    let name = StringBuilder()
    var length: Int64 = 0
    var separator = false
    for (byte in symbol.qualifiedName.toArray()) {
        if (length >= 48) { break }
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_') {
            if (separator && length > 0) {
                if (length + 2 > 48) { break }
                name.append("-"); length++
            }
            name.append(String.fromUtf8([byte]))
            length++
            separator = false
        } else { separator = true }
    }
    let readable = if (length == 0) { "api" } else { name.toString() }
    "symbols/${readable}-${stableFileHash(symbol.id)}.html"
}

internal func renderSymbolAlias(symbol: SymbolDoc, locale: String): String {
    let target = symbolPagePath(symbol)["symbols/".size..]
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
        htmlHref(SafeUrl.relative(target).getOrThrow())])
    w.void("link", attrs: [htmlAttr("rel", "describedby"), htmlAttr("type", "text/plain"),
        htmlHref(SafeUrl.siteRoute("../llms.txt"))])
    w.void("link", attrs: [htmlAttr("rel", "alternate"), htmlAttr("type", "text/markdown"),
        htmlHref(SafeUrl.siteRoute("../" + agentDeclarationMarkdownPath(symbol)))])
    w.close("head")
    w.open("body", attrs: [htmlAttr("data-cjdoc-route", "symbol-alias")])
    w.open("main")
    w.element("a", [htmlFlag("data-cjdoc-alias-target"),
        htmlHref(SafeUrl.relative(target).getOrThrow())], { link =>
        link.text(label(locale, "Open API documentation", "打开 API 文档") + ": " +
            readerQualifiedName(symbol))
    })
    w.close("main")
    w.open("script", attrs: [htmlSrc(SafeUrl.siteRoute("../symbol-alias.js")),
        htmlFlag("defer")])
    w.close("script")
    w.close("body")
    w.close("html")
    w.toString()
}

internal let HTML_SYMBOL_ALIAS_SCRIPT = #"
(function () {
  'use strict';
  var link = document.querySelector('[data-cjdoc-alias-target]');
  if (!link) return;
  var target = new URL(link.getAttribute('href'), location.href);
  target.search = location.search;
  target.hash = location.hash;
  link.href = target.href;
  location.replace(target.href);
}());
"#

internal func symbolAnchor(symbol: SymbolDoc): String {
    "symbol-${htmlStableSlug(symbol.id)}"
}

internal func assetOutputPath(asset: AssetDoc): String {
    "assets/asset-${boundedHtmlSlug(asset.id)}.${assetMediaExtension(asset.mediaType)}"
}

internal func isContainerDeclaration(symbol: SymbolDoc): Bool {
    isDocIrContainerKind(symbol.kind)
}

internal func indexSymbols(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.declarations) { index[symbol.id] = symbol }
    index
}

internal class ProjectedPackage {
    let source: PackageDoc
    let sourceFiles = ArrayList<String>()
    let symbols = ArrayList<SymbolDoc>()
    private let sourceFileSet = HashSet<String>()

    init(source: PackageDoc) { this.source = source }

    func addSymbol(symbol: SymbolDoc): Unit {
        symbols.add(symbol)
        if (sourceFileSet.add(symbol.source.path)) { sourceFiles.add(symbol.source.path) }
    }
}

internal class ProjectedModule {
    let source: ModuleDoc
    let packages = ArrayList<ProjectedPackage>()

    init(source: ModuleDoc) { this.source = source }
}

internal class RenderProjection {
    let allIndex: HashMap<String, SymbolDoc>
    let sourceReferences: SourceReferenceProjection
    let catalog: DeclarationGroupCatalog
    let snapshotId: String
    let visibleIndex = HashMap<String, SymbolDoc>()
    let visibleSymbols = ArrayList<SymbolDoc>()
    let packages = ArrayList<ProjectedPackage>()
    let modules = ArrayList<ProjectedModule>()
    let membersByOwner = HashMap<String, ArrayList<SymbolDoc>>()
    let topLevelByPackage = HashMap<String, ArrayList<SymbolDoc>>()
    let sidebarLabelsByPackage = HashMap<String, HashMap<String, String>>()
    private let memberBrowsers = HashMap<String, HtmlMemberBrowser>()

    private let apiGuideIndexes = HashMap<String, CapturedApiGuideIndex>()

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

    func members(owner: SymbolDoc): HtmlMemberBrowser {
        match (memberBrowsers.get(owner.id)) {
            case Some(value) => value
            case None =>
                let value = HtmlMemberBrowser(owner, this)
                memberBrowsers[owner.id] = value
                value
        }
    }

    init(documentation: DocumentationSet, snapshotId!: String = "") {
        this.snapshotId = snapshotId
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

internal func groupTopLevelByPackage(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    projection.topLevelByPackage
}

internal func groupMembersByOwner(projection: RenderProjection):
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

private func visibleThroughOwners(symbol: SymbolDoc, audience: String,
    index: HashMap<String, SymbolDoc>): Bool {
    var current: ?SymbolDoc = Some(symbol)
    let visited = HashSet<String>()
    while (current.isSome()) {
        let value = current.getOrThrow()
        if (!visited.add(value.id)) { return false }
        if (!isVisibleForAudience(value, audience)) { return false }
        current = match (value.ownerId) {
            case Some(ownerId) => index.get(ownerId)
            case None => None
        }
    }
    true
}

private func addVisibleOwnerId(values: HashSet<String>, ownerId: String): Unit {
    let _ = values.add(ownerId)
}

internal func visibleExtensionContainerIds(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashSet<String> {
    let audience = documentation.configuration.audience
    let ownersWithVisibleMembers = HashSet<String>()
    for (member in documentation.declarations) {
        if (!isVisibleForAudience(member, audience)) { continue }
        match (member.ownerId) {
            case Some(ownerId) => addVisibleOwnerId(ownersWithVisibleMembers, ownerId)
            case None => ()
        }
    }
    let result = HashSet<String>()
    for (extension in documentation.declarations) {
        if (extension.kind != "extend" || !ownersWithVisibleMembers.contains(extension.id)) {
            continue
        }
        for (relation in extension.symbolRelationships) {
            if (relation.kind != "extensionTarget" || relation.state != "resolved") { continue }
            match (relation.targetSymbolId) {
                case Some(targetId) => match (index.get(targetId)) {
                    case Some(target) =>
                        if (visibleThroughOwners(target, audience, index)) {
                            let _ = result.add(extension.id)
                            break
                        }
                    case None => ()
                }
                case None => ()
            }
        }
    }
    result
}

internal func renderabilityIndex(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashMap<String, Bool> {
    let results = HashMap<String, Bool>()
    let visibleExtensionContainers = visibleExtensionContainerIds(documentation, index)
    for (root in documentation.declarations) {
        if (results.contains(root.id)) { continue }
        let path = ArrayList<SymbolDoc>()
        var current: ?SymbolDoc = Some(root)
        var inherited = true
        while (current.isSome()) {
            let symbol = current.getOrThrow()
            match (results.get(symbol.id)) {
                case Some(value) =>
                    inherited = value
                    break
                case None => ()
            }
            path.add(symbol)
            if (!isVisibleForAudience(symbol, documentation.configuration.audience) &&
                !visibleExtensionContainers.contains(symbol.id)) {
                inherited = false
                break
            }
            current = match (symbol.ownerId) {
                case Some(ownerId) => index.get(ownerId)
                case None => None
            }
        }
        var position = path.size
        while (position > 0) {
            position--
            let symbol = path[position]
            inherited = inherited &&
                (isVisibleForAudience(symbol, documentation.configuration.audience) ||
                    visibleExtensionContainers.contains(symbol.id))
            results[symbol.id] = inherited
        }
    }
    results
}


internal func symbolUrl(index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): String {
    // Every visible declaration has a stable detail page. Keeping routing uniform
    // lets package pages remain indexes rather than mixing summaries and contracts.
    symbolPagePath(symbol)
}

internal func isTypeDeclaration(symbol: SymbolDoc): Bool {
    symbol.kind == "class" || symbol.kind == "struct" || symbol.kind == "interface" ||
        symbol.kind == "enum" || symbol.kind == "typeAlias"
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

internal class HtmlTypeUsage {
    let source: SymbolDoc
    let kind: String

    init(source: SymbolDoc, kind: String) {
        this.source = source
        this.kind = kind
    }
}

internal class HtmlTypeLinkIndex {
    // Prebound navigation decisions take precedence; canonical semantic names
    // remain a legacy-input fallback only when no navigation fact is present.
    private let symbolIdByCanonical = HashMap<String, String>()
    // Only for comparing identities during rendering; never used for public links.
    // Ambiguous canonical keys map to the empty sentinel, not an arbitrary target.
    private let unfilteredSymbolIdByCanonical = HashMap<String, String>()
    private let urlBySymbolId = HashMap<String, String>()
    private let reverseUsagesByTarget = HashMap<String, ArrayList<HtmlTypeUsage>>()

    init(documentation: DocumentationSet, projection: RenderProjection) {
        let moduleNameById = HashMap<String, String>()
        for (module in documentation.modules) { moduleNameById[module.id] = module.name }
        for (symbol in projection.allIndex.values()) {
            if (isTypeDeclaration(symbol)) {
                registerTypeLinkKeys(unfilteredSymbolIdByCanonical, symbol, moduleNameById)
            }
        }
        for (symbol in projection.visibleSymbols) {
            urlBySymbolId[symbol.id] = symbolUrl(projection.visibleIndex, symbol)
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
    internal func sameUnfilteredTarget(typeRef: TypeRef, symbolId: String): Bool {
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
            if (navigation.state != "resolved" || !urlBySymbolId.contains(navigation.symbolKey)) { return None }
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

    func targetUrl(typeRef: TypeRef): ?String {
        if (let Some(navigation) <- typeRef.navigation) {
            if (navigation.state != "resolved") { return None }
            if (navigation.symbolKey.startsWith("cjdoc:v2:") && !urlBySymbolId.contains(navigation.symbolKey)) { return None }
            return navigationHref("", navigation.url)
        }
        match (targetSymbolId(typeRef)) {
            case Some(symbolId) => urlBySymbolId.get(symbolId)
            case None => None
        }
    }

    func targetUrlForSymbolId(symbolId: String): ?String {
        urlBySymbolId.get(symbolId)
    }

    func reverseUsages(symbolId: String): ArrayList<HtmlTypeUsage> {
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


// Prebound document-root paths are rebased; absolute web URLs stay absolute.
internal func navigationHref(rootPrefix: String, url: String): ?String {
    if (url.isEmpty() || url.contains("\\")) { return None }
    for (byte in url.toArray()) {
        if (byte <= 0x20 || byte == 0x7F || byte == b'"' || byte == b'<' || byte == b'>') { return None }
    }
    if (url.startsWith("https://") || url.startsWith("http://")) {
        return if (isSafeAbsoluteDocumentationUrl(url)) { Some(url) } else { None }
    }
    let relative = url.removePrefix("./")
    let path = relative.split("#", 2)[0].split("?", 2)[0]
    if (!safeRelativePath(path) || !isSafeDocumentationRoute(relative)) { return None }
    Some(rootPrefix + relative)
}

internal func buildAssetLookup(assets: ArrayList<AssetDoc>,
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

internal func projectAssets(documentation: DocumentationSet,
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

internal func appendAssetArtifacts(artifacts: RenderArtifactCollector,
    assets: ArrayList<AssetDoc>, formatRoot: String): Unit {
    for (asset in assets) {
        artifacts.addOwnedBytes("${formatRoot}/${assetOutputPath(asset)}",
            asset.mediaType, decodeAssetBase64(asset.base64))
    }
}

internal func validateHtmlRouting(projection: RenderProjection, assets: ArrayList<AssetDoc>): Unit {
    let paths = HashSet<String>()
    for (path in ["index.html", "search-index.json", "search-index.js", "sidebar-index.js", "search.js", "theme-bootstrap.js", "symbol-alias.js", "style.css"]) {
        let _ = paths.add(path)
    }
    for (pkg in projection.packages) {
        let path = packagePagePath(pkg.source.moduleId, pkg.source.name)
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
    let urls = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        let url = symbolUrl(projection.visibleIndex, symbol)
        if (!urls.add(url)) {
            throw IllegalArgumentException("non-injective HTML URL for SymbolId '${symbol.id}'")
        }
    }
}
