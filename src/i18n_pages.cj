package cjdoc

import cjdoc.highlight.highlightExternalOptions
import cjdoc.documentation.assets.LocalAssetCollector
import cjdoc.documentation.markdown.MarkdownGenerationContext
import cjdoc.dependency.navigation.ExternalDocResolver
import cjdoc.documentation.pages.captureDocumentationPagesWithContext
import cjdoc.model as public_model

internal func captureDocumentationPages(value: public_model.DocumentationSet,
    request: GenerationRequest, assetCollector!: ?LocalAssetCollector = None,
    sharedContext!: ?MarkdownGenerationContext = None,
    externalResolvers!: ?Array<ExternalDocResolver> = None): public_model.DocumentationSet {
    let config = request.highlight.getOrDefault({ => loadHighlightConfig(request.projectRoot) })
    let context = sharedContext.getOrDefault({ => MarkdownGenerationContext(
        highlightMode: if (config.mode == "off") { "off" } else { "auto" },
        allowLanguage: Some({ language: String => config.allowsLanguage(language) }),
        onError: config.onError,
        externalOptions: highlightExternalOptions(request.highlightAdapter, request.highlightNode)) })
    try {
        captureDocumentationPagesWithContext(value, request.projectRoot, assetCollector, context,
            externalResolvers)
    }
    finally { if (sharedContext.isNone()) { context.highlightBudget.close() } }
}
