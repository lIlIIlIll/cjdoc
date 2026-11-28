protected package cjdoc.render.routes

import cjdoc.model.*
import std.collection.*
import std.sort.*
import std.unicode.*

// symbols/symbol- + at most 96 slug bytes + .html. The Windows transaction
// prefix already fits this budget; it must not grow with declaration depth.
private let API_HTML_MAX_PATH = 116
private let API_HTML_INDEX = "/index.html"
private let API_HTML_DIGEST_START = 12
private let API_HTML_COMPACT_TARGET_BYTES = 24
private let API_HTML_SIGNATURE_PREFIX = "/signature-"
private let API_HTML_TYPED_SIGNATURE_BYTES = 24
private let API_HTML_RESERVED_ROOTS = ["en", "zh-cn", "assets", "packages", "symbols", "agent",
    "schemas", "search", "api-surface", "coverage", "markdown", "html", "versions", "latest"]

protected enum ApiRouteProjection {
    | Historical | ReadableSymbols | ReadablePackages
}

protected class ApiHtmlChoice {
    protected let id: String
    protected let file: String
    protected let symbols: Array<SymbolDoc>
    protected let overloads: Bool

    init(identity: String, directory: String, symbols: Array<SymbolDoc>, overloads: Bool) {
        id = "api-choice:" + contractFingerprint(identity)
        file = directory + API_HTML_INDEX
        this.symbols = symbols
        this.overloads = overloads
    }
}

protected class ApiHtmlRoutes {
    private let files = HashMap<String, String>()
    private let choices = ArrayList<ApiHtmlChoice>()
    private let packageFiles = HashMap<String, String>()

    protected init(documentation: DocumentationSet, symbols: ArrayList<SymbolDoc>,
        members: HashMap<String, ArrayList<SymbolDoc>>, packages: Array<PackageDoc>,
        projection: ApiRouteProjection) {
        match (projection) {
            case ReadablePackages => allocatePackageHtmlRoutes(documentation, packages, packageFiles)
            case _ =>
                for (source in packages) {
                    packageFiles[routeKey(source.moduleId, source.name)] =
                        historicalPackagePagePath(source.moduleId, source.name)
                }
        }
        if (let Historical <- projection) {
            for (symbol in symbols) { files[symbol.id] = symbolPagePath(symbol) }
            return
        }
        let allocator = ApiRouteAllocator(documentation, files, choices)
        let roots = ArrayList<SymbolDoc>()
        let extensions = ArrayList<SymbolDoc>()
        for (symbol in symbols where symbol.ownerId.isNone()) {
            // An extension is a block of the type it augments, not a second
            // declaration of that type's name. It is allocated after every
            // ordinary route, so adding one never moves the type or its members.
            if (symbol.kind == "extend") { extensions.add(symbol) } else { roots.add(symbol) }
        }
        var level = roots
        while (!level.isEmpty()) {
            allocator.allocateLevel(level)
            let next = ArrayList<SymbolDoc>()
            for (symbol in level) {
                if (let Some(children) <- members.get(symbol.id)) { next.add(all: children) }
            }
            level = next
        }
        allocator.allocateExtensions(extensions, members)
        if (files.size != symbols.size) {
            throw IllegalArgumentException("API routes require a visible declaration owner for every member")
        }
    }

    protected func filePath(symbolId: String): ?String { files.get(symbolId) }

    protected func fileHref(symbolId: String): String { apiHtmlFileHref(files[symbolId]) }

    protected func webPath(symbolId: String): String { apiHtmlWebPath(files[symbolId]) }

    protected func packageFile(moduleId: String, name: String): String {
        packageFiles[routeKey(moduleId, name)]
    }

    protected prop selectionPages: ReadOnlyList<ApiHtmlChoice> { get() { choices } }
}

protected func apiHtmlFileHref(path: String): String {
    for (i in 0..path.size) {
        if (path[i] >= 0x80) { return percentEncodeRouteComponent(path, "") }
    }
    path
}

