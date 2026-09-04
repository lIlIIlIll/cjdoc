package cjdoc.render

import cjdoc.model.*
import std.collection.*

public func validateDocumentationSet(documentation: DocumentationSet): Unit {
    if (documentation.schemaVersion != DOC_IR_SCHEMA_VERSION) {
        domainFail("$.schemaVersion", "typed documentation must be v8")
    }
    // This occurrence-based preflight deliberately walks shared references once
    // per encoded occurrence. It bounds all recursive validation and the later
    // JSON encoder by the work and bytes they will actually emit.
    validateDocIrEncodingBudget(documentation, DOC_IR_MAX_JSON_DOCUMENT_BYTES)
    if (documentation.status != "complete" && documentation.status != "partial") {
        domainFail("$.status", "invalid structural status")
    }
    let moduleIds = HashSet<String>()
    let modulesById = HashMap<String, ModuleDoc>()
    let modulePackageKeys = HashSet<String>()
    var index: Int64 = 0
    for (module in documentation.modules) {
        if (!module.id.startsWith("cjdoc:module:v1:") || !moduleIds.add(module.id)) {
            domainFail("$.modules[${index}].id", "empty or duplicate module id")
        }
        if (!module.sourcePrefix.isEmpty() && !safeRelativePath(module.sourcePrefix)) {
            domainFail("$.modules[${index}].sourcePrefix",
                "must be empty or a portable relative logical path")
        }
        if (let Some(organization) <- module.organization) {
            if (organization.trimAscii().isEmpty() || organization.size > 1024) {
                domainFail("$.modules[${index}].organization",
                    "must be null or a non-blank bounded organization identity")
            }
        }
        modulesById[module.id] = module
        let packageNames = HashSet<String>()
        for (name in module.packageNames) {
            if (name.isEmpty() || !packageNames.add(name)) {
                domainFail("$.modules[${index}].packageNames", "empty or duplicate package name")
            }
            let _ = modulePackageKeys.add(compositeKey(module.id, name))
        }
        index++
    }
    index = 0
    for (module in documentation.modules) {
        let dependencies = HashSet<String>()
        for (dependencyId in module.dependencyIds) {
            if (dependencyId == module.id || !moduleIds.contains(dependencyId) ||
                !dependencies.add(dependencyId)) {
                domainFail("$.modules[${index}].dependencyIds", "invalid module dependency")
            }
        }
        index++
    }
    validateModuleDependencyDag(documentation.modules, modulesById)

    let providerKeys = HashSet<String>()
    let providersByKey = HashMap<String, ProviderInfo>()
    let providerModules = HashSet<String>()
    index = 0
    for (provider in documentation.providers) {
        let key = compositeKey(provider.moduleId, provider.name)
        if (provider.name.trimAscii().isEmpty() || provider.version.trimAscii().isEmpty() ||
            provider.name.size > DOC_IR_MAX_PROVIDER_IDENTITY_BYTES ||
            provider.version.size > DOC_IR_MAX_PROVIDER_IDENTITY_BYTES ||
            !moduleIds.contains(provider.moduleId) || !providerKeys.add(key)) {
            domainFail("$.providers[${index}]",
                "blank/oversized provider identity, unknown module, or duplicate provider/module pair")
        }
        providersByKey[key] = provider
        let _ = providerModules.add(provider.moduleId)
        index++
    }
    for (module in documentation.modules) {
        if (!providerModules.contains(module.id)) {
            domainFail("$.providers", "module '${module.id}' has no provider result")
        }
    }

    let packageKeys = HashSet<String>()
    index = 0
    for (pkg in documentation.packages) {
        let key = compositeKey(pkg.moduleId, pkg.name)
        if (!moduleIds.contains(pkg.moduleId) || !packageKeys.add(key)) {
            domainFail("$.packages[${index}]", "unknown module or duplicate module/package pair")
        }
        if (!modulePackageKeys.contains(key)) {
            domainFail("$.packages[${index}]", "package is not listed by its module")
        }
        index++
    }
    for (module in documentation.modules) {
        for (name in module.packageNames) {
            if (!packageKeys.contains(compositeKey(module.id, name))) {
                domainFail("$.modules", "module '${module.id}' lists unknown package '${name}'")
            }
        }
    }

    let filePaths = HashSet<String>()
    let fileKeys = HashSet<String>()
    index = 0
    for (file in documentation.files) {
        if (!safeRelativePath(file.path) || !filePaths.add(file.path) ||
            !packageKeys.contains(compositeKey(file.moduleId, file.packageName))) {
            domainFail("$.files[${index}]", "unsafe/duplicate path or unknown module/package")
        }
        let _ = fileKeys.add(compositeKey(compositeKey(file.moduleId, file.packageName), file.path))
        index++
    }

    let byId = HashMap<String, SymbolDoc>()
    index = 0
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
                providersByKey, declaration.moduleId)
        }
        match (declaration.returnType) {
            case Some(typeRef) => validateType(typeRef, "$.declarations[${index}].returnType", 0,
                providersByKey, declaration.moduleId)
            case None => ()
        }
        for (relationship in declaration.typeRelationships) {
            validateType(relationship.target, "$.declarations[${index}].typeRelationships", 0,
                providersByKey, declaration.moduleId)
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
                validateMarkdown(comment.markdown, "$.declarations[${index}].documentation.markdown", 0)
            case None => ()
        }
        index++
    }

    index = 0
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
            for (tag in comment.tags) {
                match (tag.targetSymbolId) {
                    case Some(targetId) => if (!byId.contains(targetId)) {
                        domainFail("$.declarations[${index}].documentation.tags", "unknown target SymbolId")
                    }
                    case None => if (tag.referenceState == "resolved") {
                        domainFail("$.declarations[${index}].documentation.tags", "resolved target is missing")
                    }
                }
            }
        }
        index++
    }
    validateOwnerDag(documentation.declarations, byId)

    let listedFileKeys = HashSet<String>()
    let listedSymbolIds = HashSet<String>()
    let reExportIds = HashSet<String>()
    var reExportEdges: Int64 = 0
    index = 0
    for (pkg in documentation.packages) {
        let sourceFiles = HashSet<String>()
        for (path in pkg.sourceFiles) {
            if (!sourceFiles.add(path) || !fileKeys.contains(compositeKey(compositeKey(pkg.moduleId,
                pkg.name), path))) {
                domainFail("$.packages[${index}].sourceFiles", "duplicate or unknown source file")
            }
            let _ = listedFileKeys.add(compositeKey(compositeKey(pkg.moduleId, pkg.name), path))
        }
        let symbolIds = HashSet<String>()
        for (id in pkg.symbolIds) {
            match (byId.get(id)) {
                case Some(symbol) => if (!symbolIds.add(id) || symbol.moduleId != pkg.moduleId ||
                    symbol.packageName != pkg.name) {
                    domainFail("$.packages[${index}].symbolIds", "duplicate or foreign symbol")
                }
                case None => domainFail("$.packages[${index}].symbolIds", "unknown symbol")
            }
            if (!listedSymbolIds.add(id)) {
                domainFail("$.packages[${index}].symbolIds", "symbol is listed more than once")
            }
        }
        var reExportIndex: Int64 = 0
        for (reExport in pkg.reExports) {
            let reExportPath = "$.packages[${index}].reExports[${reExportIndex}]"
            if (!validReExportId(reExport.id) || !reExportIds.add(reExport.id)) {
                domainFail("${reExportPath}.id", "invalid or duplicate re-export id")
            }
            validateRange(reExport.source, "${reExportPath}.source")
            if (!fileKeys.contains(compositeKey(compositeKey(pkg.moduleId, pkg.name),
                reExport.source.path))) {
                domainFail("${reExportPath}.source",
                    "re-export source file is not owned by exporting module/package")
            }
            if (reExport.kind == "packageAlias") {
                if (reExport.alias.isNone() || !reExport.bindings.isEmpty()) {
                    domainFail(reExportPath,
                        "package alias requires an alias and cannot expose symbol bindings")
                }
            } else if (reExport.state != "resolved" && !reExport.bindings.isEmpty()) {
                domainFail("${reExportPath}.bindings",
                    "unresolved re-export cannot expose symbol bindings")
            } else if (reExport.state == "resolved" && reExport.kind != "all" &&
                reExport.bindings.isEmpty()) {
                domainFail("${reExportPath}.bindings",
                    "resolved symbol re-export requires at least one binding")
            }
            match (reExport.targetModuleId) {
                case Some(targetModuleId) =>
                    if (!moduleIds.contains(targetModuleId) ||
                        !packageKeys.contains(compositeKey(targetModuleId,
                            reExport.targetPackageName))) {
                        domainFail(reExportPath, "unknown target module/package")
                    }
                case None => if (reExport.state == "resolved") {
                    domainFail("${reExportPath}.targetModuleId",
                        "resolved re-export is missing its target module")
                }
            }
            let exposedNames = HashSet<String>()
            var bindingIndex: Int64 = 0
            for (binding in reExport.bindings) {
                let bindingPath = "${reExportPath}.bindings[${bindingIndex}]"
                if (!exposedNames.add(binding.exposedName)) {
                    domainFail("${bindingPath}.exposedName",
                        "duplicate exposed name in re-export")
                }
                let targetIds = HashSet<String>()
                for (targetId in binding.targetSymbolIds) {
                    if (!targetIds.add(targetId)) {
                        domainFail("${bindingPath}.targetSymbolIds",
                            "duplicate target SymbolId in re-export binding")
                    }
                    match (byId.get(targetId)) {
                        case Some(target) =>
                            if (target.ownerId.isSome() ||
                                (target.visibility != "public" && target.visibility != "protected") ||
                                reExport.targetModuleId.isNone() ||
                                target.moduleId != reExport.targetModuleId.getOrThrow() ||
                                target.packageName != reExport.targetPackageName) {
                                domainFail(bindingPath,
                                    "re-export target must be a visible top-level declaration in the target package")
                            }
                        case None => domainFail(bindingPath, "unknown target SymbolId")
                    }
                    if (reExportEdges >= DOC_IR_MAX_REEXPORT_EDGES) {
                        domainFail("$.packages", "re-export edge limit exceeded")
                    }
                    reExportEdges++
                }
                bindingIndex++
            }
            reExportIndex++
        }
        index++
    }
    for (declaration in documentation.declarations) {
        if (!listedSymbolIds.contains(declaration.id)) {
            domainFail("$.packages", "declaration '${declaration.id}' is not listed")
        }
    }
    for (file in documentation.files) {
        if (!listedFileKeys.contains(compositeKey(compositeKey(file.moduleId,
            file.packageName), file.path))) {
            domainFail("$.packages", "file '${file.path}' is not listed")
        }
    }

    let assetIds = HashSet<String>()
    let assetPaths = HashSet<String>()
    let assetReferences = HashMap<String, String>()
    var totalAssetBytes: Int64 = 0
    var totalAssetPixels: Int64 = 0
    index = 0
    for (asset in documentation.assets) {
        if (!validSha256AssetId(asset.id) || !assetIds.add(asset.id) || !safeRelativePath(asset.sourcePath) ||
            !assetPaths.add(asset.sourcePath)) {
            domainFail("$.assets[${index}]", "duplicate asset id/path or unsafe source path")
        }
        for (reference in [asset.id, asset.sourcePath]) {
            match (assetReferences.get(reference)) {
                case Some(owner) => if (owner != asset.id) {
                    domainFail("$.assets[${index}]", "ambiguous asset id/sourcePath reference")
                }
                case None => assetReferences[reference] = asset.id
            }
        }
        let decoded = try {
            let _ = assetMediaExtension(asset.mediaType)
            decodeAssetBase64(asset.base64)
        } catch (_: Exception) {
            domainFail("$.assets[${index}]", "unsupported media type or invalid base64")
        }
        let pixels = try {
            validateRasterAsset(asset.mediaType, decoded)
        } catch (_: IllegalArgumentException) {
            domainFail("$.assets[${index}]", "invalid or oversized local image asset")
        }
        if (asset.id != "sha256-${docIrSha256Bytes(decoded)}") {
            domainFail("$.assets[${index}].id", "asset id does not match SHA-256 content digest")
        }
        if (decoded.size > DOC_IR_MAX_TOTAL_ASSET_BYTES - totalAssetBytes) {
            domainFail("$.assets", "decoded local assets exceed 64 MiB")
        }
        totalAssetBytes += decoded.size
        if (pixels > DOC_IR_MAX_TOTAL_ASSET_PIXELS - totalAssetPixels) {
            domainFail("$.assets", "decoded local assets exceed the total pixel budget")
        }
        totalAssetPixels += pixels
        index++
    }
    index = 0
    for (declaration in documentation.declarations) {
        if (let Some(comment) <- declaration.documentation) {
            validateMarkdownAssetReferences(comment.markdown,
                "$.declarations[${index}].documentation.markdown", assetIds)
        }
        index++
    }
    for (orphan in documentation.orphanDocComments) { validateRange(orphan.source, "$.orphanDocComments") }
    for (invocation in documentation.macroInvocations) { validateRange(invocation.source, "$.macroInvocations") }
    for (item in documentation.unsupportedDeclarations) { validateRange(item.source, "$.unsupportedDeclarations") }
    for (diagnostic in documentation.diagnostics) {
        match (diagnostic.source) { case Some(range) => validateRange(range, "$.diagnostics.source") case None => () }
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!byId.contains(symbolId)) { domainFail("$.diagnostics.symbolId", "unknown SymbolId") }
        }
    }
    var hasError = false
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error") { hasError = true; break }
    }
    var hasUnavailableSemantic = false
    for (provider in documentation.providers) {
        if (provider.state == "unavailable" || provider.state == "ambiguous") {
            hasUnavailableSemantic = true
            break
        }
    }
    if (!hasUnavailableSemantic) {
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable" ||
                declaration.semantic.state == "ambiguous") {
                hasUnavailableSemantic = true
                break
            }
        }
    }
    if (documentation.status == "complete" && (hasError || hasUnavailableSemantic ||
        !documentation.orphanDocComments.isEmpty() || !documentation.macroInvocations.isEmpty() ||
        !documentation.unsupportedDeclarations.isEmpty() ||
        !documentation.unboundSemanticDeclarations.isEmpty())) {
        domainFail("$.status", "complete status conflicts with incomplete source or semantic structure")
    }
}
