package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func decodeSymbol(node: JsonNode, path: String, legacyV6: Bool, legacy: Bool,
    modules: LegacyModuleIndex, legacyIds: HashMap<String, String>,
    assetReferences: HashMap<String, String>): SymbolDoc {
    let keys = if (legacyV6) { ["id", "kind", "name", "qualifiedName", "packageName",
        "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations",
        "typeRelationships", "symbolRelationships",
        "documentation", "source", "headerSpelling", "semantic", "origin"]
    } else if (legacy) {
        ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility",
            "genericParameters", "parameters", "returnType", "annotations", "typeRelationships",
            "symbolRelationships", "documentation", "source", "headerSpelling", "semantic", "origin"]
    } else {
        ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility",
            "genericParameters", "parameters", "returnType", "annotations", "typeRelationships",
            "symbolRelationships", "documentation", "source", "headerSpelling", "sourceApiSignature",
            "semantic", "origin", "enumNonExhaustive"]
    }
    let value = strictObject(node, path, keys)
    let parameters = ArrayList<ParameterDoc>()
    var index: Int64 = 0
    for (parameter in arrayAt(value, "parameters", path).values()) {
        parameters.add(decodeParameter(parameter, "${path}.parameters[${index}]")); index++
    }
    let typeRelationships = ArrayList<TypeRelationship>()
    index = 0
    for (relationship in arrayAt(value, "typeRelationships", path).values()) {
        typeRelationships.add(decodeTypeRelationship(relationship,
            "${path}.typeRelationships[${index}]")); index++
    }
    let symbolRelationships = ArrayList<SymbolRelationship>()
    index = 0
    for (relationship in arrayAt(value, "symbolRelationships", path).values()) {
        symbolRelationships.add(decodeSymbolRelationship(relationship,
            "${path}.symbolRelationships[${index}]", legacyV6, legacyIds)); index++
    }
    let returnNode = required(value, "returnType", path)
    let returnType: ?TypeRef = if (returnNode.isNull) { None }
        else { Some(decodeTypeRef(returnNode, "${path}.returnType", 0)) }
    let documentationNode = required(value, "documentation", path)
    let documentation: ?DocComment = if (documentationNode.isNull) { None }
        else { Some(decodeComment(documentationNode, "${path}.documentation", legacyV6,
            legacy, legacyIds, assetReferences)) }
    let semantic = strictObject(required(value, "semantic", path), "${path}.semantic",
        ["state", "provider", "canonicalSignature"])
    let origin = strictObject(required(value, "origin", path), "${path}.origin",
        ["kind", "macroSymbolId"])
    let packageName = stringAt(value, "packageName", path)
    let moduleId = if (legacyV6) { legacyModuleId(modules, packageName, path) }
        else { stringAt(value, "moduleId", path) }
    SymbolDoc(migratedSymbolId(stringAt(value, "id", path), legacyV6, legacyIds, "${path}.id"),
        stringAt(value, "kind", path),
        stringAt(value, "name", path), stringAt(value, "qualifiedName", path),
        packageName, moduleId, stringAt(value, "visibility", path),
        decodeRange(required(value, "source", path), "${path}.source"),
        stringAt(value, "headerSpelling", path),
        SemanticInfo(stringAt(semantic, "state", "${path}.semantic"),
            stringAt(semantic, "provider", "${path}.semantic"),
            canonicalSignature: nullableStringAt(semantic, "canonicalSignature", "${path}.semantic")),
        if (legacy) { None } else { nullableBoolAt(value, "enumNonExhaustive", path) },
        ownerId: migratedOptionalSymbolId(nullableStringAt(value, "ownerId", path), legacyV6,
            legacyIds, "${path}.ownerId"),
        genericParameters: stringsAt(value, "genericParameters", path),
        parameters: parameters.toArray(), returnType: returnType,
        annotations: decodeAnnotations(value, path, legacyV6),
        typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: documentation,
        origin: DeclarationOrigin(kind: stringAt(origin, "kind", "${path}.origin"),
            macroSymbolId: migratedOptionalSymbolId(nullableStringAt(origin, "macroSymbolId",
                "${path}.origin"), legacyV6, legacyIds, "${path}.origin.macroSymbolId")),
        sourceApiSignature: if (legacy) {
            SourceApiSignature("unavailable")
        } else {
            decodeSourceApiSignature(required(value, "sourceApiSignature", path),
                "${path}.sourceApiSignature")
        })
}

