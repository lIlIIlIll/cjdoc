package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*

internal let DOCUMENTATION_METADATA_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let DOCUMENTATION_METADATA_CONFIG_MAX_DEFINITIONS: Int64 = 2048

/** A raw group record parsed before module/package/owner binding. */
internal class MetadataGroupConfig {
    let packageName: String
    let owner: ?String
    let ownerId: ?String
    let id: String
    let title: String
    let titles: Array<public_model.DocumentationTitle>
    let order: ?Int64
    let line: Int64

    init(packageName: String, owner: ?String, ownerId: ?String, id: String,
        title: String, titles: Array<public_model.DocumentationTitle>, order: ?Int64,
        line: Int64) {
        this.packageName = packageName
        this.owner = owner
        this.ownerId = ownerId
        this.id = id
        this.title = title
        this.titles = titles
        this.order = order
        this.line = line
    }
}

/** A raw tag record parsed before module binding. */
internal class MetadataTagConfig {
    let id: String
    let title: String
    let titles: Array<public_model.DocumentationTitle>
    let line: Int64

    init(id: String, title: String, titles: Array<public_model.DocumentationTitle>, line: Int64) {
        this.id = id
        this.title = title
        this.titles = titles
        this.line = line
    }
}

/** Metadata declarations captured from one root's cjdoc.toml. */
internal class DocumentationMetadataConfig {
    let groups: Array<MetadataGroupConfig>
    let tags: Array<MetadataTagConfig>

    init(groups: Array<MetadataGroupConfig>, tags: Array<MetadataTagConfig>) {
        this.groups = groups
        this.tags = tags
    }
}

private func metadataConfigFailure(line: Int64, detail: String): IllegalArgumentException {
    IllegalArgumentException("CJDOC3133 at cjdoc.toml:${line}: ${detail}")
}

private func metadataConfigReadFailure(): IllegalArgumentException {
    metadataConfigFailure(1, "configuration must be valid UTF-8 and no larger than 65536 bytes")
}

private func metadataHasTriple(value: String, offset: Int64, marker: Byte): Bool {
    offset + 2 < value.size && value[offset] == marker && value[offset + 1] == marker &&
        value[offset + 2] == marker
}

private func metadataEscapedAt(value: String, offset: Int64): Bool {
    var cursor = offset
    var slashes: Int64 = 0
    while (cursor > 0 && value[cursor - 1] == b'\\') {
        slashes++
        cursor--
    }
    slashes % 2 == 1
}

private func metadataFirstUnescapedTriple(value: String, start: Int64, marker: Byte): ?Int64 {
    var index = start
    while (index < value.size) {
        if (metadataHasTriple(value, index, marker) &&
            (marker == b'\'' || !metadataEscapedAt(value, index))) {
            return Some(index)
        }
        index++
    }
    None
}

/* Track multiline values and containers separately from the comment scanner so
 * table-looking lines inside strings, arrays, or inline tables are never syntax. */
private class MetadataMultilineState {
    private var delimiter: ?Byte = None
    private var arrayDepth: Int64 = 0
    private var inlineDepth: Int64 = 0

    func isInside(): Bool { delimiter.isSome() || arrayDepth > 0 || inlineDepth > 0 }

