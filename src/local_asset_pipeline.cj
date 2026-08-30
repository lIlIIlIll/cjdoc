package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*
import std.sort.*

private let LOCAL_ASSET_MAX_BYTES: Int64 = 16 * 1024 * 1024
private let LOCAL_ASSET_TOTAL_MAX_BYTES: Int64 = 64 * 1024 * 1024
private let BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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

private func localAssetBytesStartWith(value: Array<Byte>, expected: Array<Byte>): Bool {
    if (value.size < expected.size) { return false }
    var index: Int64 = 0
    while (index < expected.size) {
        if (value[index] != expected[index]) { return false }
        index++
    }
    true
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

private func localAssetMagicIsValid(mediaType: String, value: Array<Byte>): Bool {
    match (mediaType) {
        case "image/png" => localAssetBytesStartWith(value,
            [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg" => value.size >= 3 && value[0] == 0xFF &&
            value[1] == 0xD8 && value[2] == 0xFF
        case "image/gif" => localAssetBytesStartWith(value, "GIF87a".toArray()) ||
            localAssetBytesStartWith(value, "GIF89a".toArray())
        case "image/webp" => value.size >= 12 &&
            localAssetBytesStartWith(value, "RIFF".toArray()) &&
            value[8] == b'W' && value[9] == b'E' && value[10] == b'B' && value[11] == b'P'
        case "image/avif" => value.size >= 12 && value[4] == b'f' && value[5] == b't' &&
            value[6] == b'y' && value[7] == b'p' && value[8] == b'a' && value[9] == b'v' &&
            value[10] == b'i' && (value[11] == b'f' || value[11] == b's')
        case _ => false
    }
}

private func safeLocalAssetDestination(value: String): Bool {
    !value.isEmpty() && !value.startsWith("/") && !value.contains("\\") &&
        !value.contains(":") && !value.contains("?") && !value.contains("#") &&
        !value.contains("\n") && !value.contains("\r")
}

private class ResolvedLocalAsset {
    let actualPath: String
    let logicalPath: String

    init(actualPath: String, logicalPath: String) {
        this.actualPath = actualPath
        this.logicalPath = logicalPath
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
    let relative = normalizedCandidate[(normalizedRoot.size + 1)..]
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
    ResolvedLocalAsset(canonical, logicalPath)
}

class LocalAssetCollector {
    private let origins = HashMap<String, SourceFileOrigin>()
    private let assetsStorage = ArrayList<public_model.AssetDoc>()
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let actualReferences = HashMap<String, String>()
    private let digestReferences = HashMap<String, String>()
    private let sourcePathReferences = HashMap<String, String>()
    private let failedReferences = HashSet<String>()
    private var totalBytes: Int64 = 0
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

    func reference(sourcePath: String, destination: String,
        source: public_model.SourceRange, symbolId: String): ?String {
        let origin = match (origins.get(sourcePath)) {
            case Some(value) => value
            case None =>
                fail(sourcePath, destination, source, symbolId, "source origin is unavailable")
                return None
        }
        let resolved = try {
            resolveLocalAsset(origin, destination)
        } catch (_: Exception) {
            fail(sourcePath, destination, source, symbolId, "path is missing, unsafe, or unsupported")
            return None
        }
        match (actualReferences.get(resolved.actualPath)) {
            case Some(id) => return Some(id)
            case None => ()
        }
        let path = Path(resolved.actualPath)
        let mediaType = match (localAssetMediaType(path)) {
            case Some(value) => value
            case None =>
                fail(sourcePath, destination, source, symbolId, "media type is not an allowed raster image")
                return None
        }
        let bytes = try {
            File.readFrom(path)
        } catch (_: Exception) {
            fail(sourcePath, destination, source, symbolId, "file is not readable")
            return None
        }
        if (bytes.isEmpty() || bytes.size > LOCAL_ASSET_MAX_BYTES ||
            !localAssetMagicIsValid(mediaType, bytes)) {
            fail(sourcePath, destination, source, symbolId, "file signature or size is invalid")
            return None
        }
        let digest = Sha256Digest.digestBytes(bytes)
        match (digestReferences.get(digest)) {
            case Some(id) =>
                actualReferences[resolved.actualPath] = id
                return Some(id)
            case None => ()
        }
        if (totalBytes + bytes.size > LOCAL_ASSET_TOTAL_MAX_BYTES) {
            fail(sourcePath, destination, source, symbolId, "project asset budget exceeds 64 MiB")
            return None
        }
        let id = "sha256-${digest}"
        if (sourcePathReferences.contains(resolved.logicalPath) ||
            sourcePathReferences.contains(id)) {
            fail(sourcePath, destination, source, symbolId, "asset identity is ambiguous")
            return None
        }
        sourcePathReferences[resolved.logicalPath] = id
        sourcePathReferences[id] = id
        actualReferences[resolved.actualPath] = id
        digestReferences[digest] = id
        totalBytes += bytes.size
        assetsStorage.add(public_model.AssetDoc(id, mediaType, resolved.logicalPath,
            localAssetBase64(bytes)))
        Some(id)
    }

    func assets(): Array<public_model.AssetDoc> {
        sort(assetsStorage, lessThan: { left, right => left.id < right.id }, stable: true)
        assetsStorage.toArray()
    }

    func diagnostics(): Array<public_model.Diagnostic> { diagnosticsStorage.toArray() }
}
