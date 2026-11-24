protected package cjdoc.documentation.metadata

import cjdoc.filesystem.readTextBounded
import cjdoc.manifest.{TomlLineScanner, metadataHeaderCandidate}
import cjdoc.model as public_model
import std.collection.*
import std.fs.*

internal let DOCUMENTATION_METADATA_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let DOCUMENTATION_METADATA_CONFIG_MAX_DEFINITIONS: Int64 = 2048

/** A raw group record parsed before module/package/owner binding. */
protected class MetadataGroupConfig {
    protected let packageName: String
    protected let owner: ?String
    protected let ownerId: ?String
    protected let id: String
    protected let title: String
    protected let titles: Array<public_model.DocumentationTitle>
    protected let order: ?Int64
    protected let line: Int64

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
protected class MetadataTagConfig {
    protected let id: String
    protected let title: String
    protected let titles: Array<public_model.DocumentationTitle>
    protected let line: Int64

    init(id: String, title: String, titles: Array<public_model.DocumentationTitle>, line: Int64) {
        this.id = id
        this.title = title
        this.titles = titles
        this.line = line
    }
}

/** Metadata declarations captured from one root's cjdoc.toml. */
protected class DocumentationMetadataConfig {
    protected let groups: Array<MetadataGroupConfig>
    protected let tags: Array<MetadataTagConfig>

    init(groups: Array<MetadataGroupConfig>, tags: Array<MetadataTagConfig>) {
        this.groups = groups
        this.tags = tags
    }
}

func metadataConfigFailure(line: Int64, detail: String): IllegalArgumentException {
    IllegalArgumentException("CJDOC3133 at cjdoc.toml:${line}: ${detail}")
}

private func metadataConfigReadFailure(): IllegalArgumentException {
    metadataConfigFailure(1, "configuration must be valid UTF-8 and no larger than 65536 bytes")
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

protected func loadDocumentationMetadataConfig(root: String): DocumentationMetadataConfig {
    let path = Path(root).join("cjdoc.toml")
    if (!exists(path)) { return DocumentationMetadataConfig([], []) }
    let text = try {
        readTextBounded(path, DOCUMENTATION_METADATA_CONFIG_MAX_BYTES)
    } catch (_: Exception) {
        throw metadataConfigReadFailure()
    }
    parseDocumentationMetadataConfig(text)
}

/**
 * Parse `[metadata]` from already-captured configuration text.
 *
 * One bounded read feeds both the metadata and comment readers, so two
 * namespaces can never observe different bytes for the same module root.
 */
protected func parseDocumentationMetadataConfig(text: String): DocumentationMetadataConfig {
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