internal func decodeModules(root: JsonObjectValue, legacy: Bool): Array<ModuleDoc> {
    let result = ArrayList<ModuleDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "modules", "$" ).values()) {
        let path = "$.modules[${index}]"
        let value = strictObject(node, path, if (legacy) {
            ["id", "name", "role", "sourcePrefix", "packageNames", "dependencyIds"]
        } else {
            ["id", "name", "role", "sourcePrefix", "organization", "packageNames", "dependencyIds"]
        })
        result.add(ModuleDoc(stringAt(value, "id", path), stringAt(value, "name", path),
            stringAt(value, "role", path), stringAt(value, "sourcePrefix", path),
            packageNames: stringsAt(value, "packageNames", path),
            dependencyIds: stringsAt(value, "dependencyIds", path),
            organization: if (legacy) { None<String> } else {
                nullableStringAt(value, "organization", path)
            }))
        index++
    }
    result.toArray()
}

internal func decodePackages(root: JsonObjectValue, legacy: Bool, legacyV6: Bool,
    legacyIds: HashMap<String, String>): Array<PackageDoc> {
    let result = ArrayList<PackageDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "packages", "$" ).values()) {
        let path = "$.packages[${index}]"
        let value = strictObject(node, path, if (legacy) {
            ["name", "moduleId", "sourceFiles", "symbolIds"]
        } else {
            ["name", "moduleId", "sourceFiles", "symbolIds", "reExports"]
        })
        let ids = ArrayList<String>()
        var symbolIndex: Int64 = 0
        for (id in stringsAt(value, "symbolIds", path)) {
            ids.add(migratedSymbolId(id, legacyV6, legacyIds,
                "${path}.symbolIds[${symbolIndex}]"))
            symbolIndex++
        }
        let reExports = ArrayList<ReExportDoc>()
        if (!legacy) {
            var reExportIndex: Int64 = 0
            for (reExportNode in arrayAt(value, "reExports", path).values()) {
                let reExportPath = "${path}.reExports[${reExportIndex}]"
                let reExport = strictObject(reExportNode, reExportPath,
                    ["id", "kind", "organization", "targetPackageName", "targetModuleId",
                        "alias", "state", "source", "bindings"])
                let bindings = ArrayList<ReExportBinding>()
                var bindingIndex: Int64 = 0
                for (bindingNode in arrayAt(reExport, "bindings", reExportPath).values()) {
                    let bindingPath = "${reExportPath}.bindings[${bindingIndex}]"
                    let binding = strictObject(bindingNode, bindingPath,
                        ["exposedName", "targetSymbolIds"])
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
        }
        result.add(PackageDoc(stringAt(value, "name", path), stringAt(value, "moduleId", path),
            sourceFiles: stringsAt(value, "sourceFiles", path), symbolIds: ids.toArray(),
            reExports: reExports.toArray()))
        index++
    }
    result.toArray()
}

internal func decodeFiles(root: JsonObjectValue): Array<FileDoc> {
    let result = ArrayList<FileDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "files", "$" ).values()) {
        let path = "$.files[${index}]"
        let value = strictObject(node, path, ["path", "moduleId", "packageName"])
        result.add(FileDoc(stringAt(value, "path", path), stringAt(value, "moduleId", path),
            stringAt(value, "packageName", path)))
        index++
    }
    result.toArray()
}

// One migrated provider contributes two JSON objects (provider/capabilities),
// one providers-array item, and at least 1,290 bytes to the conservative typed
// encoding census. Account for every additional v6 global-provider copy before
// allocating it; the final typed census still charges exact strings and shape.
internal let MIN_MIGRATED_PROVIDER_ENCODING_BYTES: Int64 = 1290

