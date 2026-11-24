package cjdoc.model

import std.collection.*
import std.sort.*

private let DOCUMENTATION_METADATA_MAX_TEXT_BYTES: Int64 = 256
private let DOCUMENTATION_METADATA_MAX_DEFINITIONS: Int64 = 2048
private let DOCUMENTATION_METADATA_MAX_TITLES: Int64 = 2
private let DOCUMENTATION_METADATA_MAX_ORDER: Int64 = 999999

/** A translated display title, preserving the caller's valid text verbatim. */
public class DocumentationTitle {
    public let language: String
    public let title: String

    public init(language: String, title: String) {
        if (language != "en" && language != "zh-CN") {
            throw IllegalArgumentException("documentation title language must be en or zh-CN")
        }
        if (!isDocumentationMetadataTitle(title)) {
            throw IllegalArgumentException("documentation title must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
        }
        this.language = language
        this.title = title
    }
}

/** A captured group definition scoped to one module and package container. */
public class DocumentationGroupDefinition {
    public let moduleId: String
    public let packageName: String
    public let id: String
    public let title: String
    public let ownerId: ?String
    public let order: ?Int64
    private let titlesStorage: ArrayList<DocumentationTitle>

    public init(moduleId: String, packageName: String, id: String, title: String,
        ownerId!: ?String = None, titles!: Array<DocumentationTitle> = [], order!: ?Int64 = None) {
        if (moduleId.isEmpty() || packageName.isEmpty()) {
            throw IllegalArgumentException("documentation group scope identifiers cannot be empty")
        }
        if (let Some(value) <- ownerId) {
            if (value.isEmpty()) {
                throw IllegalArgumentException("documentation group ownerId cannot be empty")
            }
        }
        if (!isDeclarationTagId(id)) {
            throw IllegalArgumentException("documentation group id must be 1-64 ASCII letters, digits, '-' or '_'")
        }
        if (!isDocumentationMetadataTitle(title)) {
            throw IllegalArgumentException("documentation group title must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
        }
        if (let Some(value) <- order) {
            if (value < 0 || value > DOCUMENTATION_METADATA_MAX_ORDER) {
                throw IllegalArgumentException("documentation group order must be between 0 and 999999")
            }
        }
        let storedTitles = validatedDocumentationTitleEntries(titles)
        this.moduleId = moduleId
        this.packageName = packageName
        this.id = id
        this.title = title
        this.ownerId = ownerId
        this.order = order
        this.titlesStorage = storedTitles
    }

    public prop titles: ReadOnlyList<DocumentationTitle> { get() { titlesStorage } }
}

/** A captured tag definition scoped to one author module. */
public class DocumentationTagDefinition {
    public let moduleId: String
    public let id: String
    public let title: String
    private let titlesStorage: ArrayList<DocumentationTitle>

    public init(moduleId: String, id: String, title: String,
        titles!: Array<DocumentationTitle> = []) {
        if (moduleId.isEmpty()) {
            throw IllegalArgumentException("documentation tag moduleId cannot be empty")
        }
        if (!isDeclarationTagId(id)) {
            throw IllegalArgumentException("documentation tag id must be 1-64 ASCII letters, digits, '-' or '_'")
        }
        if (!isDocumentationMetadataTitle(title)) {
            throw IllegalArgumentException("documentation tag title must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
        }
        let storedTitles = validatedDocumentationTitleEntries(titles)
        this.moduleId = moduleId
        this.id = id
        this.title = title
        this.titlesStorage = storedTitles
    }

    public prop titles: ReadOnlyList<DocumentationTitle> { get() { titlesStorage } }
}

/** One captured use of a project comment field by a canonical declaration. */
public class DocumentationFieldUse {
    public let symbolId: String
    private let valuesStorage: ArrayList<String>

    public init(symbolId: String, values: Array<String>) {
        if (symbolId.isEmpty()) {
            throw IllegalArgumentException("documentation field use requires a symbol id")
        }
        if (values.isEmpty()) {
            throw IllegalArgumentException("documentation field use requires at least one value")
        }
        for (value in values) {
            if (!isDocumentationFieldValue(value)) {
                throw IllegalArgumentException(
                    "documentation field value must be nonblank single-line text without controls")
            }
        }
        this.symbolId = symbolId
        this.valuesStorage = ArrayList<String>(values)
    }

