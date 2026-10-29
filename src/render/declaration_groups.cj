package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal func declarationGroup(symbol: SymbolDoc): ?DocTag {
    match (symbol.documentation) { case Some(value) => documentationGroup(value); case None => None }
}

internal func documentationGroup(comment: DocComment): ?DocTag {
    var result: ?DocTag = None
    for (tag in comment.tags where tag.name == "group") {
        if (result.isSome() || tag.subject.isEmpty() || tag.subject.size > 64 ||
            tag.description.trimAscii().isEmpty() || tag.description.size > 256 ||
            tag.description.contains("\n") || tag.description.contains("\r")) { return None }
        for (byte in tag.description.toArray()) { if (byte < 32 || byte == 127) { return None } }
        for (byte in tag.subject.toArray()) {
            if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) { return None }
        }
        result = Some(tag)
    }
    result
}

internal func declarationGroupKey(symbol: SymbolDoc): String {
    match (declarationGroup(symbol)) { case Some(tag) => tag.subject; case None => "" }
}

internal class DeclarationGroup {
    let key: String
    var title: String
    let symbols = ArrayList<SymbolDoc>()
    init(key: String, title: String) { this.key = key; this.title = title }
}

internal func declarationGroups(symbols: ArrayList<SymbolDoc>): ArrayList<DeclarationGroup> {
    let byKey = HashMap<String, DeclarationGroup>()
    let result = ArrayList<DeclarationGroup>()
    for (symbol in symbols) {
        let tag = declarationGroup(symbol)
        let key = match (tag) { case Some(value) => value.subject; case None => "" }
        let title = match (tag) { case Some(value) => value.description; case None => "" }
        let group = match (byKey.get(key)) {
            case Some(value) => value
            case None =>
                let value = DeclarationGroup(key, title)
                byKey[key] = value
                result.add(value)
                value
        }
        // Conflicting labels in decoded snapshots have a deterministic result;
        // plain labels never participate in identity or visibility decisions.
        if (title != group.title) { group.title = key }
        group.symbols.add(symbol)
    }
    sort(result, lessThan: { left, right =>
        if (left.key.isEmpty()) { false } else if (right.key.isEmpty()) { true }
        else { left.key < right.key }
    }, stable: true)
    result
}

internal func hasDeclarationGroups(groups: ArrayList<DeclarationGroup>): Bool {
    for (group in groups where !group.key.isEmpty()) { return true }
    false
}

internal func declarationGroupTitle(group: DeclarationGroup, locale: String): String {
    if (group.key.isEmpty()) { label(locale, "Other declarations", "其他声明") } else { group.title }
}

internal func appendDeclarationGroupMarkdown(out: RenderTextBuffer, group: DeclarationGroup,
    level: String, locale: String): Unit {
    out.append(level + " ")
    appendEscapedMarkdownText(out, declarationGroupTitle(group, locale))
    out.append("\n\n")
}

internal func appendDeclarationGroupMetadata(out: RenderTextBuffer, symbol: SymbolDoc,
    locale: String): Unit {
    if (let Some(tag) <- declarationGroup(symbol)) {
        out.append(label(locale, "API group: ", "接口分组："))
        appendMarkdownCodeSpan(out, tag.subject)
        out.append(" · ")
        appendEscapedMarkdownText(out, tag.description)
        out.append("\n\n")
    }
}

internal func appendDeclarationGroupBadge(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
    if (let Some(tag) <- declarationGroup(symbol)) {
        out.append("<p class=\"declaration-kind\" data-cjdoc-declaration-group=\"" +
            escapeHtml(tag.subject) + "\">" + escapeHtml(tag.description) + "</p>")
    }
}
