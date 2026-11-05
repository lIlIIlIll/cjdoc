package cjdoc

import std.collection.*

private func localizedRepeatableKey(symbol: SymbolDoc, item: LocalizedCommentItem): String {
    let tag = item.tag
    if (isAdmonitionKind(tag.name)) {
        if (let Some(id) <- item.entryId) { return symbol.id + ":doc:admonition-author:" + id }
        return ""
    }
    if (tag.name == "throws") {
        if (let Some(id) <- item.entryId) { return symbol.id + ":doc:throws:author-" + id }
    }
    if (tag.name == "see" || tag.name == "throws") {
        if (let Some(id) <- tag.targetSymbolId) { return symbol.id + ":doc:" + tag.name + ":" + id }
        return ""
    }
    if (tag.name == "example") { return "" }
    symbol.id + ":doc:" + tag.name + ":"
}

private func localizedFieldIdentity(symbol: SymbolDoc, item: LocalizedCommentItem): String {
    if (isAdmonitionKind(item.tag.name)) {
        if (let Some(id) <- item.entryId) {
            return symbol.id + ":doc:" + item.tag.name + ":author-" + id
        }
        return ""
    }
    localizedRepeatableKey(symbol, item)
}

internal func bindLocalizedDocumentationItems(documentation: DocumentationSet): Unit {
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            let counts = HashMap<String, Int64>()
            let languages = HashMap<String, HashSet<String>>()
            let explicitSubjects = HashMap<String, String>()
            let explicitTargets = HashMap<String, String>()
            let admonitionLevels = HashMap<String, String>()
            let incompatibleIds = HashSet<String>()
            for (item in comment.languageItems) {
                if (["see", "throws"].contains(item.tag.name) && item.tag.targetSymbolId.isNone()) {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC3109",
                        "language " + item.language.getOrDefault({ => "unknown" }) + ": @" + item.tag.name +
                        " target '" + item.tag.subject + "' has no unique local binding (" + item.tag.referenceState + ")",
                        source: item.source, symbolId: Some(symbol.id)))
                }
                if (["summary", "description", "param", "return", "deprecated"].contains(item.tag.name)) { continue }
                let key = localizedRepeatableKey(symbol, item)
                let group = if (key.isEmpty()) { item.tag.name } else { key }
                if (item.entryId.isSome()) {
                    if (isAdmonitionKind(item.tag.name)) {
                        match (admonitionLevels.get(group)) {
                            case Some(previous) => if (previous != item.tag.name) { let _ = incompatibleIds.add(group) }
                            case None => admonitionLevels[group] = item.tag.name
                        }
                    } else {
                        match (explicitSubjects.get(group)) {
                            case Some(previous) => if (previous != item.tag.subject) { let _ = incompatibleIds.add(group) }
                            case None => explicitSubjects[group] = item.tag.subject
                        }
                        if (let Some(target) <- item.tag.targetSymbolId) {
                            match (explicitTargets.get(group)) {
                                case Some(previous) => if (previous != target) { let _ = incompatibleIds.add(group) }
                                case None => explicitTargets[group] = target
                            }
                        }
                    }
                }
                item.fieldId = localizedFieldIdentity(symbol, item)
                let language = item.language.getOrDefault({ => "unknown" })
                let identity = group + ":" + language
                counts[identity] = counts.get(identity).getOrDefault({ => 0 }) + 1
                if (!languages.contains(group)) { languages[group] = HashSet<String>() }
                let _ = languages[group].add(language)
            }
            let reported = HashSet<String>()
            let reportedInvalidId = HashSet<String>()
            let reportedAdmonitionConflict = HashSet<String>()
            for (item in comment.languageItems) {
                if (["summary", "description", "param", "return", "deprecated"].contains(item.tag.name)) { continue }
                let key = localizedRepeatableKey(symbol, item)
                let group = if (key.isEmpty()) { item.tag.name } else { key }
                var ambiguous = item.fieldId.isEmpty() || incompatibleIds.contains(group)
                var duplicate = false
                for (language in languages[group]) {
                    if (counts[group + ":" + language] > 1) { ambiguous = true; duplicate = true }
                }
                if (isAdmonitionKind(item.tag.name) && item.entryId.isSome() &&
                    (duplicate || incompatibleIds.contains(group)) && reportedAdmonitionConflict.add(group)) {
                    documentation.diagnostics.add(Diagnostic("error", "CJDOC3118",
                        "admonition author id '" + item.entryId.getOrThrow() +
                        "' is repeated within a language or used across levels",
                        source: item.source, symbolId: Some(symbol.id)))
                }
                if (item.tag.name == "throws" && item.entryId.isSome() &&
                    (duplicate || incompatibleIds.contains(group)) && reportedInvalidId.add(group)) {
                    documentation.diagnostics.add(Diagnostic("error", "CJDOC3114",
                        "explicit @throws id '" + item.entryId.getOrThrow() +
                        "' is reused for different exceptions or repeated within a language",
                        source: item.source, symbolId: Some(symbol.id)))
                }
                if (!ambiguous || item.state == "invalid" || item.state == "conflict") { continue }
                if (isAdmonitionKind(item.tag.name)) {
                    item.fieldId = ""
                    item.state = if (item.tag.description.trimAscii().isEmpty()) { "invalid" } else { "unpaired" }
                    if (item.entryId.isNone() && languages[group].size > 1 && reported.add(group)) {
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC3107",
                            "@" + item.tag.name + " entries have no unique cross-language association; author text retained",
                            source: item.source, symbolId: Some(symbol.id)))
                    }
                    continue
                }
                item.state = "unpaired"; item.fieldId = ""
                if (item.entryId.isNone() && languages[group].size > 1 && reported.add(group)) {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC3107",
                        "@" + item.tag.name + " entries have no unique cross-language association; author text retained",
                        source: item.source, symbolId: Some(symbol.id)))
                }
            }
        }
    }
}

internal func hasLocalizedDocumentation(comment: DocComment, kind: String,
    subject!: ?String = None): Bool {
    for (item in comment.languageItems) {
        if (item.tag.name != kind || (subject.isSome() && item.tag.subject != subject.getOrThrow())) { continue }
        if ((item.state == "valid" || item.state == "unpaired") && !item.tag.description.trimAscii().isEmpty()) { return true }
    }
    false
}
