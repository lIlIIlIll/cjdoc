protected package cjdoc.render.publication

import std.collection.*
import yjson.*

private func publicationSourceKey(moduleId: String, path: String): String {
    "${moduleId}\n${path}"
}

private func publicationRememberSource(keys: HashSet<String>, moduleId: String,
    sourceNode: JsonNode): Unit {
    let path = publicationText(sourceNode, "path")
    if (!moduleId.isEmpty() && !path.isEmpty()) {
        let _ = keys.add(publicationSourceKey(moduleId, path))
    }
}

private func publicationRememberUnboundSource(root: JsonNode,
    keys: HashSet<String>, sourceNode: JsonNode): Unit {
    let path = publicationText(sourceNode, "path")
    if (path.isEmpty()) { return }
    var moduleId = ""
    var found = false
    for (file in publicationElements(root, "files")) {
        if (publicationText(file, "path") != path) { continue }
        let candidate = publicationText(file, "moduleId")
        if (candidate.isEmpty() || (found && candidate != moduleId)) { return }
        moduleId = candidate
        found = true
    }
    if (found) { let _ = keys.add(publicationSourceKey(moduleId, path)) }
}

// Tag and localized field ranges remain serialized source facts. The strict
// Doc IR validator ties them to their declaration's source file; recording them
// explicitly keeps this retention pass aligned with the published payload.

private func publicationRememberCommentSources(keys: HashSet<String>, moduleId: String,
    comment: JsonNode): Unit {
    for (fieldName in ["tags", "localizedTexts"]) {
        for (field in publicationElements(comment, fieldName)) {
            match (publicationObject(field)) {
                case Some(object) =>
                    match (object.get("source")) {
                        case Some(source) => publicationRememberSource(keys, moduleId, source)
                        case None => ()
                    }
                case None => ()
            }
        }
    }
}

private func publicationProjectPackageSourceFiles(root: JsonNode,
    retainedFileKeys: HashSet<String>): Unit {
    for (pkg in publicationElements(root, "packages")) {
        let moduleId = publicationText(pkg, "moduleId")
        let sourceFiles = ArrayList<JsonNode>()
        for (sourcePath in publicationElements(pkg, "sourceFiles")) {
            if (sourcePath.kind() == JsonKind.String &&
                retainedFileKeys.contains(publicationSourceKey(moduleId, sourcePath.asString()))) {
                sourceFiles.add(sourcePath)
            }
        }
        publicationReplaceArray(pkg, "sourceFiles", sourceFiles)
    }
}

protected func publicationProjectFileProvenance(root: JsonNode, redact: Bool): Unit {
    let retainedKeys = HashSet<String>()
    let moduleBySymbol = HashMap<String, String>()
    for (declaration in publicationElements(root, "declarations")) {
        let moduleId = publicationText(declaration, "moduleId")
        let symbolId = publicationText(declaration, "id")
        if (!symbolId.isEmpty()) { moduleBySymbol[symbolId] = moduleId }
        publicationRememberSource(retainedKeys, moduleId,
            declaration.asObject().get("source").getOrThrow())
        match (declaration.asObject().get("documentation")) {
            case Some(comment) => publicationRememberCommentSources(retainedKeys, moduleId, comment)
            case None => ()
        }
    }
    for (pkg in publicationElements(root, "packages")) {
        let moduleId = publicationText(pkg, "moduleId")
        for (reExport in publicationElements(pkg, "reExports")) {
            publicationRememberSource(retainedKeys, moduleId,
                reExport.asObject().get("source").getOrThrow())
        }
    }
    for (diagnostic in publicationElements(root, "diagnostics")) {
        let symbolId = publicationText(diagnostic, "symbolId")
        if (symbolId.isEmpty()) {
            if (!redact) {
                publicationRememberUnboundSource(root, retainedKeys,
                    diagnostic.asObject().get("source").getOrThrow())
            }
        } else {
            match (moduleBySymbol.get(symbolId)) {
                case Some(moduleId) =>
                    publicationRememberSource(retainedKeys, moduleId,
                        diagnostic.asObject().get("source").getOrThrow())
                case None => ()
            }
        }
    }
    if (!redact) {
        for (key in ["orphanDocComments", "unsupportedDeclarations", "macroInvocations"]) {
            for (record in publicationElements(root, key)) {
                publicationRememberUnboundSource(root, retainedKeys,
                    record.asObject().get("source").getOrThrow())
            }
        }
    }
    let retainedFiles = ArrayList<JsonNode>()
    let retainedFileKeys = HashSet<String>()
    for (file in publicationElements(root, "files")) {
        let moduleId = publicationText(file, "moduleId")
        let path = publicationText(file, "path")
        let key = publicationSourceKey(moduleId, path)
        if (retainedKeys.contains(key)) {
            retainedFiles.add(file)
            let _ = retainedFileKeys.add(key)
        }
    }
    publicationReplaceArray(root, "files", retainedFiles)
    publicationProjectPackageSourceFiles(root, retainedFileKeys)
}

