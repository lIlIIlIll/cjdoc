package cjdoc.render

import cjdoc.model.*
import std.collection.*


public class RenderResourceLimitException <: Exception {
    public init(message: String) { super(message) }

    protected override func getClassName(): String { "RenderResourceLimitException" }
}

internal let RENDER_ARTIFACT_LIMIT: Int64 = DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES
internal let RENDER_ARTIFACT_TOTAL_LIMIT: Int64 = 512 * 1024 * 1024
internal let RENDER_ARTIFACT_ENTRY_LIMIT: Int64 = 65536

protected func validateRenderArtifactPath(path: String): Unit {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("..")) {
        throw IllegalArgumentException("render artifact path must stay within the output directory")
    }
}

internal func reserveRenderBytes(current: Int64, incoming: Int64, limit: Int64,
    description: String): Int64 {
    if (incoming < 0 || incoming > limit || current > limit - incoming) {
        throw RenderResourceLimitException("${description} exceeds ${limit} UTF-8 bytes")
    }
    current + incoming
}

internal let RENDER_TEXT_CHUNK_BYTES: Int64 = 1024 * 1024

internal class RenderTextBuffer {
    private var storage = StringBuilder()
    private var fragments: ?ArrayList<String> = None
    private let limit: Int64
    private var bytesWritten: Int64 = 0
    private var storageBytes: Int64 = 0

    init(limit!: Int64 = RENDER_ARTIFACT_LIMIT) {
        if (limit < 0 || limit > RENDER_ARTIFACT_LIMIT) {
            throw IllegalArgumentException("invalid renderer text limit")
        }
        this.limit = limit
    }

    private func appendFragment(value: String): Unit {
        match (fragments) {
            case Some(values) => values.add(value)
            case None => fragments = Some(ArrayList<String>([value]))
        }
    }

    private func flushStorage(): Unit {
        if (storageBytes == 0) { return }
        appendFragment(storage.toString())
        storage = StringBuilder()
        storageBytes = 0
    }

    func append(value: String): Unit {
        bytesWritten = reserveRenderBytes(bytesWritten, value.size, limit,
            "renderer text buffer")
        if (value.isEmpty()) { return }
        if (value.size >= RENDER_TEXT_CHUNK_BYTES) {
            flushStorage()
            appendFragment(value)
            return
        }
        if (storageBytes > RENDER_TEXT_CHUNK_BYTES - value.size) { flushStorage() }
        storage.append(value)
        storageBytes += value.size
    }

    func append(value: Rune): Unit {
        let code = UInt32(value)
        let width: Int64 = if (code <= 0x7Fu32) { 1 } else if (code <= 0x7FFu32) { 2 }
            else if (code <= 0xFFFFu32) { 3 } else { 4 }
        bytesWritten = reserveRenderBytes(bytesWritten, width, limit,
            "renderer text buffer")
        if (storageBytes > RENDER_TEXT_CHUNK_BYTES - width) { flushStorage() }
        storage.append(value)
        storageBytes += width
    }

    prop size: Int64 { get() { bytesWritten } }

    func toString(): String {
        match (fragments) {
            case None => storage.toString()
            case Some(values) =>
                // Large pages must not geometrically grow a second contiguous
                // payload while immutable machine artifacts remain live.
                let joined = StringBuilder(bytesWritten)
                for (value in values) { joined.append(value) }
                if (storageBytes > 0) { joined.append(storage.toString()) }
                joined.toString()
        }
    }
}

/**
 * The single append surface for every render product.
 *
 * The in-memory collector keeps payloads; the root package's spool keeps only
 * metadata and writes payloads to disk. Both obey the same entry ordinals:
 * entries are addressed by their stable zero-based append ordinal, so duplicate
 * logical paths stay distinct and keep their published order.
 */
protected interface RenderArtifactStore {
    func addText(path: String, mediaType: String, content: String): Int64

    func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64

    /** Stored text of one text entry, bounded by `limit` bytes. */
    func readText(entry: Int64, limit: Int64): String

    /** Replace the payload of one text entry, keeping its path, media type and ordinal. */
    func replaceText(entry: Int64, content: String): Unit
}

public class RenderArtifact {
    public let path: String
    public let mediaType: String
    public let content: String
    private let bytesStorage: Array<Byte>
    private let binaryPayload: Bool

