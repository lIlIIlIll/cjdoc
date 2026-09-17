package cjdoc

import std.collection.*
import std.fs.*
import yjson.*

internal let EXTERNAL_DOC_INDEX_MAX_BYTES: Int64 = 8 * 1024 * 1024
internal let EXTERNAL_DOC_CONFIG_MAX_BYTES: Int64 = 64 * 1024

internal class ExternalDocResolver {
    public let name: String
    public let baseUrl: String
    public let state: String
    public let reason: String
    private let targets = HashMap<String, String>()

    init(name: String, baseUrl: String, state!: String = "available", reason!: String = "") {
        this.name = name
        this.baseUrl = baseUrl
        this.state = state
        this.reason = reason
    }

    func addTarget(key: String, url: String): Unit {
        if (key.isEmpty()) { return }
        match (targets.get(key)) {
            case Some(existing) => if (existing != url) { targets[key] = "" }
            case None => targets[key] = url
        }
    }

    func matchTarget(target: String): (String, Bool) {
        match (targets.get(target)) {
            case Some(url) => (url, url.isEmpty())
            case None => ("", false)
        }
    }
}

private func externalTomlValue(value: String): String {
    var cleaned = value.trimAscii()
    match (cleaned.indexOf("#")) {
        case Some(index) => cleaned = cleaned[..index].trimAscii()
        case None => ()
    }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        return cleaned.removePrefix("\"").removeSuffix("\"")
    }
    cleaned
}

private func safeExternalBaseUrl(value: String): Bool {
    (value.startsWith("https://") || value.startsWith("http://")) &&
        !value.contains(" ") && !value.contains("\t") && !value.contains("\n") &&
        !value.contains("#") && !value.contains("?")
}

private func safeExternalHref(baseUrl: String, href: String): ?String {
    if (href.startsWith("http://") || href.startsWith("https://")) {
        if (!safeExternalBaseUrl(href)) { return None }
        return Some(href)
    }
    var relative = href.trimAscii()
    while (relative.startsWith("/")) { relative = relative.removePrefix("/") }
    if (relative.isEmpty() || relative.contains("..") || relative.contains("\\") ||
        relative.contains(" ") || relative.contains("#") || relative.contains("?")) { return None }
    Some(baseUrl + "/" + relative)
}

private func jsonObjectField(object: JsonObject, key: String): ?JsonNode {
    object.get(key)
}

private func jsonStringField(object: JsonObject, key: String): ?String {
    match (jsonObjectField(object, key)) {
        case Some(value) => try { Some(value.asString()) } catch (_: Exception) { None }
        case None => None
    }
}

private func jsonArrayValues(value: JsonArray): Array<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (index in 0..value.size()) { result.add(value.get(index).getOrThrow()) }
    result.toArray()
}

private func addExternalEntry(resolver: ExternalDocResolver, object: JsonObject): Unit {
    let href = match (jsonStringField(object, "href")) {
        case Some(value) => value
        case None => return
    }
    let url = match (safeExternalHref(resolver.baseUrl, href)) {
        case Some(value) => value
        case None => return
    }
    for (key in ["id", "canonicalId", "qualifiedName", "name"]) {
        match (jsonStringField(object, key)) {
            case Some(value) => resolver.addTarget(value, url)
            case None => ()
        }
    }
}

private func loadExternalIndex(projectRoot: String, name: String, indexPath: String,
    baseUrl: String, expectedVersion: ?String): ExternalDocResolver {
    let resolver = ExternalDocResolver(name, baseUrl)
    if (!safeExternalBaseUrl(baseUrl)) {
        return ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation base URL is unsafe")
    }
    let path = if (indexPath.startsWith("/") || indexPath.contains(":")) {
        Path(indexPath)
    } else {
        Path(projectRoot).join(indexPath)
    }
    if (!exists(path)) {
        return ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation index is missing")
    }
    try {
        let parsed = JsonNode.parse(readTextBounded(path, EXTERNAL_DOC_INDEX_MAX_BYTES),
            config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
                maxDepth: 32, maxStringBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
                maxBufferedValueBytes: EXTERNAL_DOC_INDEX_MAX_BYTES,
                maxInputBytes: EXTERNAL_DOC_INDEX_MAX_BYTES))
        let object = parsed.asObject()
        let schemaVersion = match (jsonStringField(object, "schemaVersion")) {
            case Some(value) => value
            case None => ""
        }
        if (schemaVersion != "cjdoc.symbol-index/1") {
            return ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation index schema is stale")
        }
        match (expectedVersion) {
            case Some(version) =>
                if (jsonStringField(object, "version") != Some(version)) {
                    return ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation index version is stale")
                }
            case None => ()
        }
        let entries = match (jsonObjectField(object, "symbols")) {
            case Some(value) => value.asArray()
            case None => match (jsonObjectField(object, "entries")) {
                case Some(value) => value.asArray()
                case None => throw IllegalArgumentException("external documentation index has no symbols or entries")
            }
        }
        for (entry in jsonArrayValues(entries)) {
            addExternalEntry(resolver, entry.asObject())
        }
        resolver
    } catch (_: Exception) {
        ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation index is invalid")
    }
}

private func appendExternalResolver(result: ArrayList<ExternalDocResolver>, projectRoot: String,
    name: String, indexPath: String, baseUrl: String, version: ?String): Unit {
    if (name.isEmpty()) { return }
    if (indexPath.isEmpty() || baseUrl.isEmpty()) {
        result.add(ExternalDocResolver(name, baseUrl, state: "unavailable", reason: "external documentation configuration is incomplete"))
    } else {
        result.add(loadExternalIndex(projectRoot, name, indexPath, baseUrl, version))
    }
}

internal func loadExternalDocResolvers(projectRoot: String): Array<ExternalDocResolver> {
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return [] }
    let text = readTextBounded(path, EXTERNAL_DOC_CONFIG_MAX_BYTES)
    var section = ""
    var name = ""
    var indexPath = ""
    var baseUrl = ""
    var version: ?String = None
    let result = ArrayList<ExternalDocResolver>()
    for (rawLine in text.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            if (section.startsWith("external-docs.")) {
                appendExternalResolver(result, projectRoot, name, indexPath, baseUrl, version)
                name = ""
                indexPath = ""
                baseUrl = ""
                version = None
            }
            section = line.removePrefix("[").removeSuffix("]").trimAscii()
            if (section.startsWith("external-docs.")) {
                name = section.removePrefix("external-docs.")
            }
            continue
        }
        if (!section.startsWith("external-docs.")) { continue }
        let parts = line.split("=", 2)
        if (parts.size != 2) { continue }
        let key = parts[0].trimAscii()
        let value = externalTomlValue(parts[1])
        match (key) {
            case "index" => indexPath = value
            case "base-url" => baseUrl = if (value.endsWith("/")) { value[..value.size - 1] } else { value }
            case "version" => version = Some(value)
            case _ => ()
        }
    }
    if (section.startsWith("external-docs.")) {
        appendExternalResolver(result, projectRoot, name, indexPath, baseUrl, version)
    }
    result.toArray()
}