internal func preflightLegacyProviderMigration(providerCount: Int64, moduleCount: Int64,
    rawShape: RawSchemaShape, sourceBytes: Int64): Unit {
    if (providerCount == 0) { return }
    if (moduleCount == 0) {
        fail("$.providers", "v6 global provider cannot be mapped without a module")
    }
    let additionalModules = moduleCount - 1
    if (additionalModules == 0) { return }

    let availableObjectCopies = (DOC_IR_MAX_SCHEMA_OBJECTS - rawShape.objects) / 2
    let availableArrayCopies = DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - rawShape.arrayItems
    let availableEncodingCopies =
        (DOC_IR_MAX_JSON_DOCUMENT_BYTES - sourceBytes) / MIN_MIGRATED_PROVIDER_ENCODING_BYTES
    var availableCopies = availableObjectCopies
    if (availableArrayCopies < availableCopies) { availableCopies = availableArrayCopies }
    if (availableEncodingCopies < availableCopies) { availableCopies = availableEncodingCopies }
    // Division before multiplication is the overflow-safe checked product.
    if (availableCopies < 0 || providerCount > availableCopies / additionalModules) {
        fail("$.providers", "v6 global provider migration exceeds Doc IR occurrence/encoding budget")
    }
}

internal func decodeProviders(root: JsonObjectValue, modules: Array<ModuleDoc>, legacy: Bool,
    rawShape: RawSchemaShape, sourceBytes: Int64): Array<ProviderInfo> {
    let result = ArrayList<ProviderInfo>()
    let providerNodes = arrayAt(root, "providers", "$" )
    if (legacy) {
        preflightLegacyProviderMigration(providerNodes.size(), modules.size,
            rawShape, sourceBytes)
    }
    var index: Int64 = 0
    for (node in providerNodes.values()) {
        let path = "$.providers[${index}]"
        let keys = if (legacy) { ["name", "version", "state", "capabilities"] }
            else { ["name", "version", "moduleId", "state", "capabilities"] }
        let value = strictObject(node, path, keys)
        if (legacy) {
            let name = stringAt(value, "name", path)
            let version = stringAt(value, "version", path)
            let state = stringAt(value, "state", path)
            let capabilities = decodeCapabilities(required(value, "capabilities", path),
                "${path}.capabilities", true)
            for (module in modules) {
                result.add(ProviderInfo(name, version, module.id, state, capabilities))
            }
        } else {
            result.add(ProviderInfo(stringAt(value, "name", path), stringAt(value, "version", path),
                stringAt(value, "moduleId", path), stringAt(value, "state", path),
                decodeCapabilities(required(value, "capabilities", path), "${path}.capabilities", false)))
        }
        index++
    }
    result.toArray()
}

internal func decodeDeclarations(root: JsonObjectValue, legacyV6: Bool, legacy: Bool,
    modules: LegacyModuleIndex, legacyIds: HashMap<String, String>,
    assetReferences: HashMap<String, String>): Array<SymbolDoc> {
    let result = ArrayList<SymbolDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "declarations", "$" ).values()) {
        result.add(decodeSymbol(node, "$.declarations[${index}]", legacyV6, legacy,
            modules, legacyIds, assetReferences)); index++
    }
    result.toArray()
}

internal class DecodedAssets {
    let assets: Array<AssetDoc>
    let references: HashMap<String, String>

    init(assets: Array<AssetDoc>, references: HashMap<String, String>) {
        this.assets = assets
        this.references = references
    }
}

internal func addLegacyAssetReference(references: HashMap<String, String>, reference: String,
    id: String, path: String): Unit {
    match (references.get(reference)) {
        case Some(existing) => if (existing != id) {
            fail(path, "legacy asset reference '${reference}' is ambiguous")
        }
        case None => references[reference] = id
    }
}

