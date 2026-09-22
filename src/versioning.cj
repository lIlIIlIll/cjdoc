package cjdoc

import cjdoc.render as public_render
import std.collection.*
import std.fs.*
import std.sort.*
import yjson.*

internal let VERSION_MANIFEST_SCHEMA = "cjdoc.versions/1"
internal let VERSION_FILE_SCHEMA = "cjdoc.version/1"
internal let VERSION_FILE_MAX_BYTES: Int64 = 32 * 1024 * 1024
internal let VERSION_DIFF_MAX_BYTES: Int64 = 32 * 1024 * 1024
internal let VERSION_TOTAL_MAX_BYTES: Int64 = 256 * 1024 * 1024
internal let VERSION_MAX_SITES: Int64 = 64
internal let VERSION_COMPOSE_MAX_FILES: Int64 = 65533

private class VersionComposeBudget {
    var totalBytes: Int64 = 0
    var totalFiles: Int64 = 0

    func reserve(path: String, bytes: Int64): Unit {
        if (totalFiles >= VERSION_COMPOSE_MAX_FILES) {
            throw IllegalArgumentException("version composition exceeds ${VERSION_COMPOSE_MAX_FILES} files")
        }
        if (bytes > VERSION_TOTAL_MAX_BYTES - totalBytes) {
            throw IllegalArgumentException("version composition exceeds ${VERSION_TOTAL_MAX_BYTES} bytes")
        }
        totalFiles++
        totalBytes += bytes
    }
    func reserveArtifact(path: String, bytes: Int64): Unit {
        if (bytes > VERSION_TOTAL_MAX_BYTES - totalBytes) {
            throw IllegalArgumentException("version artifact '${path}' exceeds composition memory budget")
        }
        totalBytes += bytes
    }
    func remainingBytes(): Int64 { VERSION_TOTAL_MAX_BYTES - totalBytes }
}
private class VersionTextBuffer {
    let storage = StringBuilder()
    let limit: Int64
    var written: Int64 = 0

    init(limit: Int64) {
        if (limit < 0) { throw IllegalArgumentException("invalid version selector limit") }
        this.limit = limit
    }

    func append(value: String): Unit {
        if (value.size > limit - written) {
            throw IllegalArgumentException("version selector exceeds composition memory budget")
        }
        storage.append(value)
        written += value.size
    }

    func toString(): String { storage.toString() }
}
internal class VersionSourceFile {
    let path: String
    let mediaType: String
    let bytes: Array<Byte>

    init(path: String, mediaType: String, bytes: Array<Byte>) {
        this.path = path
        this.mediaType = mediaType
        this.bytes = bytes
    }
}

internal class VersionSymbolIndex {
    let hrefById = HashMap<String, String>()
    let idByHref = HashMap<String, String>()

    func add(id: String, href: String): Unit {
        if (id.isEmpty() || href.isEmpty() || !isSafeOutputPath(href)) {
            throw IllegalArgumentException("version symbol index contains an unsafe route")
        }
        match (hrefById.get(id)) {
            case Some(existing) => if (existing != href) {
                throw IllegalArgumentException("version symbol index contains duplicate symbol id '${id}'")
            }
            case None => ()
        }
        match (idByHref.get(href)) {
            case Some(existing) => if (existing != id) {
                throw IllegalArgumentException("version symbol index contains duplicate symbol route '${href}'")
            }
            case None => ()
        }
        hrefById[id] = href
        idByHref[href] = id
    }
}

internal class VersionComposeSpec {
    let id: String
    let source: String
    var label: String
    var basePath: String
    var channel: String
    var status: String
    var release: ?String
    var apiDiffSource: ?String

    init(id: String, source: String) {
        this.id = id
        this.source = source
        this.label = id
        this.basePath = id
        this.channel = "unspecified"
        this.status = "published"
        this.release = None
        this.apiDiffSource = None
    }
}

internal class VersionSite {
    let spec: VersionComposeSpec
    let files = ArrayList<VersionSourceFile>()
    let paths = HashSet<String>()
    let symbols: VersionSymbolIndex

