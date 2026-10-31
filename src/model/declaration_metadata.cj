package cjdoc.model

/**
 * A declaration tag ID is 1–64 ASCII letters, digits, `-` or `_`.
 *
 * The rule is case-sensitive on purpose: `stream` and `Stream` are two tags, and
 * a filter compares complete IDs. Nothing here folds case or a script, because a
 * tag ID is a stable author-declared identity, not a display name. This is the
 * single published spelling of that rule; every producer, adapter and renderer
 * asks it instead of restating the alphabet.
 */
public func isDeclarationTagId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (byte in value.toArray()) {
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_') { continue }
        return false
    }
    true
}
