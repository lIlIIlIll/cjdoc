package cjdoc

import cjdoc.model as public_model
import std.collection.*

public class DocumentationEngine {
    public func generate(request: GenerationRequest): public_model.DocumentationSet {
        let semanticProvider: SemanticProvider = if (!request.providerFactories.isEmpty()) {
            FactorySemanticProviderAdapter(request.providerFactories[0])
        } else {
            match (request.chir) {
                case Some(options) => AutoChirSemanticProvider(options,
                    workerExecutable: request.astPreflightExecutable)
                case None => defaultSemanticProvider()
            }
        }
        let documentation = generateDocumentation(request, semanticProvider: semanticProvider)
        match (request.lintProfile) {
            case "off" => resolveDocumentationReferences(documentation)
            case "standard" => lintDocumentation(documentation, false)
            case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true)
            case _ => ()
        }
        if (request.checkExamples) {
            compileDocumentationExamples(documentation)
        }
        sortDocumentationDeterministically(documentation)
        let result = publicDocumentation(documentation, request)
        validateGeneratedDocIr(result)
        result
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) {
            results.add(generate(request))
        }
        results.toArray()
    }
}
