protected package cjdoc.render.codec

import cjdoc.model.*
import std.collection.*

internal func validateDocumentationDeclarations(documentation: DocumentationSet,
    packageKeys: HashSet<String>, fileKeys: HashSet<String>,
    providersByKey: HashMap<String, ProviderInfo>, navigationEvidence: NavigationEvidence):
    HashMap<String, SymbolDoc> {
    let byId = HashMap<String, SymbolDoc>()
    var index: Int64 = 0
    for (declaration in documentation.declarations) {
        if (!declaration.id.startsWith(symbolIdModulePrefix(declaration.moduleId))) {
            domainFail("$.declarations[${index}].id", "SymbolId '${declaration.id}' does not " +
                "encode owning module '${declaration.moduleId}'")
        }
        if (byId.contains(declaration.id)) {
            domainFail("$.declarations[${index}].id", "duplicate SymbolId '${declaration.id}'")
        }
        byId[declaration.id] = declaration
        if (declaration.kind != "enum" && declaration.enumNonExhaustive.isSome()) {
            domainFail("$.declarations[${index}].enumNonExhaustive",
                "only enum declarations may carry non-exhaustive state")
        }
        if (!packageKeys.contains(compositeKey(declaration.moduleId, declaration.packageName))) {
            domainFail("$.declarations[${index}]", "unknown module/package")
        }
        if (!fileKeys.contains(compositeKey(compositeKey(declaration.moduleId,
            declaration.packageName), declaration.source.path))) {
            domainFail("$.declarations[${index}].source", "source file is not owned by declaration module/package")
        }
        validateRange(declaration.source, "$.declarations[${index}].source")
        for (parameter in declaration.parameters) {
            validateType(parameter.typeRef, "$.declarations[${index}].parameters", 0,
                providersByKey, declaration.moduleId, navigationEvidence)
        }
        match (declaration.returnType) {
            case Some(typeRef) => validateType(typeRef, "$.declarations[${index}].returnType", 0,
                providersByKey, declaration.moduleId, navigationEvidence)
            case None => ()
        }
        for (relationship in declaration.typeRelationships) {
            validateType(relationship.target, "$.declarations[${index}].typeRelationships", 0,
                providersByKey, declaration.moduleId, navigationEvidence)
        }
        var annotationIndex: Int64 = 0
        for (annotation in declaration.annotations) {
            if (annotation.provenance == "provider") {
                let provider = annotation.provider.getOrThrow()
                if (!providerSupportsAnnotations(providersByKey, declaration.moduleId, provider)) {
                    domainFail("$.declarations[${index}].annotations[${annotationIndex}]",
                        "provider annotation lacks a matching module capability")
                }
            }
            annotationIndex++
        }
        match (providerFor(providersByKey, declaration.moduleId,
            declaration.semantic.provider)) {
            case Some(provider) =>
                if (provider.state == "unavailable" &&
                    (declaration.semantic.state != "unavailable" ||
                    declaration.semantic.canonicalSignature.isSome())) {
                    domainFail("$.declarations[${index}].semantic",
                        "unavailable provider cannot supply declaration semantics or canonical data")
                }
                match (declaration.semantic.canonicalSignature) {
                case Some(canonicalSignature) =>
                    if (canonicalSignature.trimAscii().isEmpty()) {
                        domainFail("$.declarations[${index}].semantic.canonicalSignature",
                            "canonical signature must not be blank")
                    }
                    if (!provider.capabilities.canonicalSignatures) {
                        domainFail("$.declarations[${index}].semantic.canonicalSignature",
                            "canonical signature lacks provider capability")
                    }
                case None => ()
                }
            case None =>
                domainFail("$.declarations[${index}].semantic.provider",
                    "provider is not declared for the module")
        }
        match (declaration.documentation) {
            case Some(comment) =>
                if (comment.markdown.kind != "document") {
                    domainFail("$.declarations[${index}].documentation.markdown",
                        "documentation Markdown root must be a document")
                }
                validateMarkdown(comment.markdown, "$.declarations[${index}].documentation.markdown", 0,
                    declaration.moduleId, navigationEvidence)
            case None => ()
        }
        index++
    }
    byId
}

