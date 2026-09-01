package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

public class RenderResourceLimitException <: Exception {
    public init(message: String) { super(message) }

    protected override func getClassName(): String { "RenderResourceLimitException" }
}

private let RENDER_ARTIFACT_LIMIT: Int64 = DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES
private let RENDER_ARTIFACT_TOTAL_LIMIT: Int64 = 512 * 1024 * 1024
private let RENDER_ARTIFACT_ENTRY_LIMIT: Int64 = 65536

private func validateRenderArtifactPath(path: String): Unit {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("..")) {
        throw IllegalArgumentException("render artifact path must stay within the output directory")
    }
}

private func reserveRenderBytes(current: Int64, incoming: Int64, limit: Int64,
    description: String): Int64 {
    if (incoming < 0 || incoming > limit || current > limit - incoming) {
        throw RenderResourceLimitException("${description} exceeds ${limit} UTF-8 bytes")
    }
    current + incoming
}

private class RenderTextBuffer {
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

private class RenderArtifactCollector {
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

private func appendJsonArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    if (!docIrFitsEncodedBudget(documentation, RENDER_ARTIFACT_LIMIT)) {
        throw RenderResourceLimitException(
            "Doc IR JSON exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
    }
    artifacts.addText("docs.json", "application/json", encodeDocIr(documentation))
}

private func isVisibleForAudience(declaration: SymbolDoc, audience: String): Bool {
    match (audience) {
        case "external" => declaration.visibility == "public" || declaration.visibility == "protected"
        case "package" => declaration.visibility != "private"
        case "all" => true
        case _ => false
    }
}

private func appendMarkdownPlainText(out: RenderTextBuffer, node: MarkdownNode): Unit {
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

private func markdownNodeText(node: MarkdownNode): String {
    let out = RenderTextBuffer()
    appendMarkdownPlainText(out, node)
    out.toString().trimAscii()
}

private func appendEscapedMarkdownText(out: RenderTextBuffer, value: String): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '(' | ')' | '<' | '>' |
                '#' | '+' | '-' | '.' | '!' | '|' | '=' | '~' =>
                out.append("\\"); out.append(rune)
            case _ => out.append(rune)
        }
    }
}

private func safeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.contains("\n") || value.contains("\r")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    value.startsWith("https://") || value.startsWith("http://") ||
        value.startsWith("mailto:") || value.startsWith("#")
}

private func markdownHexByte(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}

private func markdownDestinationByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'-' || value == b'.' ||
        value == b'_' || value == b'~' || value == b':' || value == b'/' ||
        value == b'?' || value == b'#' || value == b'[' || value == b']' ||
        value == b'@' || value == b'!' || value == b'$' || value == b'&' ||
        value == b'*' || value == b'+' || value == b',' || value == b';' || value == b'='
}

private func appendMarkdownPercentByte(out: RenderTextBuffer, value: Byte): Unit {
    let digits = "0123456789ABCDEF"
    let high = Int64((value >> 4) & 0x0F)
    let low = Int64(value & 0x0F)
    out.append("%")
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

private func markdownLinkDestination(value: String): ?String {
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

private func assetReference(assetLookup: HashMap<String, String>, destination: String): ?String {
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

private func markdownHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    let sourceLevel = match (node.metadata) {
        case Some(metadata) => if (metadata.kind == "heading") {
            metadata.headingLevel.getOrThrow()
        } else { 1 }
        case None => 1
    }
    min(6, base + sourceLevel - 1)
}

private func appendMarkdownMarks(out: RenderTextBuffer, marker: String, count: Int64): Unit {
    if (count < 0 || count > DOC_IR_MAX_FENCE_LENGTH) {
        throw IllegalArgumentException("Markdown marker count exceeds renderer limit")
    }
    var index: Int64 = 0
    while (index < count) { out.append(marker); index++ }
}

private func longestMarkdownMarkerRun(value: String, marker: Byte): Int64 {
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

private func markdownAllSpaces(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (rune in value.runes()) { if (UInt32(rune) != 0x20u32) { return false } }
    true
}

private func appendHtmlEscapedValue(out: RenderTextBuffer, value: String,
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

private func appendMarkdownCodeSpan(out: RenderTextBuffer, value: String,
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

private class MarkdownFence {
    let marker: String
    let length: Int64

    init(marker: String, length: Int64) { this.marker = marker; this.length = length }
}

private func markdownFenceCandidate(literal: String, marker: String, requestedLength: Int64,
    infoRaw: String): ?MarkdownFence {
    if ((marker != "`" && marker != "~") || requestedLength < 3 ||
        (marker == "`" && infoRaw.contains("`"))) { return None }
    let markerByte = if (marker == "`") { b'`' } else { b'~' }
    let run = longestMarkdownMarkerRun(literal, markerByte)
    let length = max(requestedLength, run + 1)
    if (length > DOC_IR_MAX_FENCE_LENGTH) { return None }
    Some(MarkdownFence(marker, length))
}

private func selectMarkdownFence(literal: String, requestedMarker: String,
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

private func appendMarkdownCodeBlock(out: RenderTextBuffer, literal: String, infoRaw: String,
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

private func appendMarkdownInlineNode(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    tableCell!: Bool = false): Unit {
    match (node.kind) {
        case "text" => appendEscapedMarkdownText(out, node.literal)
        case "soft_break" => out.append(if (tableCell) { "<br>" } else { "\n" })
        case "hard_break" => out.append(if (tableCell) { "<br>" } else { "  \n" })
        case "emphasis" =>
            out.append("*"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("*")
        case "strong" =>
            out.append("**"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("**")
        case "strikethrough" =>
            out.append("~~"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("~~")
        case "code_span" => appendMarkdownCodeSpan(out, node.literal, tableCell: tableCell)
        case "link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("]")
            match (markdownLinkDestination(node.literal)) {
                case Some(destination) => out.append("(${destination})")
                case None => ()
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) =>
                    out.append("!["); appendEscapedMarkdownText(out, alt)
                    match (markdownLinkDestination("#${path}")) {
                        case Some(encoded) => out.append("](${encoded[1..]})")
                        case None => out.append("]")
                    }
                case None => appendEscapedMarkdownText(out, alt)
            }
        case "html_inline" | "html_block" => appendEscapedMarkdownText(out, node.literal)
        case _ => for (child in node.children) {
            appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                tableCell: tableCell)
        }
    }
}

private func appendMarkdownPrefixedBlock(out: RenderTextBuffer, content: String,
    firstPrefix: String, continuationPrefix: String,
    prefixBlankLines!: Bool = true): Unit {
    let lines = content.split("\n")
    var end = lines.size
    while (end > 0 && lines[end - 1].isEmpty()) { end-- }
    var index: Int64 = 0
    var wrote = false
    while (index < end) {
        if (!lines[index].isEmpty() || prefixBlankLines) {
            out.append(if (!wrote) { firstPrefix } else { continuationPrefix })
        }
        out.append(lines[index]); out.append("\n")
        wrote = true
        index++
    }
    if (!wrote) { out.append(firstPrefix); out.append("\n") }
}

private func appendMarkdownTableMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64): Unit {
    var rowIndex: Int64 = 0
    for (row in node.children) {
        out.append("|")
        for (cell in row.children) {
            out.append(" ")
            for (child in cell.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: true)
            }
            out.append(" |")
        }
        out.append("\n")
        if (rowIndex == 0) {
            out.append("|")
            var column: Int64 = 0
            for (_ in row.children) {
                let alignment = match (node.metadata) {
                    case Some(metadata) => if (column < metadata.tableAlignments.size) {
                        metadata.tableAlignments[column]
                    } else { "none" }
                    case None => "none"
                }
                match (alignment) {
                    case "left" => out.append(" :--- |")
                    case "center" => out.append(" :---: |")
                    case "right" => out.append(" ---: |")
                    case _ => out.append(" --- |")
                }
                column++
            }
            out.append("\n")
        }
        rowIndex++
    }
    out.append("\n")
}

private func appendMarkdownNodeMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
        }
        case "paragraph" =>
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase)
            }
            out.append("\n\n")
        case "heading" =>
            appendMarkdownMarks(out, "#", markdownHeadingLevel(node, headingBase)); out.append(" ")
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase)
            }
            out.append("\n\n")
        case "text" | "soft_break" | "hard_break" | "emphasis" | "strong" |
            "strikethrough" | "code_span" | "link" | "image" | "html_inline" =>
            appendMarkdownInlineNode(out, node, assetLookup, headingBase)
        case "code_block" =>
            match (node.metadata) {
                case Some(metadata) => if (metadata.kind == "code_block" &&
                    metadata.codeKind.getOrThrow() == "fenced") {
                    let marker = metadata.fenceCharacter.getOrThrow()
                    let fenceLength = metadata.fenceLength.getOrThrow()
                    let infoRaw = metadata.infoRaw.getOrThrow()
                    appendMarkdownCodeBlock(out, node.literal, infoRaw, marker, fenceLength)
                } else {
                    appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
                }
                case None => appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
            }
        case "thematic_break" => out.append("---\n\n")
        case "block_quote" =>
            let nested = RenderTextBuffer()
            for (child in node.children) {
                appendMarkdownNodeMarkdown(nested, child, assetLookup, headingBase)
            }
            appendMarkdownPrefixedBlock(out, nested.toString(), "> ", "> ")
            out.append("\n")
        case "list" =>
            var itemIndex: Int64 = 0
            let tight = match (node.metadata) {
                case Some(value) => value.kind == "list" && value.listTight.getOrThrow()
                case None => true
            }
            for (child in node.children) {
                let marker = if (let Some(value) <- node.metadata) {
                    if (value.kind == "list" && value.listKind.getOrThrow() == "ordered") {
                        let delimiter = if (value.listDelimiter.getOrThrow() == "parenthesis") {
                            ") "
                        } else { ". " }
                        "${value.listStart.getOrThrow() + itemIndex}${delimiter}"
                    } else { "- " }
                } else { "- " }
                let firstPrefix = RenderTextBuffer()
                firstPrefix.append(marker)
                if (let Some(itemMetadata) <- child.metadata) {
                    if (itemMetadata.kind == "list_item") {
                        match (itemMetadata.taskState.getOrThrow()) {
                            case "checked" => firstPrefix.append("[x] ")
                            case "unchecked" => firstPrefix.append("[ ] ")
                            case _ => ()
                        }
                    }
                }
                let nested = RenderTextBuffer()
                for (itemChild in child.children) {
                    appendMarkdownNodeMarkdown(nested, itemChild, assetLookup, headingBase)
                }
                let continuation = RenderTextBuffer()
                appendMarkdownMarks(continuation, " ", firstPrefix.toString().size)
                appendMarkdownPrefixedBlock(out, nested.toString(), firstPrefix.toString(),
                    continuation.toString(), prefixBlankLines: false)
                if (!tight && itemIndex + 1 < node.children.size) { out.append("\n") }
                itemIndex++
            }
            out.append("\n")
        case "list_item" =>
            for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
            }
        case "table" => appendMarkdownTableMarkdown(out, node, assetLookup, headingBase)
        case "table_row" | "table_cell" | "custom_block" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
        }
        case "custom_inline" => appendMarkdownInlineNode(out, node, assetLookup, headingBase)
        case "html_block" => appendEscapedMarkdownText(out, node.literal); out.append("\n\n")
        case _ => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
        }
    }
}