    public init(path: String, mediaType: String, content: String) {
        validateRenderArtifactPath(path)
        if (content.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = content
        this.bytesStorage = Array<Byte>()
        this.binaryPayload = false
    }

    public init(path: String, mediaType: String, bytes: Array<Byte>) {
        validateRenderArtifactPath(path)
        if (bytes.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = ""
        this.bytesStorage = bytes.clone()
        this.binaryPayload = true
    }

    protected init(path: String, mediaType: String, ownedBytes: Array<Byte>, takeOwnership: Bool) {
        validateRenderArtifactPath(path)
        if (!takeOwnership || ownedBytes.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = ""
        this.bytesStorage = ownedBytes
        this.binaryPayload = true
    }

    /** True whenever the artifact was built from a byte payload, even an empty one. */
    protected prop hasBinaryPayload: Bool { get() { binaryPayload } }

    public prop bytes: Array<Byte> { get() {
        if (!content.isEmpty()) { return content.toArray() }
        bytesStorage.clone()
    } }
    /** Root-package spool hook: the stored binary payload without a defensive copy. */
    protected prop ownedBytes: Array<Byte> { get() { bytesStorage } }
    public prop byteSize: Int64 { get() {
        if (!content.isEmpty()) { return content.size }
        bytesStorage.size
    } }
    public prop isBinary: Bool { get() { content.isEmpty() && !bytesStorage.isEmpty() } }
}

/**
 * One artifact budget shared by the in-memory collector and the root spool.
 *
 * Checks never mutate: they prove that the proposed state fits. Commit is a
 * separate call that only the storing implementation makes after the payload is
 * accepted, so a failed append or replacement leaves the previous accounting
 * and payload intact. Replacement charges `total - oldSize + newSize` and never
 * charges another entry.
 */
protected class RenderArtifactBudget {
    private let artifactLimit: Int64
    private let totalLimit: Int64
    private let entryLimit: Int64
    private var entries: Int64 = 0
    private var totalBytes: Int64 = 0

    protected init(artifactLimit!: Int64 = RENDER_ARTIFACT_LIMIT,
        totalLimit!: Int64 = RENDER_ARTIFACT_TOTAL_LIMIT,
        entryLimit!: Int64 = RENDER_ARTIFACT_ENTRY_LIMIT) {
        if (artifactLimit < 0 || artifactLimit > RENDER_ARTIFACT_LIMIT ||
            totalLimit < 0 || totalLimit > RENDER_ARTIFACT_TOTAL_LIMIT ||
            entryLimit < 0 || entryLimit > RENDER_ARTIFACT_ENTRY_LIMIT) {
            throw IllegalArgumentException("invalid render artifact collector limits")
        }
        this.artifactLimit = artifactLimit
        this.totalLimit = totalLimit
        this.entryLimit = entryLimit
    }

    /** Prove one more entry of `size` bytes fits, without changing any accounting. */
    protected func checkAdd(path: String, size: Int64): Unit {
        if (entries >= entryLimit) {
            throw RenderResourceLimitException(
                "render artifacts exceed ${entryLimit} entries")
        }
        checkPayload(path, size)
        checkTotal(size, 0)
    }

    /** Record one accepted entry after its payload is stored. */
    protected func commitAdd(size: Int64): Unit {
        totalBytes = reserveRenderBytes(totalBytes, size, totalLimit,
            "render artifact set")
        entries++
    }

    /** Prove replacing `oldSize` bytes with `newSize` bytes fits. */
    protected func checkReplace(path: String, oldSize: Int64, newSize: Int64): Unit {
        checkPayload(path, newSize)
        checkTotal(newSize, oldSize)
    }

    /** Record an accepted replacement once the new payload is stored. */
    protected func commitReplace(oldSize: Int64, newSize: Int64): Unit {
        if (oldSize > totalBytes) {
            throw IllegalArgumentException("render artifact replacement exceeds the stored payload")
        }
        totalBytes = reserveRenderBytes(totalBytes - oldSize, newSize, totalLimit,
            "render artifact set")
    }

    private func checkPayload(path: String, size: Int64): Unit {
        if (size < 0 || size > artifactLimit) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${artifactLimit} bytes")
        }
    }

    private func checkTotal(incoming: Int64, outgoing: Int64): Unit {
        let base = totalBytes - outgoing
        if (base < 0) {
            throw IllegalArgumentException("render artifact replacement exceeds the stored payload")
        }
        let _ = reserveRenderBytes(base, incoming, totalLimit, "render artifact set")
    }
}

/**
 * In-memory `RenderArtifactStore`: the array mode every public renderer entry
 * point still promises. It keeps payloads and metadata per entry, including
 * whether the payload is owned binary bytes, which the public artifact cannot
 * report for an empty owned buffer.
 */
internal class RenderArtifactCollector <: RenderArtifactStore {
    private let artifacts = ArrayList<RenderArtifact>()
    private let budget: RenderArtifactBudget

    init(artifactLimit!: Int64 = RENDER_ARTIFACT_LIMIT,
        totalLimit!: Int64 = RENDER_ARTIFACT_TOTAL_LIMIT,
        entryLimit!: Int64 = RENDER_ARTIFACT_ENTRY_LIMIT) {
        this.budget = RenderArtifactBudget(artifactLimit: artifactLimit,
            totalLimit: totalLimit, entryLimit: entryLimit)
    }

    public func addText(path: String, mediaType: String, content: String): Int64 {
        budget.checkAdd(path, content.size)
        artifacts.add(RenderArtifact(path, mediaType, content))
        budget.commitAdd(content.size)
        artifacts.size - 1
    }

    public func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64 {
        budget.checkAdd(path, bytes.size)
        artifacts.add(RenderArtifact(path, mediaType, bytes, true))
        budget.commitAdd(bytes.size)
        artifacts.size - 1
    }

    public func readText(entry: Int64, limit: Int64): String {
        let index = entryIndex(entry, "read")
        let artifact = artifacts[index]
        if (artifact.hasBinaryPayload) {
            throw IllegalArgumentException("render artifact entry ${entry} is not text")
        }
        if (limit < 0 || artifact.content.size > limit) {
            throw RenderResourceLimitException(
                "render artifact entry ${entry} exceeds ${limit} UTF-8 bytes")
        }
        artifact.content
    }

    public func replaceText(entry: Int64, content: String): Unit {
        let index = entryIndex(entry, "replace")
        let previous = artifacts[index]
        if (previous.hasBinaryPayload) {
            throw IllegalArgumentException("render artifact entry ${entry} is not text")
        }
        budget.checkReplace(previous.path, previous.byteSize, content.size)
        artifacts[index] = RenderArtifact(previous.path, previous.mediaType, content)
        budget.commitReplace(previous.byteSize, content.size)
    }

    func toArray(): Array<RenderArtifact> { artifacts.toArray() }

    private func entryIndex(entry: Int64, action: String): Int64 {
        if (entry < 0 || entry >= artifacts.size) {
            throw IllegalArgumentException(
                "cannot ${action} render artifact entry ${entry}")
        }
        entry
    }
}

protected func validateRenderArtifactBudgetForTest(sizes: Array<Int64>,
    artifactLimit: Int64, totalLimit: Int64, entryLimit: Int64): Unit {
    let artifacts = RenderArtifactCollector(artifactLimit: artifactLimit,
        totalLimit: totalLimit, entryLimit: entryLimit)
    var index: Int64 = 0
    for (size in sizes) {
        if (size < 0 || size > RENDER_ARTIFACT_LIMIT) {
            throw IllegalArgumentException("invalid test artifact size")
        }
        let _ = artifacts.addText("test-${index}.txt", "text/plain",
            String.fromUtf8(Array<Byte>(size, repeat: b'x')))
        index++
    }
}

protected func escapeHtmlWithRenderLimitForTest(value: String, limit: Int64): String {
    let out = RenderTextBuffer(limit: limit)
    appendHtmlEscapedValue(out, value)
    out.toString()
}

public interface DocumentationRenderer {
    prop format: String
    func render(documentation: DocumentationSet): Array<RenderArtifact>
}

public class JsonDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "json" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendJsonArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

internal func appendJsonArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet): Unit {
    if (!docIrFitsEncodedBudget(documentation, RENDER_ARTIFACT_LIMIT)) {
        throw RenderResourceLimitException(
            "Doc IR JSON exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
    }
    let _ = artifacts.addText("docs.json", "application/json", encodeDocIr(documentation))
}

internal func isVisibleForAudience(declaration: SymbolDoc, audience: String): Bool {
    match (audience) {
        case "external" => declaration.visibility == "public" || declaration.visibility == "protected"
        case "package" => declaration.visibility != "private"
        case "all" => true
        case _ => false
    }
}

internal func appendMarkdownPlainText(out: RenderTextBuffer, node: MarkdownNode): Unit {
    match (node.kind) {
        case "text" | "code_span" | "code_block" | "html_inline" | "html_block" =>
            out.append(node.literal)
        case "soft_break" | "hard_break" => out.append("\n")
        case "thematic_break" => out.append("\n")
        case "admonition" =>
            out.append("\n")
            for (child in node.children) { appendMarkdownPlainText(out, child) }
            out.append("\n")
        case _ =>
            var first = true
            for (child in node.children) {
                if (!first && (node.kind == "paragraph" || node.kind == "heading" ||
                    node.kind == "list_item" || node.kind == "table_cell")) { out.append(" ") }
                first = false
                appendMarkdownPlainText(out, child)
            }
            if (node.kind == "paragraph" || node.kind == "heading" ||
                node.kind == "list_item" || node.kind == "block_quote") { out.append("\n") }
    }
}

internal func markdownNodeText(node: MarkdownNode): String {
    let out = RenderTextBuffer()
    appendMarkdownPlainText(out, node)
    out.toString().trimAscii()
}

internal func documentationTagPlainText(tag: DocTag): String {
    match (tag.descriptionMarkdown) {
        case Some(tree) => markdownNodeText(tree)
        case None => tag.description
    }
}

internal func appendEscapedMarkdownText(out: RenderTextBuffer, value: String): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '(' | ')' | '<' | '>' |
                '#' | '+' | '-' | '.' | '!' | '|' | '=' | '~' =>
                out.append("\\"); out.append(rune)
            case _ => out.append(rune)
        }
    }
}

