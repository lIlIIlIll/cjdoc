protected package cjdoc.binding

import cjdoc.documentation.comments.parseDocCommentAt
import cjdoc.source.model.SourceSnapshot
import std.collection.*

/**
 * Re-interpret bound declarations under their module's captured comment policy.
 *
 * The source cache and the parse worker stay policy-independent: a cached
 * comment is always the base parse of its raw text. When a module declares a
 * policy, its declarations are re-parsed in memory from the captured raw text
 * and position, so no source file is read twice and no cache key changes.
 */
protected func applyCommentSpecs(source: SourceSnapshot): Unit {
    if (source.commentSpecs.isEmpty()) { return }
    for (declaration in source.declarations) {
        let spec = match (source.commentSpecs.get(declaration.moduleId)) {
            case Some(value) => value
            case None => continue
        }
        let comment = match (declaration.documentation) {
            case Some(value) => value
            case None => continue
        }
        declaration.documentation = parseDocCommentAt(comment.raw, comment.commentSource,
            spec: Some(spec))
    }
}
