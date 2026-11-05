package cjdoc.render

import cjdoc.model.*
import std.collection.*

/** A source link and its complete captured evidence for one source range. */
public class SourceReference {
    public let url: ?String
    public let range: SourceRange
    public let state: String
    public let reason: String
    public let repository: ?RepositoryInfo
    public let recordedRevision: ?String
    public let revisionKind: String
    public let sourceDigest: ?String
    public let normalizedDigest: ?String
    public let evidenceIdentity: ?String
    public let evidenceKind: String

    internal init(url: ?String, range: SourceRange, state: String, reason: String,
        repository: ?RepositoryInfo, recordedRevision: ?String, revisionKind: String,
        sourceDigest: ?String, normalizedDigest: ?String, evidenceIdentity: ?String,
        evidenceKind: String) {
        this.url = url
        this.range = range
        this.state = state
        this.reason = reason
        this.repository = repository
        this.recordedRevision = recordedRevision
        this.revisionKind = revisionKind
        this.sourceDigest = sourceDigest
        this.normalizedDigest = normalizedDigest
        this.evidenceIdentity = evidenceIdentity
        this.evidenceKind = evidenceKind
    }
}

private func sourceReferenceKey(moduleId: String, path: String): String {
    "${moduleId}\n${path}"
}

private func sourceReferencePathIsSafe(path: String): Bool {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\")) { return false }
    for (byte in path.toArray()) {
        if (byte < 0x20u8 || byte == 0x7Fu8) { return false }
    }
    let first = path.split("/")[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in path.split("/")) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}

private func sourceReferenceRangeIsValid(range: SourceRange): Bool {
    if (!sourceReferencePathIsSafe(range.path) || range.start.line < 1 ||
        range.start.column < 1 || range.start.byteOffset < 0 || range.end.line < 1 ||
        range.end.column < 1 || range.end.byteOffset < 0) { return false }
    if (range.end.byteOffset < range.start.byteOffset || range.end.line < range.start.line ||
        (range.end.line == range.start.line && range.end.column < range.start.column)) { return false }
    true
}

private func sourceUrlByteIsUnreserved(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'-' || value == b'.' ||
        value == b'_' || value == b'~'
}

private func appendSourceUrlSegment(out: StringBuilder, value: String): Unit {
    let digits = "0123456789ABCDEF".toArray()
    for (byte in value.toArray()) {
        if (sourceUrlByteIsUnreserved(byte)) {
            out.append(String.fromUtf8([byte]))
        } else {
            out.append("%")
            // Append ASCII hex characters, not Byte values formatted as decimals.
            out.append(String.fromUtf8([digits[Int64((byte >> 4) & 0x0Fu8)]]))
            out.append(String.fromUtf8([digits[Int64(byte & 0x0Fu8)]]))
        }
    }
}

private func sourceUrlFor(repository: RepositoryInfo, repositoryPath: String,
    range: SourceRange): ?String {
    if (!sourceReferencePathIsSafe(repositoryPath) || !sourceReferenceRangeIsValid(range)) { return None }
    let out = StringBuilder()
    out.append(repository.url)
    out.append("/blob/")
    appendSourceUrlSegment(out, repository.revision)
    out.append("/")
    var firstSegment = true
    for (segment in repositoryPath.split("/")) {
        if (!firstSegment) { out.append("/") }
        firstSegment = false
        appendSourceUrlSegment(out, segment)
    }
    let endLine = if (range.end.line > range.start.line && range.end.column == 1) {
        range.end.line - 1
    } else {
        range.end.line
    }
    if (endLine < range.start.line) { return None }
    out.append("#L${range.start.line}")
    if (endLine != range.start.line) { out.append("-L${endLine}") }
    Some(out.toString())
}

private func revisionKindFor(repository: ?RepositoryInfo): String {
    match (repository) {
        case Some(value) where value.revision.size == 40 =>
            var fullSha = true
            for (byte in value.revision.toArray()) {
                if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
                    fullSha = false
                    break
                }
            }
            if (fullSha) { "exact" } else { "ref" }
        case Some(_) => "ref"
        case None => "unavailable"
    }
}

/** Resolve source ranges only through the FileDoc captured in this document. */
internal class SourceReferenceProjection {
    private let filesByKey = HashMap<String, FileDoc>()
    private let ambiguous = HashSet<String>()

