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
    let out = StringBuilder()
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case r'\\' => out.append("\\\\")
            case r'"' => out.append("\\\"")
            case r'\n' => out.append("\\n")
            case r'\r' => out.append("\\r")
            case r'\t' => out.append("\\t")
            case _ => out.append(rune)
        }
    }
    out.append("\"")
    out.toString()
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

private func versionSafeBasePath(value: String): Bool {
    value != "latest" && isSafeOutputPath(value) && !value.startsWith(".")
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
        let bytes = readFileBounded(info.path, VERSION_FILE_MAX_BYTES)
        budget.reserve(child, bytes.size)
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
private func loadVersionApiDiff(spec: VersionComposeSpec): VersionSourceFile {
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
    let bytes = readFileBounded(path, VERSION_DIFF_MAX_BYTES)
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
            let apiDiff = loadVersionApiDiff(spec)
            budget.reserve("api-diff.json", apiDiff.bytes.size)
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
    relative: String, sites: ArrayList<VersionSite>): String {
    let out = StringBuilder()
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

private func injectVersionSelector(html: String, current: VersionSite, relative: String,
    sites: ArrayList<VersionSite>): String {
    let outputPath = versionOutputPath(current, relative)
    let selector = versionSelector(current, outputPath, relative, sites)
    match (html.indexOf("</body>")) {
        case Some(index) => html[..index] + selector + html[index..]
        case None => html + selector
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
    out.append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Versioned documentation</title></head><body><main><h1>Versioned documentation</h1><p>Choose a documentation version.</p><ul>")
    for (site in sites) {
        let marker = if (site.spec.id == latest) { " (latest)" } else { "" }
        out.append("<li><a href=\"${public_render.escapeStandaloneHtml(versionOutputPath(site, "index.html"))}\">${public_render.escapeStandaloneHtml(site.spec.label + marker)}</a> <small>${public_render.escapeStandaloneHtml(site.spec.channel)}</small></li>")
    }
    out.append("</ul><p><a href=\"versions.json\">Machine-readable version manifest</a></p></main></body></html>\n")
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

private func composeVersionArtifacts(sites: ArrayList<VersionSite>, latest: String,
    latestPolicy: String): Array<public_render.RenderArtifact> {
    let artifacts = ArrayList<public_render.RenderArtifact>()
    for (site in sites) {
        for (file in site.files) {
            let outputPath = versionOutputPath(site, file.path)
            let bytes = if (file.path.endsWith(".html")) {
                let html = try { String.fromUtf8(file.bytes) } catch (_: Exception) {
                    throw IllegalArgumentException("version HTML is not UTF-8 '${file.path}'")
                }
                injectVersionSelector(html, site, file.path, sites).toArray()
            } else {
                file.bytes
            }
            artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, bytes))
        }
    }
    artifacts.add(public_render.RenderArtifact("versions.json", "application/json",
        versionManifest(sites, latest, latestPolicy)))
    artifacts.add(public_render.RenderArtifact("index.html", "text/html; charset=utf-8",
        versionRootIndex(sites, latest)))
    artifacts.add(public_render.RenderArtifact("latest/index.html", "text/html; charset=utf-8",
        versionLatestIndex(sites, latest)))
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
    let artifacts = composeVersionArtifacts(sites, latest, latestPolicy)
    let (prepared, _) = prepareOutputAndCacheDirectories(output, None<String>)
    completeLockedOutputCommand(prepared, { lock =>
        writeOwnedArtifactsWithLockHeld(prepared, artifacts, lock, forceOwned: options.forceOwned)
        0
    }, { => println("composed ${sites.size} documentation versions into ${output}") })
}