protected func apiHtmlWebPath(path: String): String {
    apiHtmlFileHref(path.removeSuffix("index.html"))
}

// Compare spelling independently of case, canonical Unicode normalization and
// the trailing dots/spaces ignored by Windows.
protected func portableFileNameKey(name: String): String {
    var end = name.size
    while (end > 0 && (name[end - 1] == b'.' || name[end - 1] == b' ')) { end-- }
    let stem = name[..end]
    for (i in 0..end) {
        if (stem[i] >= 0x80) {
            // Include case-insensitive filesystems that compare by upper case;
            // e.g. both Greek lower-case sigmas address the same directory.
            let canonical = portableCanonicalUnicode(stem)
            return portableCanonicalUnicode(canonical.toUpper().toLower().replace("ß", "ss"))
        }
    }
    stem.toLower()
}

private func portableApiName(name: String): Bool {
    if (name.isEmpty() || name.size > API_HTML_MAX_PATH) { return false }
    for (rune in name.runes()) {
        if (rune != r'_' && !rune.isLetter() && !rune.isNumber()) { return false }
    }
    let key = portableFileNameKey(name)
    if (["con", "prn", "aux", "nul"].contains(key)) { return false }
    if (key.startsWith("com") || key.startsWith("lpt")) {
        let suffix = key[3..]
        if (["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"].contains(suffix)) {
            return false
        }
    }
    true
}

private func apiEscapedName(name: String): String {
    if (portableApiName(name)) { return name }
    if (name.size <= 16) { return "~" + htmlStableSlug(name) }
    "~" + contractFingerprint(name)
}

private func compactApiStem(name: String, bytes!: Int64 = 24): String {
    var end = if (name.size > bytes) { bytes } else { name.size }
    while (end < name.size && (name[end] & 0xC0) == 0x80) { end-- }
    let prefix = name[..end]
    if (portableApiName(prefix)) { prefix } else { "api" }
}

private func compactOverloadStem(name: String, bytes: Int64): String {
    if (name.size <= bytes && portableApiName(name)) { return name }
    // Long names often share a prefix. Retain the ending so unrelated
    // overload families don't draw addresses from the same ordinal sequence.
    let head = compactApiStem(name, bytes: bytes / 2)
    let tailBytes = bytes - head.size - 1
    var start = if (name.size > tailBytes) { name.size - tailBytes } else { 0 }
    while (start < name.size && (name[start] & 0xC0) == 0x80) { start++ }
    let tail = name[start..]
    if (portableApiName(tail)) { "${head}-${tail}" } else { head }
}

private func boundedOverloadStem(name: String, bytes: Int64): String {
    if (name.size <= bytes && portableApiName(name)) { return name }
    // Keep the readable ends but encode the omitted bytes too. Otherwise two
    // distinct long names can exchange URLs just by changing allocation order.
    let key = contractFingerprint(name)
    let stem = compactOverloadStem(name, bytes - API_HTML_DIGEST_START - 1)
    "${stem}-${key[..API_HTML_DIGEST_START]}"
}

private func extensionSignatureStem(symbol: SymbolDoc): String {
    if (symbol.parameters.isEmpty()) { return "no-args" }
    let names = StringBuilder()
    for (parameter in symbol.parameters) {
        if (names.size > 0) { names.append("_") }
        names.append(parameter.typeRef.spelling)
    }
    boundedOverloadStem(names.toString(), API_HTML_TYPED_SIGNATURE_BYTES)
}

private func compactTargetStem(path: String): String {
    if (path.size <= API_HTML_COMPACT_TARGET_BYTES) {
        var portable = true
        for (part in path.split("/")) {
            if (!portableApiName(part)) {
                portable = false
                break
            }
        }
        if (portable) { return path }
    }
    // Keep the actual type label readable; include its full package/type
    // path in the compaction so a different owner cannot take the old space.
    let start = path.lastIndexOf("/").getOrDefault({ => -1 }) + 1
    let title = compactOverloadStem(path[start..], API_HTML_COMPACT_TARGET_BYTES - API_HTML_DIGEST_START - 1)
    let key = contractFingerprint(path)
    "${title}-${key[..API_HTML_DIGEST_START]}"
}

