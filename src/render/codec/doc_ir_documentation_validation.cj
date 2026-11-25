protected package cjdoc.render.codec

import cjdoc.render.routes.safeRelativePath
import cjdoc.render.foundation.{markdownLinkDestination, renderabilityIndex}
import cjdoc.model.*
import std.collection.*

// Replay uses the producer's strict author-ID grammar for throws and
// admonitions. Opaque field IDs alone cannot prove these associations.
internal func validReplayAuthorEntryId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if (byte >= b'a' && byte <= b'z') { continue }
        if (index > 0 && ((byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) { continue }
        return false
    }
    true
}

private func validateDocumentationMetadataReferences(documentation: DocumentationSet,
    moduleIds: HashSet<String>, packageKeys: HashSet<String>,
    declarationsById: HashMap<String, SymbolDoc>): Unit {
    let groupKeys = HashSet<String>()
    var index: Int64 = 0
    for (group in documentation.metadata.groups) {
        let path = "$.metadata.groups[${index}]"
        let packageKey = compositeKey(group.moduleId, group.packageName)
        if (!moduleIds.contains(group.moduleId) || !packageKeys.contains(packageKey)) {
            domainFail(path, "group references an unknown module/package")
        }
        if (let Some(ownerId) <- group.ownerId) {
            let owner = match (declarationsById.get(ownerId)) {
                case Some(value) => value
                case None => domainFail("${path}.ownerId", "unknown container declaration")
            }
            if (!isDocIrContainerKind(owner.kind) || owner.moduleId != group.moduleId ||
                owner.packageName != group.packageName) {
                domainFail("${path}.ownerId", "owner must be a container in the same module/package")
            }
        }
        let key = documentationMetadataGroupKey(group.moduleId, group.packageName,
            group.ownerId, group.id)
        if (!groupKeys.add(key)) { domainFail(path, "duplicate group definition in scope") }
        index++
    }
    let tagKeys = HashSet<String>()
    index = 0
    for (tag in documentation.metadata.tags) {
        let path = "$.metadata.tags[${index}]"
        if (!moduleIds.contains(tag.moduleId)) {
            domainFail(path, "tag references an unknown module")
        }
        if (!tagKeys.add(documentationMetadataTagKey(tag.moduleId, tag.id))) {
            domainFail(path, "duplicate tag definition in module scope")
        }
        index++
    }
    // A field definition must be reachable from the declarations it names: a
    // use by an unknown symbol, another module's symbol, a duplicate use or an
    // out-of-cardinality value list is a contract violation, not a display hint.
    if (documentation.metadata.fields.isEmpty()) { return }
    let audience = documentation.configuration.audience
    let visible: ?HashMap<String, Bool> = if (audience == "all") { None } else {
        Some(renderabilityIndex(documentation, declarationsById, audience))
    }
    let fieldKeys = HashSet<String>()
    index = 0
    for (field in documentation.metadata.fields) {
        let path = "$.metadata.fields[${index}]"
        if (!moduleIds.contains(field.moduleId)) {
            domainFail(path, "field references an unknown module")
        }
        if (!fieldKeys.add(documentationMetadataTagKey(field.moduleId, field.id))) {
            domainFail(path, "duplicate field definition in module scope")
        }
        if (field.uses.isEmpty()) { domainFail(path, "field definition has no uses") }
        let useKeys = HashSet<String>()
        var useIndex: Int64 = 0
        for (use in field.uses) {
            let usePath = "${path}.uses[${useIndex}]"
            if (!useKeys.add(use.symbolId)) { domainFail(usePath, "duplicate symbol use") }
            let symbol = match (declarationsById.get(use.symbolId)) {
                case Some(value) => value
                case None => domainFail(usePath, "unknown symbol")
            }
            if (symbol.moduleId != field.moduleId) {
                domainFail(usePath, "cross-module field use")
            }
            if (let Some(renderable) <- visible) {
                if (!renderable.get(symbol.id).getOrDefault({ => false })) {
                    domainFail(usePath, "field use is outside the captured audience")
                }
            }
            if (!field.repeatable && use.values.size > 1) {
                domainFail(usePath, "single-value field carries multiple values")
            }
            useIndex++
        }
        index++
    }
}

internal func validateDocIrDocumentLimit(limit: Int64): Unit {
    if (limit < 1 || limit > DOC_IR_MAX_JSON_DOCUMENT_BYTES) {
        throw IllegalArgumentException("Doc IR document budget must be in 1..67108864 bytes")
    }
}

/** Validate Doc IR, including its conservative encoded size within the selected budget. */
public func validateDocumentationSet(documentation: DocumentationSet,
    maxDocumentBytes!: Int64 = DOC_IR_MAX_JSON_DOCUMENT_BYTES): Unit {
    let _ = validatedDocumentationCapacity(documentation, maxDocumentBytes)
}

