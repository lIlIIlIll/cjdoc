protected package cjdoc.documentation.markdown

import cjdoc.documentation.assets.LocalAssetCollector
import cjdoc.model as public_model
import std.collection.*

protected func parseCapturedPageMarkdown(body: String, assetCollector: LocalAssetCollector,
    sourcePath: String, context: MarkdownGenerationContext,
    bindingLines!: ?HashSet<Int64> = None): (String, public_model.MarkdownNode, HashSet<Int64>) {
    let source = public_model.SourceRange(sourcePath, public_model.SourcePosition(1, 1, 0),
        public_model.SourcePosition(1, 1, 0))
    let (prepared, text, positions) = prepareCapturedPageBindings(body, sourcePath, bindingLines)
    let tree = publicMarkdown(prepared, assetCollector, sourcePath, source, "", context, bindingPositions: Some(positions))
    let accepted = HashSet<Int64>()
    for ((_, position) in positions) { let _ = accepted.add(position.source.start.line) }
    (text, tree, accepted)
}
