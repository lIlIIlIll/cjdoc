package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*
import std.sort.*

private let LOCAL_ASSET_MAX_BYTES: Int64 = public_model.DOC_IR_MAX_ASSET_BYTES
private let LOCAL_ASSET_TOTAL_MAX_BYTES: Int64 = public_model.DOC_IR_MAX_TOTAL_ASSET_BYTES
private let LOCAL_ASSET_TOTAL_MAX_PIXELS: Int64 = public_model.DOC_IR_MAX_TOTAL_ASSET_PIXELS
private let LOCAL_ASSET_INSPECTION_IO_MAX_BYTES: Int64 = 64 * 1024 * 1024
private let LOCAL_ASSET_INSPECTION_CPU_MAX_BYTES: Int64 = 64 * 1024 * 1024
private let BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

internal func localAssetBudgetAllows(totalBytes: Int64, itemBytes: Int64): Bool {
    itemBytes > 0 && itemBytes <= LOCAL_ASSET_MAX_BYTES && totalBytes >= 0 &&
        totalBytes <= LOCAL_ASSET_TOTAL_MAX_BYTES - itemBytes
}

internal func localAssetInspectionBudgetAllows(totalBytes: Int64, itemBytes: Int64,
    limitBytes: Int64): Bool {
    itemBytes > 0 && limitBytes >= 0 && totalBytes >= 0 && itemBytes <= limitBytes &&
        totalBytes <= limitBytes - itemBytes
}

private func localAssetBase64(bytes: Array<Byte>): String {
    let out = StringBuilder()
    var index: Int64 = 0
    while (index + 3 <= bytes.size) {
        let first = Int64(bytes[index])
        let second = Int64(bytes[index + 1])
        let third = Int64(bytes[index + 2])
        for (value in [first >> 2, ((first & 3) << 4) | (second >> 4),
            ((second & 15) << 2) | (third >> 6), third & 63]) {
            out.append(BASE64_ALPHABET[value..value + 1])
        }
        index += 3
    }
    let remaining = bytes.size - index
    if (remaining == 1) {
        let first = Int64(bytes[index])
        out.append(BASE64_ALPHABET[(first >> 2)..(first >> 2) + 1])
        let second = (first & 3) << 4
        out.append(BASE64_ALPHABET[second..second + 1])
        out.append("==")
    } else if (remaining == 2) {
        let first = Int64(bytes[index])
        let second = Int64(bytes[index + 1])
        let firstIndex = first >> 2
        let secondIndex = ((first & 3) << 4) | (second >> 4)
        let thirdIndex = (second & 15) << 2
        out.append(BASE64_ALPHABET[firstIndex..firstIndex + 1])
        out.append(BASE64_ALPHABET[secondIndex..secondIndex + 1])
        out.append(BASE64_ALPHABET[thirdIndex..thirdIndex + 1])
        out.append("=")
    }
    out.toString()
}

private func localAssetMediaType(path: Path): ?String {
    match (path.extensionName) {
        case "png" => Some("image/png")
        case "jpg" | "jpeg" => Some("image/jpeg")
        case "gif" => Some("image/gif")
        case "webp" => Some("image/webp")
        case "avif" => Some("image/avif")
        case _ => None
    }
}

private func safeLocalAssetDestination(value: String): Bool {
    !value.isEmpty() && !value.startsWith("/") && !value.contains("\\") &&
        !value.contains(":") && !value.contains("?") && !value.contains("#") &&
        !value.contains("\n") && !value.contains("\r")
}

private class ResolvedLocalAsset {
    let actualPath: String
    let actualRoot: String
    let relativePath: String
    let logicalPath: String
    let expectedSize: Int64

    init(actualPath: String, actualRoot: String, relativePath: String, logicalPath: String,
        expectedSize: Int64) {
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.relativePath = relativePath
        this.logicalPath = logicalPath
        this.expectedSize = expectedSize
    }
}

internal func localAssetRelativePath(root: String, candidate: String): ?String {
    match (relativePathFromResolved(root, candidate)) {
        case Some(value) => if (value.isEmpty()) { None<String> } else { Some(value) }
        case None => None
    }
}