private func apiPackageDirectory(name: String): String {
    if (name.isEmpty()) { return "" }
    let out = StringBuilder()
    let segments = name.split(".")
    for (i in 0..segments.size) {
        let segment = segments[i]
        if (i == 0 && API_HTML_RESERVED_ROOTS.contains(portableFileNameKey(segment))) {
            out.append("~" + htmlStableSlug(segment))
        } else {
            out.append(apiEscapedName(segment))
        }
        out.append("/")
        if (out.size > API_HTML_MAX_PATH) { return "" }
    }
    out.toString()
}

private func routeIdentityPart(value: String): String { "${value.size}:${value}" }

private func apiFamilyKey(symbol: SymbolDoc, owner: String): String {
    routeIdentityPart(symbol.moduleId) + routeIdentityPart(symbol.packageName) +
        routeIdentityPart(owner) +
        routeIdentityPart(symbol.kind) + routeIdentityPart(symbol.name)
}

private func canOverloadApiRoute(symbol: SymbolDoc): Bool {
    ["function", "constructor", "macro"].contains(symbol.kind)
}

private func declaredBefore(a: SymbolDoc, b: SymbolDoc): Bool {
    if (a.source.path != b.source.path) { return a.source.path < b.source.path }
    if (a.source.start.byteOffset != b.source.start.byteOffset) {
        return a.source.start.byteOffset < b.source.start.byteOffset
    }
    a.id < b.id
}

// The resolved target is the type that owns the extension directory. Without
// one, the source spelling's head (without type arguments) names the same type.
private func extensionTargetId(symbol: SymbolDoc): ?String {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind != "extensionTarget" || relationship.state != "resolved") { continue }
        if (let Some(targetId) <- relationship.targetSymbolId) { return Some(targetId) }
    }
    None
}

private func extensionTargetHead(symbol: SymbolDoc): String {
    symbol.name.split("(", 2)[0].split("<", 2)[0].trimAscii()
        .replace(" ", "").replace("\n", "").replace("\r", "").replace("\t", "")
}

private func extensionTargetKey(symbol: SymbolDoc): String {
    if (let Some(targetId) <- extensionTargetId(symbol)) { return targetId }
    let head = extensionTargetHead(symbol)
    routeIdentityPart(symbol.moduleId) + routeIdentityPart(symbol.packageName) +
        routeIdentityPart(head)
}

// A directory's spelling is part of the route, even if it has no index.
// Multiple authored spellings may be valid in independent locales; none of
// those conflicting subtrees is safe for a route shared by both locales.
private class ApiRouteClaims {
    private let files = HashSet<String>()
    private let directories = HashMap<String, String>()

    func reserve(path: String): Unit {
        var prefix = ""
        let parts = path.split("/")
        for (i in 0..parts.size - 1) {
            let part = parts[i]
            prefix += portableFileNameKey(part) + "/"
            match (directories.get(prefix)) {
                case Some(previous) => if (previous != part) { directories[prefix] = "" }
                case None => directories[prefix] = part
            }
        }
        let _ = files.add(prefix + portableFileNameKey(parts[parts.size - 1]))
    }

    func free(path: String): Bool {
        var prefix = ""
        let parts = path.split("/")
        for (i in 0..parts.size - 1) {
            let part = parts[i]
            let key = prefix + portableFileNameKey(part)
            if (files.contains(key)) { return false }
            prefix = key + "/"
            if (let Some(previous) <- directories.get(prefix)) {
                if (previous != part) { return false }
            }
        }
        let key = prefix + portableFileNameKey(parts[parts.size - 1])
        !files.contains(key) && !directories.contains(key + "/")
    }