internal func validateDocumentationDeclarationReferences(documentation: DocumentationSet,
    byId: HashMap<String, SymbolDoc>, providersByKey: HashMap<String, ProviderInfo>,
    navigationEvidence: NavigationEvidence): Unit {
    var index: Int64 = 0
    for (declaration in documentation.declarations) {
        match (declaration.ownerId) {
            case Some(ownerId) => match (byId.get(ownerId)) {
                case Some(owner) =>
                    if (!isDocIrContainerKind(owner.kind)) {
                        domainFail("$.declarations[${index}].ownerId",
                            "owner must reference a container declaration")
                    }
                    if (owner.moduleId != declaration.moduleId ||
                        owner.packageName != declaration.packageName) {
                        domainFail("$.declarations[${index}].ownerId",
                            "owner crosses module/package boundary")
                    }
                case None => domainFail("$.declarations[${index}].ownerId", "unknown owner")
            }
            case None => ()
        }
        match (declaration.origin.macroSymbolId) {
            case Some(targetId) => if (!byId.contains(targetId)) {
                domainFail("$.declarations[${index}].origin.macroSymbolId", "unknown macro SymbolId")
            }
            case None => ()
        }
        var relationshipIndex: Int64 = 0
        for (relationship in declaration.symbolRelationships) {
            let relationshipPath =
                "$.declarations[${index}].symbolRelationships[${relationshipIndex}]"
            if ((relationship.state != "unavailable" || relationship.targetSymbolId.isSome()) &&
                !providerSupportsRelationships(providersByKey, declaration.moduleId,
                    declaration.semantic.provider)) {
                domainFail(relationshipPath,
                    "symbol relationship lacks provider relationships capability")
            }
            match (relationship.targetSymbolId) {
                case Some(targetId) => if (!byId.contains(targetId)) {
                    domainFail(relationshipPath, "unknown target SymbolId")
                }
                case None => if (relationship.state == "resolved") {
                    domainFail(relationshipPath, "resolved target is missing")
                }
            }
            relationshipIndex++
        }
        if (let Some(comment) <- declaration.documentation) {
            validateReplayComment(declaration, comment, index, byId, navigationEvidence)
        }
        index++
    }
    validateOwnerDag(documentation.declarations, byId)
}

