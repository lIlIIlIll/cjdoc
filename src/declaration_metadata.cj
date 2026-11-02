package cjdoc

import cjdoc.model.{isDeclarationTagId as model_isDeclarationTagId}
import cjdoc.model.*

/**
 * A declaration tag ID is 1–64 ASCII letters, digits, `-` or `_`.
 *
 * The rule is case-sensitive on purpose: `stream` and `Stream` are two tags and a
 * filter compares complete IDs. Nothing here folds case or a script, because a
 * tag ID is a stable author-declared identity, not a display name.
 */
internal func isDeclarationTagId(value: String): Bool {
    model_isDeclarationTagId(value)
}

/**
 * One `@tag` line split into its ID and any trailing argument text.
 *
 * `rest` exists so validation can name surplus arguments instead of silently
 * turning them into another tag or into prose.
 */
internal class DeclarationTagLine {
    let id: String
    let rest: String

    init(id: String, rest: String) {
        this.id = id
        this.rest = rest
    }
}

/**
 * Split `@tag` content into an ID and any trailing arguments.
 *
 * The split is byte-exact and does not repair a partly valid subject: the line
 * `@tag stream extra` yields ID `stream` plus `extra` so validation can report
 * the surplus argument.
 */
internal func declarationTagLine(rest: String): DeclarationTagLine {
    let trimmed = rest.trimAscii()
    var end: Int64 = 0
    while (end < trimmed.size) {
        let byte = trimmed[end]
        if (byte == b' ' || byte == b'\t') { break }
        end++
    }
    DeclarationTagLine(trimmed[..end], trimmed[end..].trimAscii())
}