private func appendDocumentationMarkdown(out: RenderTextBuffer, comment: DocComment,
    assetLookup: HashMap<String, String>, locale!: String = "en"): Unit {
    for (tag in comment.tags) {
        if (tag.name == "deprecated") {
            out.append("> **${label(locale, "Deprecated.", "已弃用。")}** ")
            appendEscapedMarkdownText(out, tag.description)
            out.append("\n\n")
            break
        }
    }
    appendMarkdownNodeMarkdown(out, comment.markdown, assetLookup, 4)
    var hasParameters = false
    for (tag in comment.tags) { if (tag.name == "param") { hasParameters = true; break } }
    if (hasParameters) {
        out.append("#### ${label(locale, "Parameters", "参数")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "param") {
                out.append("- "); appendMarkdownCodeSpan(out, tag.subject); out.append(" — ")
                appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    for (tag in comment.tags) {
        if (tag.name == "return") {
            out.append("#### ${label(locale, "Returns", "返回值")}\n\n"); appendEscapedMarkdownText(out, tag.description); out.append("\n\n")
        }
    }
    var hasThrows = false
    for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
    if (hasThrows) {
        out.append("#### ${label(locale, "Throws", "异常")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "throws") {
                out.append("- "); appendMarkdownCodeSpan(out, tag.subject); out.append(" — ")
                appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    var hasSee = false
    for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
    if (hasSee) {
        out.append("#### ${label(locale, "See also", "另请参阅")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "see") { out.append("- "); appendMarkdownCodeSpan(out, tag.subject)
                if (!tag.description.isEmpty()) {
                    out.append(" — "); appendEscapedMarkdownText(out, tag.description)
                }; out.append("\n") }
        }
        out.append("\n")
    }
    for ((name, heading) in [("since", "Since"), ("author", "Authors"),
        ("version", "Version")]) {
        var opened = false
        for (tag in comment.tags) {
            if (tag.name != name) { continue }
            if (!opened) { out.append("#### ${label(locale, heading, match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" })}\n\n"); opened = true }
            out.append("- "); appendEscapedMarkdownText(out, tag.description); out.append("\n")
        }
        if (opened) { out.append("\n") }
    }
}

public class MarkdownDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "markdown" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendMarkdownArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

private func appendMarkdownArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
        validateTypedDocumentationSet(documentation)
        let out = RenderTextBuffer()
        let projection = RenderProjection(documentation)
        let projectedAssets = projectAssets(documentation, projection)
        let assetLookup = buildAssetLookup(projectedAssets)
        out.append("# "); appendEscapedMarkdownText(out, documentation.project.name); out.append("\n\n")
        out.append("Generated by "); appendMarkdownCodeSpan(out,
            "cjdoc ${documentation.generator.version}"); out.append(" from ")
        appendMarkdownCodeSpan(out, documentation.schemaVersion); out.append(".\n\n")
        out.append("## API\n\n")
        for (declaration in projection.visibleSymbols) {
            out.append("### "); appendMarkdownCodeSpan(out, declaration.qualifiedName)
            out.append("\n\n")
            appendMarkdownCodeBlock(out, declaration.headerSpelling, "cj", "`", 3)
            match (declaration.documentation) {
                case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup)
                case None => ()
            }
            out.append("- Kind: "); appendMarkdownCodeSpan(out, declaration.kind); out.append("\n")
            out.append("- Visibility: "); appendMarkdownCodeSpan(out, declaration.visibility)
            out.append("\n- Semantic state: "); appendMarkdownCodeSpan(out,
                declaration.semantic.state)
            out.append("\n- Source: "); appendMarkdownCodeSpan(out,
                "${declaration.source.path}:${declaration.source.start.line}:${declaration.source.start.column}")
            out.append("\n\n")
            if (!declaration.typeRelationships.isEmpty()) {
                out.append("#### Type relationships\n\n")
                for (relationship in declaration.typeRelationships) {
                    out.append("- "); appendMarkdownCodeSpan(out, relationship.kind)
                    out.append(" → "); appendMarkdownCodeSpan(out, relationship.target.spelling)
                    out.append(" ("); appendMarkdownCodeSpan(out, relationship.target.semantic.state)
                    out.append(")\n")
                }
                out.append("\n")
            }
            if (!declaration.symbolRelationships.isEmpty()) {
                out.append("#### Symbol relationships\n\n")
                for (relationship in declaration.symbolRelationships) {
                    out.append("- "); appendMarkdownCodeSpan(out, relationship.kind)
                    out.append(" → "); appendMarkdownCodeSpan(out, relationship.targetDisplay)
                    out.append(" ("); appendMarkdownCodeSpan(out, relationship.state)
                    out.append(")\n")
                }
                out.append("\n")
            }
        }
        artifacts.addText("markdown/docs.md", "text/markdown; charset=utf-8", out.toString())
        appendAssetArtifacts(artifacts, projectedAssets, "markdown")
}

private func escapeHtml(value: String): String {
    let out = RenderTextBuffer()
    appendHtmlEscapedValue(out, value)
    out.toString()
}

internal func assetMediaExtension(mediaType: String): String {
    match (mediaType) {
        case "image/png" => "png"
        case "image/jpeg" => "jpg"
        case "image/gif" => "gif"
        case "image/webp" => "webp"
        case "image/avif" => "avif"
        case _ => throw IllegalArgumentException("unsupported local asset media type '${mediaType}'")
    }
}

private func base64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
    if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
    if (value == b'+') { return 62 }
    if (value == b'/') { return 63 }
    return -1
}

internal func decodeAssetBase64(value: String): Array<Byte> {
    let encoded = value.toArray()
    if (encoded.isEmpty() || encoded.size % 4 != 0) {
        throw IllegalArgumentException("invalid local asset base64")
    }
    let decoded = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < encoded.size) {
        let last = index + 4 == encoded.size
        let first = base64Digit(encoded[index])
        let second = base64Digit(encoded[index + 1])
        if (first < 0 || second < 0) { throw IllegalArgumentException("invalid local asset base64") }
        let thirdPadding = encoded[index + 2] == b'='
        let fourthPadding = encoded[index + 3] == b'='
        if (thirdPadding) {
            if (!last || !fourthPadding || (second & 15) != 0) {
                throw IllegalArgumentException("invalid local asset base64 padding")
            }
            decoded.add(UInt8((first << 2) | (second >> 4)))
        } else {
            let third = base64Digit(encoded[index + 2])
            if (third < 0) { throw IllegalArgumentException("invalid local asset base64") }
            decoded.add(UInt8((first << 2) | (second >> 4)))
            decoded.add(UInt8(((second & 15) << 4) | (third >> 2)))
            if (fourthPadding) {
                if (!last || (third & 3) != 0) {
                    throw IllegalArgumentException("invalid local asset base64 padding")
                }
            } else {
                let fourth = base64Digit(encoded[index + 3])
                if (fourth < 0) { throw IllegalArgumentException("invalid local asset base64") }
                decoded.add(UInt8(((third & 3) << 6) | fourth))
            }
        }
        index += 4
    }
    decoded.toArray()
}

private func appendStructuredTextHtml(out: RenderTextBuffer, value: String): Unit {
    if (!value.isEmpty()) { out.append("<p>${escapeHtml(value)}</p>\n") }
}

private func markdownFragmentSlug(value: String): String {
    let out = RenderTextBuffer()
    var pendingDash = false
    var wrote = false
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (code == 0x20u32 || code == 0x09u32 || code == 0x0Au32 || code == 0x0Du32) {
            pendingDash = wrote
            continue
        }
        let keep = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) ||
            (code >= 0x61u32 && code <= 0x7Au32) || code == 0x2Du32 || code == 0x5Fu32 ||
            code >= 0x80u32
        if (!keep) { continue }
        if (pendingDash) { out.append("-"); pendingDash = false }
        if (code >= 0x41u32 && code <= 0x5Au32) {
            out.append(String.fromUtf8([UInt8(code + 0x20u32)]))
        } else {
            out.append(rune)
        }
        wrote = true
    }
    let slug = out.toString()
    if (slug.isEmpty()) { "section" } else { slug }
}

private class HtmlMarkdownContext {
    let headingBase: Int64
    let headingIds = ArrayList<String>()
    let fragmentTargets = HashMap<String, String>()
    let usedHeadingSlugs = HashSet<String>()
    var nextHeading: Int64 = 0

    init(headingBase: Int64) { this.headingBase = headingBase }
}

private func collectMarkdownHeadings(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, context: HtmlMarkdownContext): Unit {
    if (node.kind == "heading") {
        let base = markdownFragmentSlug(markdownNodeText(node))
        var occurrence = match (counts.get(base)) { case Some(value) => value case None => 0 }
        var slug = if (occurrence == 0) { base } else { "${base}-${occurrence}" }
        while (context.usedHeadingSlugs.contains(slug)) {
            occurrence++
            slug = "${base}-${occurrence}"
        }
        counts[base] = occurrence + 1
        let _ = context.usedHeadingSlugs.add(slug)
        let target = "${anchorPrefix}--doc-${slug}"
        context.headingIds.add(target)
        context.fragmentTargets["#${slug}"] = target
    }
    for (child in node.children) {
        collectMarkdownHeadings(child, anchorPrefix, counts, context)
    }
}

private func markdownHtmlContext(comment: DocComment, symbol: SymbolDoc,
    headingBase: Int64): HtmlMarkdownContext {
    let context = HtmlMarkdownContext(headingBase)
    collectMarkdownHeadings(comment.markdown, symbolAnchor(symbol), HashMap<String, Int64>(), context)
    context
}

private func appendMarkdownNodeHtml(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    tableHeader!: Bool = false, tightListItem!: Bool = false): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
        }
        case "paragraph" =>
            out.append("<p>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</p>\n")
        case "heading" =>
            let level = markdownHeadingLevel(node, context.headingBase)
            let id = context.headingIds[context.nextHeading]
            context.nextHeading++
            out.append("<h${level} id=\"${escapeHtml(id)}\">"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</h${level}>\n")
        case "text" => out.append(escapeHtml(node.literal))
        case "soft_break" => out.append("\n")
        case "hard_break" => out.append("<br>\n")
        case "emphasis" =>
            out.append("<em>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</em>")
        case "strong" =>
            out.append("<strong>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</strong>")
        case "strikethrough" =>
            out.append("<del>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</del>")
        case "code_span" => out.append("<code>${escapeHtml(node.literal)}</code>")
        case "code_block" =>
            out.append("<pre><code")
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "code_block") {
                    let language = metadata.language.getOrThrow()
                    if (!language.isEmpty()) {
                        out.append(" class=\"language-${htmlStableSlug(language)}\"")
                        out.append(" data-language=\"${escapeHtml(language)}\"")
                    }
                    if (!metadata.attributesRaw.getOrThrow().isEmpty()) {
                        out.append(" data-cjdoc-attributes=\"${escapeHtml(metadata.attributesRaw.getOrThrow())}\"")
                    }
                }
            }
            out.append(">${escapeHtml(node.literal)}</code></pre>\n")
        case "thematic_break" => out.append("<hr>\n")
        case "block_quote" =>
            out.append("<blockquote>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</blockquote>\n")
        case "list" =>
            var ordered = false
            var start: Int64 = 1
            var tight = true
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "list") {
                    ordered = metadata.listKind.getOrThrow() == "ordered"
                    start = metadata.listStart.getOrThrow()
                    tight = metadata.listTight.getOrThrow()
                }
            }
            if (ordered) { out.append("<ol start=\"${start}\">") } else { out.append("<ul>") }
            for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context,
                    tightListItem: tight)
            }
            if (ordered) { out.append("</ol>\n") } else { out.append("</ul>\n") }
        case "list_item" =>
            out.append("<li>")
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "list_item") {
                    match (metadata.taskState.getOrThrow()) {
                        case "checked" => out.append("<input type=\"checkbox\" disabled checked> ")
                        case "unchecked" => out.append("<input type=\"checkbox\" disabled> ")
                        case _ => ()
                    }
                }
            }
            for (child in node.children) {
                if (tightListItem && child.kind == "paragraph") {
                    for (grandchild in child.children) {
                        appendMarkdownNodeHtml(out, grandchild, assetLookup, rootPrefix, context)
                    }
                } else {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
            }; out.append("</li>")
        case "link" =>
            let destination = match (context.fragmentTargets.get(node.literal)) {
                case Some(target) => "#${target}"
                case None => node.literal
            }
            if (safeLinkDestination(destination)) {
                out.append("<a href=\"${escapeHtml(destination)}\"")
                if (destination.startsWith("http://") || destination.startsWith("https://")) {
                    out.append(" rel=\"noopener noreferrer\"")
                }
                out.append(">")
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
                out.append("</a>")
            } else {
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) => out.append("<img src=\"${rootPrefix}${escapeHtml(path)}\" alt=\"${escapeHtml(alt)}\" loading=\"lazy\">")
                case None => out.append(escapeHtml(alt))
            }
        case "table" =>
            out.append("<table>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</table>\n")
        case "table_row" =>
            let header = match (node.metadata) {
                case Some(metadata) => metadata.kind == "table_row" && metadata.tableHeader.getOrThrow()
                case None => false
            }
            out.append("<tr>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context,
                    tableHeader: header)
            }; out.append("</tr>")
        case "table_cell" =>
            let tag = if (tableHeader) { "th" } else { "td" }
            out.append("<${tag}")
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "table_cell" && metadata.tableAlignment.getOrThrow() != "none") {
                    out.append(" class=\"align-${metadata.tableAlignment.getOrThrow()}\"")
                }
            }
            out.append(">"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</${tag}>")
        case "html_block" => out.append("<pre>${escapeHtml(node.literal)}</pre>\n")
        case "html_inline" => out.append(escapeHtml(node.literal))
        case "custom_block" | "custom_inline" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
        }
        case _ => out.append(escapeHtml(markdownNodeText(node)))
    }
}