    func claim(path: String): Bool {
        if (path.size > API_HTML_MAX_PATH || !free(path)) { return false }
        reserve(path)
        true
    }
}

private func packageHtmlDirectory(name: String): String {
    if (name.isEmpty() || name.size > API_HTML_MAX_PATH) { return "" }
    let out = StringBuilder()
    out.append("packages")
    for (segment in name.split(".")) {
        out.append("/")
        out.append(apiEscapedName(segment))
        if (out.size + API_HTML_INDEX.size > API_HTML_MAX_PATH) { return "" }
    }
    out.toString()
}

// Detect portable conflicts before making any claims: neither of two packages
// that differ only by case at a shared ancestor gets to pick its spelling.
private class PackageRouteCandidates {
    private let directories = HashMap<String, String>()
    private let names = HashMap<String, Int64>()
    private let files = HashMap<String, Int64>()

    func add(name: String, candidate: String): Unit {
        let key = portableFileNameKey(name)
        names[key] = names.get(key).getOrDefault({ => 0 }) + 1
        let file = portableFileNameKey(candidate)
        files[file] = files.get(file).getOrDefault({ => 0 }) + 1
        let _ = visitDirectories(name, { spelling =>
            let folded = portableFileNameKey(spelling)
            if (let Some(previous) <- directories.get(folded)) {
                if (previous != spelling) { directories[folded] = "" }
            } else { directories[folded] = spelling }
            true
        })
        if (let Some(previous) <- directories.get(key)) {
            if (previous != name) { directories[key] = "" }
        } else { directories[key] = name }
    }

    func unique(name: String, candidate: String): Bool {
        names[portableFileNameKey(name)] == 1 && files[portableFileNameKey(candidate)] == 1 &&
            !directories[portableFileNameKey(name)].isEmpty() && consistentParents(name)
    }

    func consistentParents(name: String): Bool {
        visitDirectories(name, { spelling => !directories[portableFileNameKey(spelling)].isEmpty() })
    }

    private func visitDirectories(name: String, visit: (String) -> Bool): Bool {
        for (i in 1..name.size) {
            if (name[i] == b'.' && !visit(name[..i])) { return false }
        }
        true
    }
}

private func allocatePackageHtmlRoutes(documentation: DocumentationSet,
    packages: Array<PackageDoc>, files: HashMap<String, String>): Unit {
    if (packages.isEmpty()) { return }
    let claims = ApiRouteClaims()
    for (page in documentation.pages) { claims.reserve(page.route) }
    let ordered = ArrayList<PackageDoc>(packages)
    sort(ordered, lessThan: { a, b =>
        if (a.moduleId == b.moduleId) { a.name < b.name } else { a.moduleId < b.moduleId }
    })
    let candidates = PackageRouteCandidates()
    let pending = ArrayList<(String, String, String)>()
    for (source in ordered) {
        let alias = historicalPackagePagePath(source.moduleId, source.name)
        if (!claims.free(alias)) {
            throw IllegalArgumentException("cannot retain historical package route for '${source.moduleId}:${source.name}'")
        }
        claims.reserve(alias)
        let candidate = packageHtmlDirectory(source.name)
        if (!candidate.isEmpty()) { candidates.add(source.name, candidate) }
        pending.add((routeKey(source.moduleId, source.name), source.name, candidate))
    }
    // Claim ordinary routes first, so a disambiguated path cannot steal one.
    for ((key, name, candidate) in pending where !candidate.isEmpty()) {
        let file = candidate + API_HTML_INDEX
        if (candidates.unique(name, candidate) && claims.claim(file)) { files[key] = file }
    }
    for ((key, name, candidate) in pending where !files.contains(key)) {
        let digest = contractFingerprint(key)
        let prefixes = if (!candidate.isEmpty() && candidates.consistentParents(name)) {
            [candidate + "~", "packages/~package~"]
        } else { ["packages/~package~"] }
        for (prefix in prefixes) {
            for (length in API_HTML_DIGEST_START..=digest.size) {
                let file = prefix + digest[..length] + API_HTML_INDEX
                if (file.size > API_HTML_MAX_PATH) { break }
                if (claims.claim(file)) {
                    files[key] = file
                    break
                }
            }
            if (files.contains(key)) { break }
        }
        if (!files.contains(key)) {
            throw IllegalArgumentException("cannot allocate distinct portable package route for '${key}'")
        }
    }
}

