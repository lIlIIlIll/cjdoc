package cjdoc

import cjdoc.examples.compileDocumentationExamples
import cjdoc.semantic.SemanticProvider
import cjdoc.binding.{
    DocumentationSet, prepareDocumentationMetadata, resolveDocumentationReferences, sortDocumentationDeterministically}
import cjdoc.documentation.i18n.{bindLocalizedDocumentationItems, prepareDocumentationLanguages}
import cjdoc.documentation.i18n.coverage.withTranslationDiagnostics
import cjdoc.quality.lintDocumentation
import cjdoc.documentation.loadDocumentationQualityConfig
import cjdoc.model as public_model
import cjdoc.render as public_render
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
    GeneratedDocumentation(documentation, finishGeneratedDocumentation(documentation, request))
}

private func finishGeneratedDocumentation(documentation: DocumentationSet,
    request: GenerationRequest): public_model.DocumentationSet {
    prepareDocumentationMetadata(documentation)
    prepareDocumentationLanguages(documentation, request.projectRoot, request.i18n)
    let qualityConfig = loadDocumentationQualityConfig(request.projectRoot)
    match (request.lintProfile) {
        case "off" => resolveDocumentationReferences(documentation)
        case "standard" => lintDocumentation(documentation, false,
            qualityConfig: Some(qualityConfig), audience: request.audience)
        case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true,
            qualityConfig: Some(qualityConfig), audience: request.audience)
        case _ => ()
    }
    bindLocalizedDocumentationItems(documentation)
    if (request.checkExamples) {
        compileDocumentationExamples(documentation, request.audience, qualityConfig)
    }
    sortDocumentationDeterministically(documentation)
    let captured = publicDocumentation(documentation, request, capturePages: true)
    let translated = withTranslationDiagnostics(captured, request.projectRoot, request.requiredLanguages)
    let result = boundGeneratedDocumentation(translated, request)
    let validated = public_render.decodeDocIr(public_render.encodeDocIr(result))
    if (validated.schemaVersion != public_model.DOC_IR_SCHEMA_VERSION) {
        throw IllegalStateException("generated Doc IR did not validate as current schema")
    }
    result
}

public class DocumentationEngine {
    public func generate(request: GenerationRequest): public_model.DocumentationSet {
        let semanticProvider: SemanticProvider = if (!request.providerFactories.isEmpty()) {
            FactorySemanticProviderAdapter(request.providerFactories[0])
        } else {
            match (request.chir) {
                case Some(options) => AutoChirSemanticProvider(options)
                case None => defaultSemanticProvider()
            }
        }
        finishGeneratedDocumentation(generateDocumentation(request, semanticProvider: semanticProvider), request)
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) {
            results.add(generate(request))
        }
        results.toArray()
    }
}