private let HTML_STYLE = """
:root {
  color-scheme: light;
  --bg: #fbfcfe;
  --surface: #ffffff;
  --surface-raised: #ffffff;
  --surface-subtle: #f5f7fb;
  --code-bg: #f6f8fc;
  --ink: #171b24;
  --muted: #626b7b;
  --faint: #8b95a6;
  --line: #e3e7ee;
  --line-strong: #d1d8e3;
  --accent: #2f6feb;
  --accent-strong: #1d55c7;
  --accent-soft: #edf3ff;
  --success: #21865b;
  --warning: #a36816;
  --danger: #c63b4a;
  --code-keyword: #8a3ffc;
  --code-type: #087f8c;
  --code-comment: #6c7789;
  --shadow: 0 12px 32px rgba(23, 31, 48, .08);
  --content-width: 56rem;
  --ui-font: Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  --display-font: var(--ui-font);
  --code-font: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --bg: #0b0e13;
  --surface: #10141b;
  --surface-raised: #151b24;
  --surface-subtle: #111720;
  --code-bg: #0c121b;
  --ink: #f1f5fb;
  --muted: #9aa5b5;
  --faint: #6e7b8e;
  --line: #242c38;
  --line-strong: #354153;
  --accent: #80a8ff;
  --accent-strong: #a9c4ff;
  --accent-soft: #162541;
  --success: #63d39b;
  --warning: #e8b45c;
  --danger: #ff8290;
  --code-keyword: #c19cff;
  --code-type: #64d2d8;
  --code-comment: #8491a4;
  --shadow: 0 18px 42px rgba(0, 0, 0, .26);
}
:root[data-theme="paper"] {
  color-scheme: light;
  --bg: #f7f2e8;
  --surface: #fffaf0;
  --surface-raised: #fffdf8;
  --surface-subtle: #f1e8d9;
  --code-bg: #f4ecdf;
  --ink: #2c2823;
  --muted: #665f55;
  --faint: #887f73;
  --line: #ded3c2;
  --line-strong: #cbbca6;
  --accent: #a34f3d;
  --accent-strong: #7d392f;
  --accent-soft: #f3dfd6;
  --success: #2f7756;
  --warning: #996016;
  --danger: #b43e43;
  --code-keyword: #8a3d84;
  --code-type: #186b70;
  --code-comment: #766d61;
  --shadow: 0 12px 32px rgba(82, 58, 33, .1);
  --ui-font: "Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif;
  --display-font: var(--ui-font);
}
:root[data-theme="ocean"] {
  color-scheme: dark;
  --bg: #07111f;
  --surface: #0c1a2c;
  --surface-raised: #12243b;
  --surface-subtle: #0d2035;
  --code-bg: #061321;
  --ink: #eaf7ff;
  --muted: #9bb8c9;
  --faint: #6f91a5;
  --line: #1e3b57;
  --line-strong: #315677;
  --accent: #61d9ff;
  --accent-strong: #a1e9ff;
  --accent-soft: #123550;
  --success: #65ddb1;
  --warning: #f1c368;
  --danger: #ff8e9d;
  --code-keyword: #d4a7ff;
  --code-type: #70e4e6;
  --code-comment: #7595aa;
  --shadow: 0 18px 42px rgba(0, 0, 0, .3);
}
:root[data-theme="forest"] {
  color-scheme: light;
  --bg: #f1f5ef;
  --surface: #fbfdf8;
  --surface-raised: #ffffff;
  --surface-subtle: #e9f0e8;
  --code-bg: #edf4ed;
  --ink: #1d2c23;
  --muted: #5f7063;
  --faint: #7f9182;
  --line: #d5e0d4;
  --line-strong: #b9cbbb;
  --accent: #2f7758;
  --accent-strong: #20573f;
  --accent-soft: #dfeee4;
  --success: #23734f;
  --warning: #8d6418;
  --danger: #b43f4a;
  --code-keyword: #7d4fa1;
  --code-type: #1b7070;
  --code-comment: #718173;
  --shadow: 0 12px 32px rgba(37, 74, 50, .09);
}
:root[data-theme="terminal"] {
  color-scheme: dark;
  --bg: #07100b;
  --surface: #0b1710;
  --surface-raised: #102219;
  --surface-subtle: #0c1d13;
  --code-bg: #050d08;
  --ink: #d9ffe7;
  --muted: #91b8a0;
  --faint: #5c886e;
  --line: #1b3b27;
  --line-strong: #2b5b3b;
  --accent: #69e69a;
  --accent-strong: #a2ffc1;
  --accent-soft: #123d25;
  --success: #70e6a3;
  --warning: #f0c56b;
  --danger: #ff8997;
  --code-keyword: #d0a4ff;
  --code-type: #78e9de;
  --code-comment: #6c9b7c;
  --shadow: 0 18px 42px rgba(0, 0, 0, .34);
  --ui-font: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;
  --display-font: var(--ui-font);
}
:root[data-theme="violet"] {
  color-scheme: light;
  --bg: #f6f3fb;
  --surface: #ffffff;
  --surface-raised: #ffffff;
  --surface-subtle: #f0ecf8;
  --code-bg: #f1effa;
  --ink: #252235;
  --muted: #68627a;
  --faint: #8f89a2;
  --line: #e1dced;
  --line-strong: #cbc3dc;
  --accent: #6848c7;
  --accent-strong: #4b319b;
  --accent-soft: #ebe5ff;
  --success: #2e7659;
  --warning: #966315;
  --danger: #b64050;
  --code-keyword: #914bc0;
  --code-type: #19737c;
  --code-comment: #7c7591;
  --shadow: 0 12px 32px rgba(69, 49, 111, .1);
  --display-font: "Avenir Next","Segoe UI",ui-sans-serif,sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    color-scheme: dark;
    --bg: #0b0e13;
    --surface: #10141b;
    --surface-raised: #151b24;
    --surface-subtle: #111720;
    --code-bg: #0c121b;
    --ink: #f1f5fb;
    --muted: #9aa5b5;
    --faint: #6e7b8e;
    --line: #242c38;
    --line-strong: #354153;
    --accent: #80a8ff;
    --accent-strong: #a9c4ff;
    --accent-soft: #162541;
    --success: #63d39b;
    --warning: #e8b45c;
    --danger: #ff8290;
    --code-keyword: #c19cff;
    --code-type: #64d2d8;
    --code-comment: #8491a4;
    --shadow: 0 18px 42px rgba(0, 0, 0, .26);
  }
}
*{box-sizing:border-box}
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 var(--ui-font);text-rendering:optimizeLegibility}
body,button,input,select{font-family:inherit}
::selection{background:var(--accent-soft);color:var(--ink)}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-track{background:var(--surface-subtle)}::-webkit-scrollbar-thumb{background:var(--line-strong);border:3px solid var(--surface-subtle);border-radius:8px}
a{color:var(--accent);text-decoration:none;text-underline-offset:3px}a:hover{text-decoration:underline}a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
h1,h2,h3,h4{color:var(--ink);line-height:1.2;letter-spacing:-.02em;font-family:var(--display-font)}h1{font-size:clamp(2rem,4vw,3rem);margin:0;font-weight:730}h2{font-size:1.35rem;margin:2.75rem 0 .9rem;padding-bottom:.65rem;border-bottom:1px solid var(--line)}h3{font-size:1rem;margin:1.6rem 0 .55rem}p{margin:.8rem 0}ul,ol{padding-left:1.3rem}li+li{margin-top:.3rem}
code,pre{font-family:var(--code-font)}code{font-size:.91em}p code,li code,dt code,dd code{padding:.13rem .35rem;border:1px solid var(--line);border-radius:5px;background:var(--code-bg);color:var(--ink)}
button,input,select{font-size:inherit}button{cursor:pointer}
.site-nav{position:sticky;top:0;z-index:20;border-bottom:1px solid var(--line);background:var(--surface)}
.site-nav-inner{max-width:1600px;min-height:64px;margin:0 auto;padding:.7rem 1.25rem;display:grid;grid-template-columns:10.5rem minmax(18rem,1fr) auto;align-items:center;gap:1.25rem}
.brand{display:inline-flex;align-items:center;gap:.58rem;color:var(--ink);font-size:1.12rem;font-weight:760;letter-spacing:-.035em}.brand:hover{text-decoration:none}.brand-mark{width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1.5px solid var(--accent);border-radius:6px;color:var(--accent);font:700 .78rem/1 ui-monospace,monospace;letter-spacing:-.08em}.brand-subtitle{display:block;margin-top:.08rem;color:var(--faint);font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase}
.site-search{min-width:0;display:flex;align-items:center;gap:.6rem}.search-area{position:relative;min-width:0;flex:1}.search-shell{height:40px;display:flex;align-items:center;gap:.65rem;padding:0 .75rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface-subtle);transition:border-color .18s ease,box-shadow .18s ease}.search-shell:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}.search-shell svg{flex:0 0 auto;color:var(--faint)}.search-shell input{width:100%;min-width:0;border:0;outline:0;background:transparent;color:var(--ink)}.search-shell input::placeholder{color:var(--muted)}kbd{padding:.18rem .38rem;border:1px solid var(--line-strong);border-bottom-width:2px;border-radius:4px;background:var(--surface);color:var(--muted);font:600 .7rem/1 ui-monospace,monospace;white-space:nowrap}
.search-filters{display:flex;gap:.35rem}.search-filters label{display:flex;align-items:center}.search-filters select{max-width:8.5rem;height:40px;padding:0 1.8rem 0 .65rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted)}
.top-actions{display:flex;align-items:center;gap:.2rem;white-space:nowrap}.version-label{padding:0 .65rem;color:var(--muted);font:600 .78rem/2 ui-monospace,monospace}.top-source{display:inline-flex;align-items:center;gap:.4rem;padding:0 .7rem;color:var(--muted);font-size:.82rem}.top-source-disabled{cursor:default;opacity:.72}.theme-picker{display:inline-flex;align-items:center}.theme-picker select{height:36px;max-width:8.8rem;padding:0 1.75rem 0 .65rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted);font-size:.78rem}.theme-picker select:hover{border-color:var(--accent);color:var(--ink)}.theme-toggle{width:36px;height:36px;display:grid;place-items:center;margin-left:.3rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted)}.theme-toggle:hover{border-color:var(--accent);color:var(--accent)}.theme-toggle .icon-moon{display:none}.theme-toggle[data-mode="dark"] .icon-sun{display:none}.theme-toggle[data-mode="dark"] .icon-moon{display:block}
.search-results{position:absolute;z-index:30;top:calc(100% + .55rem);left:0;width:100%;max-height:25rem;overflow:auto;margin:0;padding:.35rem;list-style:none;background:var(--surface-raised);border:1px solid var(--line-strong);border-radius:8px;box-shadow:var(--shadow)}.search-results:empty{display:none}.search-results a{display:block;padding:.55rem .65rem;border-radius:5px;color:var(--ink);text-decoration:none}.search-results a:hover,.search-results a:focus,.search-results [aria-selected=true] a{background:var(--accent-soft)}.search-kind{color:var(--muted);font-size:.82rem}
.docs-layout{max-width:1600px;margin:0 auto;display:grid;grid-template-columns:248px minmax(0,1fr) 220px;align-items:start}.docs-sidebar{position:sticky;top:64px;height:calc(100vh - 64px);overflow:auto;padding:2rem 1rem 3rem 1.25rem;border-right:1px solid var(--line);background:var(--surface)}.sidebar-label{margin:0 0 .7rem;color:var(--faint);font-size:.68rem;font-weight:750;letter-spacing:.12em;text-transform:uppercase}.sidebar-section+.sidebar-section{margin-top:1.8rem}.sidebar-link{display:flex;align-items:center;gap:.55rem;min-height:34px;margin:.12rem 0;padding:.38rem .6rem;border-radius:6px;color:var(--muted);font-size:.88rem;font-weight:560}.sidebar-link:hover{background:var(--surface-subtle);color:var(--ink);text-decoration:none}.sidebar-link.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:680}.sidebar-link svg{color:currentColor}.sidebar-group{margin-top:.3rem}.sidebar-group summary{display:flex;align-items:center;justify-content:space-between;gap:.4rem;padding:.42rem .6rem;color:var(--ink);font-size:.86rem;font-weight:680;cursor:pointer;list-style:none}.sidebar-group summary::-webkit-details-marker{display:none}.sidebar-group summary:before{content:"";width:7px;height:7px;border-right:1.5px solid var(--muted);border-bottom:1.5px solid var(--muted);transform:rotate(-45deg);transition:transform .16s ease}.sidebar-group[open] summary:before{transform:rotate(45deg) translate(-1px,-1px)}.sidebar-count{color:var(--faint);font:600 .7rem ui-monospace,monospace}.sidebar-packages{margin:.18rem 0 .4rem 1rem;padding-left:.45rem;border-left:1px solid var(--line)}.sidebar-package{display:flex;align-items:center;justify-content:space-between;gap:.4rem;padding:.34rem .55rem;color:var(--muted);font:500 .8rem ui-monospace,monospace;border-radius:5px}.sidebar-package:hover{background:var(--surface-subtle);color:var(--accent);text-decoration:none}.sidebar-package-count{color:var(--faint);font-size:.68rem}.sidebar-note{margin:1.8rem .6rem 0;padding-top:1rem;border-top:1px solid var(--line);color:var(--faint);font-size:.75rem}.sidebar-note code{display:block;margin-top:.28rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.docs-main{min-width:0;min-height:calc(100vh - 64px);padding:2.2rem clamp(1.25rem,4vw,4.5rem) 5rem}.content-column{max-width:var(--content-width);margin:0 auto}.toc-panel{position:sticky;top:64px;height:calc(100vh - 64px);padding:2.25rem 1.1rem 3rem 1.45rem;border-left:1px solid var(--line);background:var(--surface)}.toc-title{margin:0 0 .75rem;color:var(--faint);font-size:.68rem;font-weight:760;letter-spacing:.12em;text-transform:uppercase}.toc-panel nav{max-height:calc(100vh - 120px);overflow:auto}.toc-panel ol{margin:0;padding:0;list-style:none}.toc-panel li{margin:0}.toc-panel li[data-depth="3"]{padding-left:.7rem}.toc-panel a{display:block;padding:.32rem .65rem;border-left:2px solid transparent;color:var(--muted);font-size:.8rem;line-height:1.45}.toc-panel a:hover{color:var(--ink);text-decoration:none}.toc-panel a.is-active{border-left-color:var(--accent);color:var(--accent);font-weight:680}
.breadcrumbs{margin:0 0 1.4rem;color:var(--muted);font-size:.8rem}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:.45rem;margin:0;padding:0;list-style:none}.breadcrumbs li+li:before{content:"/";margin-right:.45rem;color:var(--faint)}.breadcrumbs a{color:var(--muted)}.page-header{margin-bottom:2.4rem}.page-header h1 code{padding:0;border:0;background:none;color:inherit;font-size:inherit}.page-lead{max-width:68ch;margin:1rem 0 0;color:var(--muted);font-size:1.03rem}.page-meta{display:flex;flex-wrap:wrap;gap:.55rem 1.25rem;margin:1.25rem 0 0;color:var(--muted);font-size:.78rem}.page-meta strong{color:var(--ink);font-weight:650}.page-meta-item{display:inline-flex;align-items:center;gap:.38rem}.status-dot{width:7px;height:7px;border-radius:50%;background:var(--success)}.status-dot.partial{background:var(--warning)}.status-dot.unavailable{background:var(--danger)}
.module-list{display:grid;gap:1rem}.module-record{padding:1rem 1.1rem;border:1px solid var(--line);border-radius:8px;background:var(--surface)}.module-record-head{display:flex;align-items:baseline;justify-content:space-between;gap:1rem}.module-record h3{margin:0;font-size:1rem}.module-record h3 code{padding:0;border:0;background:transparent;color:var(--ink)}.module-record p{margin:.35rem 0;color:var(--muted);font-size:.84rem}.record-role{color:var(--faint);font:600 .7rem ui-monospace,monospace;text-transform:uppercase}.package-links{display:grid;grid-template-columns:repeat(auto-fit,minmax(12rem,1fr));gap:.25rem .9rem;margin:.85rem 0 0;padding:.75rem 0 0;border-top:1px solid var(--line);list-style:none}.package-links li{margin:0}.package-links a{display:flex;align-items:center;justify-content:space-between;gap:.5rem;padding:.35rem .45rem;color:var(--accent);font:500 .82rem ui-monospace,monospace;border-radius:4px}.package-links a:hover{background:var(--accent-soft);text-decoration:none}.package-arrow{color:var(--faint)}.package-index{display:grid;grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));gap:.2rem .9rem;margin:0;padding:0;list-style:none}.package-index li{margin:0;border-bottom:1px solid var(--line)}.package-index a{display:flex;align-items:center;justify-content:space-between;gap:.5rem;padding:.7rem .4rem;color:var(--accent);font:500 .84rem ui-monospace,monospace}.package-index a:hover{background:var(--accent-soft);text-decoration:none}.package-index small{color:var(--faint);font:600 .7rem ui-monospace,monospace}
.record-list{margin:.5rem 0 0;padding:0;list-style:none}.record-list li{padding:.6rem 0;border-bottom:1px solid var(--line)}.record-list li:last-child{border-bottom:0}.record-list a{font-family:ui-monospace,monospace}.diagnostics-list{display:grid;gap:.45rem;margin:0;padding:0;list-style:none}.diagnostic-item{padding:.65rem .75rem;border:1px solid var(--line);border-radius:6px;background:var(--surface-subtle);font-size:.84rem}.diagnostic-item strong{font:650 .76rem ui-monospace,monospace}.diagnostic-item code{word-break:break-word}.callout{margin:1rem 0;padding:.8rem 1rem;border:1px solid color-mix(in srgb,var(--warning) 45%,var(--line));border-left:3px solid var(--warning);border-radius:6px;background:var(--surface-subtle);color:var(--muted);font-size:.84rem}.callout strong{color:var(--warning)}.meta{color:var(--muted);font-size:.8rem}.badge{display:inline-flex;align-items:center;gap:.25rem;padding:.16rem .42rem;margin-right:.3rem;border:1px solid var(--line-strong);border-radius:5px;background:var(--surface-subtle);color:var(--muted);font:650 .69rem/1.4 ui-monospace,monospace;vertical-align:middle}.badge[data-state="resolved"]{border-color:color-mix(in srgb,var(--success) 38%,var(--line));color:var(--success)}.badge[data-state="partial"]{border-color:color-mix(in srgb,var(--warning) 38%,var(--line));color:var(--warning)}.badge[data-state="unavailable"],.badge[data-state="ambiguous"]{border-color:color-mix(in srgb,var(--danger) 38%,var(--line));color:var(--danger)}
.symbol-entry{margin:2rem 0 0;padding:1.25rem 0 2rem;border-top:1px solid var(--line)}.symbol-entry h2,.declaration-summary h3{margin:.05rem 0 .8rem;padding:0;border:0;font-size:1.08rem}.symbol-entry h2 code,.declaration-summary h3 code{padding:0;border:0;background:transparent;color:var(--accent)}.symbol-entry h2 a:hover,.declaration-summary h3 a:hover{text-decoration:none}.symbol-meta{margin:.5rem 0 1rem}.symbol-contract{position:relative}.signature-heading{display:flex;align-items:center;gap:.55rem;margin:1.6rem 0 .65rem;font-size:.9rem}.signature-heading:after{content:"";height:1px;flex:1;background:var(--line)}.description>p:first-child,.summary>p:first-child{margin-top:0}.description h2{margin-top:2.2rem;font-size:1.22rem}.description h3{font-size:.98rem}.relationships{display:grid;grid-template-columns:max-content 1fr;gap:.4rem .9rem;margin:1rem 0;color:var(--muted);font-size:.83rem}.relationships dt{margin:0;color:var(--faint);font:650 .72rem ui-monospace,monospace;text-transform:uppercase}.relationships dd{margin:0}.symbol-entry dl:not(.relationships){display:grid;grid-template-columns:minmax(7rem,max-content) 1fr;gap:.75rem 1.25rem;margin:1rem 0}.parameter-list{margin:1rem 0;border-top:1px solid var(--line)}.parameter-row{display:grid;grid-template-columns:minmax(7rem,max-content) minmax(7rem,max-content) minmax(0,1fr);align-items:start;column-gap:1rem;padding:.7rem 0;border-bottom:1px solid var(--line)}.parameter-row dt,.parameter-row dd{margin:0}.parameter-row dt{color:var(--ink);font-weight:650}.parameter-type{color:var(--muted);white-space:nowrap}.parameter-colon{color:var(--faint);margin-right:.25rem}.parameter-description{min-width:0;color:var(--muted)}.parameter-description>:first-child{margin-top:0}.parameter-description>:last-child{margin-bottom:0}.symbol-entry dt{margin:0;color:var(--ink);font-weight:650}.symbol-entry dd{margin:0;color:var(--muted)}
pre{position:relative;margin:1rem 0;padding:1.1rem 3.3rem 1.1rem 1rem;overflow:auto;border:1px solid var(--line-strong);border-radius:8px;background:var(--code-bg);color:var(--ink);font-size:.83rem;line-height:1.7;white-space:pre-wrap;overflow-wrap:anywhere}pre code{padding:0;border:0;background:transparent;color:inherit;font-size:inherit}.code-copy{position:absolute;top:.55rem;right:.55rem;width:30px;height:30px;display:grid;place-items:center;border:1px solid transparent;border-radius:5px;background:transparent;color:var(--muted)}.code-copy:hover{border-color:var(--line-strong);background:var(--surface);color:var(--accent)}.code-copy[data-copied="true"]{color:var(--success)}.code-copy svg{pointer-events:none}.description blockquote{margin:1rem 0;padding:.1rem 1rem;border-left:2px solid var(--accent);color:var(--muted);background:var(--accent-soft)}.description img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:6px}.description table{width:100%;border-collapse:collapse;margin:1rem 0;font-size:.84rem}.description th,.description td{padding:.55rem .65rem;border:1px solid var(--line);text-align:left;vertical-align:top}.description th{background:var(--surface-subtle);font-weight:680}.description hr{margin:2rem 0;border:0;border-top:1px solid var(--line)}
.declaration-summary{margin:1.25rem 0;padding:1rem 0;border-top:1px solid var(--line)}.declaration-summary p{margin:.3rem 0;color:var(--muted);font-size:.84rem}.declaration-summary .meta{margin-top:.55rem}.empty-state{padding:1rem;border:1px dashed var(--line-strong);border-radius:7px;color:var(--muted)}
.site-footer{border-top:1px solid var(--line);background:var(--surface)}.footer-inner{max-width:1600px;margin:0 auto;padding:1rem 1.25rem;display:flex;align-items:center;justify-content:space-between;gap:1rem;color:var(--muted);font-size:.75rem}.footer-mark{color:var(--ink);font-weight:680}
.align-left{text-align:left}.align-center{text-align:center}.align-right{text-align:right}
@media(max-width:1180px){.docs-layout{grid-template-columns:220px minmax(0,1fr)}.toc-panel{display:none}.site-nav-inner{grid-template-columns:9rem minmax(15rem,1fr) auto}.search-filters{display:none}}
@media(max-width:760px){html{scroll-behavior:auto}.site-nav-inner{display:flex;flex-wrap:wrap;gap:.7rem;padding:.7rem .9rem}.brand{flex:0 0 auto}.top-actions{margin-left:auto}.theme-picker select{max-width:7.6rem}.site-search{order:3;width:100%}.search-shell{height:42px}.docs-layout{display:block}.docs-sidebar{position:static;height:auto;max-height:18rem;padding:1rem .9rem;border-right:0;border-bottom:1px solid var(--line)}.sidebar-section{display:inline}.sidebar-section+.sidebar-section{margin-top:1rem}.sidebar-link{display:inline-flex;margin:.1rem .2rem .1rem 0}.sidebar-group{margin-top:.65rem}.sidebar-packages{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));max-height:7rem;overflow:auto}.sidebar-note{display:none}.docs-main{padding:1.55rem .95rem 3.5rem}.content-column{max-width:none}.page-header{margin-bottom:1.8rem}.page-meta{gap:.4rem .8rem}.module-record{padding:.85rem .8rem}.package-links{grid-template-columns:1fr}.package-index{grid-template-columns:1fr}.symbol-entry dl:not(.relationships){grid-template-columns:1fr;gap:.25rem}.parameter-row{grid-template-columns:minmax(6rem,max-content) minmax(0,1fr);column-gap:.75rem}.parameter-description{grid-column:2}.symbol-entry dd{margin-bottom:.45rem}.relationships{grid-template-columns:1fr;gap:.2rem}.relationships dd{margin-bottom:.55rem}.footer-inner{align-items:flex-start;flex-direction:column;padding:.9rem}}
@media print{.site-nav,.docs-sidebar,.toc-panel{display:none}.docs-layout{display:block}.docs-main{padding:0}.site-footer{margin-top:2rem}.content-column{max-width:none}a{color:inherit;text-decoration:underline}pre{white-space:pre-wrap;overflow:visible}.code-copy{display:none}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition-duration:.01ms!important;animation-duration:.01ms!important;animation-iteration-count:1!important}}
.symbol-entry dl.parameter-list{display:grid;grid-template-columns:minmax(7rem,max-content) minmax(7rem,max-content) minmax(0,1fr);column-gap:1rem;row-gap:0}
.parameter-row{display:grid;grid-column:1/-1;grid-template-columns:subgrid}
.parameter-row dt,.parameter-row dd{min-width:0;margin:0;padding:.7rem 0;border-bottom:1px solid var(--line)}
@media(max-width:760px){.symbol-entry dl.parameter-list{grid-template-columns:minmax(6rem,max-content) minmax(0,1fr);column-gap:.75rem;row-gap:0}.parameter-description{grid-column:2}}
"""

