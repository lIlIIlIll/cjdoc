package cjdoc

import std.collection.*
import cjdoc.model as api_model

private func validDeclarationGroupId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) { return false }
    }
    true
}

private func validDeclarationGroupTitle(value: String): Bool {
    if (value.trimAscii().isEmpty() || value.size > 256) { return false }
    for (byte in value.toArray()) { if (byte < 32 || byte == 127) { return false } }
    true
}

// Invalid metadata never changes symbol visibility or becomes a heading.
internal func validateDeclarationGroup(documentation: DocumentationSet, symbol: SymbolDoc,
    comment: DocComment): Unit {
    let groups = ArrayList<DocTag>()
    for (tag in comment.contracts where tag.name == "group") { groups.add(tag) }
    if (groups.isEmpty()) { return }
    let first = groups[0]
    if (groups.size == 1 && validDeclarationGroupId(first.subject)) {
        if (validDeclarationGroupTitle(first.description)) { return }
        if (first.description.isEmpty() &&
            hasBoundDeclarationGroup(documentation.metadata, symbol, first.subject)) { return }
        if (first.description.isEmpty()) {
            documentation.diagnostics.add(Diagnostic("error", "CJDOC3137",
                "@group shorthand requires a matching metadata.groups definition for its declaration container",
                source: comment.commentSource, symbolId: Some(symbol.id)))
            return
        }
    }
    documentation.diagnostics.add(Diagnostic("error", "CJDOC3130",
        "@group requires one ASCII identifier (1–64 letters, digits, '-' or '_') and a single-line title (1–256 bytes)",
        source: comment.commentSource, symbolId: Some(symbol.id)))
}

private func hasBoundDeclarationGroup(metadata: api_model.DocumentationMetadata, symbol: SymbolDoc,
    groupId: String): Bool {
    for (group in metadata.groups) {
        if (group.moduleId == symbol.moduleId && group.packageName == symbol.packageName &&
            group.ownerId == symbol.ownerId && group.id == groupId) { return true }
    }
    false
}

internal func validateDeclarationGroupTitles(documentation: DocumentationSet): Unit {
    let titles = HashMap<String, String>()
    for (symbol in documentation.symbols) {
        let comment = match (symbol.documentation) { case Some(value) => value; case None => continue }
        let groups = ArrayList<DocTag>()
        for (tag in comment.contracts where tag.name == "group") { groups.add(tag) }
        if (groups.size != 1) { continue }
        let tag = groups[0]
        if (!validDeclarationGroupId(tag.subject) || !validDeclarationGroupTitle(tag.description)) { continue }
        let key = symbol.moduleId + "\u{0}" + symbol.packageName + "\u{0}" +
            symbol.ownerId.getOrDefault({ => "" }) + "\u{0}" + tag.subject
        match (titles.get(key)) {
            case Some(title) => if (title != tag.description) {
                documentation.diagnostics.add(Diagnostic("error", "CJDOC3131",
                    "@group identifier has conflicting titles in the same declaration container",
                    source: comment.commentSource, symbolId: Some(symbol.id)))
            }
            case None => titles[key] = tag.description
        }
    }
}
