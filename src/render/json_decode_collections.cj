package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func decodeSymbol(node: JsonNode, path: String): SymbolDoc {
    let value = strictObject(node, path, ["id", "kind", "name", "qualifiedName", "packageName", "moduleId",
        "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations",
        "typeRelationships", "symbolRelationships", "documentation", "source", "headerSpelling",
        "sourceApiSignature", "semantic", "origin", "enumNonExhaustive", "signatureHighlight"])
    let parameters = ArrayList<ParameterDoc>()
    var index: Int64 = 0
    for (parameter in jsonArrayValues(arrayAt(value, "parameters", path))) {
        parameters.add(decodeParameter(parameter, "${path}.parameters[${index}]"))
        index++
    }
    let typeRelationships = ArrayList<TypeRelationship>()
    index = 0
    for (relationship in jsonArrayValues(arrayAt(value, "typeRelationships", path))) {
        typeRelationships.add(decodeTypeRelationship(relationship,
            "${path}.typeRelationships[${index}]"))
        index++
    }
    let symbolRelationships = ArrayList<SymbolRelationship>()
    index = 0
    for (relationship in jsonArrayValues(arrayAt(value, "symbolRelationships", path))) {
        symbolRelationships.add(decodeSymbolRelationship(relationship,
            "${path}.symbolRelationships[${index}]"))
        index++
    }
    let returnNode = required(value, "returnType", path)
    let returnType: ?TypeRef = if (returnNode.isNull) { None }
        else { Some(decodeTypeRef(returnNode, "${path}.returnType", 0)) }
    let documentationNode = required(value, "documentation", path)
    let documentation: ?DocComment = if (documentationNode.isNull) { None }
        else { Some(decodeComment(documentationNode, "${path}.documentation")) }
    let semantic = strictObject(required(value, "semantic", path), "${path}.semantic",
        ["state", "provider", "canonicalSignature"])
    let origin = strictObject(required(value, "origin", path), "${path}.origin",
        ["kind", "macroSymbolId"])
    SymbolDoc(stringAt(value, "id", path), stringAt(value, "kind", path),
        stringAt(value, "name", path), stringAt(value, "qualifiedName", path),
        stringAt(value, "packageName", path), stringAt(value, "moduleId", path),
        stringAt(value, "visibility", path),
        decodeRange(required(value, "source", path), "${path}.source"),
        stringAt(value, "headerSpelling", path),
        SemanticInfo(stringAt(semantic, "state", "${path}.semantic"),
            stringAt(semantic, "provider", "${path}.semantic"),
            canonicalSignature: nullableStringAt(semantic, "canonicalSignature", "${path}.semantic")),
        nullableBoolAt(value, "enumNonExhaustive", path),
        ownerId: nullableStringAt(value, "ownerId", path),
        genericParameters: stringsAt(value, "genericParameters", path),
        parameters: parameters.toArray(), returnType: returnType,
        annotations: decodeAnnotations(value, path),
        typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: documentation,
        origin: DeclarationOrigin(kind: stringAt(origin, "kind", "${path}.origin"),
            macroSymbolId: nullableStringAt(origin, "macroSymbolId", "${path}.origin")),
        sourceApiSignature: decodeSourceApiSignature(required(value, "sourceApiSignature", path),
            "${path}.sourceApiSignature"),
        signatureHighlight: optionalCodeHighlightAt(value, "signatureHighlight", path))
}

internal func decodeModules(root: JsonObject): Array<ModuleDoc> {
    let result = ArrayList<ModuleDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "modules", "$"))) {
        let path = "$.modules[${index}]"
        let value = strictObject(node, path, ["id", "name", "role", "sourcePrefix", "organization",
            "repositoryPath", "packageNames", "dependencyIds"])
        result.add(ModuleDoc(stringAt(value, "id", path), stringAt(value, "name", path),
            stringAt(value, "role", path), stringAt(value, "sourcePrefix", path),
            packageNames: stringsAt(value, "packageNames", path),
            dependencyIds: stringsAt(value, "dependencyIds", path),
            organization: nullableStringAt(value, "organization", path),
            repositoryPath: nullableStringAt(value, "repositoryPath", path)))
        index++
    }
    result.toArray()
}

