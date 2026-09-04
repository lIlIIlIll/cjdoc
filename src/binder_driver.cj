package cjdoc

import std.collection.*

class DocumentationBinder {
    public func bind(source: SourceSnapshot, semanticResult: SemanticResult, expectedProvider!: ?String = None): DocumentationSet {
        let documentation = DocumentationSet(source.projectName)
        for (module in source.modules) {
            documentation.modules.add(copyModule(module))
        }
        for (pkg in source.packages) {
            documentation.packages.add(copyPackage(pkg))
        }
        documentation.sourceFileOrigins.add(all: source.sourceFileOrigins)
        documentation.orphanDocComments.add(all: source.orphanDocComments)
        documentation.macroInvocations.add(all: source.macroInvocations)
        documentation.unsupportedDeclarations.add(all: source.unsupportedDeclarations)
        documentation.diagnostics.add(all: source.diagnostics)
        documentation.diagnostics.add(all: semanticResult.diagnostics)

        let sourceIndexByKey = HashMap<String, Int64>()
        var index: Int64 = 0
        while (index < source.declarations.size) {
            sourceIndexByKey[source.declarations[index].sourceKey] = index
            index++
        }

        let knownModuleIds = HashSet<String>()
        for (module in source.modules) {
            let _ = knownModuleIds.add(module.id)
        }
        let reportedByModule = HashMap<String, ModuleSemanticResult>()
        let duplicateModuleResults = HashSet<String>()
        for (moduleResult in semanticResult.modules) {
            if (!knownModuleIds.contains(moduleResult.moduleId)) {
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007",
                            "semantic provider returned a result for an unknown module '${moduleResult.moduleId}'"))
            } else if (reportedByModule.contains(moduleResult.moduleId)) {
                let _ = duplicateModuleResults.add(moduleResult.moduleId)
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007",
                            "semantic provider returned duplicate results for module '${moduleResult.moduleId}'"))
            } else {
                reportedByModule[moduleResult.moduleId] = moduleResult
            }
        }

        let effectiveByModule = HashMap<String, ModuleSemanticResult>()
        let statsByModule = HashMap<String, SemanticBindingStats>()
        let semanticBySource = HashMap<String, SemanticDeclaration>()
        let ambiguousSourceKeys = HashSet<String>()
        let pendingProviderDiagnostics = ArrayList<PendingProviderDiagnostic>()
        for (module in source.modules) {
            let reported: ?ModuleSemanticResult = if (duplicateModuleResults.contains(module.id)) {
                None
            } else {
                reportedByModule.get(module.id)
            }
            let moduleResult = match (reported) {
                case Some(value) => value
                case None =>
                    let provider = match (expectedProvider) {
                        case Some(value) => value
                        case None => "unavailable"
                    }
                    let fallback = ModuleSemanticResult(module.id, provider, "unknown",
                        SemanticCapabilities(false, false, false, false, false))
                    fallback
                        .diagnostics
                        .add(
                            Diagnostic("warning", "CJDOC2001",
                                "semantic result is unavailable for module '${module.name}'; AST fallback retained"))
                    fallback
            }
            effectiveByModule[module.id] = moduleResult
            let stats = SemanticBindingStats(module.id, moduleResult.provider, moduleResult.providerVersion,
                moduleResult.capabilities)
            statsByModule[module.id] = stats
            documentation.semanticBindings.add(stats)
            for (diagnostic in moduleResult.diagnostics) {
                pendingProviderDiagnostics.add(PendingProviderDiagnostic(diagnostic, stats, module.id))
            }

            var bindingEnabled = moduleResult.capabilities.sourceBinding
            if (let Some(expected) <- expectedProvider) {
                if (moduleResult.provider != expected) {
                    recordContractViolation(documentation, stats,
                        "semantic provider result '${moduleResult.provider}' does not match provider '${expected}'")
                    bindingEnabled = false
                }
            }
            if (!moduleResult.capabilities.sourceBinding && !moduleResult.declarations.isEmpty()) {
                recordContractViolation(documentation, stats,
                    "semantic provider returned declarations without sourceBinding capability")
                bindingEnabled = false
            }
            for (semantic in moduleResult.declarations) {
                let original = match (sourceIndexByKey.get(semantic.sourceKey)) {
                    case Some(sourceIndex) => source.declarations[sourceIndex]
                    case None =>
                        stats.extraneous++
                        documentation
                            .diagnostics
                            .add(
                                Diagnostic("warning", "CJDOC1007",
                                    "semantic declaration has no matching source declaration"))
                        continue
                }
                if (semantic.moduleId != module.id || original.moduleId != module.id) {
                    stats.extraneous++
                    recordContractViolation(documentation, stats,
                        "semantic declaration crossed its module transaction boundary", source: original.source)
                    continue
                }
                if (semantic.provider != moduleResult.provider) {
                    recordContractViolation(documentation, stats,
                        "semantic declaration provider '${semantic.provider}' does not match result provider '${moduleResult.provider}'")
                    continue
                }
                if (!bindingEnabled) {
                    continue
                }
                if (semanticBySource.contains(semantic.sourceKey)) {
                    let _ = ambiguousSourceKeys.add(semantic.sourceKey)
                } else {
                    semanticBySource[semantic.sourceKey] = semantic
                }
            }
        }

        for (declaration in source.declarations) {
            let moduleResult = effectiveByModule[declaration.moduleId]
            let stats = statsByModule[declaration.moduleId]
            let semantic = if (ambiguousSourceKeys.contains(declaration.sourceKey)) {
                stats.ambiguous++
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007", "ambiguous Source to semantic binding",
                            source: declaration.source))
                semanticFallback(declaration, moduleResult.provider, "ambiguous")
            } else {
                match (semanticBySource.get(declaration.sourceKey)) {
                    case Some(found) => match (sanitizeSemantic(declaration, found, moduleResult, documentation, stats)) {
                        case Some(sanitized) =>
                            stats.matched++;
                            sanitized
                        case None =>
                            stats.missing++;
                            semanticFallback(declaration, moduleResult.provider, "unavailable")
                    }
                    case None =>
                        stats.missing++
                        documentation
                            .diagnostics
                            .add(
                                Diagnostic("warning", "CJDOC1007", "semantic declaration is unavailable",
                                    source: declaration.source))
                        semanticFallback(declaration, moduleResult.provider, "unavailable")
                }
            }
            let symbol = copySemanticToDoc(declaration, semantic)
            match (semantic.ownerSourceKey) {
                case Some(ownerKey) => match (sourceIndexByKey.get(ownerKey)) {
                    case Some(ownerIndex) => symbol.ownerIndex = ownerIndex
                    case None => documentation
                        .diagnostics
                        .add(
                            Diagnostic("warning", "CJDOC1007", "semantic owner has no matching source declaration",
                                source: declaration.source))
                }
                case None => ()
            }
            documentation.symbols.add(symbol)
        }

        finalizeIdentities(documentation.symbols)
        let omittedIndices = duplicatePrunePlan(documentation, source)
        let (idsBySourceKey, survivingIds, moduleBySymbolId) = survivingIdentityMaps(source, documentation.symbols,
            omittedIndices)
        resolveSymbolRelationshipSourceKeys(documentation.symbols, omittedIndices, idsBySourceKey)
        sanitizeDanglingReferences(documentation, omittedIndices, survivingIds)
        appendProviderDiagnostics(documentation, pendingProviderDiagnostics, moduleBySymbolId)
        removeOmittedSymbols(documentation, omittedIndices)
        rebuildPackageSymbolIds(documentation)
        resolveReExports(documentation, source)
        resolveDocumentationReferences(documentation)
        return documentation
    }
}