    func advance(line: String): Unit {
        var activeDelimiter = delimiter
        var basic: Bool = false
        var literal: Bool = false
        var escaped: Bool = false
        var index: Int64 = 0
        while (index < line.size) {
            match (activeDelimiter) {
                case Some(marker) =>
                    let closing = metadataFirstUnescapedTriple(line, index, marker)
                    match (closing) {
                        case Some(offset) =>
                            activeDelimiter = None
                            index = offset + 3
                        case None => index = line.size
                    }
                case None =>
                    let byte = line[index]
                    if (basic) {
                        if (escaped) {
                            escaped = false
                        } else if (byte == b'\\') {
                            escaped = true
                        } else if (byte == b'\"') {
                            basic = false
                        }
                        index++
                    } else if (literal) {
                        if (byte == b'\'') { literal = false }
                        index++
                    } else if (byte == b'#') {
                        index = line.size
                    } else if ((byte == b'\"' || byte == b'\'') &&
                        metadataHasTriple(line, index, byte)) {
                        let closing = metadataFirstUnescapedTriple(line, index + 3, byte)
                        match (closing) {
                            case Some(offset) => index = offset + 3
                            case None =>
                                activeDelimiter = Some(byte)
                                index = line.size
                        }
                    } else if (byte == b'\"') {
                        basic = true
                        escaped = false
                        index++
                    } else if (byte == b'\'') {
                        literal = true
                        index++
                    } else if (byte == b'[') {
                        arrayDepth++
                        index++
                    } else if (byte == b']') {
                        if (arrayDepth > 0) { arrayDepth-- }
                        index++
                    } else if (byte == b'{') {
                        inlineDepth++
                        index++
                    } else if (byte == b'}') {
                        if (inlineDepth > 0) { inlineDepth-- }
                        index++
                    } else {
                        index++
                    }
            }
        }
        delimiter = activeDelimiter
    }
}


private func metadataStripComment(value: String): String {
    var basic: Bool = false
    var literal: Bool = false
    var escaped: Bool = false
    var multilineBasic: Bool = false
    var multilineLiteral: Bool = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (multilineBasic) {
            if (byte == b'\\' && !escaped) {
                escaped = true
                index++
                continue
            }
            if (metadataHasTriple(value, index, b'"') && !metadataEscapedAt(value, index)) {
                multilineBasic = false
                index += 3
                continue
            }
            escaped = false
        } else if (multilineLiteral) {
            if (metadataHasTriple(value, index, b'\'')) {
                multilineLiteral = false
                index += 3
                continue
            }
        } else if (basic) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == b'"') {
                basic = false
            }
        } else if (literal) {
            if (byte == b'\'') { literal = false }
        } else if (byte == b'#') {
            return value[..index].trimAscii()
        } else if (byte == b'"' && metadataHasTriple(value, index, b'"')) {
            multilineBasic = true
            index += 3
            continue
        } else if (byte == b'\'' && metadataHasTriple(value, index, b'\'')) {
            multilineLiteral = true
            index += 3
            continue
        } else if (byte == b'"') {
            basic = true
            escaped = false
        } else if (byte == b'\'') {
            literal = true
        }
        index++
    }
    value.trimAscii()
}

private func metadataEqualsAt(value: String): ?Int64 {
    var basic: Bool = false
    var literal: Bool = false
    var escaped: Bool = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (basic) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == b'"') {
                basic = false
            }
        } else if (literal) {
            if (byte == b'\'') { literal = false }
        } else if (byte == b'"') {
            basic = true
        } else if (byte == b'\'') {
            literal = true
        } else if (byte == b'=') {
            return Some(index)
        }
        index++
    }
    None
}

private func metadataDecodeKeyToken(value: String, offset: Int64, line: Int64): (String, Int64) {
    if (offset >= value.size) { throw metadataConfigFailure(line, "expected a TOML key") }
    if (value[offset] == b'"' || value[offset] == b'\'') {
        if (metadataHasTriple(value, offset, value[offset])) {
            throw metadataConfigFailure(line, "multiline metadata keys are not supported")
        }
        let decoded = decodeTomlString(value, offset)
        if (decoded.invalid || decoded.value.isNone()) {
            throw metadataConfigFailure(line, "invalid quoted TOML key")
        }
        return (decoded.value.getOrThrow(), decoded.nextOffset)
    }
    let start = offset
    var cursor = offset
    while (cursor < value.size) {
        let byte = value[cursor]
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-') {
            cursor++
        } else {
            break
        }
    }
    if (cursor == start) { throw metadataConfigFailure(line, "invalid TOML key") }
    (value[start..cursor], cursor)
}