internal func safeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.contains("\n") || value.contains("\r")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    value.startsWith("https://") || value.startsWith("http://") ||
        value.startsWith("mailto:") || value.startsWith("#")
}

internal func markdownHexByte(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}

internal func markdownDestinationByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'-' || value == b'.' ||
        value == b'_' || value == b'~' || value == b':' || value == b'/' ||
        value == b'?' || value == b'#' || value == b'[' || value == b']' ||
        value == b'@' || value == b'!' || value == b'$' || value == b'&' ||
        value == b'*' || value == b'+' || value == b',' || value == b';' || value == b'='
}

internal func appendMarkdownPercentByte(out: RenderTextBuffer, value: Byte): Unit {
    let digits = "0123456789ABCDEF"
    let high = Int64((value >> 4) & 0x0F)
    let low = Int64(value & 0x0F)
    out.append("%")
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

internal func safeRelativeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.startsWith("//") || value.startsWith("/") ||
        value.contains("..") || value.contains("\\") || value.contains("#") ||
        value.contains("?") || value.contains(":") || value.contains(" ") ||
        value.contains("\n") || value.contains("\r")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    true
}

internal func markdownLinkDestination(value: String, allowRelative!: Bool = false): ?String {
    if (!safeLinkDestination(value) && (!allowRelative || !safeRelativeLinkDestination(value))) { return None }
    Some(encodeMarkdownDestination(value))
}

