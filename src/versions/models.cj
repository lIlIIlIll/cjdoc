protected package cjdoc.versions

import cjdoc.output.isSafeOutputPath
import cjdoc.render as public_render
import std.collection.*

internal let VERSION_MANIFEST_SCHEMA = "cjdoc.versions/2"
internal let VERSION_FILE_SCHEMA = "cjdoc.version/1"
internal let VERSION_FILE_MAX_BYTES: Int64 = 32 * 1024 * 1024
internal let VERSION_DIFF_MAX_BYTES: Int64 = 32 * 1024 * 1024
internal let VERSION_TOTAL_MAX_BYTES: Int64 = 256 * 1024 * 1024
protected let VERSION_MAX_SITES: Int64 = 64
internal let VERSION_COMPOSE_MAX_FILES: Int64 = 65532
internal let VERSION_CONTEXT_MAX_MEMBERS: Int64 = 4 * VERSION_COMPOSE_MAX_FILES

internal class VersionComposeBudget {
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
    let ownerById = HashMap<String, String>()
    let membersByOwner = HashMap<String, ArrayList<String>>()
    private let declaredMembersByOwner = HashMap<String, ArrayList<String>>()
    private let memberIdsByOwner = HashMap<String, HashSet<String>>()
    private let kindById = HashMap<String, String>()
    private let contextRelations = ArrayList<(String, String, String)>()
    private let contextMemberLimit: Int64
    private var contextMemberCount: Int64 = 0

    init(limit!: Int64 = VERSION_CONTEXT_MAX_MEMBERS) {
        if (limit <= 0) { throw IllegalArgumentException("invalid version context member limit") }
        this.contextMemberLimit = limit
    }

    func add(id: String, href: String, owner!: ?String = None, kind!: String = ""): Unit {
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
        kindById[id] = kind
        match (owner) {
            case Some(ownerId) =>
                if (!ownerById.contains(id)) {
                    ownerById[id] = ownerId
                    match (declaredMembersByOwner.get(ownerId)) {
                        case Some(members) => members.add(id)
                        case None => declaredMembersByOwner[ownerId] = ArrayList<String>([id])
                    }
                    addContextMember(ownerId, id)
                }
            case None => ()
        }
    }

    private func addContextMember(owner: String, id: String): Unit {
        match (memberIdsByOwner.get(owner)) {
            case Some(ids) => if (ids.contains(id)) { return }
            case None => ()
        }
        if (contextMemberCount >= contextMemberLimit) {
            throw IllegalArgumentException("version context members exceed composition memory budget")
        }
        match (memberIdsByOwner.get(owner)) {
            case Some(ids) => let _ = ids.add(id)
            case None =>
                let ids = HashSet<String>()
                let _ = ids.add(id)
                memberIdsByOwner[owner] = ids
        }
        contextMemberCount++
        match (membersByOwner.get(owner)) {
            case Some(members) => members.add(id)
            case None => membersByOwner[owner] = ArrayList<String>([id])
        }
    }

    func addContextRelation(owner: String, kind: String, state: String, target: String): Unit {
        if (state == "resolved" && (kind == "extendedBy" || kind == "inheritedMember" ||
            kind == "inherits-member")) { contextRelations.add((owner, kind, target)) }
    }

    // Mirror the renderer's explicit member projection without changing declared
    // ownership or inventing transitive inheritance/extension relationships.
    func resolveContextMembers(): Unit {
        for ((owner, kind, target) in contextRelations) {
            if (!hrefById.contains(owner) || !hrefById.contains(target)) { continue }
            if (kind == "extendedBy") {
                match (kindById.get(target)) {
                    case Some("extend") => ()
                    case _ => continue
                }
                match (declaredMembersByOwner.get(target)) {
                    case Some(members) => for (id in members) { addContextMember(owner, id) }
                    case None => ()
                }
            } else { addContextMember(owner, target) }
        }
    }
}

protected class VersionComposeSpec {
    protected let id: String
    let source: String
    protected var label: String
    protected var basePath: String
    protected var channel: String
    protected var status: String
    protected var release: ?String
    protected var apiDiffSource: ?String

    protected init(id: String, source: String) {
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

private func versionLogicalIdentityField(value: ?String): String {
    match (value) {
        case Some(text) => "S${text.size}:${text};"
        case None => "N;"
    }
}

internal class VersionLogicalIdentity {
    let language: String
    let pageId: ?String
    let symbolId: ?String
    let sectionId: ?String
    private let encodedKey: String

    init(language: String, pageId!: ?String = None, symbolId!: ?String = None,
        sectionId!: ?String = None) {
        this.language = language
        this.pageId = pageId
        this.symbolId = symbolId
        this.sectionId = sectionId
        this.encodedKey = versionLogicalIdentityField(Some(language)) +
            versionLogicalIdentityField(pageId) + versionLogicalIdentityField(symbolId) +
            versionLogicalIdentityField(sectionId)
    }

    func key(): String { encodedKey }

    func withLanguage(value: String): VersionLogicalIdentity {
        VersionLogicalIdentity(value, pageId: pageId, symbolId: symbolId, sectionId: sectionId)
    }

    func withoutSection(): VersionLogicalIdentity {
        VersionLogicalIdentity(language, pageId: pageId, symbolId: symbolId)
    }

    func pageIdentity(): VersionLogicalIdentity {
        VersionLogicalIdentity(language, pageId: pageId)
    }

    func canonicalSymbolIdentity(): VersionLogicalIdentity {
        VersionLogicalIdentity(language, symbolId: symbolId)
    }
}

internal class VersionSite {
    let spec: VersionComposeSpec
    let files = ArrayList<VersionSourceFile>()
    let paths = HashSet<String>()
    let symbols: VersionSymbolIndex
    let logicalRoutes = HashMap<String, String>()
    let logicalIdentityByHref = HashMap<String, VersionLogicalIdentity>()
    let sectionIdsByPage = HashMap<String, HashMap<String, VersionLogicalIdentity>>()
    let monoAnchors = HashMap<String, HashSet<String>>()
    let apiDirectoryFiles = HashSet<String>()
    let compatibilityPages = HashSet<String>()
    let parentsByIdentity = HashMap<String, VersionLogicalIdentity>()
    var defaultLanguage = ""

    init(spec: VersionComposeSpec, symbols: VersionSymbolIndex) {
        this.spec = spec
        this.symbols = symbols
    }

    func hasPath(path: String): Bool { paths.contains(path) }
    func hasApiDirectory(href: String): Bool { apiDirectoryFiles.contains(href.split("#", 2)[0]) }
}

internal func versionJsonEscape(value: String): String {
    public_render.escapeJsonString(value)
}

protected func versionSafeId(value: String): Bool {
    if (value.isEmpty() || value == "." || value == "..") { return false }
    if (value.contains("/") || value.contains("\\") || value.contains(":") ||
        value.contains("..") || value.contains("\n") || value.contains("\r") || value.contains("\t")) {
        return false
    }
    true
}

internal func versionOutputPath(site: VersionSite, relative: String): String {
    "${site.spec.basePath}/${relative}"
}

internal func versionRelativeHref(fromPath: String, toPath: String): String {
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