private let HTML_SEARCH_SCRIPT = """
(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  if (!input || !results) return;
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  let entries = [];
  let visible = [];
  let selected = -1;
  const ambiguousLabels = new Set();
  const displayKey = (entry) => JSON.stringify([entry.packageName, entry.qualifiedName]);
  const rank = (entry, query) => {
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + entry.summary).toLocaleLowerCase();
    return query.split(/\\s+/).filter(Boolean).every((token) => haystack.includes(token)) ? 4 : -1;
  };
  const select = (next) => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let i = 0; i < results.children.length; i += 1) {
      results.children[i].setAttribute("aria-selected", i === selected ? "true" : "false");
    }
    const active = results.children[selected];
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const render = () => {
    results.replaceChildren();
    visible = [];
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) { input.setAttribute("aria-expanded", "false"); return; }
    const selectedKind = kindFilter ? kindFilter.value : "";
    const selectedPackage = packageFilter ? packageFilter.value : "";
    visible = entries.map((entry) => ({entry, rank: rank(entry, query)}))
      .filter((item) => item.rank >= 0 && (!selectedKind || item.entry.kind === selectedKind) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id))
      .slice(0, 20).map((item) => item.entry);
    for (const entry of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const name = document.createElement("span");
      const kind = document.createElement("span");
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.href = root + entry.href;
      name.textContent = entry.qualifiedName;
      kind.className = "search-kind";
      kind.textContent = " — " + entry.kind +
        (ambiguousLabels.has(displayKey(entry)) ? " · " + entry.id : "");
      link.append(name, kind);
      item.append(link);
      results.append(item);
    }
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const addOptions = (selectElement, values) => {
    if (!selectElement) return;
    for (const value of [...new Set(values)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      selectElement.append(option);
    }
  };
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  entries = index && index.schemaVersion === "cjdoc.search-index/4" && Array.isArray(index.entries)
    ? index.entries : [];
  const firstIdsByLabel = new Map();
  for (const entry of entries) {
    const key = displayKey(entry);
    if (firstIdsByLabel.has(key) && firstIdsByLabel.get(key) !== entry.id) ambiguousLabels.add(key);
    else firstIdsByLabel.set(key, entry.id);
  }
  addOptions(kindFilter, entries.map((entry) => entry.kind));
  addOptions(packageFilter, entries.map((entry) => entry.packageName));
  render();
  input.addEventListener("input", render);
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); select(selected + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); select(selected < 0 ? visible.length - 1 : selected - 1); }
    else if (event.key === "Enter" && selected >= 0) { event.preventDefault(); results.children[selected].querySelector("a").click(); }
    else if (event.key === "Escape") { input.value = ""; render(); }
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault(); input.focus();
    }
  });
  const themeToggle = document.querySelector("[data-cjdoc-theme-toggle]");
  const themeOptions = [
    ["system", "System", "跟随系统"],
    ["light", "Light", "浅色"],
    ["dark", "Dark", "深色"],
    ["paper", "Paper", "纸张"],
    ["ocean", "Ocean", "深海"],
    ["forest", "Forest", "松林"],
    ["terminal", "Terminal", "终端"],
    ["violet", "Violet", "紫墨"]
  ];
  const themeValues = new Set(themeOptions.slice(1).map((option) => option[0]));
  const darkThemes = new Set(["dark", "ocean", "terminal"]);
  const isKnownTheme = (value) => themeValues.has(value);
  const createThemePicker = () => {
    if (!themeToggle) return null;
    const picker = document.createElement("label");
    const pickerText = document.createElement("span");
    const select = document.createElement("select");
    const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
    picker.className = "theme-picker";
    pickerText.className = "sr-only";
    pickerText.textContent = isChinese ? "主题" : "Theme";
    select.setAttribute("aria-label", pickerText.textContent);
    select.dataset.cjdocThemeSelect = "";
    for (const optionData of themeOptions) {
      const option = document.createElement("option");
      option.value = optionData[0];
      option.textContent = isChinese ? optionData[2] : optionData[1];
      select.append(option);
    }
    picker.append(pickerText, select);
    themeToggle.before(picker);
    return select;
  };
  const themeSelect = createThemePicker();
  const readTheme = () => {
    const explicit = document.documentElement.dataset.theme;
    if (isKnownTheme(explicit)) return explicit;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark" : "light";
  };
  const syncThemeControls = () => {
    const explicit = document.documentElement.dataset.theme;
    if (themeSelect) themeSelect.value = isKnownTheme(explicit) ? explicit : "system";
    if (!themeToggle) return;
    const current = readTheme();
    const isDark = darkThemes.has(current);
    const next = isDark ? "light" : "dark";
    themeToggle.dataset.mode = isDark ? "dark" : "light";
    themeToggle.setAttribute("aria-pressed", isDark ? "true" : "false");
    themeToggle.setAttribute("aria-label", "Switch to " + next + " theme");
    themeToggle.title = "Switch to " + next + " theme";
  };
  const setTheme = (next) => {
    if (next === "system") delete document.documentElement.dataset.theme;
    else if (isKnownTheme(next)) document.documentElement.dataset.theme = next;
    else return;
    try { localStorage.setItem("cjdoc-theme", next); } catch (_) { /* optional */ }
    syncThemeControls();
  };
  if (themeToggle || themeSelect) {
    try {
      const storedTheme = localStorage.getItem("cjdoc-theme");
      if (storedTheme === "system") delete document.documentElement.dataset.theme;
      else if (isKnownTheme(storedTheme)) document.documentElement.dataset.theme = storedTheme;
    } catch (_) { /* file:// storage can be unavailable */ }
    syncThemeControls();
    if (themeToggle) {
      themeToggle.addEventListener("click", () => {
        setTheme(darkThemes.has(readTheme()) ? "light" : "dark");
      });
    }
    if (themeSelect) themeSelect.addEventListener("change", () => setTheme(themeSelect.value));
  }
  const toc = document.querySelector("[data-cjdoc-toc]");
  const content = document.querySelector("[data-cjdoc-content]");
  if (toc && content) {
    const tocList = toc.querySelector("ol");
    const headings = [...content.querySelectorAll("h2, h3")];
    const usedIds = new Set();
    const slug = (value, index) => {
      const normalized = value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
      return normalized || "section-" + index;
    };
    for (let index = 0; index < headings.length; index += 1) {
      const heading = headings[index];
      let id = heading.id || slug(heading.textContent.trim(), index);
      let suffix = 2;
      while (usedIds.has(id)) { id = slug(heading.textContent.trim(), index) + "-" + suffix; suffix += 1; }
      heading.id = id;
      usedIds.add(id);
      const item = document.createElement("li");
      const link = document.createElement("a");
      item.dataset.depth = heading.tagName === "H3" ? "3" : "2";
      link.href = "#" + id;
      link.textContent = heading.textContent.trim();
      item.append(link);
      tocList.append(item);
    }
    if (!headings.length) toc.hidden = true;
    if (headings.length && "IntersectionObserver" in window) {
      const links = [...tocList.querySelectorAll("a")];
      const byId = new Map(links.map((link) => [link.hash.slice(1), link]));
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          for (const link of links) link.classList.toggle("is-active", link === byId.get(entry.target.id));
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
      links[0].classList.add("is-active");
    } else if (headings.length) {
      tocList.querySelector("a").classList.add("is-active");
    }
  }
  const copyText = async (value) => {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(value); return true; } catch (_) { /* fallback */ }
    }
    const area = document.createElement("textarea");
    area.value = value; area.setAttribute("readonly", "");
    area.style.position = "fixed"; area.style.opacity = "0";
    document.body.append(area); area.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    area.remove();
    return copied;
  };
  for (const code of document.querySelectorAll("pre > code")) {
    const pre = code.parentElement;
    if (pre.querySelector("[data-cjdoc-copy]")) continue;
    const button = document.createElement("button");
    button.type = "button"; button.className = "code-copy";
    button.setAttribute("aria-label", "Copy code");
    button.title = "Copy code";
    button.textContent = "⧉";
    pre.append(button);
    button.addEventListener("click", async () => {
      const copied = await copyText(code.textContent || "");
      button.dataset.copied = copied ? "true" : "false";
      button.setAttribute("aria-label", copied ? "Copied" : "Copy code");
      button.title = copied ? "Copied" : "Copy code";
      if (copied) window.setTimeout(() => {
        button.dataset.copied = "false";
        button.setAttribute("aria-label", "Copy code");
        button.title = "Copy code";
      }, 1400);
    });
  }
})();
"""

