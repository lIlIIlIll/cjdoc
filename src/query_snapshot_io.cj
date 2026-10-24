package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import std.fs.*
import yjson.*

private let QUERY_SOURCE_COUNT: Int64 = 64
private let QUERY_SOURCE_TOTAL_BYTES: Int64 = 512 * 1024 * 1024

private class QuerySourceLoadBudget {
    private var fileBytes: Int64 = 0
    private var modelBytes: Int64 = 0

    func reserveFile(size: Int64): Unit {
        if (size < 0 || size > QUERY_SOURCE_TOTAL_BYTES - fileBytes) {
            throw DocumentationQueryException("resource_limit", "source_total_byte_limit", "Loaded document resources exceed 512 MiB UTF-8 bytes.")
        }
        fileBytes += size
    }

    func reserveModel(size: Int64): Unit {
        if (size < 0 || size > QUERY_MAX_BYTES - modelBytes) {
            throw DocumentationQueryException("resource_limit", "catalog_model_byte_limit", "A query catalog supports at most 64 MiB of canonical Doc IR.")
        }
        modelBytes += size
    }
}

internal func queryResourcePath(path: String): Unit {
    if (!isSafeOutputPath(path) || path.contains("#") || path.contains("?")) {
        throw DocumentationQueryException("unavailable", "unsafe_resource_path", "A packaged resource path is not normalized and relative.")
    }
    for (byte in path.toArray()) {
        if (byte < 32 || byte == 127) {
            throw DocumentationQueryException("unavailable", "unsafe_resource_path", "A packaged resource path contains a control character.")
        }
    }
}

@When[os != "Windows"]
private func readQueryResource(root: Path, relative: String, expected: Int64): Array<Byte> {
    queryResourcePath(relative)
    readFileBoundedWithinExpected(root, relative, QUERY_MAX_BYTES, expected)
}

@When[os == "Windows"]
private func readQueryResource(root: Path, relative: String, expected: Int64): Array<Byte> {
    queryResourcePath(relative)
    let path = root.join(relative)
    ensureNoSymbolicLinkAncestors(path, "query resource")
    let canonicalRoot = canonicalize(root).toString()
    let canonicalPath = canonicalize(path).toString()
    if (!hostPathIsWithin(canonicalRoot, canonicalPath) || canonicalRoot == canonicalPath) {
        throw DocumentationQueryException("unavailable", "resource_outside_bundle", "A resource is outside its explicit document root.")
    }
    let bytes = readFileBounded(path, QUERY_MAX_BYTES)
    ensureNoSymbolicLinkAncestors(path, "query resource")
    if (canonicalize(path).toString() != canonicalPath || bytes.size != expected) {
        throw DocumentationQueryException("unavailable", "resource_changed", "A packaged resource changed while loading.")
    }
    bytes
}

private func queryReadTextResource(root: Path, entry: JsonObject): String {
    let path = queryString(entry, "path")
    let bytes = readQueryResource(root, path, queryInt(entry, "bytes"))
    if (query_model.contractFingerprintBytes(bytes) != queryString(entry, "sha256")) {
        throw DocumentationQueryException("unavailable", "resource_hash_mismatch", "A packaged resource does not match its declared SHA-256.")
    }
    String.fromUtf8(bytes)
}