private func metadataKeyPath(value: String, line: Int64, allowDotted: Bool): Array<String> {
    let result = ArrayList<String>()
    var cursor: Int64 = 0
    while (cursor < value.size) {
        while (cursor < value.size && (value[cursor] == b' ' || value[cursor] == b'\t')) { cursor++ }
        if (cursor >= value.size) { break }
        let (key, next) = metadataDecodeKeyToken(value, cursor, line)
        result.add(key)
        cursor = next
        while (cursor < value.size && (value[cursor] == b' ' || value[cursor] == b'\t')) { cursor++ }
        if (cursor == value.size) { break }
        if (value[cursor] != b'.' || !allowDotted) {
            throw metadataConfigFailure(line, "dotted or malformed metadata keys are not supported")
        }
        cursor++
        if (cursor == value.size) { throw metadataConfigFailure(line, "empty dotted metadata key") }
    }
    if (result.isEmpty()) { throw metadataConfigFailure(line, "empty TOML key") }
    result.toArray()
}

private func metadataScalarString(value: String, line: Int64, key: String): String {
    let scalar = value.trimAscii()
    if (scalar.startsWith("\"\"\"") || scalar.startsWith("'''")) {
        throw metadataConfigFailure(line, "multiline TOML strings are not supported for metadata '${key}'")
    }
    if (scalar.isEmpty() || (scalar[0] != b'"' && scalar[0] != b'\'')) {
        throw metadataConfigFailure(line, "metadata '${key}' must be a quoted TOML string")
    }
    let decoded = decodeTomlString(scalar, 0)
    if (decoded.invalid || decoded.value.isNone() || decoded.nextOffset != scalar.size) {
        throw metadataConfigFailure(line, "metadata '${key}' must be one valid TOML string scalar")
    }
    decoded.value.getOrThrow()
}

private func metadataIdentityText(value: String, line: Int64, key: String): String {
    let bytes = value.toArray()
    if (value.trimAscii().isEmpty()) {
        throw metadataConfigFailure(line, "metadata '${key}' must not be blank")
    }
    for (byte in bytes) {
        if (byte <= 0x1Fu8 || byte == 0x7Fu8) {
            throw metadataConfigFailure(line, "metadata '${key}' must be single-line text without C0 or DEL controls")
        }
    }
    value
}

private func metadataTitleText(value: String, line: Int64, key: String): String {
    if (!public_model.isDocumentationMetadataTitle(value)) {
        throw metadataConfigFailure(line,
            "metadata '${key}' must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
    }
    value
}

private func metadataIntegerDigit(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value) - Int64(b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value) - Int64(b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value) - Int64(b'A') + 10 }
    -1
}

private func metadataOrder(value: String, line: Int64): Int64 {
    let raw = value.trimAscii()
    let bytes = raw.toArray()
    if (bytes.isEmpty()) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }

    var cursor: Int64 = 0
    var negative: Bool = false
    var signed: Bool = false
    if (bytes[cursor] == b'+' || bytes[cursor] == b'-') {
        signed = true
        negative = bytes[cursor] == b'-'
        cursor++
        if (cursor >= bytes.size) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }
    }

    var base: Int64 = 10
    if (!signed && cursor + 1 < bytes.size && bytes[cursor] == b'0') {
        if (bytes[cursor + 1] == b'x') { base = 16; cursor += 2 }
        else if (bytes[cursor + 1] == b'o') { base = 8; cursor += 2 }
        else if (bytes[cursor + 1] == b'b') { base = 2; cursor += 2 }
    }
    if (cursor >= bytes.size) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }

    let firstDigit = cursor
    var digits: Int64 = 0
    var previousUnderscore: Bool = false
    var number: Int64 = 0
    var outOfRange: Bool = false
    while (cursor < bytes.size) {
        let byte = bytes[cursor]
        if (byte == b'_') {
            if (digits == 0 || previousUnderscore || cursor + 1 >= bytes.size) {
                throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
            }
            previousUnderscore = true
            cursor++
            continue
        }
        let digit = metadataIntegerDigit(byte)
        if (digit < 0 || digit >= base) {
            throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999")
        }
        if (previousUnderscore) { previousUnderscore = false }
        digits++
        if (number > 999999 || digit > 999999 || number * base + digit > 999999) {
            outOfRange = true
        } else {
            number = number * base + digit
        }
        cursor++
    }
    if (digits == 0 || previousUnderscore) {
        throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
    }
    if (base == 10 && bytes[firstDigit] == b'0' && digits > 1) {
        throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
    }
    if (outOfRange || (negative && number != 0)) {
        throw metadataConfigFailure(line, "metadata 'order' must be in 0..999999")
    }
    number
}

