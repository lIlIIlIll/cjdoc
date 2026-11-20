package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import yjson.*

// A package compatibility body keeps the full package content but carries no
// generated page identity: it is one physical address of the package, not a
// second package page. A version never registers it as a destination.
private func versionCompatibilityPackageBody(html: String): Bool {
    if (public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-route") == Some("package-alias")) {
        return true
    }
    public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-package-alias-for").isSome()
}

private func registerVersionApiDirectory(site: VersionSite, file: String, html: String): Unit {
    if (!file.endsWith("/index.html")) { return }
    if (public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-symbol-id").isSome() ||
        public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-page-id").isSome()) {
        let _ = site.apiDirectoryFiles.add(file)
    }
}

private func versionPageAnchors(html: String): HashSet<String> {
    let anchors = HashSet<String>()
    for (anchor in public_render.documentationHtmlAnchors(html)) { let _ = anchors.add(anchor) }
    anchors
}

/**
 * Register the declaration rows a package body really contains. The row id is
 * the stable anchor shared by every representation of that package, so the
 * logical position is the generated page identity plus the row anchor and
 * never the physical path. Rows the body lacks are not registered: a version
 * link may claim the fragment only where it actually exists.
 */
private func versionIsRowAnchor(anchor: String): Bool {
    let prefix = "symbol-"
    if (!anchor.startsWith(prefix) || anchor.size <= prefix.size) { return false }
    if ((anchor.size - prefix.size) % 2 != 0) { return false }
    for (index in prefix.size..anchor.size) {
        let byte = anchor[index]
        let hex = (byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f') ||
            (byte >= b'A' && byte <= b'F')
        if (!hex) { return false }
    }
    true
}

private func registerVersionPackageRows(site: VersionSite, file: String,
    identity: VersionLogicalIdentity, anchors: HashSet<String>): Unit {
    if (identity.pageId.isNone()) { return }
    let packagePage = identity.pageId.getOrThrow().startsWith("package:")
    if (!packagePage) { return }
    let sections = HashMap<String, VersionLogicalIdentity>()
    for (anchor in anchors) {
        if (!versionIsRowAnchor(anchor)) { continue }
        let section = VersionLogicalIdentity(identity.language, pageId: identity.pageId,
            sectionId: Some(anchor))
        sections[anchor] = section
        site.logicalRoutes[section.key()] = file + "#" + anchor
    }
    if (!sections.isEmpty()) { site.sectionIdsByPage[file] = sections }
}

private func versionPackageJsonField(object: JsonObject, key: String): ?String {
    match (object.get(key)) {
        case Some(value) => try { Some(value.asString()) } catch (_: Exception) { None }
        case None => None
    }
}

internal func loadVersionLanguageRoutes(site: VersionSite, files: ArrayList<VersionSourceFile>, paths: HashSet<String>): Unit {
    let anchors = HashMap<String, HashSet<String>>()
    for (file in files where file.path.endsWith(".html")) {
        let html = String.fromUtf8(file.bytes)
        anchors[file.path] = versionPageAnchors(html)
        if (versionCompatibilityPackageBody(html)) {
            let _ = site.compatibilityPages.add(file.path)
        } else {
            registerVersionApiDirectory(site, file.path, html)
        }
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
            // Identity follows the canonical page, not a compatibility carrier.
            if (site.compatibilityPages.contains(parts[0])) {
                throw IllegalArgumentException("site manifest names a compatibility page as a destination")
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
    // The explicit default-language body remains a package resource, not a
    // second destination. Only match the generated counterpart of a manifest entry.
    let prefix = "html/" + site.defaultLanguage + "/"
    for (file in files where file.path.startsWith(prefix) && file.path.endsWith("/index.html")) {
        if (site.compatibilityPages.contains(file.path)) { continue }
        let canonical = "html/" + file.path.removePrefix(prefix)
        if (let Some(identity) <- site.logicalIdentityByHref.get(canonical)) {
            let html = String.fromUtf8(file.bytes)
            let id = public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-symbol-id")
            let pageId = public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-page-id")
            if (identity.language != site.defaultLanguage || identity.symbolId != id ||
                identity.pageId != pageId || (id.isNone() && pageId.isNone())) { continue }
            site.logicalIdentityByHref[file.path] = identity
            if (let Some(sections) <- site.sectionIdsByPage.get(canonical)) {
                let verified = HashMap<String, VersionLogicalIdentity>()
                for ((anchor, section) in sections where anchors[file.path].contains(anchor)) {
                    verified[anchor] = section
                }
                site.sectionIdsByPage[file.path] = verified
            }
        }
    }
}

/**
 * Old monolingual publications had no generated page identity on package
 * bodies. Their only genuine package evidence is the machine manifest's
 * `kind:"package"` representation, which names the one real package page of
 * that generation. A new compatibility alias never qualifies: it redirects to
 * the canonical page instead of being a second package address.
 */
private func loadMonolingualPackageRepresentations(site: VersionSite,
    files: ArrayList<VersionSourceFile>, compatibility: HashSet<String>): Unit {
    let paths = HashSet<String>()
    for (file in files) { let _ = paths.add(file.path) }
    for (file in files where file.path == "agent/manifest.json") {
        let object = JsonNode.parse(String.fromUtf8(file.bytes), config: JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 24,
            maxInputBytes: VERSION_FILE_MAX_BYTES, maxBufferedValueBytes: VERSION_FILE_MAX_BYTES)).asObject()
        match (versionPackageJsonField(object, "schemaVersion")) {
            case Some(value) => if (value != "cjdoc.machine-manifest/1" &&
                value != "cjdoc.machine-manifest/2" && value != "cjdoc.machine-manifest/3") {
                throw IllegalArgumentException("unsupported machine manifest")
            }
            case None => throw IllegalArgumentException("machine manifest has no schemaVersion")
        }
        let representations = match (object.get("representations")) {
            case Some(value) => try { value.asArray() } catch (_: Exception) {
                throw IllegalArgumentException("machine manifest representations are invalid")
            }
            case None => throw IllegalArgumentException("machine manifest has no representations")
        }
        for (node in versionJsonArrayValues(representations)) {
            let representation = try { node.asObject() } catch (_: Exception) {
                throw IllegalArgumentException("machine manifest representation is invalid")
            }
            if (versionPackageJsonField(representation, "kind") != Some("package")) { continue }
            let id = match (versionPackageJsonField(representation, "id")) {
                case Some(value) => value
                case None => throw IllegalArgumentException("package representation has no id")
            }
            if (!id.startsWith("cjdoc:package:") || id == "cjdoc:package:") {
                throw IllegalArgumentException("package representation id is malformed")
            }
            let pageId = "package:" + id.removePrefix("cjdoc:package:")
            let href = match (versionPackageJsonField(representation, "html")) {
                case Some(value) => value
                case None => throw IllegalArgumentException("package representation has no HTML page")
            }
            if (!isSafeOutputPath(href) || !paths.contains(href)) {
                throw IllegalArgumentException("package representation points outside emitted files")
            }
            if (compatibility.contains(href)) {
                throw IllegalArgumentException(
                    "machine manifest names a package compatibility page as the package page")
            }
            let identity = VersionLogicalIdentity(site.defaultLanguage, pageId: Some(pageId))
            match (site.logicalRoutes.get(identity.key())) {
                case Some(existing) => if (existing != href) {
                    throw IllegalArgumentException(
                        "package '${pageId}' has conflicting canonical addresses")
                }
                case None =>
                    site.logicalRoutes[identity.key()] = href
                    site.logicalIdentityByHref[href] = identity
            }
        }
    }
}

internal func loadMonolingualVersionRoutes(site: VersionSite, files: ArrayList<VersionSourceFile>): Unit {
    for (file in files where file.path == "index.html") {
        let html = String.fromUtf8(file.bytes)
        site.defaultLanguage = if (html.contains("<html lang=\"zh-CN\"")) { "zh-CN" } else { "en" }
    }
    let compatibility = HashSet<String>()
    // Only pages that can carry an identity: generated directories, the
    // package subtree (historical flat files and canonical directories), and
    // symbol pages listed by the inventory. Compatibility stubs elsewhere are
    // never destinations, so they are not decoded here.
    for (file in files where file.path.endsWith("/index.html") ||
        file.path.startsWith("packages/") || site.symbols.idByHref.contains(file.path)) {
        let html = String.fromUtf8(file.bytes)
        // A compatibility body is neither a page nor a symbol destination, so
        // its content and anchors are never decoded on this path.
        if (versionCompatibilityPackageBody(html)) {
            let _ = compatibility.add(file.path)
            continue
        }
        let anchors = versionPageAnchors(html)
        registerVersionApiDirectory(site, file.path, html)
        if (let Some(pageId) <- public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-page-id")) {
            let identity = VersionLogicalIdentity(site.defaultLanguage, pageId: Some(pageId))
            site.logicalRoutes[identity.key()] = file.path
            site.logicalIdentityByHref[file.path] = identity
            if (pageId.startsWith("package:")) {
                registerVersionPackageRows(site, file.path, identity, anchors)
            }
        }
        if (let Some(id) <- site.symbols.idByHref.get(file.path)) {
            let identity = VersionLogicalIdentity(site.defaultLanguage, symbolId: Some(id))
            let key = identity.key()
            match (site.logicalRoutes.get(key)) {
                case Some(existing) => if (existing != file.path) {
                    throw IllegalArgumentException("symbol '${id}' has conflicting page addresses")
                }
                case None => site.logicalRoutes[key] = file.path
            }
            if (let Some(owner) <- site.symbols.ownerById.get(id)) {
                site.parentsByIdentity[identity.key()] = VersionLogicalIdentity(site.defaultLanguage, symbolId: Some(owner))
            }
            site.monoAnchors[file.path] = anchors
        }
    }
    loadMonolingualPackageRepresentations(site, files, compatibility)
    // A package page proven by the machine manifest also owns the scoped row
    // anchors that appear in its own body; anchors it lacks stay absent. This
    // applies to both the historical flat file and the canonical directory.
    for (file in files where file.path.endsWith("/index.html") || file.path.startsWith("packages/")) {
        let identity = match (site.logicalIdentityByHref.get(file.path)) {
            case Some(value) => value
            case None => continue
        }
        if (identity.symbolId.isSome() || identity.pageId.isNone()) { continue }
        if (!identity.pageId.getOrThrow().startsWith("package:")) { continue }
        if (site.sectionIdsByPage.contains(file.path)) { continue }
        registerVersionPackageRows(site, file.path, identity,
            versionPageAnchors(String.fromUtf8(file.bytes)))
    }
}

internal func versionIdentityRoute(site: VersionSite, identity: VersionLogicalIdentity): ?String {
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
    // A package page can exist in the requested language while the requested
    // declaration row cannot. Open that page and report the missing section
    // instead of borrowing the row from the default language. Symbol, concept
    // and every other fallback keep their existing precedence.
    if (identity.symbolId.isNone() && identity.sectionId.isSome()) {
        if (identity.pageId.map({ id => id.startsWith("package:") }).getOrDefault({ => false })) {
            if (let Some(page) <- versionIdentityRoute(target, identity.withoutSection())) {
                return VersionNavigationTarget(page, VersionNavigationState.MissingSection)
            }
        }
    }
    if (let Some(href) <- versionIdentityRouteInDefaultLanguage(target, identity)) {
        return VersionNavigationTarget(href, VersionNavigationState.MissingLanguage)
    }
    if (identity.symbolId.isSome() && (identity.sectionId.isSome() || identity.pageId.isSome())) {
        let canonical = identity.canonicalSymbolIdentity()
        if (let Some(page) <- versionIdentityRouteInDefaultLanguage(target, canonical)) {
            if (let Some(source) <- versionIdentityRoute(current, identity)) {
                let parts = source.split("#", 2)
                if (parts.size == 2 && target.monoAnchors.get(page).map({ ids => ids.contains(parts[1]) }).getOrDefault({ => false })) {
                    let state = if (target.defaultLanguage == identity.language) { VersionNavigationState.Exact }
                        else { VersionNavigationState.MissingLanguage }
                    return VersionNavigationTarget(page + "#" + parts[1], state)
                }
            }
        }
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
