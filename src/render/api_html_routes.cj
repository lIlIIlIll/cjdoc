package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*
import std.unicode.*

// symbols/symbol- + at most 96 slug bytes + .html. The Windows transaction
// prefix already fits this budget; it must not grow with declaration depth.
private let API_HTML_MAX_PATH = 116
private let API_HTML_INDEX = "/index.html"
private let API_HTML_DIGEST_START = 12
private let API_HTML_RESERVED_ROOTS = ["en", "zh-cn", "assets", "packages", "symbols", "agent",
    "schemas", "search", "api-surface", "coverage", "markdown", "html", "versions", "latest"]

internal enum ApiRouteProjection {
    | Historical | ReadableSymbols | ReadablePackages
}

internal class ApiHtmlChoice {
    let id: String
    let file: String
    let symbols: Array<SymbolDoc>
    let overloads: Bool

    init(identity: String, directory: String, symbols: Array<SymbolDoc>, overloads: Bool) {
        id = "api-choice:" + contractFingerprint(identity)
        file = directory + API_HTML_INDEX
        this.symbols = symbols
        this.overloads = overloads
    }
}

internal class ApiHtmlRoutes {
    private let files = HashMap<String, String>()
    private let choices = ArrayList<ApiHtmlChoice>()
    private let packageFiles = HashMap<String, String>()

    init(documentation: DocumentationSet, symbols: ArrayList<SymbolDoc>,
        members: HashMap<String, ArrayList<SymbolDoc>>, packages: ArrayList<ProjectedPackage>,
        projection: ApiRouteProjection) {
        match (projection) {
            case ReadablePackages => allocatePackageHtmlRoutes(documentation, packages, packageFiles)
            case _ =>
                for (pkg in packages) {
                    let source = pkg.source
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
        for (symbol in symbols where symbol.ownerId.isNone()) { roots.add(symbol) }
        var level = roots
        while (!level.isEmpty()) {
            allocator.allocateLevel(level)
            let next = ArrayList<SymbolDoc>()
            for (symbol in level) {
                if (let Some(children) <- members.get(symbol.id)) { next.add(all: children) }
            }
            level = next
        }
        if (files.size != symbols.size) {
            throw IllegalArgumentException("API routes require a visible declaration owner for every member")
        }
    }

    func filePath(symbolId: String): ?String { files.get(symbolId) }

    func fileHref(symbolId: String): String { apiHtmlFileHref(files[symbolId]) }

    func webPath(symbolId: String): String { apiHtmlWebPath(files[symbolId]) }

    func packageFile(moduleId: String, name: String): String {
        packageFiles[routeKey(moduleId, name)]
    }

    prop selectionPages: ReadOnlyList<ApiHtmlChoice> { get() { choices } }
}

internal func apiHtmlFileHref(path: String): String {
    for (i in 0..path.size) {
        if (path[i] >= 0x80) { return percentEncodeRouteComponent(path, "") }
    }
    path
}

internal func apiHtmlWebPath(path: String): String {
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

private func apiFamilyKey(symbol: SymbolDoc): String {
    routeIdentityPart(symbol.moduleId) + routeIdentityPart(symbol.packageName) +
        routeIdentityPart(symbol.ownerId.getOrDefault({ => "" })) +
        routeIdentityPart(symbol.kind) + routeIdentityPart(symbol.name)
}

private func canOverloadApiRoute(symbol: SymbolDoc): Bool {
    ["function", "constructor", "macro"].contains(symbol.kind)
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
    packages: ArrayList<ProjectedPackage>, files: HashMap<String, String>): Unit {
    if (packages.isEmpty()) { return }
    let claims = ApiRouteClaims()
    for (page in documentation.pages) { claims.reserve(page.route) }
    let ordered = ArrayList<ProjectedPackage>(packages.toArray())
    sort(ordered, lessThan: { a, b =>
        if (a.source.moduleId == b.source.moduleId) { a.source.name < b.source.name }
        else { a.source.moduleId < b.source.moduleId }
    })
    let candidates = PackageRouteCandidates()
    let pending = ArrayList<(String, String, String)>()
    for (pkg in ordered) {
        let source = pkg.source
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
    var directory: String = ""

    init(key: String, candidate: String) {
        this.key = key
        this.candidate = candidate
    }

    prop overloaded: Bool { get() { symbols.size > 1 } }
}

private class ApiRouteAllocator {
    private let files: HashMap<String, String>
    private let choices: ArrayList<ApiHtmlChoice>
    private let claims = ApiRouteClaims()
    private let packages = HashMap<String, String>()
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
            parent = files[owner].removeSuffix("index.html")
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

    func allocateLevel(level: ArrayList<SymbolDoc>): Unit {
        sort(level, lessThan: { a, b => a.id < b.id })
        let byFamily = HashMap<String, ApiRouteFamily>()
        let byCandidate = HashMap<String, ArrayList<ApiRouteFamily>>()
        let families = ArrayList<ApiRouteFamily>()
        for (symbol in level) {
            let key = if (canOverloadApiRoute(symbol)) { apiFamilyKey(symbol) } else { symbol.id }
            if (let Some(family) <- byFamily.get(key)) {
                family.symbols.add(symbol)
                continue
            }
            let family = ApiRouteFamily(key, candidateOf(symbol))
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
        if (family.overloaded) {
            if (file.size + API_HTML_DIGEST_START + 2 > API_HTML_MAX_PATH) { return false }
            let assigned = ArrayList<String>()
            let pending = HashSet<String>()
            for (symbol in family.symbols) {
                let digest = contractFingerprint(symbol.id)
                let signature = overloadSignatureFile(directory, digest, pending)
                if (signature.isEmpty()) { return false }
                assigned.add(signature)
            }
            for (i in 0..assigned.size) {
                claims.reserve(assigned[i])
                files[family.symbols[i].id] = assigned[i]
            }
            choices.add(ApiHtmlChoice("overloads:" + family.key, directory, family.symbols.toArray(), true))
        } else { files[family.symbols[0].id] = file }
        claims.reserve(file)
        family.directory = directory
        true
    }

    private func overloadSignatureFile(directory: String, digest: String, pending: HashSet<String>): String {
        for (length in API_HTML_DIGEST_START..=digest.size) {
            let file = directory + "/~" + digest[..length] + API_HTML_INDEX
            if (file.size > API_HTML_MAX_PATH) { break }
            if (claims.free(file) && pending.add(file)) { return file }
        }
        ""
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
        let digest = contractFingerprint(if (family.overloaded) { family.key } else { symbol.id })
        if (!family.candidate.isEmpty() && claimSuffixed(family.candidate + "~", digest, family)) { return }
        var end = if (symbol.name.size > 24) { 24 } else { symbol.name.size }
        while (end < symbol.name.size && (symbol.name[end] & 0xC0) == 0x80) { end-- }
        let prefix = symbol.name[..end]
        let name = if (portableApiName(prefix)) { prefix } else { "api" }
        if (!claimSuffixed("${fallbackRoot}/${name}~", digest, family)) {
            throw IllegalArgumentException("cannot allocate distinct portable API route for '${symbol.id}'")
        }
    }
}
