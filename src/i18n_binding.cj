package cjdoc

import std.collection.*

private func localizedRepeatableKey(symbol: SymbolDoc, item: LocalizedCommentItem): String {
    let tag = item.tag
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

internal func bindLocalizedDocumentationItems(documentation: DocumentationSet): Unit {
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            let counts = HashMap<String, Int64>()
            let languages = HashMap<String, HashSet<String>>()
            let explicitSubjects = HashMap<String, String>()
            let explicitTargets = HashMap<String, String>()
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
                if (item.entryId.isSome()) {
                    match (explicitSubjects.get(key)) {
                        case Some(previous) => if (previous != item.tag.subject) { let _ = incompatibleIds.add(key) }
                        case None => explicitSubjects[key] = item.tag.subject
                    }
                    if (let Some(target) <- item.tag.targetSymbolId) {
                        match (explicitTargets.get(key)) {
                            case Some(previous) => if (previous != target) { let _ = incompatibleIds.add(key) }
                            case None => explicitTargets[key] = target
                        }
                    }
                }
                item.fieldId = key
                let group = if (key.isEmpty()) { item.tag.name } else { key }
                let language = item.language.getOrDefault({ => "unknown" })
                let identity = group + ":" + language
                counts[identity] = counts.get(identity).getOrDefault({ => 0 }) + 1
                if (!languages.contains(group)) { languages[group] = HashSet<String>() }
                let _ = languages[group].add(language)
            }
            let reported = HashSet<String>()
            let reportedInvalidId = HashSet<String>()
            for (item in comment.languageItems) {
                if (["summary", "description", "param", "return", "deprecated"].contains(item.tag.name)) { continue }
                let group = if (item.fieldId.isEmpty()) { item.tag.name } else { item.fieldId }
                var ambiguous = item.fieldId.isEmpty() || incompatibleIds.contains(group)
                var duplicate = false
                for (language in languages[group]) {
                    if (counts[group + ":" + language] > 1) { ambiguous = true; duplicate = true }
                }
                if (item.entryId.isSome() && (duplicate || incompatibleIds.contains(group)) &&
                    reportedInvalidId.add(group)) {
                    documentation.diagnostics.add(Diagnostic("error", "CJDOC3114",
                        "explicit @throws id '" + item.entryId.getOrThrow() +
                        "' is reused for different exceptions or repeated within a language",
                        source: item.source, symbolId: Some(symbol.id)))
                }
                if (!ambiguous || item.state == "invalid" || item.state == "conflict") { continue }
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
