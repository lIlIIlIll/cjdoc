protected package cjdoc.documentation.comments

import cjdoc.filesystem.readTextBounded
import cjdoc.manifest.{TomlLineScanner, commentsHeaderCandidate, decodeTomlString, tomlAssignmentEquals}
import cjdoc.model.{DocumentationTitle, isDocumentationFieldId, isDocumentationMetadataTitle}
import std.collection.*
import std.fs.*

internal let COMMENT_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let COMMENT_CONFIG_MAX_DEFINITIONS: Int64 = 2048

func commentConfigFailure(line: Int64, detail: String): IllegalArgumentException {
    IllegalArgumentException("CJDOC3139 at cjdoc.toml:${line}: ${detail}")
}

private func commentConfigReadFailure(): IllegalArgumentException {
    commentConfigFailure(1, "configuration must be valid UTF-8 and no larger than 65536 bytes")
}


/** Decode one quoted TOML scalar exactly; reject any trailing content. */
private func commentScalarString(value: String, line: Int64, key: String): String {
    let scalar = value.trimAscii()
    if (scalar.startsWith("\"\"\"") || scalar.startsWith("'''")) {
        throw commentConfigFailure(line, "multiline TOML strings are not supported for '${key}'")
    }
    if (scalar.isEmpty() || (scalar[0] != b'"' && scalar[0] != b'\'')) {
        throw commentConfigFailure(line, "'${key}' must be a quoted TOML string")
    }
    let decoded = decodeTomlString(scalar, 0)
    if (decoded.invalid || decoded.value.isNone() ||
        !scalar[decoded.nextOffset..].trimAscii().isEmpty()) {
        throw commentConfigFailure(line, "'${key}' must be a quoted TOML string")
    }
    decoded.value.getOrThrow()
}

private func commentScalarBoolean(value: String, line: Int64, key: String): Bool {
    let scalar = value.trimAscii()
    if (scalar == "true") { return true }
    if (scalar == "false") { return false }
    throw commentConfigFailure(line, "'${key}' must be true or false")
}

private class CommentFieldBuilder {
    let line: Int64
    var id: ?String = None
    var title: ?String = None
    var repeatable = false
    var titleEn: ?String = None
    var titleZhCn: ?String = None
    var titlesTableSeen = false
    let seenKeys = HashSet<String>()

    init(line: Int64) { this.line = line }

    func finish(): CommentFieldDefinition {
        let fieldId = match (id) {
            case Some(value) => value
            case None => throw commentConfigFailure(line, "comment field record is missing required 'id'")
        }
        let baseTitle = match (title) {
            case Some(value) => value
            case None => throw commentConfigFailure(line,
                "comment field record is missing required 'title'")
        }
        let titles = ArrayList<DocumentationTitle>()
        match (titleEn) {
            case Some(value) => let _ = titles.add(DocumentationTitle("en", value))
            case None => ()
        }
        match (titleZhCn) {
            case Some(value) => let _ = titles.add(DocumentationTitle("zh-CN", value))
            case None => ()
        }
        CommentFieldDefinition(fieldId, baseTitle, titles: titles.toArray(), repeatable: repeatable)
    }
}

private class CommentRuleBuilder {
    let line: Int64
    var required: ?String = None
    var whenPresent: ?String = None
    var severity = "error"
    let seenKeys = HashSet<String>()

    init(line: Int64) { this.line = line }
}