private func appendSlugByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789abcdef"
    let high = Int64((byte >> 4) & 0x0F)
    let low = Int64(byte & 0x0F)
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

private func htmlStableSlug(value: String): String {
    if (value.isEmpty()) { return "root" }
    let out = StringBuilder()
    for (byte in value.toArray()) { appendSlugByte(out, byte) }
    out.toString()
}

private func stableFileHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

private func boundedHtmlSlug(value: String): String {
    let slug = htmlStableSlug(value)
    if (slug.size <= 160) { return slug }
    slug[..120] + "--" + stableFileHash(value)
}

private func routeKey(moduleId: String, packageName: String): String {
    "${moduleId.size}:${moduleId}${packageName}"
}

private func packagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.html"
}

private func symbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.html"
}

private func symbolAnchor(symbol: SymbolDoc): String {
    "symbol-${htmlStableSlug(symbol.id)}"
}

private func assetOutputPath(asset: AssetDoc): String {
    "assets/asset-${boundedHtmlSlug(asset.id)}.${assetMediaExtension(asset.mediaType)}"
}

private func isContainerDeclaration(symbol: SymbolDoc): Bool {
    isDocIrContainerKind(symbol.kind)
}

private func indexSymbols(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.declarations) { index[symbol.id] = symbol }
    index
}

private class ProjectedPackage {
    let source: PackageDoc
    let sourceFiles = ArrayList<String>()
    let symbols = ArrayList<SymbolDoc>()
    private let sourceFileSet = HashSet<String>()

    init(source: PackageDoc) { this.source = source }

    func addSymbol(symbol: SymbolDoc): Unit {
        symbols.add(symbol)
        if (sourceFileSet.add(symbol.source.path)) { sourceFiles.add(symbol.source.path) }
    }
}

private class ProjectedModule {
    let source: ModuleDoc
    let packages = ArrayList<ProjectedPackage>()

    init(source: ModuleDoc) { this.source = source }
}

private class RenderProjection {
    let allIndex: HashMap<String, SymbolDoc>
    let visibleIndex = HashMap<String, SymbolDoc>()
    let visibleSymbols = ArrayList<SymbolDoc>()
    let packages = ArrayList<ProjectedPackage>()
    let modules = ArrayList<ProjectedModule>()

    init(documentation: DocumentationSet) {
        allIndex = indexSymbols(documentation)
        let renderable = renderabilityIndex(documentation, allIndex)
        for (symbol in documentation.declarations) {
            if (renderable[symbol.id]) {
                visibleSymbols.add(symbol)
                visibleIndex[symbol.id] = symbol
            }
        }

        let packagesByRoute = HashMap<String, ProjectedPackage>()
        for (pkg in documentation.packages) {
            let projected = ProjectedPackage(pkg)
            packagesByRoute[routeKey(pkg.moduleId, pkg.name)] = projected
        }
        for (symbol in visibleSymbols) {
            match (packagesByRoute.get(routeKey(symbol.moduleId, symbol.packageName))) {
                case Some(projected) => projected.addSymbol(symbol)
                case None => () // Typed-domain validation reports the package mismatch first.
            }
        }
        for (pkg in documentation.packages) {
            let projected = packagesByRoute[routeKey(pkg.moduleId, pkg.name)]
            if (!projected.symbols.isEmpty() || !pkg.reExports.isEmpty()) {
                sort(projected.sourceFiles)
                packages.add(projected)
            }
        }

        let modulesById = HashMap<String, ProjectedModule>()
        for (module in documentation.modules) {
            let projected = ProjectedModule(module)
            modulesById[module.id] = projected
        }
        for (pkg in packages) {
            match (modulesById.get(pkg.source.moduleId)) {
                case Some(projected) => projected.packages.add(pkg)
                case None => () // Typed-domain validation reports the module mismatch first.
            }
        }
        for (module in documentation.modules) {
            let projected = modulesById[module.id]
            if (!projected.packages.isEmpty()) { modules.add(projected) }
        }
    }
}

private func groupTopLevelByPackage(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols where symbol.ownerId.isNone()) {
        let key = routeKey(symbol.moduleId, symbol.packageName)
        match (groups.get(key)) {
            case Some(values) => values.add(symbol)
            case None => groups[key] = ArrayList<SymbolDoc>([symbol])
        }
    }
    groups
}

private func groupMembersByOwner(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.ownerId) {
            case Some(ownerId) => match (groups.get(ownerId)) {
                case Some(values) => values.add(symbol)
                case None => groups[ownerId] = ArrayList<SymbolDoc>([symbol])
            }
            case None => ()
        }
    }
    groups
}

private func findSymbol(index: HashMap<String, SymbolDoc>, id: String): ?SymbolDoc {
    index.get(id)
}

private func renderabilityIndex(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashMap<String, Bool> {
    let results = HashMap<String, Bool>()
    for (root in documentation.declarations) {
        if (results.contains(root.id)) { continue }
        let path = ArrayList<SymbolDoc>()
        var current: ?SymbolDoc = Some(root)
        var inherited = true
        while (current.isSome()) {
            let symbol = current.getOrThrow()
            match (results.get(symbol.id)) {
                case Some(value) =>
                    inherited = value
                    break
                case None => ()
            }
            path.add(symbol)
            if (!isVisibleForAudience(symbol, documentation.configuration.audience)) {
                inherited = false
                break
            }
            current = match (symbol.ownerId) {
                case Some(ownerId) => index.get(ownerId)
                case None => None
            }
        }
        var position = path.size
        while (position > 0) {
            position--
            let symbol = path[position]
            inherited = inherited &&
                isVisibleForAudience(symbol, documentation.configuration.audience)
            results[symbol.id] = inherited
        }
    }
    results
}

private func containingPageSymbol(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): ?SymbolDoc {
    if (isContainerDeclaration(symbol)) { return Some(symbol) }
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => if (isContainerDeclaration(owner)) { Some(owner) } else { None }
            case None => None
        }
        case None => None
    }
}

private func symbolUrl(documentation: DocumentationSet, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc): String {
    match (containingPageSymbol(documentation, index, symbol)) {
        case Some(container) =>
            let page = symbolPagePath(container)
            if (container.id == symbol.id) { page } else { page + "#" + symbolAnchor(symbol) }
        case None => packagePagePath(symbol.moduleId, symbol.packageName) + "#" + symbolAnchor(symbol)
    }
}