    init(spec: VersionComposeSpec, symbols: VersionSymbolIndex) {
        this.spec = spec
        this.symbols = symbols
    }

    func hasPath(path: String): Bool { paths.contains(path) }
}

private func versionJsonEscape(value: String): String {
    public_render.escapeJsonString(value)
}

private func versionMediaType(path: String): String {
    if (path.endsWith(".html")) { return "text/html; charset=utf-8" }
    if (path.endsWith(".css")) { return "text/css; charset=utf-8" }
    if (path.endsWith(".js")) { return "text/javascript; charset=utf-8" }
    if (path.endsWith(".json")) { return "application/json" }
    if (path.endsWith(".svg")) { return "image/svg+xml" }
    if (path.endsWith(".png")) { return "image/png" }
    if (path.endsWith(".jpg") || path.endsWith(".jpeg")) { return "image/jpeg" }
    if (path.endsWith(".gif")) { return "image/gif" }
    if (path.endsWith(".webp")) { return "image/webp" }
    "application/octet-stream"
}

private func versionSafeId(value: String): Bool {
    if (value.isEmpty() || value == "." || value == "..") { return false }
    if (value.contains("/") || value.contains("\\") || value.contains(":") ||
        value.contains("..") || value.contains("\n") || value.contains("\r") || value.contains("\t")) {
        return false
    }
    true
}

private func versionPathContainsLatest(value: String): Bool {
    value == "latest" || value.startsWith("latest/") || value.endsWith("/latest") ||
        value.contains("/latest/")
}
private func versionSafeBasePath(value: String): Bool {
    !versionPathContainsLatest(value) && isSafeOutputPath(value) && !value.startsWith(".") &&
        !value.contains("#") && !value.contains("?")
}
private func versionJsonStringField(object: JsonObject, key: String): ?String {
    match (object.get(key)) {
        case Some(value) => try { Some(value.asString()) } catch (_: Exception) { None }
        case None => None
    }
}

private func versionJsonArrayValues(value: JsonArray): Array<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (index in 0..value.size()) { result.add(value.get(index).getOrThrow()) }
    result.toArray()
}

private func collectVersionFilesInDirectory(directory: Path, relative: String,
    files: ArrayList<VersionSourceFile>, seen: HashSet<String>, budget: VersionComposeBudget): Unit {
    for (info in Directory.readFrom(directory)) {
        if (info.isSymbolicLink()) {
            throw IllegalArgumentException("version source contains a symbolic link '${info.path}'")
        }
        let child = if (relative.isEmpty()) { info.name } else { "${relative}/${info.name}" }
        if (!isSafeOutputPath(child)) {
            throw IllegalArgumentException("version source contains an unsafe path '${child}'")
        }
        if (info.isDirectory()) {
            collectVersionFilesInDirectory(info.path, child, files, seen, budget)
            continue
        }
        if (!info.isRegular()) {
            throw IllegalArgumentException("version source contains a non-regular entry '${info.path}'")
        }
        if (!seen.add(child)) {
            throw IllegalArgumentException("version source contains duplicate path '${child}'")
        }
        let expectedSize = info.size
        budget.reserve(child, expectedSize)
        let bytes = readFileBounded(info.path, VERSION_FILE_MAX_BYTES)
        if (bytes.size != expectedSize) {
            throw IllegalArgumentException("version source changed while reading '${child}'")
        }
        files.add(VersionSourceFile(child, versionMediaType(child), bytes))
    }
}