internal func encodeMarkdownDestination(value: String): String {
    let bytes = value.toArray()
    let out = RenderTextBuffer()
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte == b'%' && index + 2 < bytes.size && markdownHexByte(bytes[index + 1]) &&
            markdownHexByte(bytes[index + 2])) {
            out.append(String.fromUtf8([byte, bytes[index + 1], bytes[index + 2]]))
            index += 3
        } else {
            if (markdownDestinationByte(byte)) { out.append(String.fromUtf8([byte])) } else {
                appendMarkdownPercentByte(out, byte)
            }
            index++
        }
    }
    out.toString()
}

internal func assetReference(assetLookup: HashMap<String, String>, destination: String): ?String {
    match (assetLookup.get("path:${destination}")) {
        case Some(value) => Some(value)
        case None => match (assetLookup.get("id:${destination}")) {
            case Some(value) => Some(value)
            case None => if (destination.startsWith("./")) {
                assetLookup.get("path:${destination[2..]}")
            } else { None }
        }
    }
}

internal func markdownRequestedHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    let sourceLevel = match (node.metadata) {
        case Some(metadata) => if (metadata.kind == "heading") {
            metadata.headingLevel.getOrThrow()
        } else { 1 }
        case None => 1
    }
    base + sourceLevel - 1
}

internal func markdownHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    min(6, markdownRequestedHeadingLevel(node, base))
}

internal func appendMarkdownMarks(out: RenderTextBuffer, marker: String, count: Int64): Unit {
    if (count < 0 || count > DOC_IR_MAX_FENCE_LENGTH) {
        throw IllegalArgumentException("Markdown marker count exceeds renderer limit")
    }
    var index: Int64 = 0
    while (index < count) { out.append(marker); index++ }
}

