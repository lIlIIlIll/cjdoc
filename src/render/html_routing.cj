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
    let slug = htmlStableSlug(value)
    if (slug.size <= 160) { return slug }
    slug[..120] + "--" + stableFileHash(value)
}

internal func routeKey(moduleId: String, packageName: String): String {
    "${moduleId.size}:${moduleId}${packageName}"
}

internal func packagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.html"
}

internal func symbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.html"
}

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
    let visibleIndex = HashMap<String, SymbolDoc>()
    let visibleSymbols = ArrayList<SymbolDoc>()
    let packages = ArrayList<ProjectedPackage>()
    let modules = ArrayList<ProjectedModule>()

    init(documentation: DocumentationSet) {
        allIndex = indexSymbols(documentation)
        let renderable = renderabilityIndex(documentation, allIndex)
        for (symbol in documentation.declarations) {
            if (renderable[symbol.id]) {
                visibleSymbols.add(symbol)
                visibleIndex[symbol.id] = symbol
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
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols where symbol.ownerId.isNone()) {
        let key = routeKey(symbol.moduleId, symbol.packageName)
        match (groups.get(key)) {
            case Some(values) => values.add(symbol)
            case None => groups[key] = ArrayList<SymbolDoc>([symbol])
        }
    }
    groups
}

internal func groupMembersByOwner(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.ownerId) {
            case Some(ownerId) => match (groups.get(ownerId)) {
                case Some(values) => values.add(symbol)
                case None => groups[ownerId] = ArrayList<SymbolDoc>([symbol])
            }
            case None => ()
        }
    }
    groups
}

internal func findSymbol(index: HashMap<String, SymbolDoc>, id: String): ?SymbolDoc {
    index.get(id)
}

internal func renderabilityIndex(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashMap<String, Bool> {
    let results = HashMap<String, Bool>()
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
            if (!isVisibleForAudience(symbol, documentation.configuration.audience)) {
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
                isVisibleForAudience(symbol, documentation.configuration.audience)
            results[symbol.id] = inherited
        }
    }
    results
}

internal func containingPageSymbol(index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): ?SymbolDoc {
    if (isContainerDeclaration(symbol)) { return Some(symbol) }
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => if (isContainerDeclaration(owner)) { Some(owner) } else { None }
            case None => None
        }
        case None => None
    }
}