private func loadVersionSymbols(files: ArrayList<VersionSourceFile>): VersionSymbolIndex {
    let result = VersionSymbolIndex()
    for (file in files) {
        if (file.path != "symbol-index.json") { continue }
        let text = try { String.fromUtf8(file.bytes) } catch (_: Exception) {
            throw IllegalArgumentException("version symbol index is not UTF-8")
        }
        let parsed = try {
            JsonNode.parse(text, config: JsonReadOptions(
                duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 24,
                maxStringBytes: VERSION_FILE_MAX_BYTES,
                maxBufferedValueBytes: VERSION_FILE_MAX_BYTES,
                maxInputBytes: VERSION_FILE_MAX_BYTES))
        } catch (_: Exception) {
            throw IllegalArgumentException("version symbol index is invalid JSON")
        }
        let object = try { parsed.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("version symbol index must be an object")
        }
        match (versionJsonStringField(object, "schemaVersion")) {
            case Some(value) => if (value != "cjdoc.symbol-index/1") {
                throw IllegalArgumentException("version symbol index schema is unsupported")
            }
            case None => throw IllegalArgumentException("version symbol index has no schemaVersion")
        }
        let entries = try { object["entries"].asArray() } catch (_: Exception) {
            throw IllegalArgumentException("version symbol index has no entries")
        }
        for (entryNode in versionJsonArrayValues(entries)) {
            let entry = try { entryNode.asObject() } catch (_: Exception) {
                throw IllegalArgumentException("version symbol index entry is invalid")
            }
            let id = match (versionJsonStringField(entry, "id")) {
                case Some(value) => value
                case None => throw IllegalArgumentException("version symbol index entry has no id")
            }
            let href = match (versionJsonStringField(entry, "href")) {
                case Some(value) => value
                case None => throw IllegalArgumentException("version symbol index entry has no href")
            }
            result.add(id, href)
        }
    }
    result
}
private func loadVersionApiDiff(spec: VersionComposeSpec, budget: VersionComposeBudget): VersionSourceFile {
    let source = match (spec.apiDiffSource) {
        case Some(value) => value
        case None => throw IllegalArgumentException("version API diff source is missing")
    }
    let path = Path(source)
    if (!exists(path)) { throw IllegalArgumentException("version API diff is missing '${source}'") }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isRegular()) {
        throw IllegalArgumentException("version API diff must be a regular file '${source}'")
    }
    let expectedSize = info.size
    budget.reserve("api-diff.json", expectedSize)
    let bytes = readFileBounded(path, VERSION_DIFF_MAX_BYTES)
    if (bytes.size != expectedSize) {
        throw IllegalArgumentException("version API diff changed while reading '${source}'")
    }
    let text = try { String.fromUtf8(bytes) } catch (_: Exception) {
        throw IllegalArgumentException("version API diff is not UTF-8 '${source}'")
    }
    let parsed = try {
        JsonNode.parse(text, config: JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 32,
            maxStringBytes: VERSION_DIFF_MAX_BYTES,
            maxBufferedValueBytes: VERSION_DIFF_MAX_BYTES,
            maxInputBytes: VERSION_DIFF_MAX_BYTES))
    } catch (_: Exception) {
        throw IllegalArgumentException("version API diff is invalid JSON '${source}'")
    }
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("version API diff must be an object '${source}'")
    }
    match (versionJsonStringField(object, "schemaVersion")) {
        case Some(value) => if (value != "cjdoc.api-diff/1") {
            throw IllegalArgumentException("version API diff schema is unsupported '${source}'")
        }
        case None => throw IllegalArgumentException("version API diff has no schemaVersion '${source}'")
    }
    VersionSourceFile("api-diff.json", "application/json", bytes)
}

private func loadVersionDoctestEvidence(root: Path, budget: VersionComposeBudget): ?VersionSourceFile {
    let path = root.parent.join("doctest/results.json")
    if (!exists(path)) { return None }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isRegular()) {
        throw IllegalArgumentException("version doctest evidence is not a regular file '" + path.toString() + "'")
    }
    let expectedSize = info.size
    budget.reserve("doctest/results.json", expectedSize)
    let bytes = readFileBounded(path, VERSION_FILE_MAX_BYTES)
    if (bytes.size != expectedSize) {
        throw IllegalArgumentException("version doctest evidence changed while reading '" + path.toString() + "'")
    }
    Some(VersionSourceFile("doctest/results.json", "application/json", bytes))
}

