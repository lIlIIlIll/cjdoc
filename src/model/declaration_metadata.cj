package cjdoc.model

import std.collection.*
import std.sort.*

/**
 * A declaration tag ID is 1–64 ASCII letters, digits, `-` or `_`.
 *
 * The rule is case-sensitive on purpose: `stream` and `Stream` are two tags, and
 * a filter compares complete IDs. Nothing here folds case or a script, because a
 * tag ID is a stable author-declared identity, not a display name. This is the
 * single published spelling of that rule; every producer, adapter and renderer
 * asks it instead of restating the alphabet.
 */
public func isDeclarationTagId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_') { continue }
        return false
    }
    true
}

private func declarationTagIdLessThan(left: String, right: String): Bool {
    var index: Int64 = 0
    while (index < left.size && index < right.size) {
        if (left[index] != right[index]) { return left[index] < right[index] }
        index++
    }
    left.size < right.size
}

protected func isSharedDeclarationMetadataTag(tag: DocTag): Bool {
    tag.directives.isEmpty() &&
        tag.fieldId.isEmpty() && tag.translationState.isEmpty() &&
        tag.contentLanguage.isNone() && tag.referenceState == "unavailable" &&
        tag.targetSymbolId.isNone() && tag.exampleMarkdown.isNone() &&
        tag.descriptionMarkdown.isNone() && tag.navigation.isNone()
}

protected func canonicalDocumentationGroupTag(comment: DocComment): ?DocTag {
    var selected: ?DocTag = None
    for (tag in comment.tags where tag.name == "group") {
        if (selected.isSome() || !isDeclarationTagId(tag.subject) ||
            !isSharedDeclarationMetadataTag(tag)) { return None }
        if (!tag.description.isEmpty()) {
            if (tag.description.trimAscii().isEmpty() || tag.description.size > 256) { return None }
            for (index in 0..tag.description.size) {
                let byte = tag.description[index]
                if (byte < 32 || byte == 127) { return None }
            }
        }
        selected = Some(tag)
    }
    selected
}

private func isDeclarationMetadataTag(tag: DocTag): Bool {
    tag.name == "tag" && isDeclarationTagId(tag.subject) &&
        tag.description.isEmpty() && isSharedDeclarationMetadataTag(tag)
}

/**
 * Return the effective classification IDs carried by a captured comment.
 *
 * Invalid or translated/behavioral tag records are excluded. The returned set
 * is case-sensitive, unique and sorted by ASCII byte order; source text and the
 * comment's original tag order are left untouched.
 */
public func documentationTagIds(comment: ?DocComment): Array<String> {
    let value = match (comment) {
        case Some(comment) => comment
        case None => return []
    }
    let seen = HashSet<String>()
    let ids = ArrayList<String>()
    for (tag in value.tags) {
        if (!isDeclarationMetadataTag(tag) || !seen.add(tag.subject)) { continue }
        ids.add(tag.subject)
    }
    sort(ids, lessThan: { left, right => declarationTagIdLessThan(left, right) })
    ids.toArray()
}
