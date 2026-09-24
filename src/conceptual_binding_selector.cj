package cjdoc

import cjdoc.model as public_model

/**
 * Match an explicit source-spelling selector without parsing Cangjie types or
 * constructing a SymbolId. Existing type/member selectors remain descriptive.
 * An exact header is deliberately not advertised as a canonical signature.
 */
internal func conceptualBindingMatches(symbol: public_model.SymbolDoc, target: String, selector: String): Bool {
    let identityMatches = if (target.startsWith("id:")) {
        symbol.id == target.removePrefix("id:")
    } else {
        symbol.qualifiedName == target
    }
    if (!identityMatches) { return false }
    if (selector.startsWith("signature:")) {
        let header = selector.removePrefix("signature:")
        return !header.isEmpty() && symbol.headerSpelling == header
    }
    true
}
