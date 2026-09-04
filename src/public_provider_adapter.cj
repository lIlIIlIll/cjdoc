package cjdoc

import cjdoc.provider as public_provider
import std.collection.*

internal class FactorySemanticProviderAdapter <: SemanticProvider {
    private let factory: public_provider.SemanticProviderFactory
    private let identity: ProviderIdentitySnapshot

    init(factory: public_provider.SemanticProviderFactory) {
        this.factory = factory
        this.identity = captureProviderIdentity(factory)
    }

    public func providerName(): String {
        identity.name
    }
    public func providerVersion(): String {
        identity.version
    }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult()
        let sourceMapper = PublicSourceMapper(origins: source.sourceFileOrigins.toArray())
        for (module in source.modules) {
            if (let Some(message) <- identity.failure) {
                result.modules.add(fallbackModuleResult(module, identity, message))
                continue
            }
            try {
                let moduleDeclarations = ArrayList<SourceDeclaration>()
                let declarationsByKey = HashMap<String, SourceDeclaration>()
                let issued = HashMap<String, public_provider.SourceDeclarationId>()
                let issuer = public_provider.SourceDeclarationIssuer()
                for (declaration in source.declarations) {
                    if (!moduleOwnsDeclaration(module, declaration)) {
                        continue
                    }
                    if (issued.contains(declaration.sourceKey)) {
                        throw IllegalArgumentException("duplicate source declaration id in module")
                    }
                    moduleDeclarations.add(declaration)
                    declarationsByKey[declaration.sourceKey] = declaration
                    issued[declaration.sourceKey] = issuer.issue(declaration.sourceKey)
                }
                let moduleSourceFiles = HashSet<String>()
                for (pkg in source.packages) {
                    if (pkg.moduleId != module.id) {
                        continue
                    }
                    for (path in pkg.sourceFiles) {
                        let _ = moduleSourceFiles.add(path)
                    }
                }
                for (declaration in moduleDeclarations) {
                    let _ = moduleSourceFiles.add(declaration.source.path)
                }
                let views = ArrayList<public_provider.SourceDeclarationView>()
                for (declaration in moduleDeclarations) {
                    let parameters = ArrayList<public_provider.SourceParameterView>()
                    for (parameter in declaration.parameters) {
                        parameters.add(
                            public_provider.SourceParameterView(parameter.name, parameter.typeSpelling,
                                defaultExpression: parameter.defaultExpression))
                    }
                    let id = issued[declaration.sourceKey]
                    let owner: ?public_provider.SourceDeclarationId = match (declaration.ownerSourceKey) {
                        case Some(value) => match (issued.get(value)) {
                            case Some(ownerId) => Some(ownerId)
                            case None => throw IllegalArgumentException(
                                "source owner is outside the provider module transaction")
                        }
                        case None => None
                    }
                    views.add(
                        public_provider.SourceDeclarationView(id, declaration.kind, declaration.name,
                            declaration.packageName, declaration.visibility, declaration.genericParameters.size,
                            sourceMapper.range(declaration.source), declaration.sourceSignature,
                            declaration.enumNonExhaustive, ownerId: owner, parameters: parameters.toArray(),
                            returnTypeSpelling: declaration.returnTypeSpelling,
                            annotations: declaration.annotations.toArray()))
                }

                let semanticModule = public_provider.SemanticModule(module.id, module.name, module.role,
                    module.sourcePrefix)
                var openedSession: ?public_provider.SemanticProviderSession = None
                try {
                    openedSession = Some(factory.open(semanticModule))
                } catch (_: Exception) {
                    result.modules.add(fallbackModuleResult(module, identity, providerExceptionSummary("open")))
                }
                if (openedSession.isNone()) {
                    continue
                }
                let session = openedSession.getOrThrow()
                var stagedResult: ?ModuleSemanticResult = None
                var failureMessage: ?String = None
                try {
                    let batch = session.analyze(views)
                    let budget = ProviderBatchBudget(moduleDeclarations.size)
                    budget.consumeText(identity.name)
                    budget.consumeText(identity.version)
                    budget.consumeDeclarations(batch.declarations.size)
                    budget.consumeDiagnostics(batch.diagnostics.size)
                    if (!batch.capabilities.sourceBinding && !batch.declarations.isEmpty()) {
                        throw IllegalArgumentException(
                            "semantic provider returned declarations without sourceBinding capability")
                    }
                    let staged = ModuleSemanticResult(module.id, identity.name, identity.version,
                        SemanticCapabilities(batch.capabilities.sourceBinding, batch.capabilities.ownership,
                            batch.capabilities.visibility, batch.capabilities.canonicalTypes,
                            batch.capabilities.canonicalSignatures,
                            symbolRelationships: batch.capabilities.relationships,
                            annotations: batch.capabilities.annotations))
                    let returned = HashSet<String>()
                    for (item in batch.declarations) {
                        budget.consumeText(item.sourceId.serialize())
                        budget.consumeText(item.state)
                        let sourceKey = match (issuedSourceKey(issuer, issued, item.sourceId)) {
                            case Some(value) => value
                            case None => throw IllegalArgumentException(
                                "semantic provider returned an unknown or cross-session source declaration id")
                        }
                        if (!returned.add(sourceKey)) {
                            throw IllegalArgumentException(
                                "semantic provider returned a duplicate source declaration id")
                        }
                        let original = declarationsByKey[sourceKey]
                        let owner = match (item.ownerId) {
                            case Some(candidate) =>
                                budget.consumeText(candidate.serialize())
                                if (!batch.capabilities.ownership) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned ownership without ownership capability")
                                }
                                let key = match (issuedSourceKey(issuer, issued, candidate)) {
                                    case Some(value) => value
                                    case None => throw IllegalArgumentException(
                                        "semantic provider returned an unknown or cross-session owner id")
                                }
                                if (original.ownerSourceKey != Some(key)) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed source declaration ownership")
                                }
                                Some(key)
                            case None => original.ownerSourceKey
                        }
                        let visibility = match (item.visibility) {
                            case Some(value) =>
                                budget.consumeText(value)
                                if (!batch.capabilities.visibility) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned visibility without visibility capability")
                                }
                                if (!validProviderVisibility(value)) {
                                    throw IllegalArgumentException("semantic provider returned invalid visibility")
                                }
                                value
                            case None => original.visibility
                        }
                        if (item.canonicalSignature.isSome() && !batch.capabilities.canonicalSignatures) {
                            throw IllegalArgumentException(
                                "semantic provider returned canonical signature without capability")
                        }
                        if (let Some(canonicalSignature) <- item.canonicalSignature) {
                            budget.consumeText(canonicalSignature)
                            if (canonicalSignature.trimAscii().isEmpty()) {
                                throw IllegalArgumentException(
                                    "semantic provider returned an empty canonical signature")
                            }
                            if (item.state == "unavailable") {
                                throw IllegalArgumentException(
                                    "semantic provider attached a canonical signature to an unavailable declaration")
                            }
                        }
                        if (item.annotationsProvided && !batch.capabilities.annotations) {
                            throw IllegalArgumentException(
                                "semantic provider returned annotations without annotations capability")
                        }
                        budget.consumeRelationshipsAndAnnotations(item.annotations.size)
                        for (annotation in item.annotations) {
                            budget.consumeText(annotation)
                            if (annotation.isEmpty()) {
                                throw IllegalArgumentException(
                                    "semantic provider returned an empty annotation spelling")
                            }
                        }
                        if ((!item.typeRelationships.isEmpty() || !item.symbolRelationships.isEmpty()) &&
                            !batch.capabilities.relationships) {
                            throw IllegalArgumentException(
                                "semantic provider returned relationships without relationships capability")
                        }
                        budget.consumeRelationshipsAndAnnotations(item.typeRelationships.size)
                        budget.consumeRelationshipsAndAnnotations(item.symbolRelationships.size)
                        let semantic = SemanticDeclaration(sourceKey, original.kind, original.name, original.packageName,
                            original.moduleId, owner, visibility, item.state, identity.name,
                            canonicalSignature: item.canonicalSignature, isContainer: original.isContainer,
                            enumNonExhaustive: original.enumNonExhaustive)
                        semantic.genericParameters.add(all: original.genericParameters)
                        if (item.parameters.isEmpty()) {
                            for (parameter in original.parameters) {
                                semantic
                                    .parameters
                                    .add(
                                        SemanticParameter(parameter.name,
                                            TypeRef(parameter.typeSpelling, state: "partial")))
                            }
                        } else {
                            if (item.parameters.size != original.parameters.size) {
                                throw IllegalArgumentException("semantic provider changed declaration parameter count")
                            }
                            var parameterIndex: Int64 = 0
                            while (parameterIndex < item.parameters.size) {
                                budget.consumeText(item.parameters[parameterIndex].name)
                                if (item.parameters[parameterIndex].name != original.parameters[parameterIndex].name) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed declaration parameter name")
                                }
                                validateProviderType(item.parameters[parameterIndex].typeRef, batch.capabilities,
                                    identity.name, budget)
                                semantic
                                    .parameters
                                    .add(
                                        SemanticParameter(item.parameters[parameterIndex].name,
                                            providerType(item.parameters[parameterIndex].typeRef)))
                                parameterIndex++
                            }
                        }
                        semantic.returnType = match (item.returnType) {
                            case Some(value) =>
                                validateProviderType(value, batch.capabilities, identity.name, budget)
                                Some(providerType(value))
                            case None => match (original.returnTypeSpelling) {
                                case Some(value) => Some(TypeRef(value, state: "partial"))
                                case None => None
                            }
                        }
                        semantic.annotations.add(all: original.annotations)
                        if (item.annotationsProvided) {
                            semantic.providerAnnotations.add(all: item.annotations)
                        }
                        for (relationship in item.typeRelationships) {
                            budget.consumeText(relationship.kind)
                            validateProviderType(relationship.target, batch.capabilities, identity.name, budget)
                            semantic
                                .relationships
                                .add(TypeRelationship(relationship.kind, providerType(relationship.target)))
                        }
                        for (relationship in item.symbolRelationships) {
                            budget.consumeText(relationship.kind)
                            budget.consumeText(relationship.targetDisplay)
                            budget.consumeText(relationship.state)
                            if (let Some(targetId) <- relationship.targetSymbolId) {
                                budget.consumeText(targetId)
                                if (!validProviderSymbolId(targetId)) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned an invalid relationship target SymbolId")
                                }
                            }
                            let targetSourceKey: ?String = match (relationship.targetSourceId) {
                                case Some(target) =>
                                    budget.consumeText(target.serialize())
                                    match (issuedSourceKey(issuer, issued, target)) {
                                        case Some(value) => Some(value)
                                        case None => throw IllegalArgumentException(
                                            "semantic provider returned an unknown or cross-session relationship target id")
                                    }
                                case None => None
                            }
                            semantic
                                .symbolRelationships
                                .add(
                                    SymbolRelationship(relationship.kind, relationship.targetDisplay, relationship.state,
                                        targetSymbolId: relationship.targetSymbolId, targetSourceKey: targetSourceKey))
                        }
                        staged.declarations.add(semantic)
                    }
                    if ((batch.capabilities.canonicalTypes || batch.capabilities.visibility) &&
                        providerIntroducesSymbolIdConflict(moduleDeclarations, staged.declarations, identity.name)) {
                        throw IllegalArgumentException("semantic provider introduced conflicting SymbolIds")
                    }
                    for (diagnostic in batch.diagnostics) {
                        validateProviderDiagnostic(diagnostic, moduleSourceFiles, sourceMapper, budget)
                        staged
                            .diagnostics
                            .add(
                                Diagnostic(diagnostic.severity, diagnostic.code, diagnostic.message,
                                    source: match (diagnostic.source) {
                                        case Some(range) => Some(
                                            SourceLocation(range.path, range.start.line, range.start.column,
                                                range.end.line, range.end.column))
                                        case None => None
                                    }, symbolId: diagnostic.symbolId))
                    }
                    stagedResult = Some(staged)
                } catch (_: Exception) {
                    failureMessage = Some(providerExceptionSummary("analysis or validation"))
                }
                try {
                    session.close()
                } catch (_: Exception) {
                    failureMessage = Some(match (failureMessage) {
                        case Some(previous) => previous + "; " + providerExceptionSummary("close")
                        case None => providerExceptionSummary("close")
                    })
                }
                match (failureMessage) {
                    case Some(message) => result.modules.add(fallbackModuleResult(module, identity, message))
                    case None => result.modules.add(stagedResult.getOrThrow())
                }
            } catch (_: Exception) {
                result
                    .modules
                    .add(fallbackModuleResult(module, identity, providerExceptionSummary("module transaction")))
            }
        }
        return result
    }
}