private func loadVersionSite(spec: VersionComposeSpec, budget: VersionComposeBudget): VersionSite {
    let root = Path(spec.source)
    if (!exists(root)) { throw IllegalArgumentException("version source is missing '${spec.source}'") }
    let info = FileInfo(root)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalArgumentException("version source must be a regular directory '${spec.source}'")
    }
    let files = ArrayList<VersionSourceFile>()
    let seen = HashSet<String>()
    collectVersionFilesInDirectory(root, "", files, seen, budget)
    match (loadVersionDoctestEvidence(root, budget)) {
        case Some(evidence) =>
            if (seen.add(evidence.path)) { files.add(evidence) }
        case None => ()
    }
    sort(files, lessThan: { left, right => left.path < right.path }, stable: true)
    if (!seen.contains("index.html")) {
        throw IllegalArgumentException("version source has no index.html '${spec.source}'")
    }
    let site = VersionSite(spec, loadVersionSymbols(files))
    for (file in files) {
        site.files.add(file)
        site.paths.add(file.path)
    }
    match (spec.apiDiffSource) {
        case Some(_) =>
            if (!site.paths.add("api-diff.json")) {
                throw IllegalArgumentException("version source already contains api-diff.json")
            }
            let apiDiff = loadVersionApiDiff(spec, budget)
            site.files.add(apiDiff)
            sort(site.files, lessThan: { left, right => left.path < right.path }, stable: true)
        case None => ()
    }
    site
}

private func parseVersionInput(value: String): (String, String) {
    let parts = value.split("=", 2)
    if (parts.size != 2 || !versionSafeId(parts[0]) || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("--version requires SAFE_ID=LOCAL_HTML_DIRECTORY")
    }
    (parts[0], parts[1])
}

private func versionAssignment(values: HashMap<String, String>, id: String): String {
    match (values.get(id)) {
        case Some(value) => value
        case None => ""
    }
}

private func buildVersionSpecs(options: NewCliOptions): (ArrayList<VersionComposeSpec>, String, String) {
    if (options.versionInputs.isEmpty()) {
        throw IllegalArgumentException("versions compose requires at least one --version ID=PATH")
    }
    if (options.versionInputs.size > VERSION_MAX_SITES) {
        throw IllegalArgumentException("versions compose exceeds ${VERSION_MAX_SITES} versions")
    }
    let specs = ArrayList<VersionComposeSpec>()
    let ids = HashSet<String>()
    var firstId = ""
    for (raw in options.versionInputs) {
        let (id, source) = parseVersionInput(raw)
        if (!ids.add(id)) { throw IllegalArgumentException("duplicate version id '${id}'") }
        if (firstId.isEmpty()) { firstId = id }
        let spec = VersionComposeSpec(id, source)
        let label = versionAssignment(options.versionLabels, id)
        let channel = versionAssignment(options.versionChannels, id)
        let status = versionAssignment(options.versionStatuses, id)
        let basePath = versionAssignment(options.versionBasePaths, id)
        let release = versionAssignment(options.versionReleases, id)
        let apiDiff = versionAssignment(options.versionDiffs, id)
        if (!label.isEmpty()) { spec.label = label }
        if (!channel.isEmpty()) { spec.channel = channel }
        if (!status.isEmpty()) { spec.status = status }
        if (!basePath.isEmpty()) { spec.basePath = basePath }
        if (!release.isEmpty()) { spec.release = Some(release) }
        if (!apiDiff.isEmpty()) { spec.apiDiffSource = Some(apiDiff) }
        if (!versionSafeBasePath(spec.basePath)) {
            throw IllegalArgumentException("unsafe version base path '${spec.basePath}'")
        }
        specs.add(spec)
    }
    for (assignmentId in options.versionAssignmentIds) {
        if (!ids.contains(assignmentId)) {
            throw IllegalArgumentException("version metadata assignment names unknown version '${assignmentId}'")
        }
    }
    let seenPaths = HashSet<String>()
    for (spec in specs) {
        if (!seenPaths.add(spec.basePath)) {
            throw IllegalArgumentException("duplicate version base path '${spec.basePath}'")
        }
        if (spec.basePath == "index.html" || spec.basePath.startsWith("index.html/") ||
            spec.basePath == "versions.json" || spec.basePath.startsWith("versions.json/")) {
            throw IllegalArgumentException("version base path collides with publisher files '${spec.basePath}'")
        }
        if (spec.basePath == "latest" || spec.basePath.startsWith("latest/")) {
            throw IllegalArgumentException("version base path collides with latest alias '${spec.basePath}'")
        }
    }
    let ordered = specs.toArray()
    sort(ordered, lessThan: { left, right => left.basePath < right.basePath }, stable: true)
    var firstPath = ""
    for (left in ordered) {
        if (firstPath.isEmpty()) { firstPath = left.basePath; continue }
        if (left.basePath.startsWith(firstPath + "/") || firstPath.startsWith(left.basePath + "/")) {
            throw IllegalArgumentException("version base paths overlap")
        }
        firstPath = left.basePath
    }
    let latest = match (options.latestVersion) {
        case Some(value) =>
            if (!ids.contains(value)) { throw IllegalArgumentException("--latest names an unknown version '${value}'") }
            value
        case None => firstId
    }
    let policy = if (options.latestVersion.isSome()) { "explicit" } else { "first-listed" }
    (ArrayList<VersionComposeSpec>(ordered), latest, policy)
}

