protected package cjdoc.documentation.pages

import cjdoc.filesystem.readTextBounded
import cjdoc.manifest.{TomlLineScanner, decodeTomlString, tomlAssignmentEquals, tomlAssignmentString}
import cjdoc.model as public_model
import std.collection.*
import std.fs.*

protected let CONCEPTUAL_CONFIG_MAX_BYTES: Int64 = 64 * 1024

protected class ConceptualPageSpec {
    var source = ""
    var route = ""
    var title = ""
    var id = ""
    var language: ?String = None
    var kind = "guide"
    var packageName = ""
    let sections = ArrayList<public_model.DocumentationSection>()

    init(source!: String = "", route!: String = "", title!: String = "") {
        this.source = source
        this.route = route
        this.title = title
    }
}

protected class ConceptualDocsConfig {
    var enabled = false
    var indexSource = "docs/index.md"
    let pages = ArrayList<ConceptualPageSpec>()
    let packageSources = HashMap<String, String>()
}

protected func conceptualSafeRelative(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.startsWith("\\") ||
        value.contains("\\") || value.contains("..") || value.contains(":")) { return false }
    true
}

protected func conceptualSafeRoute(value: String): Bool {
    if (!conceptualSafeRelative(value) || value.contains("?") || value.contains("#")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    true
}

// Values are decoded from the shared TOML lexer's comment-stripped line: quoted
// strings keep escapes and '#' bytes, and legacy bare scalars stay accepted.
private func conceptualValue(code: String, equals: Int64): String {
    let decoded = tomlAssignmentString(code, equals)
    if (!decoded.invalid && decoded.value.isSome()) { return decoded.value.getOrThrow() }
    code[equals + 1..].trimAscii()
}

private func conceptualKey(code: String, equals: Int64): String {
    let raw = code[..equals].trimAscii()
    if (raw.startsWith("\"") || raw.startsWith("'")) {
        let decoded = decodeTomlString(raw, 0)
        if (!decoded.invalid && decoded.value.isSome() && decoded.nextOffset == raw.size) {
            return decoded.value.getOrThrow()
        }
    }
    raw
}

// One header shape for both forms; anything unbalanced is reported only when it
// names the docs namespace this reader owns.
private func conceptualHeader(code: String): ?(Bool, String) {
    let trimmed = code.trimAscii()
    let array = trimmed.startsWith("[[")
    let open: Int64 = if (array) { 2 } else { 1 }
    let closing = if (array) { "]]" } else { "]" }
    if (trimmed.size < open + closing.size || !trimmed.endsWith(closing)) { return None }
    if (trimmed.size == open + closing.size) { return None }
    Some((array, trimmed[open..trimmed.size - closing.size].trimAscii()))
}

private func conceptualHeaderRejected(code: String): Unit {
    let trimmed = code.trimAscii()
    if (trimmed.startsWith("[docs") || trimmed.startsWith("[[docs")) {
        throw IllegalArgumentException("malformed [docs] table header: " + trimmed)
    }
}

private func conceptualPathFromValue(code: String, equals: Int64, setting: String): String {
    let path = conceptualValue(code, equals)
    if (!conceptualSafeRelative(path) || !path.endsWith(".md")) {
        throw IllegalArgumentException("[docs] ${setting} must be a safe relative Markdown path")
    }
    path
}

// The shared lexer withholds every line that participates in a multiline
// string. Documentation tables do not support them, so a withheld line there is
// rejected instead of silently dropping a page registration.
private func conceptualMultilineValueRejected(rawLine: String, section: String): Unit {
    if (!section.startsWith("docs") || rawLine.trimAscii().isEmpty()) { return }
    throw IllegalArgumentException("[docs] settings must use single-line TOML values")
}

private func finishConceptualPage(config: ConceptualDocsConfig, current: ?ConceptualPageSpec): Unit {
    match (current) {
        case Some(page) =>
            if (page.source.isEmpty()) {
                throw IllegalArgumentException("[[docs.pages]] requires source")
            }
            if (!conceptualSafeRelative(page.source) || !page.source.endsWith(".md")) {
                throw IllegalArgumentException("[[docs.pages]] source must be a safe relative Markdown path")
            }
            if (!page.route.isEmpty() && !conceptualSafeRoute(page.route)) {
                throw IllegalArgumentException("[[docs.pages]] route must be a safe relative path")
            }
            config.pages.add(page)
        case None => ()
    }
}

private func conceptualPageAssignment(page: ConceptualPageSpec, key: String, code: String,
    equals: Int64): Unit {
    if (key == "source" || key == "path") {
        page.source = conceptualPathFromValue(code, equals, key)
    } else if (key == "route") {
        page.route = conceptualValue(code, equals)
    } else if (key == "title") {
        page.title = conceptualValue(code, equals)
    } else if (key == "id") {
        page.id = conceptualValue(code, equals)
    } else if (key == "language") {
        page.language = Some(public_model.documentationLanguage(conceptualValue(code, equals)))
    } else if (key == "kind") {
        page.kind = conceptualValue(code, equals)
    } else if (key == "package") {
        page.packageName = conceptualValue(code, equals)
    }
}

private func conceptualPackageName(value: String): String {
    if (!conceptualSafeRelative(value)) {
        throw IllegalArgumentException("[docs.packages] package name is unsafe")
    }
    value
}

private func conceptualAssignment(config: ConceptualDocsConfig, current: ?ConceptualPageSpec,
    section: String, code: String): Unit {
    let equals = match (tomlAssignmentEquals(code)) {
        case Some(value) => value
        case None => return
    }
    let key = conceptualKey(code, equals)
    if (section == "docs") {
        if (key == "index" || key == "index-source") {
            config.indexSource = conceptualPathFromValue(code, equals, key)
        }
    } else if (section == "docs.pages" && current.isSome()) {
        conceptualPageAssignment(current.getOrThrow(), key, code, equals)
    } else if (section == "docs.pages.sections" && current.isSome()) {
        current.getOrThrow().sections.add(public_model.DocumentationSection(
            conceptualKey(code, equals), conceptualValue(code, equals)))
    } else if (section == "docs.packages") {
        let source = conceptualPathFromValue(code, equals, "package overview")
        config.packageSources[conceptualPackageName(key)] = source
    } else if (section.startsWith("docs.packages.")) {
        let packageName = conceptualPackageName(section.removePrefix("docs.packages."))
        if (key == "source" || key == "path" || key == "overview") {
            config.packageSources[packageName] = conceptualPathFromValue(code, equals, key)
        }
    }
}

private func conceptualHeaderSection(config: ConceptualDocsConfig, current: ?ConceptualPageSpec,
    array: Bool, name: String): (String, ?ConceptualPageSpec) {
    // Section tables belong to the page that precedes them and never start one.
    if (name == "docs.pages.sections" && !array) {
        if (current.isSome()) { return ("docs.pages.sections", current) }
        return ("other", None)
    }
    finishConceptualPage(config, current)
    if (name == "docs.pages") {
        if (array) {
            config.enabled = true
            return ("docs.pages", Some(ConceptualPageSpec()))
        }
        return ("other", None)
    }
    if (name == "docs" || name == "docs.packages" || name.startsWith("docs.packages.")) {
        config.enabled = true
    }
    (name, None)
}

// The shared TOML lexer owns quoting, escapes and comments, so a header or value
// is classified from the same bytes every other reader sees. Tables this reader
// does not own stay untouched instead of being re-parsed with local rules.
protected func loadConceptualDocsConfig(projectRoot: String): ConceptualDocsConfig {
    let config = ConceptualDocsConfig()
    let configPath = Path(projectRoot).join("cjdoc.toml")
    if (!exists(configPath)) { return config }
    let text = readTextBounded(configPath, CONCEPTUAL_CONFIG_MAX_BYTES)
    let scanner = TomlLineScanner()
    var section = ""
    var current: ?ConceptualPageSpec = None
    for (rawLine in text.split("\n")) {
        let code = match (scanner.code(rawLine)) {
            case Some(value) => value
            case None =>
                conceptualMultilineValueRejected(rawLine, section)
                continue
        }
        if (code.isEmpty()) { continue }
        if (code.startsWith("[")) {
            let (array, name) = match (conceptualHeader(code)) {
                case Some(value) => value
                case None =>
                    conceptualHeaderRejected(code)
                    continue
            }
            let (nextSection, nextPage) = conceptualHeaderSection(config, current, array, name)
            section = nextSection
            current = nextPage
            continue
        }
        conceptualAssignment(config, current, section, code)
    }
    finishConceptualPage(config, current)
    config
}
