package cjdoc

import std.collection.*

/**
 * Validate every `@tag` line of one declaration comment.
 *
 * A tag is presentation-free classification metadata: it never enters the
 * behavior contract set, the contract quality score or a translation field. Only
 * a single ASCII identifier with no trailing arguments is valid, and duplicates
 * of a valid ID collapse silently because a tag set is a set. An invalid tag is
 * reported and excluded from the effective set; the declaration itself, its
 * other tags and its prose are untouched.
 */
internal func validateDeclarationTags(documentation: DocumentationSet, symbol: SymbolDoc,
    comment: DocComment): Unit {
    for (tag in comment.contracts where tag.name == "tag") {
        if (isValidDeclarationTagTag(tag)) { continue }
        documentation.diagnostics.add(Diagnostic("error", "CJDOC3132",
            "@tag requires one ASCII identifier (1-64 letters, digits, '-' or '_') with no extra arguments",
            source: comment.commentSource, symbolId: Some(symbol.id)))
    }
}

private func isValidDeclarationTagTag(tag: DocTag): Bool {
    isDeclarationTagId(tag.subject) && tag.description.isEmpty()
}