private class ApiRouteFamily {
    let key: String
    let symbols = ArrayList<SymbolDoc>()
    let candidate: String
    let typedSignatures: Bool
    var directory: String = ""

    init(key: String, candidate: String, typedSignatures: Bool) {
        this.key = key
        this.candidate = candidate
        this.typedSignatures = typedSignatures
    }

    prop overloaded: Bool { get() { symbols.size > 1 } }
    prop hasSignaturePages: Bool { get() { typedSignatures || overloaded } }
    prop signatureBudget: Int64 {
        get() { if (typedSignatures) { API_HTML_TYPED_SIGNATURE_BYTES } else { 19 } }
    }
}

private struct ApiExtensionScope {
    let memberParent: String
    let target: String
    let targetKey: String

    init(memberParent: String, target: String, targetKey: String) {
        this.memberParent = memberParent
        this.target = target
        this.targetKey = targetKey
    }
}

private class ApiRouteAllocator {
    private let files: HashMap<String, String>
    private let choices: ArrayList<ApiHtmlChoice>
    private let claims = ApiRouteClaims()
    private let packages = HashMap<String, String>()
    private let extensionsById = HashMap<String, ApiExtensionScope>()
    private let fallbackRoot: String

    init(documentation: DocumentationSet, files: HashMap<String, String>,
        choices: ArrayList<ApiHtmlChoice>) {
        this.files = files
        this.choices = choices
        for (page in documentation.pages) { claims.reserve(page.route) }
        for (file in ["index.html", "validation.html", "style.css", "search.js", "search-index.js",
            "search-index.json", "sidebar-index.js", "theme-bootstrap.js", "symbol-alias.js",
            "symbol-index.json", "llms.txt", "llms-full.txt", "machine-manifest.json",
            "site-manifest.json", "language-routes.js", "version-routes.js"]) {
            claims.reserve(file)
        }
        // These are generator-owned subtrees in at least one publication mode.
        for (root in API_HTML_RESERVED_ROOTS) { claims.reserve(root) }
        var root = "~api"
        var ordinal = 0
        while (!claims.free(root)) {
            ordinal++
            root = "~api~${ordinal}"
        }
        fallbackRoot = root
    }

    private func candidateOf(symbol: SymbolDoc): String {
        let parent: String
        if (let Some(owner) <- symbol.ownerId) {
            parent = match (extensionsById.get(owner)) {
                case Some(scope) =>
                    if (scope.memberParent.isEmpty()) { return "" }
                    scope.memberParent
                case _ => files[owner].removeSuffix("index.html")
            }
        } else {
            parent = match (packages.get(symbol.packageName)) {
                case Some(path) => path
                case None =>
                    let path = apiPackageDirectory(symbol.packageName)
                    packages[symbol.packageName] = path
                    path
            }
            if (parent.isEmpty() && !symbol.packageName.isEmpty()) { return "" }
        }
        if (parent.size + symbol.name.size + API_HTML_INDEX.size > API_HTML_MAX_PATH) { return "" }
        parent + apiEscapedName(symbol.name)
    }

    private func extensionScope(symbol: SymbolDoc): ?ApiExtensionScope {
        symbol.ownerId.flatMap({ id => extensionsById.get(id) })
    }