    init(documentation: DocumentationSet) {
        for (file in documentation.files) {
            let key = sourceReferenceKey(file.moduleId, file.path)
            if (ambiguous.contains(key)) { continue }
            if (filesByKey.contains(key)) {
                let _ = filesByKey.remove(key)
                let _ = ambiguous.add(key)
            } else {
                filesByKey[key] = file
            }
        }
    }

    func project(moduleId: String, range: SourceRange): SourceReference {
        let key = sourceReferenceKey(moduleId, range.path)
        if (ambiguous.contains(key)) {
            return SourceReference(None, range, "ambiguous", "conflicting_registration",
                None, None, "unavailable", None, None, None, "none")
        }
        let file = match (filesByKey.get(key)) {
            case Some(value) => value
            case None => return SourceReference(None, range, "unavailable", "no_registration",
                None, None, "unavailable", None, None, None, "none")
        }
        let provenance = file.provenance
        if (!sourceReferenceRangeIsValid(range)) {
            return SourceReference(None, range, "unavailable", "invalid_range", None, None,
                "unavailable", provenance.sourceDigest, provenance.normalizedDigest, None, "none")
        }
        let repository = provenance.repository
        let url: ?String = if (provenance.state == "verified" || provenance.state == "declared") {
            match ((repository, provenance.repositoryPath)) {
                case (Some(value), Some(path)) => sourceUrlFor(value, path, range)
                case _ => None
            }
        } else { None }
        let state = if (url.isSome() || (provenance.state != "verified" && provenance.state != "declared")) {
            provenance.state
        } else { "unavailable" }
        let reason = if (state == provenance.state) { provenance.reason }
            else { "path_escape" }
        SourceReference(url, range, state, reason,
            if (state == "verified" || state == "declared") { repository } else { None },
            if (state == "verified" || state == "declared") {
                repository.map({ value => value.revision })
            } else { None },
            if (state == "verified" || state == "declared") {
                revisionKindFor(repository)
            } else { "unavailable" },
            provenance.sourceDigest, provenance.normalizedDigest,
            if (state == "verified") { provenance.evidenceIdentity } else { None },
            if (state == "verified") { provenance.evidenceKind } else { "none" })
    }
}

internal func appendSourceReferenceEvidenceMarkdown(out: RenderTextBuffer,
    source: SourceReference, locale: String): Unit {
    out.append("- ${label(locale, "Source evidence", "源码证据")}: ")
    appendMarkdownCodeSpan(out, "${source.state}/${source.reason}")
    out.append("\n")
    match (source.url) {
        case Some(url) =>
            out.append("- ${label(locale, "Repository source", "仓库源码")}: ")
            match (markdownLinkDestination(url)) {
                case Some(destination) =>
                    out.append("[" + label(locale, "Open source", "打开源码") + "](" +
                        destination + ")\n")
                case None => appendMarkdownCodeSpan(out, url); out.append("\n")
            }
        case None => ()
    }
}

/** Serialize the shared source-evidence object used by Agent and query artifacts. */
public func sourceReferenceJson(value: SourceReference): String {
    let out = StringBuilder()
    out.append("{\"url\":${nullableString(value.url)},\"range\":")
    appendRange(out, value.range)
    out.append(",\"state\":${escapeJsonString(value.state)},\"reason\":${escapeJsonString(value.reason)}")
    out.append(",\"repository\":")
    match (value.repository) {
        case Some(repository) => out.append("{\"url\":${escapeJsonString(repository.url)},\"revision\":${escapeJsonString(repository.revision)}}")
        case None => out.append("null")
    }
    out.append(",\"recordedRevision\":${nullableString(value.recordedRevision)}")
    out.append(",\"revisionKind\":${escapeJsonString(value.revisionKind)}")
    out.append(",\"sourceDigest\":${nullableString(value.sourceDigest)}")
    out.append(",\"normalizedDigest\":${nullableString(value.normalizedDigest)}")
    out.append(",\"evidenceIdentity\":${nullableString(value.evidenceIdentity)}")
    out.append(",\"evidenceKind\":${escapeJsonString(value.evidenceKind)}}")
    out.toString()
}
