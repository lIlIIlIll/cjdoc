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

internal func validateRenderArtifactPath(path: String): Unit {
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

internal class RenderTextBuffer {
    private let storage = StringBuilder()
    private let limit: Int64
    private var bytesWritten: Int64 = 0

    init(limit!: Int64 = RENDER_ARTIFACT_LIMIT) {
        if (limit < 0 || limit > RENDER_ARTIFACT_LIMIT) {
            throw IllegalArgumentException("invalid renderer text limit")
        }
        this.limit = limit
    }

    func append(value: String): Unit {
        bytesWritten = reserveRenderBytes(bytesWritten, value.size, limit,
            "renderer text buffer")
        storage.append(value)
    }

    func append(value: Rune): Unit {
        let code = UInt32(value)
        let width: Int64 = if (code <= 0x7Fu32) { 1 } else if (code <= 0x7FFu32) { 2 }
            else if (code <= 0xFFFFu32) { 3 } else { 4 }
        bytesWritten = reserveRenderBytes(bytesWritten, width, limit,
            "renderer text buffer")
        storage.append(value)
    }

    prop size: Int64 { get() { bytesWritten } }

    func toString(): String { storage.toString() }
}

public class RenderArtifact {
    public let path: String
    public let mediaType: String
    public let content: String
    private let bytesStorage: Array<Byte>

    public init(path: String, mediaType: String, content: String) {
        validateRenderArtifactPath(path)
        if (content.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = content
        this.bytesStorage = content.toArray()
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
    }

    public prop bytes: Array<Byte> { get() { bytesStorage.clone() } }
    public prop byteSize: Int64 { get() { bytesStorage.size } }
    public prop isBinary: Bool { get() { content.isEmpty() && !bytesStorage.isEmpty() } }
}

internal class RenderArtifactCollector {
    private let artifacts = ArrayList<RenderArtifact>()
    private let artifactLimit: Int64
    private let totalLimit: Int64
    private let entryLimit: Int64
    private var totalBytes: Int64 = 0

    init(artifactLimit!: Int64 = RENDER_ARTIFACT_LIMIT,
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

    private func reserve(size: Int64, path: String): Unit {
        if (artifacts.size >= entryLimit) {
            throw RenderResourceLimitException(
                "render artifacts exceed ${entryLimit} entries")
        }
        if (size < 0 || size > artifactLimit) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${artifactLimit} bytes")
        }
        totalBytes = reserveRenderBytes(totalBytes, size, totalLimit,
            "render artifact set")
    }

    func addText(path: String, mediaType: String, content: String): Unit {
        reserve(content.size, path)
        artifacts.add(RenderArtifact(path, mediaType, content))
    }

    func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Unit {
        reserve(bytes.size, path)
        artifacts.add(RenderArtifact(path, mediaType, bytes, true))
    }

    func toArray(): Array<RenderArtifact> { artifacts.toArray() }
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
        artifacts.addText("test-${index}.txt", "text/plain",
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

internal func appendJsonArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    if (!docIrFitsEncodedBudget(documentation, RENDER_ARTIFACT_LIMIT)) {
        throw RenderResourceLimitException(
            "Doc IR JSON exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
    }
    artifacts.addText("docs.json", "application/json", encodeDocIr(documentation))
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

internal func markdownLinkDestination(value: String): ?String {
    if (!safeLinkDestination(value)) { return None }
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
    Some(out.toString())
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

internal func markdownHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    let sourceLevel = match (node.metadata) {
        case Some(metadata) => if (metadata.kind == "heading") {
            metadata.headingLevel.getOrThrow()
        } else { 1 }
        case None => 1
    }
    min(6, base + sourceLevel - 1)
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