    func allocateLevel(level: ArrayList<SymbolDoc>): Unit {
        sort(level, lessThan: { a, b => a.id < b.id })
        let byFamily = HashMap<String, ApiRouteFamily>()
        let byCandidate = HashMap<String, ArrayList<ApiRouteFamily>>()
        let families = ArrayList<ApiRouteFamily>()
        for (symbol in level) {
            let overloadable = canOverloadApiRoute(symbol)
            let scope = if (overloadable) { extensionScope(symbol) } else { None<ApiExtensionScope> }
            let key = if (overloadable) {
                let owner = scope.map({ item => "extend:" + item.targetKey })
                    .getOrDefault({ => symbol.ownerId.getOrDefault({ => "" }) })
                apiFamilyKey(symbol, owner)
            } else { symbol.id }
            if (let Some(family) <- byFamily.get(key)) {
                family.symbols.add(symbol)
                continue
            }
            let family = ApiRouteFamily(key, candidateOf(symbol), scope.isSome())
            family.symbols.add(symbol)
            byFamily[key] = family
            families.add(family)
            if (family.candidate.isEmpty()) { continue }
            let candidateKey = portableFileNameKey(family.candidate)
            match (byCandidate.get(candidateKey)) {
                case Some(group) => group.add(family)
                case None => byCandidate[candidateKey] = ArrayList<ApiRouteFamily>([family])
            }
        }
        for (family in families where !family.candidate.isEmpty()) {
            let group = byCandidate[portableFileNameKey(family.candidate)]
            if (group.size == 1) {
                let _ = claimFamily(family.candidate, family)
            } else if (group[0].key == family.key) {
                claimModuleChoice(family.candidate, group)
            }
        }
        for (family in families) { allocateFamily(family) }
    }

    /**
     * Extensions live under the type they augment, as `<type>/extensions/<n>/`.
     *
     * Block indexes follow declaration order. Member routes belong to the
     * target type, not to a block's place in that order. Collision suffixes
     * use target identity plus ordinal, never the block's member-dependent ID.
     */
    func allocateExtensions(extensions: ArrayList<SymbolDoc>,
        members: HashMap<String, ArrayList<SymbolDoc>>): Unit {
        // The counter is per target; the sort only needs declaration order.
        sort(extensions, lessThan: { a, b => declaredBefore(a, b) })
        let ordinals = HashMap<String, Int64>()
        // Compact paths also use this per-target ordinal, never a global counter.
        for (symbol in extensions) {
            let targetDirectory = extensionTargetDirectory(symbol)
            let root = targetDirectory + "/extensions"
            let key = extensionTargetKey(symbol)
            let ordinal = ordinals.get(key).getOrDefault({ => 0 }) + 1
            ordinals[key] = ordinal
            let memberParent = if (targetDirectory.isEmpty()) { "" } else { targetDirectory + "/" }
            let target = if (targetDirectory.isEmpty()) {
                apiPackageDirectory(symbol.packageName) + extensionTargetHead(symbol)
            } else { targetDirectory }
            let identity = routeIdentityPart(symbol.moduleId) + routeIdentityPart(symbol.packageName) +
                routeIdentityPart(key) + ordinal.toString()
            extensionsById[symbol.id] = ApiExtensionScope(memberParent, target, key)
            let directory = if (ordinal == 1) { root } else { root + "/" + ordinal.toString() }
            if (!targetDirectory.isEmpty() && allocateExtensionDirectory(symbol, directory, identity)) {
                continue
            }
            let compact = "${fallbackRoot}/extensions/${compactTargetStem(target)}/extension-${ordinal}"
            if (!allocateExtensionDirectory(symbol, compact, identity)) {
                throw IllegalArgumentException("cannot allocate distinct extension route for '${symbol.id}'")
            }
        }
        // Distinct blocks can add overloads to the same method on the target.
        // Treat them as one family, with member URLs independent of block order.
        let next = ArrayList<SymbolDoc>()
        for (symbol in extensions) {
            if (let Some(children) <- members.get(symbol.id)) { next.add(all: children) }
        }
        if (!next.isEmpty()) { allocateLevel(next) }
    }