private func validateReplayComment(declaration: SymbolDoc, comment: DocComment, index: Int64,
    byId: HashMap<String, SymbolDoc>, navigationEvidence: NavigationEvidence): Unit {
    validateReplayThrowsEntries(declaration, comment)
    validateReplayAdmonitionEntries(declaration, comment)
    let validFields = HashSet<String>()
    for (text in comment.localizedTexts) {
        if (let Some(navigation) <- text.navigation) {
            navigationEvidence.validate(navigation, "$.documentation.localizedTexts.navigation", declaration.moduleId)
        }
        let paired = ["valid", "empty", "conflict"].contains(text.state)
        if (paired && text.fieldId.isEmpty()) {
            domainFail("$.documentation.localizedTexts.fieldId", "paired field identity is missing")
        }
        if (paired && ["summary", "description", "param", "return"].contains(text.kind)) {
            let subject = if (text.kind == "param") { text.subject } else { "" }
            if (text.fieldId != declaration.id + ":doc:" + text.kind + ":" + subject) {
                domainFail("$.documentation.localizedTexts.fieldId", "field identity does not match its selector")
            }
        }
        if (text.state == "valid" && text.kind == "param") {
            var knownParameter = false
            for (parameter in declaration.parameters) {
                // A positional payload may be addressed by its ordinal selector
                // or by the placeholder Doc IR stores for it.
                if (parameterMatchesSubject(declaration.kind, parameter.name, text.subject)) {
                    knownParameter = true
                    break
                }
            }
            if (!knownParameter) { domainFail("$.documentation.localizedTexts.subject", "unknown parameter") }
        }
        if (text.state == "valid" && !text.fieldId.isEmpty() &&
            !validFields.add(text.fieldId + ":" + text.language.getOrDefault({ => "unknown" }))) {
            domainFail("$.documentation.localizedTexts", "duplicate valid language field")
        }
        validateMarkdown(text.markdown, "$.declarations[${index}].documentation.localizedTexts.markdown", 0,
            declaration.moduleId, navigationEvidence)
        if (!text.fieldId.isEmpty() && !text.fieldId.startsWith(declaration.id + ":doc:" + text.kind + ":")) {
            domainFail("$.documentation.localizedTexts.fieldId", "field does not belong to declaration/kind")
        }
        if (let Some(source) <- text.source) {
            validateRange(source, "$.documentation.localizedTexts.source")
            if (source.path != declaration.source.path) {
                domainFail("$.documentation.localizedTexts.source", "field source must belong to declaration file")
            }
        }
        if (let Some(targetId) <- text.targetSymbolId) {
            if (["see", "throws"].contains(text.kind) && text.referenceState != "resolved") {
                domainFail("$.documentation.localizedTexts", "unresolved reference cannot carry a target")
            }
            if (!byId.contains(targetId)) { domainFail("$.documentation.localizedTexts", "unknown target SymbolId") }
        } else if (text.referenceState == "resolved") {
            domainFail("$.documentation.localizedTexts", "resolved target is missing")
        }
    }
    for (tag in comment.tags) {
        let tagPath = "$.declarations[${index}].documentation.tags"
        if (let Some(source) <- tag.source) {
            validateRange(source, tagPath + ".source")
            if (source.path != declaration.source.path) {
                domainFail(tagPath + ".source", "tag source must belong to declaration file")
            }
        }
        if (let Some(navigation) <- tag.navigation) {
            navigationEvidence.validate(navigation, tagPath + ".navigation", declaration.moduleId)
        }
        if (!tag.directives.isEmpty() && tag.name != "example") {
            domainFail(tagPath, "directives are only allowed on @example tags")
        }
        validateExampleMarkdown(tag, "${tagPath}.exampleMarkdown", declaration.moduleId, navigationEvidence)
        if (let Some(tree) <- tag.descriptionMarkdown) {
            validateMarkdown(tree, tagPath + ".descriptionMarkdown", 0, declaration.moduleId, navigationEvidence)
        }
        match (tag.targetSymbolId) {
            case Some(targetId) => if (!byId.contains(targetId)) {
                domainFail(tagPath, "unknown target SymbolId")
            }
            case None => if (tag.referenceState == "resolved") {
                domainFail(tagPath, "resolved target is missing")
            }
        }
    }
}

private func validateReplayThrowsEntries(declaration: SymbolDoc, comment: DocComment): Unit {
    let prefix = declaration.id + ":doc:throws:author-"
    let subjects = HashMap<String, String>()
    let targets = HashMap<String, String>()
    let languages = HashSet<String>()
    for (text in comment.localizedTexts) {
        if (text.kind != "throws" || !text.fieldId.startsWith(prefix)) { continue }
        let id = text.fieldId[prefix.size..]
        if (!validReplayAuthorEntryId(id)) {
            domainFail("$.documentation.localizedTexts.fieldId", "invalid explicit throws author identity")
        }
        if (text.state == "unpaired") {
            domainFail("$.documentation.localizedTexts.fieldId", "unpaired throws cannot retain an author identity")
        }
        // Invalid or conflicting author entries are kept for diagnostics, but
        // cannot establish a trusted equivalence or hide a readable condition.
        if (text.state == "invalid" || text.state == "conflict") { continue }
        match (subjects.get(text.fieldId)) {
            case Some(previous) => if (previous != text.subject) {
                domainFail("$.documentation.localizedTexts", "throws author identity has conflicting subjects")
            }
            case None => subjects[text.fieldId] = text.subject
        }
        // The producer compares resolved targets only when both are known.
        // Do not reject a legitimate paired fallback whose other target is absent.
        if (let Some(target) <- text.targetSymbolId) {
            match (targets.get(text.fieldId)) {
                case Some(previous) => if (previous != target) {
                    domainFail("$.documentation.localizedTexts", "throws author identity has conflicting targets")
                }
                case None => targets[text.fieldId] = target
            }
        }
        let languageKey = text.fieldId + ":" + text.language.getOrDefault({ => "unknown" })
        if (!languages.add(languageKey)) {
            domainFail("$.documentation.localizedTexts", "repeated throws author identity within a language")
        }
    }
}