    public prop values: ReadOnlyList<String> { get() { valuesStorage } }
}

/**
 * A project comment field published for one module.
 *
 * Values live here, associated by canonical symbol id, rather than inside each
 * declaration: a declaration record keeps one documentation tree, and an offline
 * query can still answer "which declarations is owner=platform?" without
 * re-reading source or `cjdoc.toml`.
 */
public class DocumentationFieldDefinition {
    public let moduleId: String
    public let id: String
    public let title: String
    private let titlesStorage: ArrayList<DocumentationTitle>
    public let repeatable: Bool
    private let usesStorage: ArrayList<DocumentationFieldUse>

    public init(moduleId: String, id: String, title: String,
        titles!: Array<DocumentationTitle> = [], repeatable!: Bool = false,
        uses!: Array<DocumentationFieldUse> = []) {
        if (moduleId.isEmpty()) {
            throw IllegalArgumentException("documentation field moduleId cannot be empty")
        }
        if (!isDocumentationFieldId(id)) {
            throw IllegalArgumentException("documentation field id must match [a-z][a-z0-9-]{0,63}")
        }
        if (!isDocumentationMetadataTitle(title)) {
            throw IllegalArgumentException("documentation field title must be nonblank, single-line text of 1-256 UTF-8 bytes")
        }
        if (uses.isEmpty()) {
            throw IllegalArgumentException("documentation field definition requires at least one use")
        }
        let storedTitles = validatedDocumentationTitleEntries(titles)
        let seen = HashSet<String>()
        let storedUses = ArrayList<DocumentationFieldUse>(uses)
        for (use in storedUses) {
            if (!seen.add(use.symbolId)) {
                throw IllegalArgumentException("documentation field repeats one symbol use")
            }
            if (!repeatable && use.values.size > 1) {
                throw IllegalArgumentException("single-value documentation field carries multiple values")
            }
        }
        this.moduleId = moduleId
        this.id = id
        this.title = title
        this.titlesStorage = storedTitles
        this.repeatable = repeatable
        this.usesStorage = storedUses
    }

    public prop titles: ReadOnlyList<DocumentationTitle> { get() { titlesStorage } }
    public prop uses: ReadOnlyList<DocumentationFieldUse> { get() { usesStorage } }

    /** Display title for one page language, falling back to the declared title. */
    public func titleFor(language: String): String {
        for (entry in titlesStorage) {
            if (entry.language == language) { return entry.title }
        }
        title
    }
}

/** Field identity rule; the same shape the project configuration enforces. */
protected func isDocumentationFieldId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if (byte >= b'a' && byte <= b'z') { continue }
        if (index > 0 && ((byte >= b'0' && byte <= b'9') || byte == b'-')) { continue }
        return false
    }
    true
}

/** True for one legal custom field value: nonblank, single line, no controls. */
protected func isDocumentationFieldValue(value: String): Bool {
    documentationFieldValueProblem(value).isEmpty()
}

/** Report why a stored value cannot be the text of one authored field line. */
protected func documentationFieldValueProblem(value: String): String {
    var codePoints: Int64 = 0
    var containsNonWhitespace = false
    for (rune in value.runes()) {
        codePoints++
        if (codePoints > 16384) { return "too-long" }
        let code = UInt32(rune)
        if (code == 0x0Au32 || code == 0x0Du32 || code == 0x85u32 ||
            code == 0x2028u32 || code == 0x2029u32) { return "multiline" }
        if ((code < 0x20u32 && code != 0x09u32) ||
            (code >= 0x7Fu32 && code <= 0x9Fu32)) { return "control" }
        if (code != 0x20u32 && code != 0x09u32) { containsNonWhitespace = true }
    }
    if (!containsNonWhitespace) { "empty" } else { "" }
}

/** Immutable captured metadata definitions for a documentation set. */
public class DocumentationMetadata {
    private let groupsStorage: ArrayList<DocumentationGroupDefinition>
    private let tagsStorage: ArrayList<DocumentationTagDefinition>
    private let fieldsStorage: ArrayList<DocumentationFieldDefinition>

