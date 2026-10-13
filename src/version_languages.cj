package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import yjson.*

internal func loadVersionLanguageRoutes(site: VersionSite, files: ArrayList<VersionSourceFile>, paths: HashSet<String>): Unit {
    let anchors = HashMap<String, HashSet<String>>()
    for (file in files where file.path.endsWith(".html")) {
        let ids = HashSet<String>()
        for (id in public_render.documentationHtmlAnchors(String.fromUtf8(file.bytes))) { let _ = ids.add(id) }
        anchors[file.path] = ids
    }
    for (file in files where file.path == "site-manifest.json") {
        let object = JsonNode.parse(String.fromUtf8(file.bytes), config: JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 24,
            maxInputBytes: VERSION_FILE_MAX_BYTES, maxBufferedValueBytes: VERSION_FILE_MAX_BYTES)).asObject()
        if (object["schemaVersion"].asString() != "cjdoc.site-manifest/1") { throw IllegalArgumentException("unsupported site manifest") }
        let languageNode = object.get("defaultLanguage")
        if (languageNode.isSome() && !languageNode.getOrThrow().isNull) { site.defaultLanguage = public_model.documentationLanguage(languageNode.getOrThrow().asString()) }
        for (node in versionJsonArrayValues(object["routes"].asArray())) {
            let route = node.asObject()
            let language = public_model.documentationLanguage(route["language"].asString())
            let href = route["href"].asString()
            let parts = href.split("#", 2)
            if (!isSafeOutputPath(parts[0]) || !paths.contains(parts[0])) { throw IllegalArgumentException("site manifest points outside emitted files") }
            if (parts.size == 2 && (!anchors.contains(parts[0]) || !anchors[parts[0]].contains(parts[1]))) {
                throw IllegalArgumentException("site manifest points to a nonexistent emitted fragment")
            }
            var identity = language + ":"
            if (!route["symbolId"].isNull) {
                if (!route["pageId"].isNull) { identity += route["pageId"].asString() + ":" }
                identity += "symbol:" + route["symbolId"].asString()
            }
            else if (!route["pageId"].isNull) { identity += "page:" + route["pageId"].asString() }
            else { throw IllegalArgumentException("site route has no explicit identity") }
            if (!route["sectionId"].isNull) { identity += ":section:" + route["sectionId"].asString() }
            if (site.logicalRoutes.contains(identity)) { throw IllegalArgumentException("duplicate logical site route") }
            site.logicalRoutes[identity] = href
            let owner = route.get("ownerSymbolId")
            if (owner.isSome() && !owner.getOrThrow().isNull) { site.parentsByIdentity[identity] = language + ":symbol:" + owner.getOrThrow().asString() }
            site.logicalIdsByHref[href] = identity
            if (parts.size == 2) {
                if (!site.sectionIdsByPage.contains(parts[0])) { site.sectionIdsByPage[parts[0]] = HashMap<String, String>() }
                site.sectionIdsByPage[parts[0]][parts[1]] = identity
            }
        }
    }
}

internal func versionLanguageTarget(current: VersionSite, identity: String, target: VersionSite): (String, Bool) {
    if (let Some(href) <- target.logicalRoutes.get(identity)) { return (href, false) }
    let parts = identity.split(":", 2)
    let language = parts[0]
    if (!target.defaultLanguage.isEmpty() && parts.size == 2) {
        if (let Some(href) <- target.logicalRoutes.get(target.defaultLanguage + ":" + parts[1])) { return (href, true) }
    }
    var parent = current.parentsByIdentity.get(identity)
    let visited = HashSet<String>()
    while (parent.isSome() && visited.add(parent.getOrThrow())) {
        let key = parent.getOrThrow()
        if (let Some(href) <- target.logicalRoutes.get(key)) { return (href, true) }
        let ownerParts = key.split(":", 2)
        if (!target.defaultLanguage.isEmpty() && ownerParts.size == 2) {
            if (let Some(href) <- target.logicalRoutes.get(target.defaultLanguage + ":" + ownerParts[1])) {
                return (href, true)
            }
        }
        parent = current.parentsByIdentity.get(key)
    }
    let section = identity.indexOf(":section:")
    if (let Some(at) <- section) {
        if (let Some(href) <- target.logicalRoutes.get(identity[..at])) { return (href, true) }
    }
    let home = "html/" + language + "/index.html"
    if (target.hasPath(home)) { return (home, true) }
    if (!target.defaultLanguage.isEmpty()) {
        let defaultHome = "html/" + target.defaultLanguage + "/index.html"
        if (target.hasPath(defaultHome)) { return (defaultHome, true) }
    }
    ("index.html", true)
}