private class MetadataGroupBuilder {
    let line: Int64
    var packageName: ?String = None
    var owner: ?String = None
    var ownerId: ?String = None
    var id: ?String = None
    var title: ?String = None
    var order: ?Int64 = None
    var titleEn: ?String = None
    var titleZhCn: ?String = None
    var titlesTableSeen: Bool = false
    let seenKeys = HashSet<String>()

    init(line: Int64) { this.line = line }

    func finish(): MetadataGroupConfig {
        let groupPackage = match (packageName) {
            case Some(value) => value
            case None => throw metadataConfigFailure(line, "group record is missing required 'package'")
        }
        let groupId = match (id) {
            case Some(value) => value
            case None => throw metadataConfigFailure(line, "group record is missing required 'id'")
        }
        let baseTitle = match (title) {
            case Some(value) => value
            case None => throw metadataConfigFailure(line, "group record is missing required 'title'")
        }
        let titles = ArrayList<public_model.DocumentationTitle>()
        match (titleEn) {
            case Some(value) => let _ = titles.add(public_model.DocumentationTitle("en", value))
            case None => ()
        }
        match (titleZhCn) {
            case Some(value) => let _ = titles.add(public_model.DocumentationTitle("zh-CN", value))
            case None => ()
        }
        MetadataGroupConfig(groupPackage, owner, ownerId, groupId, baseTitle, titles.toArray(), order, line)
    }
}

private class MetadataTagBuilder {
    let line: Int64
    var id: ?String = None
    var title: ?String = None
    var titleEn: ?String = None
    var titleZhCn: ?String = None
    var titlesTableSeen: Bool = false
    let seenKeys = HashSet<String>()

    init(line: Int64) { this.line = line }

    func finish(): MetadataTagConfig {
        let tagId = match (id) {
            case Some(value) => value
            case None => throw metadataConfigFailure(line, "tag record is missing required 'id'")
        }
        let baseTitle = match (title) {
            case Some(value) => value
            case None => throw metadataConfigFailure(line, "tag record is missing required 'title'")
        }
        let titles = ArrayList<public_model.DocumentationTitle>()
        match (titleEn) {
            case Some(value) => let _ = titles.add(public_model.DocumentationTitle("en", value))
            case None => ()
        }
        match (titleZhCn) {
            case Some(value) => let _ = titles.add(public_model.DocumentationTitle("zh-CN", value))
            case None => ()
        }
        MetadataTagConfig(tagId, baseTitle, titles.toArray(), line)
    }
}

private func metadataHeaderCandidate(path: String): Bool {
    let value = path.trimAscii()
    if (value.startsWith("metadata")) {
        if (value.size == 8) { return true }
        let next = value[8]
        return next == b'.' || next == b' ' || next == b'\t' || next == b']'
    }
    if (!value.isEmpty() && (value[0] == b'"' || value[0] == b'\'')) {
        let decoded = decodeTomlString(value, 0)
        if (!decoded.invalid && decoded.value.isSome()) {
            return decoded.value.getOrThrow() == "metadata"
        }
        return value.startsWith("\"metadata") || value.startsWith("'metadata")
    }
    false
}