private func buildAssetLookup(assets: ArrayList<AssetDoc>): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in assets) {
        let path = assetOutputPath(asset)
        lookup["id:${asset.id}"] = path
        lookup["path:${asset.sourcePath}"] = path
    }
    lookup
}

private func selectAsset(selected: HashSet<String>, assetId: String): Unit {
    let _ = selected.add(assetId)
}

private func collectReferencedAssets(node: MarkdownNode,
    references: HashMap<String, String>, selected: HashSet<String>): Unit {
    if (node.kind == "image") {
        var destination = node.literal
        if (destination.startsWith("./")) { destination = destination[2..] }
        match (references.get(destination)) {
            case Some(assetId) => selectAsset(selected, assetId)
            case None => ()
        }
    }
    for (child in node.children) {
        collectReferencedAssets(child, references, selected)
    }
}

private func projectAssets(documentation: DocumentationSet,
    projection: RenderProjection): ArrayList<AssetDoc> {
    let references = HashMap<String, String>()
    for (asset in documentation.assets) {
        references[asset.id] = asset.id
        references[asset.sourcePath] = asset.id
    }
    let selected = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.documentation) {
            case Some(comment) => collectReferencedAssets(comment.markdown, references, selected)
            case None => ()
        }
    }
    let assets = ArrayList<AssetDoc>()
    for (asset in documentation.assets) {
        if (selected.contains(asset.id)) { assets.add(asset) }
    }
    assets
}

private func appendAssetArtifacts(artifacts: RenderArtifactCollector,
    assets: ArrayList<AssetDoc>, formatRoot: String): Unit {
    for (asset in assets) {
        artifacts.addOwnedBytes("${formatRoot}/${assetOutputPath(asset)}",
            asset.mediaType, decodeAssetBase64(asset.base64))
    }
}

private func validateHtmlRouting(documentation: DocumentationSet,
    projection: RenderProjection, assets: ArrayList<AssetDoc>): Unit {
    let paths = HashSet<String>()
    for (path in ["index.html", "search-index.json", "search-index.js", "search.js", "style.css"]) {
        let _ = paths.add(path)
    }
    for (pkg in projection.packages) {
        let path = packagePagePath(pkg.source.moduleId, pkg.source.name)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for package '${pkg.source.name}'")
        }
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let path = symbolPagePath(symbol)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for SymbolId '${symbol.id}'")
        }
    }
    for (asset in assets) {
        let path = assetOutputPath(asset)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for asset '${asset.id}'")
        }
    }
    let urls = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        let url = symbolUrl(documentation, projection.visibleIndex, symbol)
        if (!urls.add(url)) {
            throw IllegalArgumentException("non-injective HTML URL for SymbolId '${symbol.id}'")
        }
    }
}

private func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

private func appendHtmlSidebar(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, rootPrefix: String, locale: String): Unit {
    out.append("<aside class=\"docs-sidebar\" aria-label=\"${label(locale, "Documentation navigation", "文档导航")}\">")
    out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Documentation", "文档")}</p>")
    out.append("<a class=\"sidebar-link\" data-cjdoc-nav-link href=\"${rootPrefix}index.html\">${label(locale, "Overview", "总览")}</a>")
    out.append("<a class=\"sidebar-link is-current\" data-cjdoc-nav-link href=\"${rootPrefix}index.html#packages\">${label(locale, "API Reference", "API 参考")}</a></div>")
    if (!projection.modules.isEmpty()) {
        out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Package reference", "包参考")}</p>")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<details class=\"sidebar-group\" open><summary><span>${escapeHtml(module.name)}</span><span class=\"sidebar-count\">${projected.packages.size}</span></summary><div class=\"sidebar-packages\">")
            for (pkg in projected.packages) {
                out.append("<a class=\"sidebar-package\" data-cjdoc-nav-link href=\"${rootPrefix}${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><span>${escapeHtml(pkg.source.name)}</span><span class=\"sidebar-package-count\">${pkg.symbols.size}</span></a>")
            }
            out.append("</div></details>")
        }
        out.append("</div>")
    }
    out.append("<p class=\"sidebar-note\">${label(locale, "Generated from", "生成自")}<code>${escapeHtml(documentation.schemaVersion)}</code></p></aside>")
}

private func appendPageStart(out: RenderTextBuffer, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en"): Unit {
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body>\n")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<a class=\"brand\" href=\"${rootPrefix}index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span>cjdoc<span class=\"brand-subtitle\">${label(locale, "API docs", "API 文档")}</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><svg width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"></circle><path d=\"m20 20-4-4\"></path></svg><label class=\"sr-only\">${label(locale, "Search API", "搜索 API")}</label>")
    out.append("<input type=\"search\" placeholder=\"${label(locale, "Search docs", "搜索文档")}\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"${rootPrefix}\"><kbd>Ctrl K</kbd></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul></div>")
    out.append("<div class=\"search-filters\"><label><span class=\"sr-only\">${label(locale, "Filter by kind", "按类别筛选")}</span><select data-cjdoc-kind aria-label=\"${label(locale, "Filter by kind", "按类别筛选")}\"><option value=\"\">${label(locale, "All kinds", "全部类别")}</option></select></label><label><span class=\"sr-only\">${label(locale, "Filter by package", "按包筛选")}</span><select data-cjdoc-package aria-label=\"${label(locale, "Filter by package", "按包筛选")}\"><option value=\"\">${label(locale, "All packages", "全部包")}</option></select></label></div></div>")
    out.append("<div class=\"top-actions\"><span class=\"version-label\" title=\"${label(locale, "Generated by cjdoc", "由 cjdoc 生成")}\">v${escapeHtml(documentation.generator.version)}</span><span class=\"top-source top-source-disabled\" aria-disabled=\"true\" title=\"${label(locale, "Repository URL is not included in this Doc IR", "此 Doc IR 未包含仓库地址")}\"><svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M12 .7a11.3 11.3 0 0 0-3.57 22.02c.57.1.78-.25.78-.55v-2.1c-3.18.69-3.85-1.34-3.85-1.34-.52-1.32-1.27-1.67-1.27-1.67-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.02 1.75 2.67 1.25 3.32.96.1-.74.4-1.25.72-1.54-2.54-.29-5.21-1.27-5.21-5.66 0-1.25.45-2.27 1.18-3.07-.12-.29-.51-1.45.11-3.03 0 0 .96-.31 3.12 1.17a10.85 10.85 0 0 1 5.68 0c2.16-1.48 3.12-1.17 3.12-1.17.62 1.58.23 2.74.11 3.03.73.8 1.18 1.82 1.18 3.07 0 4.4-2.68 5.36-5.23 5.64.41.36.77 1.07.77 2.16v3.2c0 .3.2.65.79.54A11.3 11.3 0 0 0 12 .7Z\"></path></svg><span>GitHub</span></span><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-label=\"Switch theme\" aria-pressed=\"false\"><svg class=\"icon-sun\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><circle cx=\"12\" cy=\"12\" r=\"4\"></circle><path d=\"M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42\"></path></svg><svg class=\"icon-moon\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><path d=\"M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5 8.5 8.5 0 1 0 20.5 14.7Z\"></path></svg></button></div>")
    out.append("</div></header>\n<div class=\"docs-layout\">")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale)
    out.append("<main class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\">\n")
}

private func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"${label(locale, "On this page", "本页目录")}\"><p class=\"toc-title\">${label(locale, "On this page", "本页目录")}</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><span><span class=\"footer-mark\">cjdoc</span> · ${label(locale, "Generated from Doc IR", "由 Doc IR 生成")}</span><span>${escapeHtml(documentation.generator.version)} · ${escapeHtml(documentation.schemaVersion)}</span></div></footer></body></html>\n")
}

private func findTag(comment: DocComment, name: String, subject!: ?String = None): ?DocTag {
    for (tag in comment.tags) {
        if (tag.name == name && (subject.isNone() || tag.subject == subject.getOrThrow())) { return Some(tag) }
    }
    None
}

private func tagHeading(name: String): String {
    match (name) {
        case "since" => "Since"
        case "author" => "Authors"
        case "version" => "Version"
        case _ => name
    }
}

private func isUnitType(value: TypeRef): Bool {
    match (value.semantic.canonical) {
        case Some(canonical) => canonical == "Unit" || canonical == "std.core.Unit"
        case None => value.spelling.trimAscii() == "Unit"
    }
}

private func appendDocumentationHtml(out: RenderTextBuffer, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, headingBase!: Int64 = 3,
    locale!: String = "en"): Unit {
    match (symbol.documentation) {
        case Some(comment) =>
            match (findTag(comment, "deprecated")) {
                case Some(tag) =>
                    out.append("<aside class=\"callout\"><strong>${label(locale, "Deprecated.", "已弃用。")}</strong> ")
                    appendStructuredTextHtml(out, tag.description)
                    out.append("</aside>\n")
                case None => ()
            }
            out.append("<h2>${label(locale, "Overview", "概览")}</h2><div class=\"description\">")
            appendMarkdownNodeHtml(out, comment.markdown, assetLookup, rootPrefix,
                markdownHtmlContext(comment, symbol, headingBase))
            out.append("</div>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt><code>${escapeHtml(parameter.name)}</code></dt><dd class=\"parameter-type\"><span class=\"parameter-colon\">:</span><code>${escapeHtml(parameter.typeRef.spelling)}</code></dd><dd class=\"parameter-description\">")
                    match (parameter.documentation) {
                        case Some(value) => appendStructuredTextHtml(out, value)
                        case None => match (findTag(comment, "param", subject: Some(parameter.name))) {
                            case Some(tag) => appendStructuredTextHtml(out, tag.description)
                            case None => ()
                        }
                    }
                    out.append("</dd></div>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => if (!isUnitType(returnType)) {
                    out.append("<h3>${label(locale, "Returns", "返回值")}</h3><p><code>${escapeHtml(returnType.spelling)}</code></p>\n")
                    match (findTag(comment, "return")) {
                        case Some(tag) => appendStructuredTextHtml(out, tag.description)
                        case None => ()
                    }
                }
                case None => ()
            }
            var hasThrows = false
            for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
            if (hasThrows) {
                out.append("<h3>${label(locale, "Throws", "异常")}</h3><dl>\n")
                for (tag in comment.tags) {
                    if (tag.name == "throws") {
                        out.append("<dt><code>${escapeHtml(tag.subject)}</code></dt><dd>")
                        appendStructuredTextHtml(out, tag.description)
                        out.append("</dd>\n")
                    }
                }
                out.append("</dl>\n")
            }
            var hasSee = false
            for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
            if (hasSee) {
                out.append("<h3>${label(locale, "See also", "另请参阅")}</h3><ul>\n")
                for (tag in comment.tags) {
                    if (tag.name != "see") { continue }
                    out.append("<li>")
                    match (tag.targetSymbolId) {
                        case Some(targetId) => match (findSymbol(index, targetId)) {
                            case Some(target) =>
                                out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, target))}\"><code>${escapeHtml(tag.subject)}</code></a>")
                            case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                        }
                        case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                    }
                    if (!tag.description.isEmpty()) {
                        out.append(" "); appendStructuredTextHtml(out, tag.description)
                    }
                    out.append("</li>\n")
                }
                out.append("</ul>\n")
            }
            for (name in ["since", "author", "version"]) {
                var opened = false
                for (tag in comment.tags) {
                    if (tag.name != name) { continue }
                    if (!opened) { out.append("<h3>${escapeHtml(label(locale, tagHeading(name), match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" }))}</h3><ul>\n"); opened = true }
                    out.append("<li>"); appendStructuredTextHtml(out, tag.description); out.append("</li>\n")
                }
                if (opened) { out.append("</ul>\n") }
            }
        case None =>
            out.append("<h2>${label(locale, "Overview", "概览")}</h2><p class=\"empty-state\">${label(locale, "No documentation is available for this declaration.", "此声明暂无文档。")}</p>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt><code>${escapeHtml(parameter.name)}</code></dt><dd class=\"parameter-type\"><span class=\"parameter-colon\">:</span><code>${escapeHtml(parameter.typeRef.spelling)}</code></dd><dd class=\"parameter-description\"></dd></div>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => if (!isUnitType(returnType)) {
                    out.append("<h3>${label(locale, "Returns", "返回值")}</h3><p><code>${escapeHtml(returnType.spelling)}</code></p>\n")
                }
                case None => ()
            }
    }
}

private func appendSymbolMetadata(out: RenderTextBuffer, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    locale!: String = "en"): Unit {
    out.append("<div class=\"symbol-meta\"><p class=\"meta\"><span class=\"badge\">${escapeHtml(symbol.kind)}</span>")
    out.append("<span class=\"badge\">${escapeHtml(symbol.visibility)}</span>")
    out.append("<span class=\"badge\" data-state=\"${escapeHtml(symbol.semantic.state)}\">semantic: ${escapeHtml(symbol.semantic.state)}</span>")
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => out.append(" Owner: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a> ·")
            case None => out.append(" Owner: <code>${escapeHtml(ownerId)}</code> ·")
        }
        case None => ()
    }
    out.append(" <code>${escapeHtml(symbol.source.path)}:${symbol.source.start.line}:${symbol.source.start.column}</code></p>\n")
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<p class=\"meta\">Generic parameters: ")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append("<code>${escapeHtml(parameter)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.annotations.isEmpty()) {
        out.append("<p class=\"meta\">Annotations: ")
        var first = true
        for (annotation in symbol.annotations) {
            if (!first) { out.append(" ") }; first = false
            out.append("<code>${escapeHtml(annotation.spelling)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.typeRelationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
        out.append("<dl class=\"relationships\">")
        for (relationship in symbol.typeRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd><code>${escapeHtml(relationship.target.spelling)}</code> <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span></dd>")
        }
        for (relationship in symbol.symbolRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (findSymbol(index, targetId)) {
                    case Some(target) =>
                        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.state)}\">${escapeHtml(relationship.state)}</span></dd>")
        }
        out.append("</dl>\n")
    }
    out.append("</div><h2 class=\"signature-heading\">${label(locale, "Signature", "签名")}</h2><pre class=\"signature-block\"><code>${escapeHtml(symbol.headerSpelling)}</code></pre>\n")
}