private func commentTitleText(value: String, line: Int64, key: String): String {
    if (!isDocumentationMetadataTitle(value)) {
        throw commentConfigFailure(line,
            "'${key}' must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
    }
    value
}

private func commentNameText(value: String, line: Int64, key: String): String {
    if (!isDocumentationFieldId(value)) {
        throw commentConfigFailure(line, "'${key}' must match [a-z][a-z0-9-]{0,63}")
    }
    value
}

// Header recognition is intentionally narrow: only the five documented tables
// exist, so a misspelled table fails before generation instead of being ignored.
private class CommentConfigParser {
    let aliases = HashMap<String, (String, Int64)>()
    let fieldBuilders = ArrayList<CommentFieldBuilder>()
    let ruleBuilders = ArrayList<CommentRuleBuilder>()
    var latestField: ?CommentFieldBuilder = None
    var latestRule: ?CommentRuleBuilder = None
    var section = "root"
    var rootTableSeen = false
    var aliasCount: Int64 = 0
    var fieldCount: Int64 = 0
    var ruleCount: Int64 = 0
    var aliasesTableSeen = false

    func isCommentHeader(value: String): Bool {
        let text = value.trimAscii()
        if (text.startsWith("comments")) {
            if (text.size == 8) { return true }
            let next = text[8]
            return next == b'.' || next == b' ' || next == b'\t' || next == b']'
        }
        if (!text.isEmpty() && (text[0] == b'"' || text[0] == b'\'')) {
            let decoded = decodeTomlString(text, 0)
            if (!decoded.invalid && decoded.value.isSome()) {
                return decoded.value.getOrThrow() == "comments"
            }
            return text.startsWith("\"comments") || text.startsWith("'comments")
        }
        false
    }

    func handleHeader(value: String, line: Int64): Unit {
        let previous = section
        section = "other"
        let text = value.trimAscii()
        let arrayTable = text.startsWith("[[")
        var pathText = ""
        var validShape = false
        if (arrayTable && text.endsWith("]]") && text.size >= 4) {
            pathText = text[2..text.size - 2].trimAscii()
            validShape = true
        } else if (!arrayTable && text.startsWith("[") && text.endsWith("]") && text.size >= 2) {
            pathText = text[1..text.size - 1].trimAscii()
            validShape = true
        }
        if (!validShape) {
            let possible = if (text.startsWith("[[")) { text[2..] } else { text[1..] }
            if (isCommentHeader(possible)) {
                throw commentConfigFailure(line, "malformed comment table header")
            }
            latestField = None
            return
        }
        if (!isCommentHeader(pathText)) {
            latestField = None
            return
        }
        if (!pathText.startsWith("comments") || pathText.startsWith("\"") ||
            pathText.startsWith("'")) {
            // Quoted or dotted spellings are not part of the documented grammar.
            throw commentConfigFailure(line, "comment tables must use the documented literal names")
        }
        let rest = if (pathText.size == 8) { "" } else { pathText[8..].trimAscii() }
        if (rest.isEmpty()) {
            if (arrayTable) { throw commentConfigFailure(line, "[[comments]] must be a single table") }
            if (rootTableSeen) {
                throw commentConfigFailure(line, "duplicate [comments] table")
            }
            rootTableSeen = true
            section = "comments-root"
        } else if (rest == ".aliases") {
            if (arrayTable) { throw commentConfigFailure(line, "[[comments.aliases]] must be a table") }
            if (aliasesTableSeen) { throw commentConfigFailure(line, "duplicate [comments.aliases] table") }
            aliasesTableSeen = true
            section = "aliases"
        } else if (rest == ".fields") {
            if (!arrayTable) { throw commentConfigFailure(line, "comments.fields must be array tables") }
            fieldCount++
            if (fieldCount > COMMENT_CONFIG_MAX_DEFINITIONS) {
                throw commentConfigFailure(line, "comment fields exceed 2048 definitions")
            }
            let builder = CommentFieldBuilder(line)
            fieldBuilders.add(builder)
            latestField = Some(builder)
            section = "field"
        } else if (rest == ".fields.titles") {
            if (arrayTable) { throw commentConfigFailure(line, "[[comments.fields.titles]] must be a table") }
            if (previous != "field") {
                throw commentConfigFailure(line, "titles must immediately follow their comment field")
            }
            let builder = match (latestField) {
                case Some(value) => value
                case None => throw commentConfigFailure(line, "orphan [comments.fields.titles] table")
            }
            if (builder.titlesTableSeen) {
                throw commentConfigFailure(line, "duplicate [comments.fields.titles] table for current field")
            }
            builder.titlesTableSeen = true
            section = "field-titles"
        } else if (rest == ".rules") {
            if (!arrayTable) { throw commentConfigFailure(line, "comments.rules must be array tables") }
            ruleCount++
            if (ruleCount > COMMENT_CONFIG_MAX_DEFINITIONS) {
                throw commentConfigFailure(line, "comment rules exceed 2048 definitions")
            }
            let builder = CommentRuleBuilder(line)
            ruleBuilders.add(builder)
            latestRule = Some(builder)
            section = "rule"
        } else {
            throw commentConfigFailure(line, "unknown comment table '[" + pathText + "]'")
        }
    }

    func assignment(cleaned: String, line: Int64): Unit {
        if (section == "root" || section == "other") { return }
        if (section == "comments-root") {
            throw commentConfigFailure(line, "[comments] does not allow keys")
        }
        let equals = match (tomlAssignmentEquals(cleaned)) {
            case Some(value) => value
            case None => throw commentConfigFailure(line, "expected a comment key/value assignment")
        }
        let key = cleaned[..equals].trimAscii()
        if (key.isEmpty()) { throw commentConfigFailure(line, "comment configuration has an empty key") }
        let rawValue = cleaned[equals + 1..].trimAscii()
        if (rawValue.isEmpty()) { throw commentConfigFailure(line, "'${key}' requires a value") }
        match (section) {
            case "aliases" => assignmentAlias(key, rawValue, line)
            case "field" => assignmentField(key, rawValue, line)
            case "field-titles" => assignmentFieldTitle(key, rawValue, line)
            case "rule" => assignmentRule(key, rawValue, line)
            case _ => ()
        }
    }

    private func assignmentAlias(key: String, rawValue: String, line: Int64): Unit {
        let alias = commentNameText(key, line, key)
        let target = commentNameText(commentScalarString(rawValue, line, key), line, key)
        if (aliases.contains(alias)) {
            throw commentConfigFailure(line, "duplicate comment alias '${alias}'")
        }
        aliasCount++
        if (aliasCount > COMMENT_CONFIG_MAX_DEFINITIONS) {
            throw commentConfigFailure(line, "comment aliases exceed 2048 definitions")
        }
        aliases[alias] = (target, line)
    }

    private func assignmentField(key: String, rawValue: String, line: Int64): Unit {
        let builder = match (latestField) {
            case Some(value) => value
            case None => throw commentConfigFailure(line, "comment field setting has no current record")
        }
        if (!builder.seenKeys.add(key)) {
            throw commentConfigFailure(line, "duplicate comment field key '${key}'")
        }
        match (key) {
            case "id" => builder.id = Some(commentNameText(
                commentScalarString(rawValue, line, key), line, key))
            case "title" => builder.title = Some(commentTitleText(
                commentScalarString(rawValue, line, key), line, key))
            case "repeatable" => builder.repeatable = commentScalarBoolean(rawValue, line, key)
            case _ => throw commentConfigFailure(line, "unknown comment field key '${key}'")
        }
    }

    private func assignmentFieldTitle(key: String, rawValue: String, line: Int64): Unit {
        let builder = match (latestField) {
            case Some(value) => value
            case None => throw commentConfigFailure(line, "comment field title has no current field")
        }
        if (!builder.seenKeys.add("titles:${key}")) {
            throw commentConfigFailure(line, "duplicate comment field title language '${key}'")
        }
        let title = commentTitleText(commentScalarString(rawValue, line, key), line, key)
        match (key) {
            case "en" => builder.titleEn = Some(title)
            case "zh-CN" => builder.titleZhCn = Some(title)
            case _ => throw commentConfigFailure(line, "comment field titles allow only 'en' and 'zh-CN'")
        }
    }

    private func assignmentRule(key: String, rawValue: String, line: Int64): Unit {
        let builder = match (latestRule) {
            case Some(value) => value
            case None => throw commentConfigFailure(line, "comment rule setting has no current record")
        }
        if (!builder.seenKeys.add(key)) {
            throw commentConfigFailure(line, "duplicate comment rule key '${key}'")
        }
        match (key) {
            case "require" => builder.required = Some(commentNameText(
                commentScalarString(rawValue, line, key), line, key))
            case "when-present" => builder.whenPresent = Some(commentNameText(
                commentScalarString(rawValue, line, key), line, key))
            case "severity" =>
                let value = commentScalarString(rawValue, line, key)
                if (value != "error" && value != "warning") {
                    throw commentConfigFailure(line, "'severity' must be error or warning")
                }
                builder.severity = value
            case _ => throw commentConfigFailure(line, "unknown comment rule key '${key}'")
        }
    }

    private func resolveTarget(authored: String, line: Int64, fields: HashSet<String>): String {
        if (aliases.contains(authored)) {
            throw commentConfigFailure(line,
                "comment alias '${authored}' must name a builtin tag or a project field, not another alias")
        }
        if (fields.contains(authored)) { return authored }
        if (isBuiltinCommentTagName(authored)) { return authored }
        throw commentConfigFailure(line, "comment alias '${authored}' names an unknown target")
    }

    /**
     * Validate the whole file, then hand back a resolved policy.
     *
     * Aliases may be written before the field they name, so reference checks
     * run only after every definition has been collected.
     */
    func finish(): CommentSpec {
        let fieldIds = HashSet<String>()
        let fields = ArrayList<CommentFieldDefinition>()
        for (builder in fieldBuilders) {
            let definition = builder.finish()
            if (!fieldIds.add(definition.id)) {
                throw commentConfigFailure(builder.line, "duplicate comment field '${definition.id}'")
            }
            if (isBuiltinCommentTagName(definition.id)) {
                throw commentConfigFailure(builder.line,
                    "comment field '${definition.id}' conflicts with a builtin tag")
            }
            fields.add(definition)
        }
        let resolvedAliases = HashMap<String, String>()
        for (alias in aliases.keys()) {
            let entry = aliases[alias]
            let target = entry[0]
            let line = entry[1]
            if (fieldIds.contains(alias) || isBuiltinCommentTagName(alias)) {
                throw commentConfigFailure(line,
                    "comment alias '${alias}' conflicts with a builtin tag or a project field")
            }
            resolvedAliases[alias] = resolveTarget(target, line, fieldIds)
        }
        let rules = ArrayList<CommentRule>()
        for (builder in ruleBuilders) {
            let requiredAuthored = match (builder.required) {
                case Some(value) => value
                case None => throw commentConfigFailure(builder.line,
                    "comment rule is missing required 'require'")
            }
            let required = resolveRuleName(requiredAuthored, builder.line, fieldIds)
            let whenPresent: ?String = match (builder.whenPresent) {
                case Some(value) => Some(resolveRuleName(value, builder.line, fieldIds))
                case None => None
            }
            rules.add(CommentRule(required, whenPresent, builder.severity))
        }
        CommentSpec(aliases: resolvedAliases, fields: fields.toArray(), rules: rules.toArray())
    }

    private func resolveRuleName(authored: String, line: Int64, fields: HashSet<String>): String {
        if (aliases.contains(authored)) {
            throw commentConfigFailure(line,
                "comment rule names must use a formal tag or field name, not alias '${authored}'")
        }
        if (fields.contains(authored) || isBuiltinCommentTagName(authored)) { return authored }
        throw commentConfigFailure(line, "comment rule names an unknown tag or field '${authored}'")
    }
}

/**
 * Read the comment policy of one module root.
 *
 * The file is read once by the caller and shared with the metadata reader, so
 * this entry point accepts the already-captured text.
 */
protected func parseCommentSpec(text: String, configPath!: String = "cjdoc.toml"): CommentSpec {
    try {
        parseCommentSpecText(text)
    } catch (error: IllegalArgumentException) {
        throw IllegalArgumentException(error.message.replace("CJDOC3139 at cjdoc.toml:",
            "CJDOC3139 at " + configPath + ":"))
    }
}

private func parseCommentSpecText(text: String): CommentSpec {
    let parser = CommentConfigParser()
    let scanner = TomlLineScanner()
    var lineNumber: Int64 = 0
    for (rawLine in text.split("\n")) {
        lineNumber++
        let insideMultiline = scanner.inMultilineString
        let visible = match (scanner.code(rawLine)) {
            case Some(value) => value
            case None =>
                if (!insideMultiline && (commentsHeaderCandidate(rawLine) ||
                    (parser.section != "root" && parser.section != "other" &&
                        !rawLine.trimAscii().startsWith("[")))) {
                    throw commentConfigFailure(lineNumber, "multiline TOML strings are not supported in comment tables")
                }
                continue
        }
        let cleaned = visible.trimAscii()
        if (cleaned.isEmpty()) { continue }
        if (cleaned.startsWith("[")) {
            parser.handleHeader(cleaned, lineNumber)
            continue
        }
        parser.assignment(cleaned, lineNumber)
    }
    parser.finish()
}

/** A project without `cjdoc.toml` has no comment policy. */
protected func loadCommentSpec(root: String): CommentSpec {
    let path = Path(root).join("cjdoc.toml")
    if (!exists(path)) { return CommentSpec() }
    let text = try {
        readTextBounded(path, COMMENT_CONFIG_MAX_BYTES)
    } catch (_: Exception) {
        throw commentConfigReadFailure()
    }
    parseCommentSpec(text)
}