    public init(groups!: Array<DocumentationGroupDefinition> = [],
        tags!: Array<DocumentationTagDefinition> = [],
        fields!: Array<DocumentationFieldDefinition> = []) {
        if (groups.size > DOCUMENTATION_METADATA_MAX_DEFINITIONS ||
            tags.size > DOCUMENTATION_METADATA_MAX_DEFINITIONS ||
            fields.size > DOCUMENTATION_METADATA_MAX_DEFINITIONS) {
            throw IllegalArgumentException("documentation metadata exceeds 2048 definitions in a category")
        }
        let groupsStorage = ArrayList<DocumentationGroupDefinition>(groups)
        let tagsStorage = ArrayList<DocumentationTagDefinition>(tags)
        sort(groupsStorage, lessThan: { left, right =>
            if (left.moduleId != right.moduleId) { metadataUtf8LessThan(left.moduleId, right.moduleId) }
            else if (left.packageName != right.packageName) { metadataUtf8LessThan(left.packageName, right.packageName) }
            else if (left.ownerId != right.ownerId) {
                match ((left.ownerId, right.ownerId)) {
                    case (None, Some(_)) => true
                    case (Some(_), None) => false
                    case (Some(leftOwner), Some(rightOwner)) =>
                        metadataUtf8LessThan(leftOwner, rightOwner)
                    case _ => false
                }
            } else if (left.id != right.id) { metadataUtf8LessThan(left.id, right.id) }
            else { false }
        }, stable: true)
        sort(tagsStorage, lessThan: { left, right =>
            if (left.moduleId != right.moduleId) { metadataUtf8LessThan(left.moduleId, right.moduleId) }
            else if (left.id != right.id) { metadataUtf8LessThan(left.id, right.id) }
            else { false }
        }, stable: true)
        let fieldsStorage = ArrayList<DocumentationFieldDefinition>(fields)
        sort(fieldsStorage, lessThan: { left, right =>
            if (left.moduleId != right.moduleId) { metadataUtf8LessThan(left.moduleId, right.moduleId) }
            else { metadataUtf8LessThan(left.id, right.id) }
        }, stable: true)
        this.groupsStorage = groupsStorage
        this.tagsStorage = tagsStorage
        this.fieldsStorage = fieldsStorage
    }

    public prop groups: ReadOnlyList<DocumentationGroupDefinition> { get() { groupsStorage } }
    public prop tags: ReadOnlyList<DocumentationTagDefinition> { get() { tagsStorage } }
    public prop fields: ReadOnlyList<DocumentationFieldDefinition> { get() { fieldsStorage } }
}

/** True when text is a legal author-facing metadata title, without rewriting it. */
protected func isDocumentationMetadataTitle(value: String): Bool {
    if (value.isEmpty() || value.size > DOCUMENTATION_METADATA_MAX_TEXT_BYTES) { return false }

    var containsNonWhitespace = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (byte <= 0x1Fu8 || byte == 0x7Fu8) { return false }
        if (isMetadataLineSeparator(value, index)) { return false }
        let whitespaceWidth = metadataWhitespaceWidth(value, index)
        if (whitespaceWidth > 0) {
            index += whitespaceWidth
        } else {
            containsNonWhitespace = true
            index += 1
        }
    }
    containsNonWhitespace
}

private func validatedDocumentationTitleEntries(
    titles: Array<DocumentationTitle>): ArrayList<DocumentationTitle> {
    if (titles.size > DOCUMENTATION_METADATA_MAX_TITLES) {
        throw IllegalArgumentException("documentation metadata records support at most two translated titles")
    }
    let languages = HashSet<String>()
    let result = ArrayList<DocumentationTitle>(titles)
    for (item in result) {
        if (!languages.add(item.language)) {
            throw IllegalArgumentException("documentation metadata title language must not be duplicated")
        }
    }
    sort(result, lessThan: { left, right => metadataUtf8LessThan(left.language, right.language) },
        stable: true)
    result
}

private func metadataUtf8LessThan(left: String, right: String): Bool {
    var index: Int64 = 0
    while (index < left.size && index < right.size) {
        if (left[index] != right[index]) { return left[index] < right[index] }
        index++
    }
    left.size < right.size
}

private func isMetadataLineSeparator(value: String, index: Int64): Bool {
    if (value[index] == 0xC2u8 && index + 1 < value.size && value[index + 1] == 0x85u8) {
        return true
    }
    value[index] == 0xE2u8 && index + 2 < value.size && value[index + 1] == 0x80u8 &&
        (value[index + 2] == 0xA8u8 || value[index + 2] == 0xA9u8)
}