internal func decodePackages(root: JsonObject): Array<PackageDoc> {
    let result = ArrayList<PackageDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "packages", "$"))) {
        let path = "$.packages[${index}]"
        let value = strictObject(node, path, ["name", "moduleId", "sourceFiles", "symbolIds", "reExports"])
        let reExports = ArrayList<ReExportDoc>()
        var reExportIndex: Int64 = 0
        for (reExportNode in jsonArrayValues(arrayAt(value, "reExports", path))) {
            let reExportPath = "${path}.reExports[${reExportIndex}]"
            let reExport = strictObject(reExportNode, reExportPath,
                ["id", "kind", "organization", "targetPackageName", "targetModuleId",
                    "alias", "state", "source", "bindings"])
            let bindings = ArrayList<ReExportBinding>()
            var bindingIndex: Int64 = 0
            for (bindingNode in jsonArrayValues(arrayAt(reExport, "bindings", reExportPath))) {
                let bindingPath = "${reExportPath}.bindings[${bindingIndex}]"
                let binding = strictObject(bindingNode, bindingPath, ["exposedName", "targetSymbolIds"])
                bindings.add(ReExportBinding(stringAt(binding, "exposedName", bindingPath),
                    targetSymbolIds: stringsAt(binding, "targetSymbolIds", bindingPath)))
                bindingIndex++
            }
            reExports.add(ReExportDoc(stringAt(reExport, "id", reExportPath),
                stringAt(reExport, "kind", reExportPath),
                stringAt(reExport, "targetPackageName", reExportPath),
                stringAt(reExport, "state", reExportPath),
                decodeRange(required(reExport, "source", reExportPath), "${reExportPath}.source"),
                organization: nullableStringAt(reExport, "organization", reExportPath),
                targetModuleId: nullableStringAt(reExport, "targetModuleId", reExportPath),
                alias: nullableStringAt(reExport, "alias", reExportPath),
                bindings: bindings.toArray()))
            reExportIndex++
        }
        result.add(PackageDoc(stringAt(value, "name", path), stringAt(value, "moduleId", path),
            sourceFiles: stringsAt(value, "sourceFiles", path),
            symbolIds: stringsAt(value, "symbolIds", path), reExports: reExports.toArray()))
        index++
    }
    result.toArray()
}


internal func decodeFiles(root: JsonObject): Array<FileDoc> {
    let result = ArrayList<FileDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "files", "$" ))) {
        let path = "$.files[${index}]"
        let value = strictObject(node, path, ["path", "moduleId", "packageName"])
        result.add(FileDoc(stringAt(value, "path", path), stringAt(value, "moduleId", path),
            stringAt(value, "packageName", path)))
        index++
    }
    result.toArray()
}

internal func decodeProviders(root: JsonObject): Array<ProviderInfo> {
    let result = ArrayList<ProviderInfo>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "providers", "$"))) {
        let path = "$.providers[${index}]"
        let value = strictObject(node, path, ["name", "version", "moduleId", "state", "capabilities"])
        result.add(ProviderInfo(stringAt(value, "name", path), stringAt(value, "version", path),
            stringAt(value, "moduleId", path), stringAt(value, "state", path),
            decodeCapabilities(required(value, "capabilities", path), "${path}.capabilities")))
        index++
    }
    result.toArray()
}

internal func decodeDeclarations(root: JsonObject): Array<SymbolDoc> {
    let result = ArrayList<SymbolDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "declarations", "$"))) {
        result.add(decodeSymbol(node, "$.declarations[${index}]"))
        index++
    }
    result.toArray()
}

internal func decodeAssets(root: JsonObject): Array<AssetDoc> {
    let result = ArrayList<AssetDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "assets", "$"))) {
        let path = "$.assets[${index}]"
        let value = strictObject(node, path, ["id", "mediaType", "sourcePath", "base64"])
        result.add(AssetDoc(stringAt(value, "id", path), stringAt(value, "mediaType", path),
            stringAt(value, "sourcePath", path), stringAt(value, "base64", path)))
        index++
    }
    result.toArray()
}

internal func decodeDiagnostics(root: JsonObject): Array<Diagnostic> {
    let result = ArrayList<Diagnostic>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "diagnostics", "$"))) {
        let path = "$.diagnostics[${index}]"
        let value = strictObject(node, path, ["severity", "code", "message", "source", "symbolId"])
        let sourceNode = required(value, "source", path)
        result.add(Diagnostic(stringAt(value, "severity", path), stringAt(value, "code", path),
            stringAt(value, "message", path),
            source: if (sourceNode.isNull) { None }
                else { Some(decodeRange(sourceNode, "${path}.source")) },
            symbolId: nullableStringAt(value, "symbolId", path)))
        index++
    }
    result.toArray()
}


internal func decodeOrphans(root: JsonObject): Array<OrphanDocComment> {
    let result = ArrayList<OrphanDocComment>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "orphanDocComments", "$" ))) {
        let path = "$.orphanDocComments[${index}]"
        let value = strictObject(node, path, ["rawText", "source"])
        result.add(OrphanDocComment(stringAt(value, "rawText", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeMacros(root: JsonObject): Array<MacroInvocation> {
    let result = ArrayList<MacroInvocation>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "macroInvocations", "$" ))) {
        let path = "$.macroInvocations[${index}]"
        let value = strictObject(node, path, ["name", "source"])
        result.add(MacroInvocation(stringAt(value, "name", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeUnsupported(root: JsonObject): Array<UnsupportedDeclaration> {
    let result = ArrayList<UnsupportedDeclaration>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "unsupportedDeclarations", "$" ))) {
        let path = "$.unsupportedDeclarations[${index}]"
        let value = strictObject(node, path, ["kind", "name", "reason", "source"])
        result.add(UnsupportedDeclaration(stringAt(value, "kind", path), stringAt(value, "name", path),
            stringAt(value, "reason", path), decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeUnbound(root: JsonObject): Array<UnboundSemanticDeclaration> {
    let result = ArrayList<UnboundSemanticDeclaration>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(root, "unboundSemanticDeclarations", "$" ))) {
        let path = "$.unboundSemanticDeclarations[${index}]"
        let value = strictObject(node, path, ["provider", "display", "reason"])
        result.add(UnboundSemanticDeclaration(stringAt(value, "provider", path),
            stringAt(value, "display", path), stringAt(value, "reason", path)))
        index++
    }
    result.toArray()
}