private func versionOutputPath(site: VersionSite, relative: String): String {
    "${site.spec.basePath}/${relative}"
}

private func versionRelativeHref(fromPath: String, toPath: String): String {
    let parts = fromPath.split("/")
    let out = StringBuilder()
    var index: Int64 = 0
    while (index + 1 < parts.size) {
        out.append("../")
        index++
    }
    out.append(toPath)
    out.toString()
}

private func versionTargetRoute(current: VersionSite, relative: String, target: VersionSite): (String, Bool) {
    match (current.symbols.idByHref.get(relative)) {
        case Some(id) => match (target.symbols.hrefById.get(id)) {
            case Some(href) => (href, false)
            case None => ("index.html", true)
        }
        case None => if (target.hasPath(relative)) { (relative, false) } else { ("index.html", false) }
    }
}

private func versionSelector(current: VersionSite, currentOutputPath: String,
    relative: String, sites: ArrayList<VersionSite>, limit!: Int64 = VERSION_FILE_MAX_BYTES): String {
    let out = VersionTextBuffer(limit)
    out.append("<nav class=\"cjdoc-version-selector\" aria-label=\"Documentation version\"><span>Version</span>")
    for (target in sites) {
        let (route, unavailable) = versionTargetRoute(current, relative, target)
        let targetPath = versionOutputPath(target, route)
        let href = versionRelativeHref(currentOutputPath, targetPath)
        let currentClass = if (target.spec.id == current.spec.id) { " aria-current=\"page\"" } else { "" }
        let suffix = if (unavailable && target.spec.id != current.spec.id) {
            " (symbol unavailable)"
        } else {
            ""
        }
        out.append("<a href=\"${public_render.escapeStandaloneHtml(href)}\"${currentClass}>${public_render.escapeStandaloneHtml(target.spec.label + suffix)}</a>")
        match (target.spec.apiDiffSource) {
            case Some(_) =>
                let diffPath = versionOutputPath(target, "api-diff.json")
                let diffHref = versionRelativeHref(currentOutputPath, diffPath)
                out.append(" <a href=\"${public_render.escapeStandaloneHtml(diffHref)}\">Changes</a>")
            case None => ()
        }
    }
    out.append("</nav>\n")
    out.toString()
}

