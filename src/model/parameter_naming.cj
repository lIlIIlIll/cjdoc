package cjdoc.model

import std.collection.*

/*
 * A positional enum payload has no source identifier. The source collector
 * therefore stores a synthetic `_<index>` placeholder so Doc IR v20 keeps the
 * existing `parameters[].name` wire shape. That placeholder is not an author
 * name, so the only published spelling of its meaning lives here: renderers
 * project `#<index>` and `@param` matching resolves the same selector.
 */

/**
 * True when a declaration kind carries positional payload parameters.
 *
 * Only enum cases lack identifiers for their payload; every other declaration
 * kind in Doc IR has a real parameter name.
 */
public func positionalPayloadKind(kind: String): Bool {
    kind == "enumCase"
}

/** The reader-facing spelling of a positional payload: `#0`, `#1`, ... */
public func positionalPayloadDisplay(index: Int64): String {
    "#" + index.toString()
}

/**
 * Parse a positional selector into a zero-based index.
 *
 * Author syntax is `#<digits>`; the stored `_<digits>` placeholder is accepted
 * as well so a name already captured in Doc IR addresses the same payload.
 * Empty, signed, padded, trailing-text and overflowing spellings are not
 * positions and return `None`.
 */
public func positionalPayloadIndex(value: String): ?Int64 {
    if (value.size < 2) { return None }
    let marker = value[0]
    if (marker != b'#' && marker != b'_') { return None }
    if (value.size > 2 && value[1] == b'0') { return None }
    var index: Int64 = 0
    for (position in 1..value.size) {
        let byte = value[position]
        if (byte < b'0' || byte > b'9') { return None }
        let digit = Int64(byte - b'0')
        if (index > 922337203685477580 ||
            (index == 922337203685477580 && digit > 7)) { return None }
        index = index * 10 + digit
    }
    Some(index)
}

/**
 * Resolve a parameter's stored name to its reader-facing spelling.
 *
 * `kind` is the owning declaration kind, so a non-enum declaration keeps an
 * author-written leading-underscore name unchanged.
 */
public func parameterDisplayName(kind: String, name: String): String {
    if (!positionalPayloadKind(kind)) { return name }
    match (positionalPayloadIndex(name)) {
        case Some(index) => positionalPayloadDisplay(index)
        case None => name
    }
}

/** Readable spelling of an author selector under its declaration kind. */
public func parameterSubjectDisplay(kind: String, subject: String): String {
    parameterDisplayName(kind, subject)
}

/**
 * True when a documented subject selects the parameter stored under `name`.
 *
 * A named parameter matches only its own name. A positional payload matches
 * either its ordinal selector or the stored placeholder, so both spellings
 * address one payload and a named `_0` on a function is never a position.
 */
public func parameterMatchesSubject(kind: String, name: String, subject: String): Bool {
    if (!positionalPayloadKind(kind)) { return name == subject }
    if (name == subject) { return true }
    match (positionalPayloadIndex(name)) {
        case Some(index) => positionalPayloadIndex(subject) == index
        case None => false
    }
}

/** First `@param`-style tag whose subject selects the given parameter. */
public func findParameterTag(kind: String, tags: ReadOnlyList<DocTag>,
    name: String): ?DocTag {
    for (tag in tags) {
        if (tag.name != "param") { continue }
        if (parameterMatchesSubject(kind, name, tag.subject)) { return Some(tag) }
    }
    None
}