    private func allocateExtensionDirectory(symbol: SymbolDoc, directory: String, identity: String): Bool {
        if (directory.size + API_HTML_INDEX.size > API_HTML_MAX_PATH) { return false }
        if (claim(directory)) {
            files[symbol.id] = directory + API_HTML_INDEX
            return true
        }
        let digest = contractFingerprint(identity)
        for (length in API_HTML_DIGEST_START..=digest.size) {
            let fallback = directory + "~" + digest[..length]
            if (fallback.size + API_HTML_INDEX.size > API_HTML_MAX_PATH) { break }
            if (claim(fallback)) {
                files[symbol.id] = fallback + API_HTML_INDEX
                return true
            }
        }
        false
    }

    // The type an extension augments owns its directory. Without a resolved
    // extension target the source spelling's head still names that type.
    private func extensionTargetDirectory(symbol: SymbolDoc): String {
        let parent = match (packages.get(symbol.packageName)) {
            case Some(path) => path
            case None =>
                let path = apiPackageDirectory(symbol.packageName)
                packages[symbol.packageName] = path
                path
        }
        if (let Some(targetId) <- extensionTargetId(symbol)) {
            if (let Some(path) <- files.get(targetId)) {
                return path.removeSuffix(API_HTML_INDEX)
            }
        }
        if (parent.isEmpty() && !symbol.packageName.isEmpty()) { return "" }
        let head = extensionTargetHead(symbol)
        let separator = head.lastIndexOf(".")
        let tail = if (separator.isSome()) { head[separator.getOrThrow() + 1..] } else { head }
        let escaped = apiEscapedName(tail.trimAscii())
        if (escaped.isEmpty()) { "" } else { parent + escaped }
    }

    private func claim(directory: String): Bool { claims.claim(directory + API_HTML_INDEX) }

    private func claimModuleChoice(candidate: String, group: ArrayList<ApiRouteFamily>): Unit {
        let modules = HashSet<String>()
        for (family in group) {
            if (family.candidate != candidate) { return }
            let _ = modules.add(family.symbols[0].moduleId)
        }
        if (modules.size < 2 || !claim(candidate)) { return }
        let symbols = ArrayList<SymbolDoc>()
        for (family in group) { symbols.add(all: family.symbols) }
        choices.add(ApiHtmlChoice("modules:" + candidate, candidate, symbols.toArray(), false))
    }

    private func claimFamily(directory: String, family: ApiRouteFamily): Bool {
        let file = directory + API_HTML_INDEX
        if (file.size > API_HTML_MAX_PATH || !claims.free(file)) { return false }
        if (family.hasSignaturePages) {
            sort(family.symbols, lessThan: { a, b => declaredBefore(a, b) })
            if (!reserveSignatureDirectories(directory, family)) {
                // A fitting choice page keeps its address even if its children do not fit.
                let compact = compactOverloadDirectory(family)
                if (!reserveSignatureDirectories(compact, family)) {
                    throw IllegalArgumentException("cannot allocate compact signatures for '${family.symbols[0].id}'")
                }
            }
            if (family.overloaded) {
                choices.add(ApiHtmlChoice("overloads:" + family.key, directory, family.symbols.toArray(), true))
            }
        } else { files[family.symbols[0].id] = file }
        claims.reserve(file)
        family.directory = directory
        true
    }

