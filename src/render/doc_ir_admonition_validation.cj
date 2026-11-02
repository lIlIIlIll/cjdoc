package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func validateAdmonitionWrapper(tree: MarkdownNode, level: String, path: String): Unit {
    if (tree.kind != "document" || tree.children.size != 1) {
        domainFail(path, "admonition text requires exactly one captured wrapper")
    }
    let block = tree.children[0]
    if (block.kind != "admonition" || block.metadata.isNone() ||
        block.metadata.getOrThrow().admonitionLevel != Some(level) ||
        block.children.isEmpty() || !block.literal.isEmpty()) {
        domainFail(path, "admonition wrapper does not match the author level")
    }
}

private func validateAdmonitionIdentity(owner: String, level: String, entryId: ?String,
    fieldId: String, path: String): Unit {
    if (let Some(id) <- entryId) {
        if (!validReplayAuthorEntryId(id)) { domainFail(path, "invalid admonition author identity") }
        if (!fieldId.isEmpty() && fieldId != owner + ":doc:" + level + ":author-" + id) {
            domainFail(path, "admonition field identity does not match owner/level/author")
        }
    } else if (!fieldId.isEmpty()) {
        domainFail(path, "admonition field identity requires an author identity")
    }
}

// IDs share one namespace across all three levels. Retained conflict groups
// are legal partial captures, but none of their variants may claim pairing.
internal func validateReplayAdmonitionEntries(declaration: SymbolDoc, comment: DocComment): Unit {
    let levels = HashMap<String, String>()
    let languages = HashSet<String>()
    let conflicts = HashSet<String>()
    if (comment.localizationScope == "admonitions" && comment.defaultLanguage.isSome()) {
        domainFail("$.documentation.defaultLanguage", "admonitions-only scope has no comment default language")
    }
    for (text in comment.localizedTexts) {
        if (!isAdmonitionLevel(text.kind)) {
            if (comment.localizationScope == "admonitions") {
                domainFail("$.documentation.localizedTexts", "admonitions-only scope contains another field kind")
            }
            continue
        }
        if (let Some(id) <- text.entryId) {
            match (levels.get(id)) {
                case Some(previous) => if (previous != text.kind) { let _ = conflicts.add(id) }
                case None => levels[id] = text.kind
            }
            let languageKey = compositeKey(id, text.language.getOrDefault({ => "unknown" }))
            if (!languages.add(languageKey)) { let _ = conflicts.add(id) }
        }
    }
    for (text in comment.localizedTexts where isAdmonitionLevel(text.kind)) {
        let path = "$.documentation.localizedTexts"
        validateAdmonitionIdentity(declaration.id, text.kind, text.entryId, text.fieldId, path)
        let conflicting = match (text.entryId) {
            case Some(id) => conflicts.contains(id)
            case None => false
        }
        if (text.state == "conflict" ||
            (conflicting && (!text.fieldId.isEmpty() ||
                (text.state != "unpaired" && text.state != "invalid")))) {
            domainFail(path, "conflicting admonition author identities must remain unpaired")
        }
        if (text.state == "unpaired" || text.state == "invalid") {
            if (!text.fieldId.isEmpty()) { domainFail(path, "independent admonition cannot retain a field identity") }
        } else if (text.fieldId.isEmpty()) {
            domainFail(path, "paired admonition requires an author field identity")
        }
        if (text.state == "empty" || text.state == "invalid") {
            if (text.markdown.kind != "document" || !text.markdown.children.isEmpty()) {
                domainFail(path, "empty or invalid admonition must retain an empty document")
            }
        } else {
            validateAdmonitionWrapper(text.markdown, text.kind, path + ".markdown")
        }
    }
    let visibleVariants = HashSet<String>()
    for (tag in comment.tags where isAdmonitionLevel(tag.name)) {
        let path = "$.documentation.tags"
        validateAdmonitionIdentity(declaration.id, tag.name, tag.entryId, tag.fieldId, path)
        if (tag.fieldId.isEmpty() && tag.translationState != "unpaired") {
            domainFail(path, "independent admonition must retain unpaired translation state")
        }
        if (tag.descriptionMarkdown.isNone()) { domainFail(path, "visible admonition requires captured Markdown") }
        validateAdmonitionWrapper(tag.descriptionMarkdown.getOrThrow(), tag.name, path + ".descriptionMarkdown")
        if (let Some(id) <- tag.entryId) {
            if (conflicts.contains(id) && !tag.fieldId.isEmpty()) {
                domainFail(path, "conflicting admonition tag cannot claim pairing")
            }
        }
        if (!tag.fieldId.isEmpty()) {
            let key = compositeKey(tag.fieldId, tag.contentLanguage.getOrDefault({ => "unknown" }))
            if (!visibleVariants.add(key)) { domainFail(path, "duplicate selected admonition language variant") }
        }
    }
}