private func injectVersionSelector(html: String, selector: String): String {
    let shellMarker = "<div class=\"docs-layout\">"
    match (html.indexOf(shellMarker)) {
        case Some(index) => html[..index] + selector + html[index..]
        case None =>
            match (html.indexOf("</header>")) {
                case Some(index) =>
                    let end = index + "</header>".size
                    html[..end] + selector + html[end..]
                case None =>
                    match (html.indexOf("</body>")) {
                        case Some(index) => html[..index] + selector + html[index..]
                        case None => html + selector
                    }
            }
    }
}
private func versionManifest(sites: ArrayList<VersionSite>, latest: String,
    latestPolicy: String): String {
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"${VERSION_MANIFEST_SCHEMA}\",\n")
    out.append("  \"project\": \"composed\",\n  \"latest\": ${versionJsonEscape(latest)},\n")
    out.append("  \"latestPolicy\": ${versionJsonEscape(latestPolicy)},\n  \"versions\": [")
    var first = true
    for (site in sites) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\":${versionJsonEscape(site.spec.id)},\"label\":${versionJsonEscape(site.spec.label)},")
        out.append("\"basePath\":${versionJsonEscape(site.spec.basePath)},\"channel\":${versionJsonEscape(site.spec.channel)},")
        out.append("\"status\":${versionJsonEscape(site.spec.status)},\"index\":${versionJsonEscape(versionOutputPath(site, "index.html"))},")
        let symbolIndex = if (site.hasPath("symbol-index.json")) {
            versionJsonEscape(versionOutputPath(site, "symbol-index.json"))
        } else {
            "null"
        }
        let apiDiff = match (site.spec.apiDiffSource) {
            case Some(_) => versionJsonEscape(versionOutputPath(site, "api-diff.json"))
            case None => "null"
        }
        out.append("\"symbolIndex\":" + symbolIndex + ",\"apiDiff\":" + apiDiff)
        match (site.spec.release) {
            case Some(value) => out.append(",\"release\":${versionJsonEscape(value)}")
            case None => ()
        }
        out.append("}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func versionRootIndex(sites: ArrayList<VersionSite>, latest: String): String {
    let out = StringBuilder()
    out.append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>Documentation versions</title><style>")
    out.append(":root{color-scheme:light;--ink:#17212b;--muted:#536071;--surface:#f5f7fa;--surface-raised:#fff;--line:#d7dee8;--accent:#176b5d;--accent-soft:#dff4ef;--shadow:0 18px 48px rgba(23,33,43,.12);font:16px/1.6 system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}*{box-sizing:border-box}body{margin:0;background:var(--surface);color:var(--ink)}.site-nav{border-bottom:1px solid var(--line);background:var(--surface-raised)}.site-nav-inner{max-width:1080px;margin:0 auto;padding:1rem 1.5rem;display:flex;align-items:center;justify-content:space-between;gap:1rem}.brand{color:inherit;text-decoration:none;display:flex;align-items:center;gap:.7rem}.brand-mark{display:grid;place-items:center;width:2rem;height:2rem;border-radius:7px;background:#176b5d;color:#fff;font:700 .95rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}.brand-copy{display:flex;flex-direction:column;line-height:1.15}.brand-project{font-size:.98rem}.brand-subtitle,.version-root-meta{color:var(--muted);font-size:.8rem}.version-root{max-width:900px;margin:0 auto;padding:clamp(3rem,8vw,7rem) 1.5rem}.eyebrow{margin:0 0 .75rem;color:var(--accent);font:700 .75rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase}.version-root h1{max-width:12ch;margin:0;font-size:clamp(2.4rem,7vw,5.2rem);line-height:.98;letter-spacing:-.06em}.page-lead{max-width:44rem;margin:1.4rem 0 2.5rem;color:var(--muted);font-size:1.08rem}.version-list{display:grid;gap:.75rem}.version-card{display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:1.1rem 1.2rem;border:1px solid var(--line);border-radius:10px;background:var(--surface-raised);box-shadow:var(--shadow);color:inherit;text-decoration:none}.version-card:hover,.version-card:focus-visible{border-color:var(--accent);outline:2px solid var(--accent-soft);outline-offset:2px}.version-card-main{display:flex;flex-direction:column}.version-card-main strong{font-size:1.08rem}.version-card-main span,.version-card-meta{color:var(--muted);font-size:.85rem}.site-footer{max-width:900px;margin:0 auto;padding:1.5rem;color:var(--muted);font-size:.8rem}@media(prefers-color-scheme:dark){:root{color-scheme:dark;--ink:#e8eef5;--muted:#aab7c7;--surface:#111820;--surface-raised:#18222d;--line:#2b3948;--accent:#5ed6bd;--accent-soft:#123b34;--shadow:0 18px 48px rgba(0,0,0,.3)}}@media(max-width:600px){.site-nav-inner{padding:.8rem 1rem}.version-root{padding:3rem 1rem}.version-card{align-items:flex-start;flex-direction:column}.version-root h1{font-size:3.3rem}.version-root-meta{display:none}}</style></head><body data-cjdoc-route=\"version-root\"><header class=\"site-nav\"><div class=\"site-nav-inner\"><a class=\"brand\" href=\"latest/index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span class=\"brand-copy\"><strong class=\"brand-project\">Documentation</strong><span class=\"brand-subtitle\">Version index</span></span></a><span class=\"version-root-meta\">Composed by cjdoc</span></div></header><main class=\"version-root\"><p class=\"eyebrow\">Documentation versions</p><h1>Choose a version.</h1><p class=\"page-lead\">Select the project and document version that matches the API reference you want to read.</p><nav class=\"version-list\" aria-label=\"Documentation versions\">")
    for (site in sites) {
        let href = public_render.escapeStandaloneHtml(versionOutputPath(site, "index.html"))
        let label = public_render.escapeStandaloneHtml(site.spec.label)
        let channel = public_render.escapeStandaloneHtml(site.spec.channel)
        let latestText = if (site.spec.id == latest) { "Latest" } else { "" }
        out.append("<a class=\"version-card\" href=\"")
        out.append(href)
        out.append("\"><span class=\"version-card-main\"><strong>")
        out.append(label)
        out.append("</strong><span>")
        out.append(channel)
        out.append("</span></span><span class=\"version-card-meta\">")
        out.append(latestText)
        match (site.spec.release) {
            case Some(value) =>
                if (!latestText.isEmpty()) { out.append(" · ") }
                out.append("Released ")
                out.append(public_render.escapeStandaloneHtml(value))
            case None => ()
        }
        out.append("</span></a>\n")
    }
    out.append("</nav></main><footer class=\"site-footer\"><span>cjdoc · Version manifest: </span><a href=\"versions.json\">versions.json</a></footer></body></html>\n")
    out.toString()
}
private func versionLatestIndex(sites: ArrayList<VersionSite>, latest: String): String {
    for (site in sites) {
        if (site.spec.id == latest) {
            let href = "../${versionOutputPath(site, "index.html")}".replace("//", "/")
            return "<!doctype html><meta http-equiv=\"refresh\" content=\"0; url=${public_render.escapeStandaloneHtml(href)}\"><title>Latest documentation</title><p><a href=\"${public_render.escapeStandaloneHtml(href)}\">Latest documentation</a></p>\n"
        }
    }
    throw IllegalArgumentException("latest version disappeared during composition")
}

