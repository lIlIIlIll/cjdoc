package cjdoc

import cjdoc.model as public_model
import std.collection.*

internal class GeneratedDocumentation {
    public let internalDocumentation: DocumentationSet
    public let publicDocumentation: public_model.DocumentationSet

    init(internalDocumentation: DocumentationSet,
        publicDocumentation: public_model.DocumentationSet) {
        this.internalDocumentation = internalDocumentation
        this.publicDocumentation = publicDocumentation
    }
}

internal func generateDocumentationWithSource(request: GenerationRequest,
    semanticProvider: SemanticProvider): GeneratedDocumentation {
    let documentation = generateDocumentation(request, semanticProvider: semanticProvider)
    let qualityConfig = loadDocumentationQualityConfig(request.projectRoot)
    match (request.lintProfile) {
        case "off" => resolveDocumentationReferences(documentation)
        case "standard" => lintDocumentation(documentation, false,
            qualityConfig: Some(qualityConfig), audience: request.audience)
        case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true,
            qualityConfig: Some(qualityConfig), audience: request.audience)
        case _ => ()
    }
    sortDocumentationDeterministically(documentation)
    let result = publicDocumentation(documentation, request)
    validateGeneratedDocIr(result)
    GeneratedDocumentation(documentation, result)
}
internal func generatePublicDocumentationWithSource(request: GenerationRequest,
    semanticProvider: SemanticProvider): (public_model.DocumentationSet, Array<SourceFileOrigin>) {
    let generated = generateDocumentationWithSource(request, semanticProvider)
    let origins = generated.internalDocumentation.sourceFileOrigins.toArray()
    (generated.publicDocumentation, origins)
}

public class DocumentationEngine {
    public func generate(request: GenerationRequest): public_model.DocumentationSet {
        let semanticProvider: SemanticProvider = if (request.providerFactories.isEmpty()) {
            defaultSemanticProvider()
        } else {
            FactorySemanticProviderAdapter(request.providerFactories[0])
        }
        generateDocumentationWithSource(request, semanticProvider).publicDocumentation
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) {
            results.add(generate(request))
        }
        results.toArray()
    }
}
