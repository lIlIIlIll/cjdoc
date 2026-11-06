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
            let pageId = if (route["pageId"].isNull) { None<String> } else { Some(route["pageId"].asString()) }
            let symbolId = if (route["symbolId"].isNull) { None<String> } else { Some(route["symbolId"].asString()) }
            let sectionId = if (route["sectionId"].isNull) { None<String> } else { Some(route["sectionId"].asString()) }
            if (pageId.isNone() && symbolId.isNone()) { throw IllegalArgumentException("site route has no explicit identity") }
            let identity = VersionLogicalIdentity(language, pageId: pageId, symbolId: symbolId,
                sectionId: sectionId)
            let key = identity.key()
            if (site.logicalRoutes.contains(key)) { throw IllegalArgumentException("duplicate logical site route") }
            site.logicalRoutes[key] = href
            let owner = route.get("ownerSymbolId")
            if (owner.isSome() && !owner.getOrThrow().isNull) {
                site.parentsByIdentity[key] = VersionLogicalIdentity(language,
                    symbolId: Some(owner.getOrThrow().asString()))
            }
            site.logicalIdentityByHref[href] = identity
            if (parts.size == 2) {
                if (!site.sectionIdsByPage.contains(parts[0])) {
                    site.sectionIdsByPage[parts[0]] = HashMap<String, VersionLogicalIdentity>()
                }
                site.sectionIdsByPage[parts[0]][parts[1]] = identity
            }
        }
    }
}

private func versionIdentityRoute(site: VersionSite, identity: VersionLogicalIdentity): ?String {
    site.logicalRoutes.get(identity.key())
}

private func versionIdentityRouteInDefaultLanguage(site: VersionSite,
    identity: VersionLogicalIdentity): ?String {
    if (site.defaultLanguage.isEmpty()) { return None }
    site.logicalRoutes.get(identity.withLanguage(site.defaultLanguage).key())
}

private func versionHasCanonicalSymbol(target: VersionSite, identity: VersionLogicalIdentity): Bool {
    let symbolId = identity.symbolId.getOrDefault({ => "" })
    if (symbolId.isEmpty()) { return false }
    if (target.symbols.hrefById.contains(symbolId)) { return true }
    let canonical = identity.canonicalSymbolIdentity()
    if (target.logicalRoutes.contains(canonical.key()) ||
        target.logicalRoutes.contains(canonical.withLanguage(target.defaultLanguage).key())) { return true }
    target.logicalRoutes.contains(identity.withoutSection().key()) ||
        target.logicalRoutes.contains(identity.withoutSection().withLanguage(target.defaultLanguage).key())
}

private func versionHasPageRoute(target: VersionSite, identity: VersionLogicalIdentity): Bool {
    let page = identity.pageIdentity()
    target.logicalRoutes.contains(page.key()) ||
        target.logicalRoutes.contains(page.withLanguage(target.defaultLanguage).key())
}

private func versionLanguageFallbackState(identity: VersionLogicalIdentity,
    target: VersionSite): VersionNavigationState {
    if (identity.symbolId.isSome()) {
        if ((identity.sectionId.isSome() || identity.pageId.isSome()) &&
            versionHasCanonicalSymbol(target, identity)) {
            return VersionNavigationState.MissingSection
        }
        return VersionNavigationState.MissingSymbol
    }
    if (identity.sectionId.isSome() && versionHasPageRoute(target, identity)) {
        return VersionNavigationState.MissingSection
    }
    VersionNavigationState.MissingPage
}

internal func versionLanguageTarget(current: VersionSite, identity: VersionLogicalIdentity,
    target: VersionSite): VersionNavigationTarget {
    if (let Some(href) <- versionIdentityRoute(target, identity)) {
        return VersionNavigationTarget(href, VersionNavigationState.Exact)
    }
    if (let Some(href) <- versionIdentityRouteInDefaultLanguage(target, identity)) {
        return VersionNavigationTarget(href, VersionNavigationState.MissingLanguage)
    }
    let state = versionLanguageFallbackState(identity, target)
    var parent = current.parentsByIdentity.get(identity.key())
    let visited = HashSet<String>()
    while (parent.isSome() && visited.add(parent.getOrThrow().key())) {
        let owner = parent.getOrThrow()
        if (let Some(href) <- versionIdentityRoute(target, owner)) {
            return VersionNavigationTarget(href, state)
        }
        if (let Some(href) <- versionIdentityRouteInDefaultLanguage(target, owner)) {
            return VersionNavigationTarget(href, state)
        }
        parent = current.parentsByIdentity.get(owner.key())
    }
    if (identity.sectionId.isSome()) {
        let page = identity.withoutSection()
        if (let Some(href) <- versionIdentityRoute(target, page)) {
            return VersionNavigationTarget(href, state)
        }
        if (let Some(href) <- versionIdentityRouteInDefaultLanguage(target, page)) {
            return VersionNavigationTarget(href, state)
        }
    }
    let home = "html/" + identity.language + "/index.html"
    if (target.hasPath(home)) { return VersionNavigationTarget(home, state) }
    if (!target.defaultLanguage.isEmpty()) {
        let defaultHome = "html/" + target.defaultLanguage + "/index.html"
        if (target.hasPath(defaultHome)) { return VersionNavigationTarget(defaultHome, state) }
    }
    VersionNavigationTarget("index.html", state)
}
