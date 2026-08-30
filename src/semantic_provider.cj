package cjdoc

private func astTypeRef(spelling: String): TypeRef {
    if (spelling.isEmpty()) {
        return TypeRef("", state: "unavailable")
    }
    return TypeRef(spelling, state: "partial")
}

// AstSemanticProvider deliberately exposes only semantics that std.ast can
// establish without type checking. Type spellings are useful but never
// promoted to canonical/resolved types.
class AstSemanticProvider <: SemanticProvider {
    public func providerName(): String { "ast" }
    public func providerVersion(): String { "1" }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult()
        for (module in source.modules) {
            let moduleResult = ModuleSemanticResult(module.id, providerName(), providerVersion(),
                SemanticCapabilities(true, true, true, false, false))
            for (declaration in source.declarations) {
                if (declaration.moduleId != module.id) { continue }
                let semantic = SemanticDeclaration(
                declaration.sourceKey,
                declaration.kind,
                declaration.name,
                declaration.packageName,
                declaration.moduleId,
                declaration.ownerSourceKey,
                declaration.visibility,
                "partial",
                providerName(),
                isContainer: declaration.isContainer
            )
                semantic.genericParameters.add(all: declaration.genericParameters)
                for (parameter in declaration.parameters) {
                    semantic.parameters.add(SemanticParameter(parameter.name,
                        astTypeRef(parameter.typeSpelling)))
                }
                if (let Some(spelling) <- declaration.returnTypeSpelling) {
                    semantic.returnType = Some(astTypeRef(spelling))
                }
                semantic.annotations.add(all: declaration.annotations)
                for (relationship in declaration.relationships) {
                    semantic.relationships.add(TypeRelationship(relationship.kind,
                        astTypeRef(relationship.targetSpelling)))
                }
                for (relationship in declaration.symbolRelationships) {
                    semantic.symbolRelationships.add(SymbolRelationship(relationship.kind,
                        relationship.targetDisplay, "unavailable"))
                }
                moduleResult.declarations.add(semantic)
            }
            result.modules.add(moduleResult)
        }
        return result
    }
}
