protected package cjdoc.versions

import cjdoc.filesystem.readFileBounded
import cjdoc.output.{isSafeOutputPath, validateOwnedManifest}
import std.collection.*
import std.fs.*
import std.sort.*
import yjson.*

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

private func versionJsonStringField(object: JsonObject, key: String): ?String {
    match (object.get(key)) {
        case Some(value) => try { Some(value.asString()) } catch (_: Exception) { None }
        case None => None
    }
}

internal func versionJsonArrayValues(value: JsonArray): Array<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (index in 0..value.size()) { result.add(value.get(index).getOrThrow()) }
    result.toArray()
}

private func loadVersionContextRelations(index: VersionSymbolIndex, owner: String,
    entry: JsonObject): Unit {
    let relations = match (entry.get("relations")) {
        case Some(value) => try { value.asArray() } catch (_: Exception) { return }
        case None => return
    }
    for (node in versionJsonArrayValues(relations)) {
        let relation = try { node.asObject() } catch (_: Exception) { continue }
        let kind = match (versionJsonStringField(relation, "kind")) {
            case Some(value) => value
            case None => continue
        }
        let state = match (versionJsonStringField(relation, "state")) {
            case Some(value) => value
            case None => continue
        }
        match (versionJsonStringField(relation, "targetId")) {
            case Some(target) => index.addContextRelation(owner, kind, state, target)
            case None => ()
        }
    }
}

private func collectVersionFilesInDirectory(directory: Path, relative: String,
    files: ArrayList<VersionSourceFile>, seen: HashSet<String>, budget: VersionComposeBudget): Unit {
    for (info in Directory.readFrom(directory)) {
        if (info.isSymbolicLink()) {
            throw IllegalArgumentException("version source contains a symbolic link '${info.path}'")
        }
        let child = if (relative.isEmpty()) { info.name } else { "${relative}/${info.name}" }
        if (relative.isEmpty() && info.name == ".cjdoc-output.json") {
            if (!info.isRegular()) { throw IllegalArgumentException("version ownership manifest must be a regular file") }
            let _ = validateOwnedManifest(directory)
            continue
        }
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

internal func loadVersionSymbols(files: ArrayList<VersionSourceFile>): VersionSymbolIndex {
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
            case Some(value) => if (value != "cjdoc.symbol-index/2") {
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
            let kind = match (versionJsonStringField(entry, "kind")) {
                case Some(value) => value
                case None => ""
            }
            result.add(id, href, owner: versionJsonStringField(entry, "ownerId"), kind: kind)
            loadVersionContextRelations(result, id, entry)
        }
    }
    result.resolveContextMembers()
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
        case Some(value) => if (value != "cjdoc.api-diff/1" && value != "cjdoc.api-diff/2") {
            throw IllegalArgumentException("version API diff schema is unsupported '${source}'")
        }
        case None => throw IllegalArgumentException("version API diff has no schemaVersion '${source}'")
    }
    VersionSourceFile("api-diff.json", "application/json", bytes)
}


internal func loadVersionSite(spec: VersionComposeSpec, budget: VersionComposeBudget): VersionSite {
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
    var multilingual = false
    for (file in files) { if (file.path == "site-manifest.json") { multilingual = true } }
    if (!seen.contains("index.html") && !multilingual) {
        throw IllegalArgumentException("version source has no index.html '${spec.source}'")
    }
    let site = VersionSite(spec, loadVersionSymbols(files))
    if (multilingual) {
        loadVersionLanguageRoutes(site, files, seen)
        if (!seen.contains("index.html")) {
            let home = StringBuilder()
            home.append("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Documentation languages</title><body><h1>Documentation languages</h1><ul>")
            for (language in ["en", "zh-CN"]) {
                let path = "html/" + language + "/index.html"
                if (seen.contains(path)) { home.append("<li><a href=\"" + path + "\">" + language + "</a></li>") }
            }
            home.append("</ul></body></html>")
            budget.reserve("index.html", home.toString().size)
            files.add(VersionSourceFile("index.html", "text/html; charset=utf-8", home.toString().toArray()))
        }
    } else {
        loadMonolingualVersionRoutes(site, files)
    }
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