private func metadataHeaderPath(value: String, line: Int64): Array<String> {
    metadataKeyPath(value, line, true)
}

private class MetadataParserState {
    let groupBuilders = ArrayList<MetadataGroupBuilder>()
    let tagBuilders = ArrayList<MetadataTagBuilder>()
    var latestGroup: ?MetadataGroupBuilder = None
    var latestTag: ?MetadataTagBuilder = None
    var section = "root"
    var atRoot = true
    var groupDefinitionCount: Int64 = 0
    var tagDefinitionCount: Int64 = 0
    var metadataTableSeen: Bool = false

    func handleHeader(value: String, line: Int64): Unit {
        atRoot = false
        let text = value.trimAscii()
        let arrayTable = text.startsWith("[[")
        var pathText = ""
        var validShape = false
        if (arrayTable && text.endsWith("]]" ) && text.size >= 4) {
            pathText = text[2..text.size - 2].trimAscii()
            validShape = true
        } else if (!arrayTable && text.startsWith("[") && text.endsWith("]") && text.size >= 2) {
            pathText = text[1..text.size - 1].trimAscii()
            validShape = true
        }

        if (!validShape) {
            let possiblePath = if (text.startsWith("[[")) { text[2..] } else { text[1..] }
            if (metadataHeaderCandidate(possiblePath)) {
                throw metadataConfigFailure(line, "malformed metadata table header")
            }
            section = "other"
            return
        }

        if (!metadataHeaderCandidate(pathText)) {
            section = "other"
            return
        }
        let path = metadataHeaderPath(pathText, line)
        if (path[0] != "metadata") {
            section = "other"
            return
        }

        if (!arrayTable && path.size == 1 && path[0] == "metadata") {
            if (metadataTableSeen) { throw metadataConfigFailure(line, "duplicate [metadata] table") }
            metadataTableSeen = true
            section = "metadata-root"
        } else if (arrayTable && path.size == 2 && path[0] == "metadata" && path[1] == "groups") {
            groupDefinitionCount++
            if (groupDefinitionCount > DOCUMENTATION_METADATA_CONFIG_MAX_DEFINITIONS) {
                throw metadataConfigFailure(line, "metadata groups exceed 2048 definitions")
            }
            let builder = MetadataGroupBuilder(line)
            groupBuilders.add(builder)
            latestGroup = Some(builder)
            section = "group"
        } else if (!arrayTable && path.size == 3 && path[0] == "metadata" &&
            path[1] == "groups" && path[2] == "titles") {
            let builder = match (latestGroup) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "orphan [metadata.groups.titles] table")
            }
            if (builder.titlesTableSeen) {
                throw metadataConfigFailure(line, "duplicate [metadata.groups.titles] table for current group")
            }
            builder.titlesTableSeen = true
            section = "group-titles"
        } else if (arrayTable && path.size == 2 && path[0] == "metadata" && path[1] == "tags") {
            tagDefinitionCount++
            if (tagDefinitionCount > DOCUMENTATION_METADATA_CONFIG_MAX_DEFINITIONS) {
                throw metadataConfigFailure(line, "metadata tags exceed 2048 definitions")
            }
            let builder = MetadataTagBuilder(line)
            tagBuilders.add(builder)
            latestTag = Some(builder)
            section = "tag"
        } else if (!arrayTable && path.size == 3 && path[0] == "metadata" &&
            path[1] == "tags" && path[2] == "titles") {
            let builder = match (latestTag) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "orphan [metadata.tags.titles] table")
            }
            if (builder.titlesTableSeen) {
                throw metadataConfigFailure(line, "duplicate [metadata.tags.titles] table for current tag")
            }
            builder.titlesTableSeen = true
            section = "tag-titles"
        } else {
            throw metadataConfigFailure(line, "unsupported metadata table or dotted table form")
        }
    }

    func assignment(rawLine: String, line: Int64): Unit {
        let cleaned = metadataStripComment(rawLine)
        if (cleaned.isEmpty()) { return }
        if (section == "metadata-root") {
            throw metadataConfigFailure(line, "[metadata] does not allow keys")
        }
        let equals = metadataEqualsAt(cleaned)
        if (equals.isNone()) { throw metadataConfigFailure(line, "expected a metadata key/value assignment") }
        let position = equals.getOrThrow()
        let keyPath = metadataKeyPath(cleaned[..position].trimAscii(), line, false)
        if (keyPath.size != 1) { throw metadataConfigFailure(line, "dotted metadata keys are not supported") }
        let key = keyPath[0]
        let rawValue = cleaned[position + 1..].trimAscii()
        if (rawValue.isEmpty()) { throw metadataConfigFailure(line, "metadata '${key}' requires a value") }
        if (rawValue.startsWith("\"\"\"") || rawValue.startsWith("'''")) {
            throw metadataConfigFailure(line, "multiline TOML strings are not supported for metadata values")
        }

        if (section == "group") {
            let builder = match (latestGroup) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "group setting has no current record")
            }
            if (!builder.seenKeys.add(key)) { throw metadataConfigFailure(line, "duplicate group key '${key}'") }
            match (key) {
                case "package" => builder.packageName = Some(metadataIdentityText(
                    metadataScalarString(rawValue, line, key), line, key))
                case "id" =>
                    let id = metadataScalarString(rawValue, line, key)
                    if (!public_model.isDeclarationTagId(id)) {
                        throw metadataConfigFailure(line, "group id must be 1-64 ASCII letters, digits, '-' or '_'")
                    }
                    builder.id = Some(id)
                case "title" => builder.title = Some(metadataTitleText(
                    metadataScalarString(rawValue, line, key), line, key))
                case "owner" =>
                    if (builder.ownerId.isSome()) { throw metadataConfigFailure(line, "owner and owner-id are mutually exclusive") }
                    builder.owner = Some(metadataIdentityText(metadataScalarString(rawValue, line, key), line, key))
                case "owner-id" =>
                    if (builder.owner.isSome()) { throw metadataConfigFailure(line, "owner and owner-id are mutually exclusive") }
                    builder.ownerId = Some(metadataIdentityText(metadataScalarString(rawValue, line, key), line, key))
                case "order" => builder.order = Some(metadataOrder(rawValue, line))
                case _ => throw metadataConfigFailure(line, "unknown metadata group key '${key}'")
            }
        } else if (section == "group-titles") {
            let builder = match (latestGroup) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "translated group title has no current group")
            }
            if (!builder.seenKeys.add("titles:${key}")) {
                throw metadataConfigFailure(line, "duplicate group title language '${key}'")
            }
            let title = metadataTitleText(metadataScalarString(rawValue, line, key), line, key)
            match (key) {
                case "en" => builder.titleEn = Some(title)
                case "zh-CN" => builder.titleZhCn = Some(title)
                case _ => throw metadataConfigFailure(line, "metadata titles allow only 'en' and 'zh-CN'")
            }
        } else if (section == "tag") {
            let builder = match (latestTag) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "tag setting has no current record")
            }
            if (!builder.seenKeys.add(key)) { throw metadataConfigFailure(line, "duplicate tag key '${key}'") }
            match (key) {
                case "id" =>
                    let id = metadataScalarString(rawValue, line, key)
                    if (!public_model.isDeclarationTagId(id)) {
                        throw metadataConfigFailure(line, "tag id must be 1-64 ASCII letters, digits, '-' or '_'")
                    }
                    builder.id = Some(id)
                case "title" => builder.title = Some(metadataTitleText(
                    metadataScalarString(rawValue, line, key), line, key))
                case _ => throw metadataConfigFailure(line, "unknown metadata tag key '${key}'")
            }
        } else if (section == "tag-titles") {
            let builder = match (latestTag) {
                case Some(value) => value
                case None => throw metadataConfigFailure(line, "translated tag title has no current tag")
            }
            if (!builder.seenKeys.add("titles:${key}")) {
                throw metadataConfigFailure(line, "duplicate tag title language '${key}'")
            }
            let title = metadataTitleText(metadataScalarString(rawValue, line, key), line, key)
            match (key) {
                case "en" => builder.titleEn = Some(title)
                case "zh-CN" => builder.titleZhCn = Some(title)
                case _ => throw metadataConfigFailure(line, "metadata titles allow only 'en' and 'zh-CN'")
            }
        }
    }

    func rejectRootMetadataKey(line: String, lineNumber: Int64): Unit {
        let cleaned = metadataStripComment(line)
        if (cleaned.isEmpty()) { return }
        let equals = metadataEqualsAt(cleaned)
        let keyText = match (equals) {
            case Some(position) => cleaned[..position].trimAscii()
            case None => cleaned
        }
        if (metadataHeaderCandidate(keyText)) {
            let path = metadataKeyPath(keyText, lineNumber, true)
            if (path[0] == "metadata") {
                throw metadataConfigFailure(lineNumber, "metadata definitions must use the supported metadata tables")
            }
        }
    }

    func result(): DocumentationMetadataConfig {
        let groups = ArrayList<MetadataGroupConfig>()
        for (builder in groupBuilders) { groups.add(builder.finish()) }
        let tags = ArrayList<MetadataTagConfig>()
        for (builder in tagBuilders) { tags.add(builder.finish()) }
        DocumentationMetadataConfig(groups.toArray(), tags.toArray())
    }
}