private func loadQueryMachineManifest(path: Path, text: String, budget: QuerySourceLoadBudget,
    isLatest!: Bool = false, catalogIdentity!: String = ""): QuerySnapshotInput {
    query_render.validateDocumentationArtifactJson(text, "machine-manifest")
    let manifest = querySnapshotJson(text)
    // The layout is part of machine-manifest/1, independent of the deployment
    // URL: <document-root>/agent/manifest.json with root-relative resource paths.
    if (path.parent.fileName != "agent") {
        throw DocumentationQueryException("unavailable", "manifest_layout", "A machine manifest must be inside the document root's agent directory.")
    }
    let root = path.parent.parent
    validateQueryHtmlRepresentations(root, manifest)
    let resources = manifest.get("resources").getOrThrow().asArray()
    if (resources.size() > 65536) {
        throw DocumentationQueryException("resource_limit", "bundle_resource_count", "A machine package supports at most 65536 resources.")
    }
    let paths = HashSet<String>()
    var total: Int64 = 0
    var docIr: ?String = None
    var inventory: ?String = None
    let docEntry = manifest.get("docIr").getOrThrow().asObject()
    let inventoryEntry = manifest.get("symbolIndex").getOrThrow().asObject()
    let reportPaths = HashSet<String>()
    let reportContents = HashMap<String, String>()
    let reports = manifest.get("reports").getOrThrow().asArray()
    for (index in 0..reports.size()) { reportPaths.add(queryString(reports[index].asObject(), "path")) }
    for (index in 0..resources.size()) {
        let entry = resources[index].asObject()
        let relative = queryString(entry, "path")
        let size = queryInt(entry, "bytes")
        if (!paths.add(relative) || size < 0 || size > QUERY_SOURCE_TOTAL_BYTES - total) {
            throw DocumentationQueryException("resource_limit", "bundle_resource_limit", "Packaged resources are duplicated or exceed the total byte budget.")
        }
        total += size
        budget.reserveFile(size)
        let content = queryReadTextResource(root, entry)
        if (reportPaths.contains(relative)) { reportContents[relative] = content }
        if (relative == queryString(docEntry, "path")) {
            if (queryString(entry, "sha256") != queryString(docEntry, "sha256")) {
                throw DocumentationQueryException("unavailable", "doc_ir_hash_mismatch", "The Doc IR reference contradicts its resource record.")
            }
            docIr = Some(content)
        }
        if (relative == queryString(inventoryEntry, "path")) {
            if (queryString(entry, "sha256") != queryString(inventoryEntry, "sha256")) {
                throw DocumentationQueryException("unavailable", "inventory_hash_mismatch", "The inventory reference contradicts its resource record.")
            }
            inventory = Some(content)
        }
    }
    if (docIr.isNone() || inventory.isNone()) {
        throw DocumentationQueryException("unavailable", "required_resource_missing", "The bundle does not contain its Doc IR and inventory.")
    }
    let revision = queryString(manifest, "publicationRevision")
    let snapshot = query_render.DocumentationReadSnapshot(query_render.decodeDocIr(docIr.getOrThrow()),
        version: if (revision.isEmpty()) { None } else { Some(revision) })
    budget.reserveModel(snapshot.encodedDocumentation.size)
    if (snapshot.snapshotId != queryString(manifest, "snapshotId") || snapshot.encodedDocumentation != docIr.getOrThrow()) {
        throw DocumentationQueryException("unavailable", "snapshot_binding_mismatch", "The bundle's content and projection do not match its snapshot identity.")
    }
    if (snapshot.renderSymbolInventory() != inventory.getOrThrow()) {
        throw DocumentationQueryException("unavailable", "inventory_projection_mismatch", "The inventory is not the projection of the bundled Doc IR.")
    }
    validateQueryRepresentationGraph(manifest, snapshot, paths)
    // A publisher's resource checksum binds this package, not an independent
    // host pin. Exact dependency matches require captured host binding evidence.
    let attachments = loadDocumentationQueryReports(manifest, snapshot, reportContents)
    return QuerySnapshotInput(snapshot, "machine-manifest", query_model.contractFingerprint(catalogIdentity + "\n" + text),
        packagedRepresentations: true, inventoryText: inventory, isLatest: isLatest,
        attachments: Some(attachments))
}

private func queryInputPath(value: String): Path {
    let path = Path(value)
    ensureNoSymbolicLinkAncestors(path, "query snapshot")
    let resolved = canonicalize(path)
    if (!FileInfo(resolved).isDirectory()) { return resolved }
    for (relative in ["agent/manifest.json", "manifest.json", "versions.json"]) {
        let candidate = resolved.join(relative)
        if (exists(candidate)) {
            ensureNoSymbolicLinkAncestors(candidate, "query snapshot")
            return candidate
        }
    }
    throw DocumentationQueryException("unavailable", "manifest_missing", "The supplied directory has no explicit machine or version manifest.")
}

private func appendQueryVersionSources(result: ArrayList<QuerySnapshotInput>, path: Path,
    catalog: JsonObject, budget: QuerySourceLoadBudget): Unit {
    validateQueryVersionCatalog(catalog)
    let latest = queryString(catalog, "latest")
    let versions = catalog.get("versions").getOrThrow().asArray()
    if (versions.size() < 1 || versions.size() > QUERY_SOURCE_COUNT) {
        throw DocumentationQueryException("resource_limit", "version_source_limit", "The version catalog exceeds the supported source count.")
    }
    let ids = HashSet<String>()
    var foundLatest = false
    for (index in 0..versions.size()) {
        let version = versions[index].asObject()
        let id = queryString(version, "id")
        if (id.isEmpty() || !ids.add(id)) { throw IllegalArgumentException("invalid version catalog identity") }
        foundLatest = foundLatest || id == latest
        let roots = ArrayList<String>()
        if (let Some(languages) <- version.get("languages")) {
            let entries = languages.asArray()
            for (position in 0..entries.size()) { roots.add(queryString(entries[position].asObject(), "root")) }
        } else { roots.add(queryString(version, "basePath")) }
        for (relative in roots) {
            queryResourcePath(relative)
            let manifest = path.parent.join(relative).join("agent/manifest.json")
            ensureNoSymbolicLinkAncestors(manifest, "version machine manifest")
            if (!exists(manifest)) {
                throw DocumentationQueryException("unavailable", "version_details_not_packaged", "A version has no packaged machine details; it is not replaced by current/latest data.")
            }
            if (result.size >= QUERY_SOURCE_COUNT) { throw IllegalArgumentException("query source count limit exceeded") }
            let text = readTextBounded(manifest, QUERY_MAX_BYTES)
            budget.reserveFile(text.size)
            let identity = query_model.contractFingerprint(queryCanonical(catalog)) + "\n" + id + "\n" + relative
            let input = loadQueryMachineManifest(manifest, text, budget, isLatest: id == latest, catalogIdentity: identity)
            result.add(input)
        }
    }
    if (!foundLatest) { throw IllegalArgumentException("version catalog latest alias has no declared target") }
}