private func resolveLocalAsset(origin: SourceFileOrigin, destination: String): ResolvedLocalAsset {
    if (!safeLocalAssetDestination(destination)) {
        throw IllegalArgumentException("image destination is not a safe local path")
    }
    let normalizedRoot = normalizedHostPath(Path(origin.actualRoot).normalize().toString())
    let candidate = Path(origin.actualPath).parent.join(destination).normalize()
    let normalizedCandidate = normalizedHostPath(candidate.toString())
    if (!hostPathIsWithin(normalizedRoot, normalizedCandidate) ||
        normalizedCandidate == normalizedRoot) {
        throw IllegalArgumentException("image destination escapes its source module")
    }
    let relative = match (localAssetRelativePath(normalizedRoot, normalizedCandidate)) {
        case Some(value) => value
        case None => throw IllegalArgumentException("image destination escapes its source module")
    }
    var current = Path(normalizedRoot)
    let parts = relative.split("/")
    var index: Int64 = 0
    while (index < parts.size) {
        let part = parts[index]
        if (part.isEmpty() || part == "." || part == "..") {
            throw IllegalArgumentException("image destination is not normalized")
        }
        current = current.join(part)
        let info = FileInfo(current)
        if (info.isSymbolicLink()) {
            throw IllegalArgumentException("image destination traverses a symbolic link")
        }
        if (index + 1 < parts.size && !info.isDirectory()) {
            throw IllegalArgumentException("image destination parent is not a directory")
        }
        index++
    }
    let info = FileInfo(current)
    if (!info.isRegular() || info.size <= 0 || info.size > LOCAL_ASSET_MAX_BYTES) {
        throw IllegalArgumentException("image asset is not a bounded regular file")
    }
    let canonical = normalizedHostPath(canonicalize(current).toString())
    if (canonical != normalizedCandidate || !hostPathIsWithin(normalizedRoot, canonical)) {
        throw IllegalArgumentException("image destination changed during resolution")
    }
    let logicalPath = if (origin.logicalPrefix.isEmpty()) {
        relative
    } else {
        origin.logicalPrefix + "/" + relative
    }
    ResolvedLocalAsset(canonical, normalizedRoot, relative, logicalPath, info.size)
}

private class CachedLocalAssetReference {
    let id: ?String
    let reason: ?String

    init(id!: ?String = None, reason!: ?String = None) {
        this.id = id; this.reason = reason
    }
}

class LocalAssetCollector {
    private let origins = HashMap<String, SourceFileOrigin>()
    private let assetsStorage = ArrayList<public_model.AssetDoc>()
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let actualReferences = HashMap<String, String>()
    private let digestReferences = HashMap<String, String>()
    private let sourcePathReferences = HashMap<String, String>()
    private let referenceCache = HashMap<String, CachedLocalAssetReference>()
    private let actualFailureCache = HashMap<String, String>()
    private let failedReferences = HashSet<String>()
    private var totalBytes: Int64 = 0
    private var totalPixels: Int64 = 0
    private var inspectionIoBytes: Int64 = 0
    private var inspectionCpuBytes: Int64 = 0
    var incomplete: Bool = false

    init(sourceFiles: ReadOnlyList<SourceFileOrigin>) {
        for (source in sourceFiles) { origins[source.logicalPath] = source }
    }

    private func fail(sourcePath: String, destination: String,
        source: public_model.SourceRange, symbolId: String, reason: String): Unit {
        incomplete = true
        let key = "${symbolId.size}:${symbolId}${destination}"
        if (!failedReferences.add(key)) { return }
        diagnosticsStorage.add(public_model.Diagnostic("warning", "CJDOC4026",
            "local documentation image '${destination}' from '${sourcePath}' was omitted: ${reason}",
            source: Some(source), symbolId: Some(symbolId)))
    }

    private func failCached(referenceKey: String, actualPath: ?String,
        sourcePath: String, destination: String, source: public_model.SourceRange,
        symbolId: String, reason: String): ?String {
        referenceCache[referenceKey] = CachedLocalAssetReference(reason: Some(reason))
        match (actualPath) {
            case Some(path) => actualFailureCache[path] = reason
            case None => ()
        }
        fail(sourcePath, destination, source, symbolId, reason)
        None
    }