internal func loadDocumentationMetadataConfig(root: String): DocumentationMetadataConfig {
    let path = Path(root).join("cjdoc.toml")
    if (!exists(path)) { return DocumentationMetadataConfig([], []) }
    let text = try {
        readTextBounded(path, DOCUMENTATION_METADATA_CONFIG_MAX_BYTES)
    } catch (_: Exception) {
        throw metadataConfigReadFailure()
    }

    let state = MetadataParserState()
    let multiline = MetadataMultilineState()
    let comments = TomlLineScanner()
    var lineNumber: Int64 = 0
    for (rawLine in text.split("\n")) {
        lineNumber++
        if (multiline.isInside()) {
            let _ = comments.code(rawLine)
            multiline.advance(rawLine)
            continue
        }

        let trimmed = rawLine.trimAscii()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) {
            let _ = comments.code(rawLine)
            multiline.advance(rawLine)
            continue
        }

        if (trimmed.startsWith("[")) {
            let visible = comments.code(rawLine)
            multiline.advance(rawLine)
            match (visible) {
                case Some(value) => state.handleHeader(value, lineNumber)
                case None =>
                    if (metadataHeaderCandidate(trimmed[1..])) {
                        throw metadataConfigFailure(lineNumber, "multiline strings are not supported in metadata table headers")
                    }
            }
            continue
        }

        if (state.section == "metadata-root" || state.section == "group" ||
            state.section == "group-titles" || state.section == "tag" || state.section == "tag-titles") {
            state.assignment(rawLine, lineNumber)
            let _ = comments.code(rawLine)
            multiline.advance(rawLine)
            continue
        }

        if (state.atRoot) {
            // Reserved keys must be checked before multiline values disappear from scanner output.
            state.rejectRootMetadataKey(rawLine, lineNumber)
        }
        let visible = comments.code(rawLine)
        multiline.advance(rawLine)
        match (visible) {
            case Some(value) =>
                let cleaned = value.trimAscii()
                if (cleaned.startsWith("[")) { state.handleHeader(cleaned, lineNumber) }
            case None => ()
        }
    }
    state.result()
}