    // Extension signatures use type labels even before they have an overload,
    // so another block cannot replace the singleton's address. Other overload
    // families retain the readable declaration-order numbering.
    private func reserveSignatureDirectories(directory: String, family: ApiRouteFamily): Bool {
        if (family.typedSignatures &&
            directory.size + API_HTML_SIGNATURE_PREFIX.size + family.signatureBudget + API_HTML_INDEX.size >
                API_HTML_MAX_PATH) { return false }
        let typedNames = if (family.typedSignatures) { Some(HashSet<String>()) } else { None<HashSet<String>> }
        let assigned = ArrayList<String>()
        for (index in 0..family.symbols.size) {
            let label = if (family.typedSignatures) { extensionSignatureStem(family.symbols[index]) }
                else { (index + 1).toString() }
            let readable = directory + API_HTML_SIGNATURE_PREFIX + label + API_HTML_INDEX
            if (readable.size > API_HTML_MAX_PATH) { return false }
            let available = match (typedNames) {
                case Some(names) => names.add(portableFileNameKey(label))
                case None => true
            }
            if (available && claims.free(readable)) {
                assigned.add(readable)
                continue
            }
            let digest = contractFingerprint(family.symbols[index].id)
            let fallback = overloadSignatureFile(directory, digest, assigned)
            if (fallback.isEmpty()) { return false }
            assigned.add(fallback)
        }
        for (index in 0..assigned.size) {
            claims.reserve(assigned[index])
            files[family.symbols[index].id] = assigned[index]
        }
        true
    }

    private func overloadSignatureFile(base: String, digest: String, assigned: ArrayList<String>): String {
        for (length in API_HTML_DIGEST_START..=digest.size) {
            let file = base + "/~" + digest[..length] + API_HTML_INDEX
            if (file.size > API_HTML_MAX_PATH) { break }
            if (claims.free(file) && !assigned.contains(file)) { return file }
        }
        ""
    }

    private func compactOverloadDirectory(family: ApiRouteFamily): String {
        let symbol = family.symbols[0]
        var root = "${fallbackRoot}/overloads/"
        if (let Some(scope) <- extensionScope(symbol)) {
            root += compactTargetStem(scope.target) + "/"
        }
        // A family must fit future signatures too without changing addresses.
        let available = API_HTML_MAX_PATH - root.size - API_HTML_SIGNATURE_PREFIX.size -
            family.signatureBudget - API_HTML_INDEX.size
        let name = symbol.name
        let bytes = if (available < 49) { available } else { 49 }
        let readable = root + boundedOverloadStem(name, bytes)
        if (claims.free(readable)) { return readable }
        // A suffix is justified only when the compact directory is actually
        // occupied. Use the family identity, not its position in a traversal.
        let digest = contractFingerprint(family.key)
        for (length in API_HTML_DIGEST_START..=digest.size) {
            let room = available - length - 1
            if (room < 8) { break }
            let directory = root + compactOverloadStem(name, room) + "~" + digest[..length]
            if (claims.free(directory)) { return directory }
        }
        throw IllegalArgumentException("cannot allocate distinct compact overload route for '${family.symbols[0].id}'")
    }

    private func claimSuffixed(prefix: String, digest: String, family: ApiRouteFamily): Bool {
        for (length in API_HTML_DIGEST_START..=digest.size) {
            let directory = prefix + digest[..length]
            if (directory.size + API_HTML_INDEX.size > API_HTML_MAX_PATH) { break }
            if (claimFamily(directory, family)) { return true }
        }
        false
    }

    private func allocateFamily(family: ApiRouteFamily): Unit {
        if (!family.directory.isEmpty()) { return }
        let symbol = family.symbols[0]
        if (family.hasSignaturePages && (family.candidate.isEmpty() ||
            family.candidate.size + API_HTML_INDEX.size > API_HTML_MAX_PATH)) {
            if (claimFamily(compactOverloadDirectory(family), family)) { return }
            throw IllegalArgumentException("cannot allocate compact overload route for '${symbol.id}'")
        }
        let digest = contractFingerprint(if (family.hasSignaturePages) { family.key } else { symbol.id })
        if (!family.candidate.isEmpty() && claimSuffixed(family.candidate + "~", digest, family)) { return }
        if (!claimSuffixed("${fallbackRoot}/${compactApiStem(symbol.name)}~", digest, family)) {
            throw IllegalArgumentException("cannot allocate distinct portable API route for '${symbol.id}'")
        }
    }
}