private func metadataWhitespaceWidth(value: String, index: Int64): Int64 {
    let byte = value[index]
    if (byte == 0x20u8) { return 1 }
    if (byte == 0xC2u8 && index + 1 < value.size && value[index + 1] == 0xA0u8) { return 2 }
    if (byte == 0xE1u8 && index + 2 < value.size && value[index + 1] == 0x9Au8 &&
        value[index + 2] == 0x80u8) { return 3 }
    if (byte == 0xE2u8 && index + 2 < value.size && value[index + 1] == 0x80u8 &&
        value[index + 2] >= 0x80u8 && value[index + 2] <= 0x8Au8) { return 3 }
    if (byte == 0xE2u8 && index + 2 < value.size && value[index + 1] == 0x80u8 &&
        value[index + 2] == 0xAFu8) { return 3 }
    if (byte == 0xE2u8 && index + 2 < value.size && value[index + 1] == 0x81u8 &&
        value[index + 2] == 0x9Fu8) { return 3 }
    if (byte == 0xE3u8 && index + 2 < value.size && value[index + 1] == 0x80u8 &&
        value[index + 2] == 0x80u8) { return 3 }
    0
}

/**
 * Return only definitions referenced by the supplied already-visible declarations.
 * The caller owns visibility selection; this helper never derives or broadens it.
 */
protected func documentationMetadataForDeclarations(metadata: DocumentationMetadata,
    declarations: Array<SymbolDoc>): DocumentationMetadata {
    let groupUses = HashSet<String>()
    let tagUses = HashSet<String>()
    for (declaration in declarations) {
        if (let Some(comment) <- declaration.documentation) {
            match (canonicalDocumentationGroupTag(comment)) {
                case Some(groupTag) => let _ = groupUses.add(documentationMetadataGroupKey(
                    declaration.moduleId, declaration.packageName, declaration.ownerId,
                    groupTag.subject))
                case None => ()
            }
            for (tagId in documentationTagIds(Some(comment))) {
                let _ = tagUses.add(documentationMetadataTagKey(declaration.moduleId, tagId))
            }
        }
    }

    let groups = ArrayList<DocumentationGroupDefinition>()
    for (group in metadata.groups) {
        let key = documentationMetadataGroupKey(group.moduleId, group.packageName,
            group.ownerId, group.id)
        if (groupUses.contains(key)) {
            groups.add(DocumentationGroupDefinition(group.moduleId, group.packageName,
                group.id, group.title, ownerId: group.ownerId, titles: group.titles.toArray(),
                order: group.order))
        }
    }
    let tags = ArrayList<DocumentationTagDefinition>()
    for (tag in metadata.tags) {
        let key = documentationMetadataTagKey(tag.moduleId, tag.id)
        if (tagUses.contains(key)) {
            tags.add(DocumentationTagDefinition(tag.moduleId, tag.id, tag.title,
                titles: tag.titles.toArray()))
        }
    }
    // A field survives only through uses by declarations visible here: an
    // `all -> external` re-publication must drop a private-only value rather
    // than publish a definition whose uses all disappeared.
    let visibleModules = HashMap<String, HashSet<String>>()
    for (declaration in declarations) {
        match (visibleModules.get(declaration.moduleId)) {
            case Some(ids) => let _ = ids.add(declaration.id)
            case None =>
                let ids = HashSet<String>()
                let _ = ids.add(declaration.id)
                visibleModules[declaration.moduleId] = ids
        }
    }
    let fields = ArrayList<DocumentationFieldDefinition>()
    for (field in metadata.fields) {
        let moduleIds = match (visibleModules.get(field.moduleId)) {
            case Some(value) => value
            case None => continue
        }
        let retainedUses = ArrayList<DocumentationFieldUse>()
        for (use in field.uses) {
            if (!moduleIds.contains(use.symbolId)) { continue }
            retainedUses.add(use)
        }
        if (retainedUses.isEmpty()) { continue }
        fields.add(DocumentationFieldDefinition(field.moduleId, field.id, field.title,
            titles: field.titles.toArray(), repeatable: field.repeatable,
            uses: retainedUses.toArray()))
    }
    DocumentationMetadata(groups: groups.toArray(), tags: tags.toArray(),
        fields: fields.toArray())
}
private func metadataKeyField(value: String): String {
    "${value.size}:${value}"
}

/** Stable, collision-free identity of a metadata group container and ID. */
protected func documentationMetadataGroupKey(moduleId: String, packageName: String,
    ownerId: ?String, id: String): String {
    let owner = match (ownerId) {
        case Some(value) => "1" + metadataKeyField(value)
        case None => "0"
    }
    metadataKeyField(moduleId) + metadataKeyField(packageName) + owner + metadataKeyField(id)
}

/** Stable, collision-free identity of a module-scoped metadata tag. */
protected func documentationMetadataTagKey(moduleId: String, id: String): String {
    metadataKeyField(moduleId) + metadataKeyField(id)
}