internal func loadDocumentationQuerySources(paths: Array<String>): ArrayList<QuerySnapshotInput> {
    if (paths.isEmpty() || paths.size > QUERY_SOURCE_COUNT) { throw IllegalArgumentException("query requires 1..64 explicit snapshots") }
    let result = ArrayList<QuerySnapshotInput>()
    let budget = QuerySourceLoadBudget()
    for (value in paths) {
        let path = queryInputPath(value)
        let text = readTextBounded(path, QUERY_MAX_BYTES)
        budget.reserveFile(text.size)
        let root = querySnapshotJson(text)
        let version = queryString(root, "schemaVersion")
        if (version == "cjdoc.machine-manifest/1") { result.add(loadQueryMachineManifest(path, text, budget)) }
        else if (version == "cjdoc.versions/2") { appendQueryVersionSources(result, path, root, budget) }
        else {
            let snapshot = query_render.DocumentationReadSnapshot(query_render.decodeDocIr(text))
            budget.reserveModel(snapshot.encodedDocumentation.size)
            result.add(QuerySnapshotInput(snapshot, "doc-ir", query_model.contractFingerprint(text)))
        }
    }
    if (result.size > QUERY_SOURCE_COUNT) { throw IllegalArgumentException("query source count limit exceeded") }
    bindDocumentationQueryReports(result)
    result
}

internal func loadDocumentationQueryModels(models: Array<query_model.DocumentationSet>): ArrayList<QuerySnapshotInput> {
    if (models.isEmpty() || models.size > QUERY_SOURCE_COUNT) { throw IllegalArgumentException("query requires 1..64 models") }
    let result = ArrayList<QuerySnapshotInput>()
    let budget = QuerySourceLoadBudget()
    for (model in models) {
        let snapshot = query_render.DocumentationReadSnapshot(model)
        budget.reserveModel(snapshot.encodedDocumentation.size)
        result.add(QuerySnapshotInput(snapshot, "public-model", snapshot.snapshotId))
    }
    result
}

internal func projectDocumentationQuerySources(inputs: ArrayList<QuerySnapshotInput>, request: JsonObject): ArrayList<QuerySnapshotInput> {
    let result = ArrayList<QuerySnapshotInput>()
    let ids = HashSet<String>()
    let language = queryString(request, "language")
    let audience = queryString(request, "audience")
    for (input in inputs) {
        let cfgProfile = queryString(request, "cfgProfile")
        if (!cfgProfile.isEmpty() && cfgProfile != input.documentation.configuration.cfgProfile) { continue }
        let currentAudience = input.documentation.configuration.audience
        let canNarrow = audience.isEmpty() || audience == currentAudience || currentAudience == "all" ||
            (currentAudience == "package" && audience == "external")
        if (!canNarrow) { continue }
        if ((language.isEmpty() || language == input.snapshot.locale) && (audience.isEmpty() || audience == currentAudience)) {
            if (ids.add(input.snapshot.snapshotId)) { result.add(input) }
            continue
        }
        let snapshot = try {
            query_render.DocumentationReadSnapshot(input.documentation,
                locale: if (language.isEmpty()) { None } else { Some(language) },
                audience: if (audience.isEmpty()) { None } else { Some(audience) },
                version: if (input.snapshot.publicationRevision.isEmpty()) { None } else { Some(input.snapshot.publicationRevision) })
        } catch (_: IllegalArgumentException) {
            if (!queryBool(request, "languageFallback")) { continue }
            // Language fallback must still apply audience narrowing. Returning
            // the original all-audience snapshot here would leak hidden data.
            query_render.DocumentationReadSnapshot(input.documentation, locale: Some(input.snapshot.locale),
                audience: if (audience.isEmpty()) { None } else { Some(audience) },
                version: if (input.snapshot.publicationRevision.isEmpty()) { None } else { Some(input.snapshot.publicationRevision) })
        }
        if (!ids.add(snapshot.snapshotId)) { continue }
        result.add(QuerySnapshotInput(snapshot, input.sourceKind, input.sourceIdentity,
            sourceSnapshotId: input.sourceSnapshotId, isLatest: input.isLatest,
            attachments: Some(input.attachments)))
    }
    result
}