internal func decodeAssets(root: JsonObjectValue, legacy: Bool): DecodedAssets {
    let result = ArrayList<AssetDoc>()
    let references = HashMap<String, String>()
    let oldIds = HashSet<String>()
    let sourcePaths = HashSet<String>()
    let migratedIds = HashSet<String>()
    var totalBytes: Int64 = 0
    var totalPixels: Int64 = 0
    var index: Int64 = 0
    for (node in arrayAt(root, "assets", "$" ).values()) {
        let path = "$.assets[${index}]"
        let value = strictObject(node, path, ["id", "mediaType", "sourcePath", "base64"])
        let oldId = stringAt(value, "id", path)
        let mediaType = stringAt(value, "mediaType", path)
        let sourcePath = stringAt(value, "sourcePath", path)
        let base64 = stringAt(value, "base64", path)
        if (!legacy) {
            result.add(AssetDoc(oldId, mediaType, sourcePath, base64))
            index++
            continue
        }
        if (!oldIds.add(oldId)) { fail("${path}.id", "duplicate legacy asset id") }
        if (!sourcePaths.add(sourcePath) || !safeRelativePath(sourcePath)) {
            fail("${path}.sourcePath", "duplicate or unsafe legacy asset source path")
        }
        let decoded = try {
            let _ = assetMediaExtension(mediaType)
            decodeAssetBase64(base64)
        } catch (_: Exception) {
            fail(path, "unsupported media type or invalid legacy asset base64")
        }
        let pixels = try {
            validateRasterAsset(mediaType, decoded)
        } catch (_: IllegalArgumentException) {
            fail(path, "invalid or oversized legacy image asset")
        }
        if (decoded.size > DOC_IR_MAX_TOTAL_ASSET_BYTES - totalBytes) {
            fail(path, "legacy image assets exceed the decoded-byte budget")
        }
        totalBytes += decoded.size
        if (pixels > DOC_IR_MAX_TOTAL_ASSET_PIXELS - totalPixels) {
            fail(path, "legacy image assets exceed the total-pixel budget")
        }
        totalPixels += pixels
        let id = "sha256-${docIrSha256Bytes(decoded)}"
        addLegacyAssetReference(references, oldId, id, path)
        addLegacyAssetReference(references, sourcePath, id, path)
        addLegacyAssetReference(references, "./${sourcePath}", id, path)
        if (migratedIds.add(id)) { result.add(AssetDoc(id, mediaType, sourcePath, base64)) }
        index++
    }
    DecodedAssets(result.toArray(), references)
}

internal func decodeOrphans(root: JsonObjectValue): Array<OrphanDocComment> {
    let result = ArrayList<OrphanDocComment>()
    var index: Int64 = 0
    for (node in arrayAt(root, "orphanDocComments", "$" ).values()) {
        let path = "$.orphanDocComments[${index}]"
        let value = strictObject(node, path, ["rawText", "source"])
        result.add(OrphanDocComment(stringAt(value, "rawText", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeMacros(root: JsonObjectValue): Array<MacroInvocation> {
    let result = ArrayList<MacroInvocation>()
    var index: Int64 = 0
    for (node in arrayAt(root, "macroInvocations", "$" ).values()) {
        let path = "$.macroInvocations[${index}]"
        let value = strictObject(node, path, ["name", "source"])
        result.add(MacroInvocation(stringAt(value, "name", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeUnsupported(root: JsonObjectValue): Array<UnsupportedDeclaration> {
    let result = ArrayList<UnsupportedDeclaration>()
    var index: Int64 = 0
    for (node in arrayAt(root, "unsupportedDeclarations", "$" ).values()) {
        let path = "$.unsupportedDeclarations[${index}]"
        let value = strictObject(node, path, ["kind", "name", "reason", "source"])
        result.add(UnsupportedDeclaration(stringAt(value, "kind", path), stringAt(value, "name", path),
            stringAt(value, "reason", path), decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

internal func decodeUnbound(root: JsonObjectValue): Array<UnboundSemanticDeclaration> {
    let result = ArrayList<UnboundSemanticDeclaration>()
    var index: Int64 = 0
    for (node in arrayAt(root, "unboundSemanticDeclarations", "$" ).values()) {
        let path = "$.unboundSemanticDeclarations[${index}]"
        let value = strictObject(node, path, ["provider", "display", "reason"])
        result.add(UnboundSemanticDeclaration(stringAt(value, "provider", path),
            stringAt(value, "display", path), stringAt(value, "reason", path)))
        index++
    }
    result.toArray()
}

internal func decodeDiagnostics(root: JsonObjectValue, legacy: Bool,
    legacyIds: HashMap<String, String>): Array<Diagnostic> {
    let result = ArrayList<Diagnostic>()
    var index: Int64 = 0
    for (node in arrayAt(root, "diagnostics", "$" ).values()) {
        let path = "$.diagnostics[${index}]"
        let value = strictObject(node, path, ["severity", "code", "message", "source", "symbolId"])
        let sourceNode = required(value, "source", path)
        result.add(Diagnostic(stringAt(value, "severity", path), stringAt(value, "code", path),
            stringAt(value, "message", path),
            source: if (sourceNode.isNull) { None }
                else { Some(decodeRange(sourceNode, "${path}.source")) },
            symbolId: migratedOptionalSymbolId(nullableStringAt(value, "symbolId", path), legacy,
                legacyIds, "${path}.symbolId")))
        index++
    }
    result.toArray()
}