internal func symbolUrl(index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): String {
    match (containingPageSymbol(index, symbol)) {
        case Some(container) =>
            let page = symbolPagePath(container)
            if (container.id == symbol.id) { page } else { page + "#" + symbolAnchor(symbol) }
        case None => packagePagePath(symbol.moduleId, symbol.packageName) + "#" + symbolAnchor(symbol)
    }
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

internal class HtmlTypeLinkIndex {
    // Canonical semantic names and direct SymbolIds are lookup keys. The final
    // href is always derived from the matched SymbolId through the existing
    // routing layer.
    private let symbolIdByCanonical = HashMap<String, String>()
    private let urlBySymbolId = HashMap<String, String>()

    init(documentation: DocumentationSet, projection: RenderProjection) {
        let moduleNameById = HashMap<String, String>()
        for (module in documentation.modules) { moduleNameById[module.id] = module.name }
        for (symbol in projection.visibleSymbols) {
            urlBySymbolId[symbol.id] = symbolUrl(projection.visibleIndex, symbol)
            if (!isTypeDeclaration(symbol)) { continue }
            registerTypeLinkKey(symbolIdByCanonical, symbol.id, symbol.id)
            registerTypeLinkKey(symbolIdByCanonical, symbol.qualifiedName, symbol.id)
            match (moduleNameById.get(symbol.moduleId)) {
                case Some(moduleName) =>
                    registerTypeLinkKey(symbolIdByCanonical,
                        "${moduleName}.${symbol.qualifiedName}", symbol.id)
                    let relative = packageRelativeTypeName(symbol)
                    if (!relative.isEmpty()) {
                        registerTypeLinkKey(symbolIdByCanonical, "${moduleName}.${relative}", symbol.id)
                    }
                case None => ()
            }
        }
    }

    func targetUrl(typeRef: TypeRef): ?String {
        if (typeRef.semantic.state != "resolved") { return None }
        match (typeRef.semantic.canonical) {
            case Some(canonical) => match (symbolIdByCanonical.get(canonical)) {
                case Some(symbolId) =>
                    if (symbolId.isEmpty()) { None } else { urlBySymbolId.get(symbolId) }
                case None => None
            }
            case None => None
        }
    }

    func shouldShowUnavailableTitle(typeRef: TypeRef): Bool {
        if (typeRef.semantic.state == "unavailable") { return true }
        if (typeRef.semantic.state != "resolved") { return false }
        match (targetUrl(typeRef)) {
            case Some(_) => false
            case None => true
        }
    }
}

internal func typeHeadSpelling(spelling: String): String {
    match (spelling.indexOf("<")) {
        case Some(index) => spelling[..index].trimAscii()
        case None => spelling
    }
}

internal func typeGenericSuffix(spelling: String): String {
    let bytes = spelling.toArray()
    var depth: Int64 = 0
    var genericEnd: Int64 = -1
    var index: Int64 = 0
    for (byte in bytes) {
        if (byte == b'<') {
            depth++
        } else if (byte == b'>' && depth > 0) {
            depth--
            if (depth == 0) { genericEnd = index }
        }
        index++
    }
    if (genericEnd < 0 || genericEnd + 1 >= spelling.size) { "" }
    else { spelling[genericEnd + 1..] }
}

internal func appendTypeAtomHtml(out: RenderTextBuffer, typeRef: TypeRef,
    spelling: String, typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    match (typeLinkIndex.targetUrl(typeRef)) {
        case Some(url) =>
            out.append("<a class=\"type-link\" href=\"${escapeHtml(rootPrefix + url)}\">${escapeHtml(spelling)}</a>")
        case None => out.append(escapeHtml(spelling))
    }
}

internal func appendTypeRefContentHtml(out: RenderTextBuffer, typeRef: TypeRef,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    match (typeRef.spelling.indexOf("<")) {
        case Some(_) =>
            if (typeRef.arguments.isEmpty()) {
                appendTypeAtomHtml(out, typeRef, typeRef.spelling, typeLinkIndex, rootPrefix)
                return
            }
            appendTypeAtomHtml(out, typeRef, typeHeadSpelling(typeRef.spelling),
                typeLinkIndex, rootPrefix)
            out.append("&lt;")
            var first = true
            for (argument in typeRef.arguments) {
                if (!first) { out.append(", ") }
                first = false
                appendTypeRefContentHtml(out, argument, typeLinkIndex, rootPrefix)
            }
            out.append("&gt;")
            let suffix = typeGenericSuffix(typeRef.spelling)
            if (!suffix.isEmpty()) { out.append(escapeHtml(suffix)) }
        case None => appendTypeAtomHtml(out, typeRef, typeRef.spelling, typeLinkIndex, rootPrefix)
    }
}

internal func appendTypeRefCodeHtml(out: RenderTextBuffer, typeRef: TypeRef,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String,
    className!: String = ""): Unit {
    out.append("<code")
    if (!className.isEmpty()) { out.append(" class=\"${escapeHtml(className)}\"") }
    if (typeLinkIndex.shouldShowUnavailableTitle(typeRef)) {
        out.append(" title=\"${escapeHtml(label(locale, "Definition unavailable", "定义不可用"))}\"")
    }
    out.append(">")
    appendTypeRefContentHtml(out, typeRef, typeLinkIndex, rootPrefix)
    out.append("</code>")
}

internal func buildAssetLookup(assets: ArrayList<AssetDoc>): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in assets) {
        let path = assetOutputPath(asset)
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
    projection: RenderProjection): ArrayList<AssetDoc> {
    let references = HashMap<String, String>()
    for (asset in documentation.assets) {
        references[asset.id] = asset.id
        references[asset.sourcePath] = asset.id
    }
    let selected = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.documentation) {
            case Some(comment) => collectReferencedAssets(comment.markdown, references, selected)
            case None => ()
        }
    }
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
    for (path in ["index.html", "search-index.json", "search-index.js", "search.js", "theme-bootstrap.js", "style.css"]) {
        let _ = paths.add(path)
    }
    for (pkg in projection.packages) {
        let path = packagePagePath(pkg.source.moduleId, pkg.source.name)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for package '${pkg.source.name}'")
        }
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let path = symbolPagePath(symbol)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for SymbolId '${symbol.id}'")
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