internal func validatedDocumentationCapacity(documentation: DocumentationSet,
    maxDocumentBytes: Int64): Int64 {
    validateDocIrDocumentLimit(maxDocumentBytes)
    if (documentation.schemaVersion != DOC_IR_SCHEMA_VERSION) {
        domainFail("$.schemaVersion", "typed documentation must be current Doc IR")
    }
    // This occurrence-based preflight deliberately walks shared references once
    // per encoded occurrence. It bounds all recursive validation and the later
    // JSON encoder by the work and bytes they will actually emit.
    let capacity = validateDocIrEncodingBudget(documentation, maxDocumentBytes)
    if (documentation.status != "complete" && documentation.status != "partial") {
        domainFail("$.status", "invalid structural status")
    }
    if (documentation.apiCollectionState != "resolved" && documentation.apiCollectionState != "partial" &&
        documentation.apiCollectionState != "unavailable") {
        domainFail("$.apiCollectionState", "invalid API collection state")
    }
    let (moduleIds, modulePackageKeys) = validateDocumentationModules(documentation)
    let navigationEvidence = validateDependencyMetadata(documentation, moduleIds)
    let providersByKey = validateDocumentationProviders(documentation, moduleIds)
    let (packageKeys, fileKeys) = validateDocumentationInventory(documentation, moduleIds, modulePackageKeys)
    let byId = validateDocumentationDeclarations(documentation, packageKeys, fileKeys,
        providersByKey, navigationEvidence)
    validateDocumentationDeclarationReferences(documentation, byId, providersByKey, navigationEvidence)
    validateDocumentationMetadataReferences(documentation, moduleIds, packageKeys, byId)
    validateDocumentationPackageListings(documentation, moduleIds, packageKeys, fileKeys, byId)
    let assetIds = validateDocumentationAssets(documentation)
    validateDocumentationPages(documentation, assetIds, byId, navigationEvidence)
    validateDocumentationDiagnostics(documentation, byId)
    capacity
}

private func validateDocumentationModules(documentation: DocumentationSet):
    (HashSet<String>, HashSet<String>) {
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
    (moduleIds, modulePackageKeys)
}

private func validateDocumentationProviders(documentation: DocumentationSet,
    moduleIds: HashSet<String>): HashMap<String, ProviderInfo> {
    let providerKeys = HashSet<String>()
    let providersByKey = HashMap<String, ProviderInfo>()
    let providerModules = HashSet<String>()
    var index: Int64 = 0
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
    providersByKey
}

private func validateDocumentationInventory(documentation: DocumentationSet,
    moduleIds: HashSet<String>, modulePackageKeys: HashSet<String>): (HashSet<String>, HashSet<String>) {
    let packageKeys = HashSet<String>()
    var index: Int64 = 0
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
        if (!safeRelativePath(file.path) || !filePaths.add(compositeKey(file.moduleId, file.path)) ||
            !packageKeys.contains(compositeKey(file.moduleId, file.packageName))) {
            domainFail("$.files[${index}]", "unsafe/duplicate path or unknown module/package")
        }
        let _ = fileKeys.add(compositeKey(compositeKey(file.moduleId, file.packageName), file.path))
        index++
    }
    (packageKeys, fileKeys)
}

private func validateDocumentationPackageListings(documentation: DocumentationSet,
    moduleIds: HashSet<String>, packageKeys: HashSet<String>, fileKeys: HashSet<String>,
    byId: HashMap<String, SymbolDoc>): Unit {
    let reachability = ReExportReachability(documentation)
    let listedFileKeys = HashSet<String>()
    let listedSymbolIds = HashSet<String>()
    let reExportIds = HashSet<String>()
    var reExportEdges: Int64 = 0
    var index: Int64 = 0
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
            var targetClosure: ?HashSet<String> = None
            match (reExport.targetModuleId) {
                case Some(targetModuleId) =>
                    if (!moduleIds.contains(targetModuleId) ||
                        !packageKeys.contains(compositeKey(targetModuleId,
                            reExport.targetPackageName))) {
                        domainFail(reExportPath, "unknown target module/package")
                    }
                    // The stored package is the one the exporting module imported
                    // directly; it must be importable from that module.
                    if (!reachability.moduleReaches(pkg.moduleId, targetModuleId)) {
                        domainFail(reExportPath,
                            "target package is not reachable from the exporting module")
                    }
                    if (!reExport.bindings.isEmpty()) {
                        targetClosure = match (reachability.closure(targetModuleId,
                            reExport.targetPackageName)) {
                            case Some(value) => Some(value)
                            case None => domainFail(reExportPath,
                                "re-export target reachability exceeded its work budget")
                        }
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
                            let reachable = match (targetClosure) {
                                case Some(values) => values.contains(targetId)
                                case None => false
                            }
                            if (target.ownerId.isSome() ||
                                (target.visibility != "public" && target.visibility != "protected") ||
                                !reachable) {
                                domainFail(bindingPath,
                                    "re-export target must be a visible top-level declaration reachable through the target package")
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
}

private func validateDocumentationDiagnostics(documentation: DocumentationSet,
    byId: HashMap<String, SymbolDoc>): Unit {
    for (orphan in documentation.orphanDocComments) { validateRange(orphan.source, "$.orphanDocComments") }
    for (invocation in documentation.macroInvocations) { validateRange(invocation.source, "$.macroInvocations") }
    for (item in documentation.unsupportedDeclarations) { validateRange(item.source, "$.unsupportedDeclarations") }
    for (diagnostic in documentation.diagnostics) {
        match (diagnostic.source) { case Some(range) => validateRange(range, "$.diagnostics.source") case None => () }
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!byId.contains(symbolId)) { domainFail("$.diagnostics.symbolId", "unknown SymbolId") }
        }
    }
    let externalKeys = HashSet<String>()
    for (reference in documentation.externalDocumentation) {
        if (!byId.contains(reference.symbolId) || !externalKeys.add(reference.symbolId + ":" + reference.name) ||
            ((reference.state == "available") == reference.url.isEmpty()) ||
            (!reference.url.isEmpty() && markdownLinkDestination(reference.url, allowRelative: true).isNone())) {
            domainFail("$.externalDocumentation", "unknown target, duplicate resolver, state/URL mismatch or unsafe URL")
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