private func appendSymbolArticle(out: RenderTextBuffer, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, linkTitle!: Bool = false,
    locale!: String = "en"): Unit {
    out.append("<article class=\"symbol-entry\" id=\"${symbolAnchor(symbol)}\"><h2>")
    if (linkTitle) {
        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a>")
    } else { out.append("<code>${escapeHtml(symbol.qualifiedName)}</code>") }
    out.append("</h2>\n")
    appendSymbolMetadata(out, documentation, index, symbol, rootPrefix, locale: locale)
    appendDocumentationHtml(out, documentation, index, symbol, rootPrefix, assetLookup,
        locale: locale)
    out.append("</article>\n")
}

private func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en"): String {
    let out = RenderTextBuffer()
    appendPageStart(out, "${documentation.project.name} ${label(locale, "API documentation", "API 文档")}", "",
        documentation, projection, locale: locale)
    out.append("<header class=\"page-header\"><h1>${escapeHtml(documentation.project.name)} ${label(locale, "API documentation", "API 文档")}</h1>")
    if (locale == "zh-CN") {
        out.append("<p class=\"page-lead\">${projection.modules.size} 个模块，${projection.packages.size} 个包，${projection.visibleSymbols.size} 个可见声明</p>\n")
    } else {
        out.append("<p class=\"page-lead\">${projection.modules.size} modules, ${projection.packages.size} packages, ${projection.visibleSymbols.size} visible declarations</p>\n")
    }
    out.append("</header>\n")
    if (!projection.modules.isEmpty()) {
        out.append("<h2 id=\"modules\">${label(locale, "Modules", "模块")}</h2><div class=\"module-list\">\n")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<section class=\"module-record\"><h3><code>${escapeHtml(module.name)}</code> <span class=\"badge\">${escapeHtml(module.role)}</span></h3>")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">Source prefix: <code>${escapeHtml(prefix)}</code></p><ul class=\"package-links\">\n")
            for (pkg in projected.packages) {
                out.append("<li><a href=\"${escapeHtml(packagePagePath(module.id, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
            }
            out.append("</ul></section>\n")
        }
        out.append("</div>\n")
    }
    out.append("<h2 id=\"packages\">${label(locale, "Packages", "包")}</h2><ul class=\"package-index\">\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
    }
    out.append("</ul>\n")
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<h2 id=\"diagnostics\">${label(locale, "Diagnostics", "诊断")}</h2><ul class=\"diagnostics-list\">\n")
        for (diagnostic in documentation.diagnostics) {
            if (let Some(symbolId) <- diagnostic.symbolId) {
                if (!projection.visibleIndex.contains(symbolId)) { continue }
            }
            out.append("<li><strong>${escapeHtml(diagnostic.severity)}[${escapeHtml(diagnostic.code)}]</strong>: ${escapeHtml(diagnostic.message)}")
            match (diagnostic.source) {
                case Some(source) => out.append(" <code>${escapeHtml(source.path)}:${source.start.line}:${source.start.column}</code>")
                case None => ()
            }
            out.append("</li>\n")
        }
        out.append("</ul>\n")
    }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

private func renderPackagePage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, topLevelByPackage: HashMap<String, ArrayList<SymbolDoc>>,
    pkg: ProjectedPackage, assetLookup: HashMap<String, String>, locale!: String = "en"): String {
    let packageDoc = pkg.source
    let out = RenderTextBuffer()
    appendPageStart(out, "${label(locale, "Package", "包")} ${packageDoc.name}", "../",
        documentation, projection, locale: locale)
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li><li aria-current=\"page\">${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1>${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></h1></header>\n")
    if (!pkg.sourceFiles.isEmpty()) {
        out.append("<h2 id=\"sources\">${label(locale, "Sources", "源文件")}</h2><ul class=\"record-list\">\n")
        for (path in pkg.sourceFiles) { out.append("<li><code>${escapeHtml(path)}</code></li>\n") }
        out.append("</ul>\n")
    }
    if (!packageDoc.reExports.isEmpty()) {
        out.append("<h2 id=\"re-exports\">${label(locale, "Re-exports", "公开重导出")}</h2><ul class=\"record-list\">\n")
        for (reExport in packageDoc.reExports) {
            if (reExport.kind == "packageAlias") {
                out.append("<li><code>${escapeHtml(reExport.alias.getOrThrow())}</code>")
                if (reExport.state == "resolved") { out.append(" → package") }
                out.append(" <code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            if (reExport.bindings.isEmpty()) {
                out.append("<li><code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            for (binding in reExport.bindings) {
                out.append("<li><code>${escapeHtml(binding.exposedName)}</code> → ")
                var firstTarget = true
                for (targetId in binding.targetSymbolIds) {
                    if (!firstTarget) { out.append(", ") }; firstTarget = false
                    match (findSymbol(index, targetId)) {
                        case Some(target) => out.append("<a href=\"../${escapeHtml(symbolUrl(documentation, index, target))}\"><code>${escapeHtml(target.qualifiedName)}</code></a>")
                        case None => out.append("<code>${escapeHtml(targetId)}</code>")
                    }
                }
                out.append(" <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
            }
        }
        out.append("</ul>\n")
    }
    out.append("<h2 id=\"declarations\">${label(locale, "Declarations", "声明")}</h2>\n")
    var wroteDeclaration = false
    match (topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) => for (symbol in symbols) {
            wroteDeclaration = true
            if (isContainerDeclaration(symbol)) {
                out.append("<section class=\"declaration-summary\"><h3><a href=\"../${escapeHtml(symbolPagePath(symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a> <span class=\"badge\">${escapeHtml(symbol.kind)}</span></h3>")
                match (symbol.documentation) {
                    case Some(comment) => out.append("<p>${escapeHtml(markdownNodeText(comment.markdown))}</p>")
                    case None => ()
                }
                out.append("</section>\n")
            } else {
                appendSymbolArticle(out, documentation, index, symbol, "../", assetLookup,
                    locale: locale)
            }
        }
        case None => ()
    }
    if (!wroteDeclaration) { out.append("<p class=\"empty-state\">${label(locale, "No declarations are visible for this audience.", "此受众范围内没有直接声明。")}</p>\n") }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

private func memberSectionTitle(symbol: SymbolDoc): String {
    match (symbol.kind) {
        case "constructor" => "Constructors"
        case "property" => "Properties"
        case "variable" => "Variables"
        case "function" => "Functions"
        case "enumCase" => "Enum cases"
        case "class" => "Nested classes"
        case "struct" => "Nested structs"
        case "interface" => "Nested interfaces"
        case "enum" => "Nested enums"
        case "extend" => "Nested extensions"
        case _ => "Other members"
    }
}

private func appendMemberSection(out: RenderTextBuffer, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    owner: SymbolDoc, title: String, assetLookup: HashMap<String, String>, locale: String): Unit {
    var opened = false
    match (membersByOwner.get(owner.id)) {
        case Some(members) => for (member in members) {
            if (memberSectionTitle(member) != title) { continue }
            if (!opened) { out.append("<h2>${escapeHtml(label(locale, title, match (title) { case "Constructors" => "构造器"; case "Properties" => "属性"; case "Variables" => "变量"; case "Functions" => "函数"; case "Enum cases" => "枚举项"; case "Nested classes" => "嵌套类"; case "Nested structs" => "嵌套结构体"; case "Nested interfaces" => "嵌套接口"; case "Nested enums" => "嵌套枚举"; case "Nested extensions" => "嵌套扩展"; case _ => "其他成员" }))}</h2>\n"); opened = true }
            appendSymbolArticle(out, documentation, index, member, "../", assetLookup,
                linkTitle: isContainerDeclaration(member), locale: locale)
        }
        case None => ()
    }
}

private func renderSymbolPage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, locale!: String = "en"): String {
    let out = RenderTextBuffer()
    appendPageStart(out, symbol.qualifiedName, "../", documentation, projection, locale: locale)
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li>")
    out.append("<li><a href=\"../${escapeHtml(packagePagePath(symbol.moduleId, symbol.packageName))}\">${label(locale, "Package", "包")} <code>${escapeHtml(symbol.packageName)}</code></a></li>")
    out.append("<li aria-current=\"page\"><code>${escapeHtml(symbol.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1><code>${escapeHtml(symbol.qualifiedName)}</code></h1>")
    appendSymbolMetadata(out, documentation, index, symbol, "../", locale: locale)
    out.append("</header>\n")
    appendDocumentationHtml(out, documentation, index, symbol, "../", assetLookup,
        headingBase: 2, locale: locale)
    for (title in ["Constructors", "Properties", "Variables", "Functions", "Enum cases",
        "Nested classes", "Nested structs", "Nested interfaces", "Nested enums", "Nested extensions",
        "Other members"]) {
        appendMemberSection(out, documentation, index, membersByOwner, symbol, title, assetLookup,
            locale)
    }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

private func appendSearchJsonString(out: RenderTextBuffer, value: String): Unit {
    let digits = "0123456789abcdef"
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case '"' => out.append("\\\"")
            case '\\' => out.append("\\\\")
            case '\u{0008}' => out.append("\\b")
            case '\u{000c}' => out.append("\\f")
            case '\n' => out.append("\\n")
            case '\r' => out.append("\\r")
            case '\t' => out.append("\\t")
            case _ =>
                let code = UInt32(rune)
                if (code < 0x20u32) {
                    out.append("\\u")
                    out.append(digits[Int64((code >> 12) & 0xFu32)..
                        Int64((code >> 12) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 8) & 0xFu32)..
                        Int64((code >> 8) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 4) & 0xFu32)..
                        Int64((code >> 4) & 0xFu32) + 1])
                    out.append(digits[Int64(code & 0xFu32)..Int64(code & 0xFu32) + 1])
                } else { out.append(rune) }
        }
    }
    out.append("\"")
}

private func renderSearchIndex(documentation: DocumentationSet,
    projection: RenderProjection): String {
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.search-index/4\",\n  \"entries\": [")
    var first = true
    let visible = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(visible, lessThan: { left, right => left.id < right.id }, stable: true)
    for (declaration in visible) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"canonicalId\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"exposure\": false")
        out.append(", \"name\": "); appendSearchJsonString(out, declaration.name)
        out.append(", \"qualifiedName\": "); appendSearchJsonString(out, declaration.qualifiedName)
        out.append(", \"kind\": "); appendSearchJsonString(out, declaration.kind)
        out.append(", \"packageName\": "); appendSearchJsonString(out, declaration.packageName)
        let summary = match (declaration.documentation) {
            case Some(comment) => markdownNodeText(comment.markdown)
            case None => ""
        }
        out.append(", \"summary\": "); appendSearchJsonString(out, summary)
        out.append(", \"href\": ")
        appendSearchJsonString(out,
            symbolUrl(documentation, projection.visibleIndex, declaration))
        out.append("}")
    }
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                for (targetId in binding.targetSymbolIds) {
                    match (projection.visibleIndex.get(targetId)) {
                        case Some(target) =>
                            if (!first) { out.append(",") }; first = false
                            out.append("\n    {\"id\": ")
                            appendSearchJsonString(out,
                                "${reExport.id}:${binding.exposedName}:${target.id}")
                            out.append(", \"canonicalId\": "); appendSearchJsonString(out, target.id)
                            out.append(", \"exposure\": true, \"name\": ")
                            appendSearchJsonString(out, binding.exposedName)
                            out.append(", \"qualifiedName\": ")
                            appendSearchJsonString(out, "${pkg.name}.${binding.exposedName}")
                            out.append(", \"kind\": "); appendSearchJsonString(out, target.kind)
                            out.append(", \"packageName\": "); appendSearchJsonString(out, pkg.name)
                            let summary = match (target.documentation) {
                                case Some(comment) => markdownNodeText(comment.markdown)
                                case None => ""
                            }
                            out.append(", \"summary\": "); appendSearchJsonString(out, summary)
                            out.append(", \"href\": ")
                            appendSearchJsonString(out,
                                symbolUrl(documentation, projection.visibleIndex, target))
                            out.append("}")
                        case None => ()
                    }
                }
            }
        }
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func renderSearchIndexScript(searchIndex: String): String {
    let out = RenderTextBuffer()
    out.append("globalThis.__CJDOC_SEARCH_INDEX__ = ")
    out.append(searchIndex.trimAscii())
    out.append(";\n")
    out.toString()
}