private func rewriteComposedDoctestEvidence(html: String, site: VersionSite,
    outputPath: String, filePath: String): String {
    if (!site.hasPath("doctest/results.json") || filePath != "validation.html") { return html }
    let evidencePath = versionOutputPath(site, "doctest/results.json")
    let href = versionRelativeHref(outputPath, evidencePath)
    html.replace("href=\"../doctest/results.json\"", "href=\"" + public_render.escapeStandaloneHtml(href) + "\"")
}

private func attachComposedApiDiffEvidence(html: String, site: VersionSite,
    outputPath: String, filePath: String): String {
    if (site.spec.apiDiffSource.isNone() || filePath != "validation.html") { return html }
    let diffPath = versionOutputPath(site, "api-diff.json")
    let href = versionRelativeHref(outputPath, diffPath)
    let link = "<a href=\"" + public_render.escapeStandaloneHtml(href) + "\">api-diff.json</a>"
    var result = html
    result = result.replace("API diff: not attached to this generation", "API diff: attached: " + link)
    result = result.replace("API diff：本次生成未附带", "API diff：已附带：" + link)
    result = result.replace("No comparison report was attached to this generation. Run the explicit cjdoc diff command to inspect version-to-version changes; this page does not infer compatibility.", "Attached comparison report: " + link + ".")
    result = result.replace("本次生成未附带比较报告。请显式运行 cjdoc diff 命令检查版本间变化；本页面不会推断兼容性。", "已附带比较报告：" + link + "。")
    result
}