internal func longestMarkdownMarkerRun(value: String, marker: Byte): Int64 {
    var longest: Int64 = 0
    var current: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == marker) {
            current++
            if (current > longest) { longest = current }
        } else { current = 0 }
    }
    longest
}

internal func markdownAllSpaces(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (rune in value.runes()) { if (UInt32(rune) != 0x20u32) { return false } }
    true
}

internal func appendHtmlEscapedValue(out: RenderTextBuffer, value: String,
    encodeTablePipe!: Bool = false): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '&' => out.append("&amp;")
            case '<' => out.append("&lt;")
            case '>' => out.append("&gt;")
            case '"' => out.append("&quot;")
            case '\'' => out.append("&#39;")
            case '|' => if (encodeTablePipe) { out.append("&#124;") } else { out.append(rune) }
            case _ => out.append(rune)
        }
    }
}

internal func appendMarkdownCodeSpan(out: RenderTextBuffer, value: String,
    tableCell!: Bool = false): Unit {
    let normalizedValue = value.replace("\r", " ").replace("\n", " ")
    // Backslash escaping cannot represent every pipe inside a GFM table code span:
    // an odd run of preceding backslashes changes whether the table parser sees
    // the pipe as escaped. Inline HTML has stable table parsing and preserves the
    // exact code text after entity decoding.
    if (tableCell && normalizedValue.contains("|")) {
        out.append("<code>")
        appendHtmlEscapedValue(out, normalizedValue, encodeTablePipe: true)
        out.append("</code>")
        return
    }
    let normalized = normalizedValue
    let delimiterLength = longestMarkdownMarkerRun(normalized, b'`') + 1
    if (delimiterLength > DOC_IR_MAX_FENCE_LENGTH) {
        out.append("<code>${escapeHtml(normalized)}</code>")
        return
    }
    let padded = !markdownAllSpaces(normalized) &&
        (normalized.startsWith(" ") || normalized.endsWith(" ") ||
        normalized.startsWith("`") || normalized.endsWith("`"))
    appendMarkdownMarks(out, "`", delimiterLength)
    if (padded) { out.append(" ") }
    out.append(normalized)
    if (padded) { out.append(" ") }
    appendMarkdownMarks(out, "`", delimiterLength)
}

internal class MarkdownFence {
    let marker: String
    let length: Int64

    init(marker: String, length: Int64) { this.marker = marker; this.length = length }
}

internal func markdownFenceCandidate(literal: String, marker: String, requestedLength: Int64,
    infoRaw: String): ?MarkdownFence {
    if ((marker != "`" && marker != "~") || requestedLength < 3 ||
        (marker == "`" && infoRaw.contains("`"))) { return None }
    let markerByte = if (marker == "`") { b'`' } else { b'~' }
    let run = longestMarkdownMarkerRun(literal, markerByte)
    let length = max(requestedLength, run + 1)
    if (length > DOC_IR_MAX_FENCE_LENGTH) { return None }
    Some(MarkdownFence(marker, length))
}

internal func selectMarkdownFence(literal: String, requestedMarker: String,
    requestedLength: Int64, infoRaw: String): MarkdownFence {
    if (infoRaw.contains("\n") || infoRaw.contains("\r")) {
        throw IllegalArgumentException("invalid fenced-code renderer info string")
    }
    match (markdownFenceCandidate(literal, requestedMarker, requestedLength, infoRaw)) {
        case Some(value) => return value
        case None => ()
    }
    let alternate = if (requestedMarker == "~") { "`" } else { "~" }
    match (markdownFenceCandidate(literal, alternate, 3, infoRaw)) {
        case Some(value) => value
        case None => throw IllegalArgumentException(
            "code block cannot be represented within the Markdown fence limit")
    }
}

internal func appendMarkdownCodeBlock(out: RenderTextBuffer, literal: String, infoRaw: String,
    requestedMarker: String, requestedLength: Int64): Unit {
    let fence = selectMarkdownFence(literal, requestedMarker, requestedLength, infoRaw)
    appendMarkdownMarks(out, fence.marker, fence.length)
    if (!infoRaw.isEmpty()) { out.append(infoRaw) }
    out.append("\n")
    out.append(literal)
    if (!literal.endsWith("\n")) { out.append("\n") }
    appendMarkdownMarks(out, fence.marker, fence.length)
    out.append("\n\n")
}