    private func succeedCached(referenceKey: String, actualPath: String, id: String): String {
        referenceCache[referenceKey] = CachedLocalAssetReference(id: Some(id))
        actualReferences[actualPath] = id
        id
    }

    func reference(sourcePath: String, destination: String,
        source: public_model.SourceRange, symbolId: String): ?String {
        let referenceKey = "${sourcePath.size}:${sourcePath}${destination}"
        match (referenceCache.get(referenceKey)) {
            case Some(cached) => match (cached.id) {
                case Some(id) => return Some(id)
                case None =>
                    let reason = cached.reason.getOrThrow()
                    fail(sourcePath, destination, source, symbolId, reason)
                    return None
            }
            case None => ()
        }
        let origin = match (origins.get(sourcePath)) {
            case Some(value) => value
            case None =>
                return failCached(referenceKey, None<String>, sourcePath, destination, source, symbolId,
                    "source origin is unavailable")
        }
        let resolved = try {
            resolveLocalAsset(origin, destination)
        } catch (_: Exception) {
            return failCached(referenceKey, None<String>, sourcePath, destination, source, symbolId,
                "path is missing, unsafe, or unsupported")
        }
        match (actualReferences.get(resolved.actualPath)) {
            case Some(id) => return Some(succeedCached(referenceKey, resolved.actualPath, id))
            case None => ()
        }
        match (actualFailureCache.get(resolved.actualPath)) {
            case Some(reason) => return failCached(referenceKey, Some(resolved.actualPath),
                sourcePath, destination, source, symbolId, reason)
            case None => ()
        }
        let path = Path(resolved.actualPath)
        let mediaType = match (localAssetMediaType(path)) {
            case Some(value) => value
            case None =>
                return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                    source, symbolId, "media type is not an allowed raster image")
        }
        if (!localAssetInspectionBudgetAllows(inspectionIoBytes, resolved.expectedSize,
            LOCAL_ASSET_INSPECTION_IO_MAX_BYTES)) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "project asset inspection I/O budget exceeds 64 MiB")
        }
        if (!localAssetInspectionBudgetAllows(inspectionCpuBytes, resolved.expectedSize,
            LOCAL_ASSET_INSPECTION_CPU_MAX_BYTES)) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "project asset inspection CPU budget exceeds 64 MiB")
        }
        inspectionIoBytes += resolved.expectedSize
        inspectionCpuBytes += resolved.expectedSize
        let bytes = try {
            readFileBoundedWithinExpected(Path(resolved.actualRoot), resolved.relativePath,
                LOCAL_ASSET_MAX_BYTES, resolved.expectedSize)
        } catch (_: Exception) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "file is not readable or changed while reading")
        }
        let pixels = try {
            public_model.validateRasterAsset(mediaType, bytes)
        } catch (_: Exception) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "image container or dimensions are invalid")
        }
        let digest = Sha256Digest.digestBytes(bytes)
        match (digestReferences.get(digest)) {
            case Some(id) =>
                return Some(succeedCached(referenceKey, resolved.actualPath, id))
            case None => ()
        }
        if (!localAssetBudgetAllows(totalBytes, bytes.size)) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "project asset budget exceeds 64 MiB")
        }
        if (pixels > LOCAL_ASSET_TOTAL_MAX_PIXELS - totalPixels) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "project image pixel budget exceeds 200 million pixels")
        }
        let id = "sha256-${digest}"
        if (sourcePathReferences.contains(resolved.logicalPath) ||
            sourcePathReferences.contains(id)) {
            return failCached(referenceKey, Some(resolved.actualPath), sourcePath, destination,
                source, symbolId, "asset identity is ambiguous")
        }
        sourcePathReferences[resolved.logicalPath] = id
        sourcePathReferences[id] = id
        digestReferences[digest] = id
        totalBytes += bytes.size
        totalPixels += pixels
        assetsStorage.add(public_model.AssetDoc(id, mediaType, resolved.logicalPath,
            localAssetBase64(bytes)))
        Some(succeedCached(referenceKey, resolved.actualPath, id))
    }

    func assets(): Array<public_model.AssetDoc> {
        sort(assetsStorage, lessThan: { left, right => left.id < right.id }, stable: true)
        assetsStorage.toArray()
    }

    func diagnostics(): Array<public_model.Diagnostic> { diagnosticsStorage.toArray() }
}