public class HtmlDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "html" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendHtmlArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

private func appendHtmlArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, locale!: String = "en"): Unit {
        validateTypedDocumentationSet(documentation)
        let projection = RenderProjection(documentation)
        let index = projection.visibleIndex
        let projectedAssets = projectAssets(documentation, projection)
        let assetLookup = buildAssetLookup(projectedAssets)
        validateHtmlRouting(documentation, projection, projectedAssets)
        let topLevelByPackage = groupTopLevelByPackage(projection)
        let membersByOwner = groupMembersByOwner(projection)
        let searchIndex = renderSearchIndex(documentation, projection)
        artifacts.addText("html/index.html", "text/html; charset=utf-8",
            renderHtmlIndex(documentation, projection, locale: locale))
        artifacts.addText("html/search-index.json", "application/json", searchIndex)
        artifacts.addText("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex))
        artifacts.addText("html/search.js", "text/javascript; charset=utf-8", HTML_SEARCH_SCRIPT)
        artifacts.addText("html/style.css", "text/css; charset=utf-8", HTML_STYLE)
        for (pkg in projection.packages) {
            artifacts.addText("html/${packagePagePath(pkg.source.moduleId, pkg.source.name)}",
                "text/html; charset=utf-8",
                renderPackagePage(documentation, projection, index, topLevelByPackage, pkg, assetLookup,
                    locale: locale))
        }
        for (symbol in projection.visibleSymbols) {
            if (isContainerDeclaration(symbol)) {
                artifacts.addText("html/${symbolPagePath(symbol)}", "text/html; charset=utf-8",
                    renderSymbolPage(documentation, projection, index, membersByOwner, symbol, assetLookup,
                        locale: locale))
            }
        }
        appendAssetArtifacts(artifacts, projectedAssets, "html")
}

private func appendJsonStringArray(out: RenderTextBuffer, values: ReadOnlyList<String>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }
        first = false
        appendSearchJsonString(out, value)
    }
    out.append("]")
}

private func appendApiSurfaceArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.api-surface/1\",\n  \"project\": ")
    appendSearchJsonString(out, documentation.project.name)
    out.append(",\n  \"audience\": ")
    appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"declarations\": [")
    var first = true
    for (symbol in projection.visibleSymbols) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, symbol.id)
        out.append(", \"moduleId\": "); appendSearchJsonString(out, symbol.moduleId)
        out.append(", \"packageName\": "); appendSearchJsonString(out, symbol.packageName)
        out.append(", \"ownerId\": ")
        match (symbol.ownerId) {
            case Some(ownerId) => appendSearchJsonString(out, ownerId)
            case None => out.append("null")
        }
        out.append(", \"kind\": "); appendSearchJsonString(out, symbol.kind)
        out.append(", \"name\": "); appendSearchJsonString(out, symbol.name)
        out.append(", \"visibility\": "); appendSearchJsonString(out, symbol.visibility)
        out.append(", \"sourceApiSignature\": {\"state\": ")
        appendSearchJsonString(out, symbol.sourceApiSignature.state)
        out.append(", \"tokens\": ")
        appendJsonStringArray(out, symbol.sourceApiSignature.tokens)
        out.append("}}")
    }
    if (!first) { out.append("\n  ") }
    out.append("],\n  \"exposures\": [")
    first = true
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                if (!first) { out.append(",") }
                first = false
                out.append("\n    {\"reExportId\": "); appendSearchJsonString(out, reExport.id)
                out.append(", \"moduleId\": "); appendSearchJsonString(out, pkg.moduleId)
                out.append(", \"packageName\": "); appendSearchJsonString(out, pkg.name)
                out.append(", \"exposedName\": "); appendSearchJsonString(out, binding.exposedName)
                out.append(", \"targetSymbolIds\": ")
                appendJsonStringArray(out, binding.targetSymbolIds)
                out.append("}")
            }
        }
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    artifacts.addText("api-surface/api-surface.json", "application/json", out.toString())
}

private func coveragePercent(documented: Int64, total: Int64): Int64 {
    if (total == 0) { 100 } else { documented * 100 / total }
}

public func documentationCoverageCounts(documentation: DocumentationSet):
    (Int64, Int64, Int64, Int64) {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    var symbols: Int64 = 0
    var documentedSymbols: Int64 = 0
    var parameters: Int64 = 0
    var documentedParameters: Int64 = 0
    for (symbol in projection.visibleSymbols) {
        symbols++
        if (symbol.documentation.isSome()) { documentedSymbols++ }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
            parameters++
            if (parameter.documentation.isSome()) { documentedParameters++ }
        }
    }
    (symbols, documentedSymbols, parameters, documentedParameters)
}

private func appendCoverageArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    let (symbols, documentedSymbols, parameters, documentedParameters) =
        documentationCoverageCounts(documentation)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.documentation-coverage/1\",\n")
    out.append("  \"audience\": "); appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"symbols\": {\"total\": ${symbols}, \"documented\": ${documentedSymbols}, \"percent\": ${coveragePercent(documentedSymbols, symbols)}},\n")
    out.append("  \"parameters\": {\"total\": ${parameters}, \"documented\": ${documentedParameters}, \"percent\": ${coveragePercent(documentedParameters, parameters)}}\n}\n")
    artifacts.addText("coverage/coverage.json", "application/json", out.toString())
}

public class ApiSurfaceDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "api-surface" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendApiSurfaceArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

public class DocumentationCoverageRenderer <: DocumentationRenderer {
    public prop format: String { get() { "coverage" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendCoverageArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

private func markdownPackagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.md"
}

private func markdownSymbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.md"
}

private func appendMarkdownSiteSymbol(out: RenderTextBuffer, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, heading: String, locale: String): Unit {
    out.append("${heading} "); appendMarkdownCodeSpan(out, symbol.qualifiedName); out.append("\n\n")
    appendMarkdownCodeBlock(out, symbol.headerSpelling, "cj", "`", 3)
    match (symbol.documentation) {
        case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup, locale: locale)
        case None => ()
    }
    out.append("- "); appendEscapedMarkdownText(out, "${symbol.kind} · ${symbol.visibility}")
    out.append("\n- "); appendMarkdownCodeSpan(out,
        "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
    out.append("\n\n")
}

private func nestedAssetLookup(assets: ArrayList<AssetDoc>): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in assets) {
        let path = "../${assetOutputPath(asset)}"
        lookup["id:${asset.id}"] = path
        lookup["path:${asset.sourcePath}"] = path
    }
    lookup
}

private func appendMarkdownSiteArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, locale: String): Unit {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let projectedAssets = projectAssets(documentation, projection)
    let assetLookup = nestedAssetLookup(projectedAssets)
    let topLevelByPackage = groupTopLevelByPackage(projection)
    let membersByOwner = groupMembersByOwner(projection)
    let index = RenderTextBuffer()
    index.append("# "); appendEscapedMarkdownText(index, documentation.project.name)
    index.append(" "); appendEscapedMarkdownText(index, label(locale, "API documentation", "API 文档"))
    index.append("\n\n## ${label(locale, "Packages", "包")}\n\n")
    for (pkg in projection.packages) {
        index.append("- ["); appendEscapedMarkdownText(index, pkg.source.name)
        index.append("](${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)})\n")
    }
    artifacts.addText("markdown/index.md", "text/markdown; charset=utf-8", index.toString())
    for (pkg in projection.packages) {
        let out = RenderTextBuffer()
        out.append("# ${label(locale, "Package", "包")} "); appendMarkdownCodeSpan(out, pkg.source.name)
        out.append("\n\n[${label(locale, "Home", "首页")}](../index.md)\n\n")
        if (!pkg.source.reExports.isEmpty()) {
            out.append("## ${label(locale, "Re-exports", "公开重导出")}\n\n")
            for (reExport in pkg.source.reExports) {
                if (reExport.kind == "packageAlias") {
                    out.append("- "); appendMarkdownCodeSpan(out, reExport.alias.getOrThrow())
                    if (reExport.state == "resolved") {
                        out.append(" → ${label(locale, "package", "包")} ")
                    } else { out.append(" · ") }
                    appendMarkdownCodeSpan(out, reExport.targetPackageName)
                    out.append(" · "); appendEscapedMarkdownText(out,
                        "${reExport.kind} · ${reExport.state}")
                    out.append("\n")
                    continue
                }
                if (reExport.bindings.isEmpty()) {
                    out.append("- "); appendMarkdownCodeSpan(out, reExport.targetPackageName)
                    out.append(" · "); appendEscapedMarkdownText(out,
                        "${reExport.kind} · ${reExport.state}")
                    out.append("\n")
                    continue
                }
                for (binding in reExport.bindings) {
                    out.append("- "); appendMarkdownCodeSpan(out, binding.exposedName)
                    out.append(" → ")
                    var firstTarget = true
                    for (targetId in binding.targetSymbolIds) {
                        if (!firstTarget) { out.append(", ") }; firstTarget = false
                        match (projection.visibleIndex.get(targetId)) {
                            case Some(target) =>
                                out.append("["); appendMarkdownCodeSpan(out, target.qualifiedName)
                                let targetPath = if (isContainerDeclaration(target)) {
                                    "../${markdownSymbolPagePath(target)}"
                                } else {
                                    "../${markdownPackagePagePath(target.moduleId, target.packageName)}"
                                }
                                out.append("](${targetPath})")
                            case None => appendMarkdownCodeSpan(out, targetId)
                        }
                    }
                    out.append(" · "); appendEscapedMarkdownText(out, reExport.state)
                    out.append("\n")
                }
            }
            out.append("\n")
        }
        out.append("## ${label(locale, "Declarations", "声明")}\n\n")
        match (topLevelByPackage.get(routeKey(pkg.source.moduleId, pkg.source.name))) {
            case Some(symbols) => for (symbol in symbols) {
                if (isContainerDeclaration(symbol)) {
                    out.append("- ["); appendMarkdownCodeSpan(out, symbol.qualifiedName)
                    out.append("](../${markdownSymbolPagePath(symbol)})\n")
                } else {
                    appendMarkdownSiteSymbol(out, symbol, assetLookup, "###", locale)
                }
            }
            case None => out.append("${label(locale, "No direct declarations.", "没有直接声明。")}\n")
        }
        artifacts.addText("markdown/${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)}",
            "text/markdown; charset=utf-8", out.toString())
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let out = RenderTextBuffer()
        out.append("# "); appendMarkdownCodeSpan(out, symbol.qualifiedName)
        out.append("\n\n[${label(locale, "Package", "包")} ")
        appendMarkdownCodeSpan(out, symbol.packageName)
        out.append("](../${markdownPackagePagePath(symbol.moduleId, symbol.packageName)})\n\n")
        appendMarkdownCodeBlock(out, symbol.headerSpelling, "cj", "`", 3)
        match (symbol.documentation) {
            case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup, locale: locale)
            case None => ()
        }
        match (membersByOwner.get(symbol.id)) {
            case Some(members) => if (!members.isEmpty()) {
                out.append("## ${label(locale, "Members", "成员")}\n\n")
                for (member in members) {
                    appendMarkdownSiteSymbol(out, member, assetLookup, "###", locale)
                }
            }
            case None => ()
        }
        artifacts.addText("markdown/${markdownSymbolPagePath(symbol)}",
            "text/markdown; charset=utf-8", out.toString())
    }
    appendAssetArtifacts(artifacts, projectedAssets, "markdown")
}

public func renderDocumentationFormatsWithOptions(documentation: DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", markdownLayout!: String = "site"):
    Array<RenderArtifact> {
    if (locale != "zh-CN" && locale != "en") {
        throw IllegalArgumentException("locale must be zh-CN or en")
    }
    if (markdownLayout != "site" && markdownLayout != "single") {
        throw IllegalArgumentException("Markdown layout must be site or single")
    }
    let artifacts = RenderArtifactCollector()
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => if (markdownLayout == "single") {
                appendMarkdownArtifacts(artifacts, documentation)
            } else {
                appendMarkdownSiteArtifacts(artifacts, documentation, locale)
            }
            case "html" => appendHtmlArtifacts(artifacts, documentation, locale: locale)
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" => appendCoverageArtifacts(artifacts, documentation)
            case _ => throw IllegalArgumentException(
                "unsupported documentation format '${format}'")
        }
    }
    artifacts.toArray()
}

public func renderDocumentationFormats(documentation: DocumentationSet,
    formats: Array<String>): Array<RenderArtifact> {
    let artifacts = RenderArtifactCollector()
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => appendMarkdownArtifacts(artifacts, documentation)
            case "html" => appendHtmlArtifacts(artifacts, documentation)
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" => appendCoverageArtifacts(artifacts, documentation)
            case _ => throw IllegalArgumentException(
                "unsupported documentation format '${format}'")
        }
    }
    artifacts.toArray()
}

public func rendererFor(format: String): DocumentationRenderer {
    match (format) {
        case "json" => JsonDocumentationRenderer()
        case "markdown" => MarkdownDocumentationRenderer()
        case "html" => HtmlDocumentationRenderer()
        case "api-surface" => ApiSurfaceDocumentationRenderer()
        case "coverage" => DocumentationCoverageRenderer()
        case _ => throw IllegalArgumentException("unsupported documentation format '${format}'")
    }
}