private func composeVersionArtifacts(sites: ArrayList<VersionSite>, latest: String,
    latestPolicy: String, budget: VersionComposeBudget): Array<public_render.RenderArtifact> {
    let artifacts = ArrayList<public_render.RenderArtifact>()
    for (site in sites) {
        for (file in site.files) {
            let outputPath = versionOutputPath(site, file.path)
            if (file.path.endsWith(".html")) {
                let remaining = budget.remainingBytes()
                if (file.bytes.size >= remaining) {
                    throw IllegalArgumentException("version artifact '${outputPath}' exceeds composition memory budget")
                }
                let selectorAvailable = remaining - file.bytes.size
                let selectorLimit = if (selectorAvailable < VERSION_FILE_MAX_BYTES) {
                    selectorAvailable
                } else {
                    VERSION_FILE_MAX_BYTES
                }
                let selector = versionSelector(site, outputPath, file.path, sites, limit: selectorLimit)
                budget.reserveArtifact(outputPath, file.bytes.size + selector.size)
                let html = try { String.fromUtf8(file.bytes) } catch (_: Exception) {
                    throw IllegalArgumentException("version HTML is not UTF-8 '${file.path}'")
                }
                let withEvidence = rewriteComposedDoctestEvidence(html, site, outputPath, file.path)
                let content = injectVersionSelector(attachComposedApiDiffEvidence(withEvidence, site, outputPath, file.path), selector)
                artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, content))
            } else {
                budget.reserveArtifact(outputPath, file.bytes.size)
                artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, file.bytes))
            }
        }
    }
    let manifest = versionManifest(sites, latest, latestPolicy)
    budget.reserveArtifact("versions.json", manifest.size)
    artifacts.add(public_render.RenderArtifact("versions.json", "application/json", manifest))
    let rootIndex = versionRootIndex(sites, latest)
    budget.reserveArtifact("index.html", rootIndex.size)
    artifacts.add(public_render.RenderArtifact("index.html", "text/html; charset=utf-8", rootIndex))
    let latestIndex = versionLatestIndex(sites, latest)
    budget.reserveArtifact("latest/index.html", latestIndex.size)
    artifacts.add(public_render.RenderArtifact("latest/index.html", "text/html; charset=utf-8", latestIndex))
    artifacts.toArray()
}

internal func appendDocumentVersionArtifact(artifacts: ArrayList<public_render.RenderArtifact>,
    version: String, projectName: String): Unit {
    if (!versionSafeId(version)) {
        throw IllegalArgumentException("--doc-version must be a safe version identifier")
    }
    let content = "{\n  \"schemaVersion\": \"${VERSION_FILE_SCHEMA}\",\n  \"id\": ${versionJsonEscape(version)},\n  \"label\": ${versionJsonEscape(version)},\n  \"project\": ${versionJsonEscape(projectName)}\n}\n"
    artifacts.add(public_render.RenderArtifact("html/version.json", "application/json", content))
}

internal func runVersionsCompose(options: NewCliOptions): Int64 {
    let output = match (options.output) {
        case Some(path) => path
        case None => throw IllegalArgumentException("versions compose requires --output")
    }
    let (specs, latest, latestPolicy) = buildVersionSpecs(options)
    let sites = ArrayList<VersionSite>()
    let budget = VersionComposeBudget()
    for (spec in specs) { sites.add(loadVersionSite(spec, budget)) }
    let outputPath = canonicalForWrite(Path(output), "version composition output")
    for (site in sites) {
        let source = canonicalize(Path(site.spec.source))
        if (pathContains(source, outputPath) || pathContains(outputPath, source)) {
            throw IllegalArgumentException("version source and composition output overlap")
        }
        match (site.spec.apiDiffSource) {
            case Some(path) =>
                let diff = canonicalize(Path(path))
                if (pathContains(diff, outputPath) || pathContains(outputPath, diff)) {
                    throw IllegalArgumentException("version API diff and composition output overlap")
                }
            case None => ()
        }
    }
    let artifacts = composeVersionArtifacts(sites, latest, latestPolicy, budget)
    let (prepared, _) = prepareOutputAndCacheDirectories(output, None<String>)
    completeLockedOutputCommand(prepared, { lock =>
        writeOwnedArtifactsWithLockHeld(prepared, artifacts, lock, forceOwned: options.forceOwned)
        0
    }, { => println("composed ${sites.size} documentation versions into ${output}") })
}
