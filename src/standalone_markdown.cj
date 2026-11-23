package cjdoc

import cjdoc.highlight.highlightExternalOptions
import cjdoc.documentation.assets.LocalAssetCollector
import cjdoc.source.model.SourceFileOrigin
import cjdoc.documentation.markdown.{MarkdownGenerationContext, publicMarkdown}
import cjdoc.model as public_model
import std.collection.*

public func parseStandaloneMarkdown(body: String, highlightMode!: String = "auto",
    highlightAdapter!: ?String = None, highlightNode!: ?String = None): public_model.MarkdownNode {
    let source = public_model.SourceRange("conceptual.md", public_model.SourcePosition(1, 1, 0),
        public_model.SourcePosition(1, 1, 0))
    let assets = LocalAssetCollector(ArrayList<SourceFileOrigin>())
    let context = MarkdownGenerationContext(highlightMode: highlightMode,
        externalOptions: highlightExternalOptions(highlightAdapter, highlightNode))
    try { publicMarkdown(body, assets, "conceptual.md", source, "cjdoc:conceptual", context) }
    finally { context.highlightBudget.close() }
}
