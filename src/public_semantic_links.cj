package cjdoc

import cjdoc.model as public_model
import std.collection.*

private func semanticLinkVisible(symbol: public_model.SymbolDoc, audience: String,
    index: HashMap<String, public_model.SymbolDoc>): Bool {
    var current: ?public_model.SymbolDoc = Some(symbol)
    while (current.isSome()) {
        let value = current.getOrThrow()
        let visible = match (audience) {
            case "external" => value.visibility == "public" || value.visibility == "protected"
            case "package" => value.visibility != "private"
            case _ => true
        }
        if (!visible) { return false }
        current = match (value.ownerId) {
            case Some(ownerId) => index.get(ownerId)
            case None => None
        }
    }
    true
}

private func semanticLinkBase(target: String): String {
    match (target.indexOf("(")) {
        case Some(index) => target[..index]
        case None => target
    }
}

private func semanticLinkSignature(target: String): ?String {
    match (target.indexOf("(")) {
        case Some(index) =>
            let end = if (target.endsWith(")")) { target.size - 1 } else { target.size }
            if (end <= index + 1) { Some("") } else { Some(target[index + 1..end]) }
        case None => None
    }
}
private func semanticLinkTypeKey(value: String): String {
    value.trimAscii().replace(" ", "").replace("\t", "")
}

private func semanticLinkParameterTypeParts(signature: String): Array<String> {
    let parts = ArrayList<String>()
    let value = signature.trimAscii()
    if (value.isEmpty()) { return parts.toArray() }
    var start: Int64 = 0
    var angleDepth: Int64 = 0
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    var index: Int64 = 0
    while (index < value.size) {
        match (value[index]) {
            case b'<' => angleDepth++
            case b'>' => if (angleDepth > 0) { angleDepth-- }
            case b'(' => roundDepth++
            case b')' => if (roundDepth > 0) { roundDepth-- }
            case b'[' => squareDepth++
            case b']' => if (squareDepth > 0) { squareDepth-- }
            case b',' =>
                if (angleDepth == 0 && roundDepth == 0 && squareDepth == 0) {
                    parts.add(value[start..index].trimAscii())
                    start = index + 1
                }
            case _ => ()
        }
        index++
    }
    parts.add(value[start..value.size].trimAscii())
    parts.toArray()
}

private func semanticLinkStructuredSignatureMatches(signature: String,
    candidate: public_model.SymbolDoc): Bool {
    if (signature.isEmpty()) { return candidate.parameters.isEmpty() }
    let expected = semanticLinkParameterTypeParts(signature)
    if (expected.size != candidate.parameters.size) { return false }
    var index: Int64 = 0
    while (index < expected.size) {
        let actual = candidate.parameters[index].typeRef
        let wanted = semanticLinkTypeKey(expected[index])
        let spellingMatches = wanted == semanticLinkTypeKey(actual.spelling)
        let canonicalMatches = match (actual.semantic.canonical) {
            case Some(canonical) => wanted == semanticLinkTypeKey(canonical)
            case None => false
        }
        if (!spellingMatches && !canonicalMatches) { return false }
        index++
    }
    true
}

private func semanticLinkCandidate(target: String, owner: public_model.SymbolDoc,
    candidate: public_model.SymbolDoc): Bool {
    if (candidate.moduleId != owner.moduleId) { return false }
    if (target == candidate.id) { return true }
    let base = semanticLinkBase(target)
    let signature = semanticLinkSignature(target)
    let baseMatches = base == candidate.qualifiedName || base == candidate.name ||
        base == "${candidate.packageName}.${candidate.name}" ||
        base == "${candidate.packageName}.${candidate.qualifiedName}"
    if (!baseMatches) { return false }
    match (signature) {
        case Some(value) => semanticLinkStructuredSignatureMatches(value, candidate)
        case None => true
    }
}

private func semanticLinkScore(target: String, owner: public_model.SymbolDoc,
    candidate: public_model.SymbolDoc): Int64 {
    var score: Int64 = if (candidate.packageName == owner.packageName) { 4 } else { 0 }
    let base = semanticLinkBase(target)
    let signature = semanticLinkSignature(target)
    if (target == candidate.id) { score += 16 }
    if (base == candidate.qualifiedName) { score += 12 }
    if (base == "${candidate.packageName}.${candidate.qualifiedName}") { score += 10 }
    if (base == candidate.name) { score += 4 }
    match (signature) {
        case Some(_) => score += 18
        case None => ()
    }
    score
}

private func semanticLinkStableHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

private func semanticLinkLocalUrl(symbolId: String): String {
    let digits = "0123456789abcdef"
    let out = StringBuilder()
    for (byte in symbolId.toArray()) {
        let high = Int64((byte >> 4) & 15)
        let low = Int64(byte & 15)
        out.append(digits[high..high + 1])
        out.append(digits[low..low + 1])
    }
    let slug = out.toString()
    let bounded = if (slug.size <= 96) { slug } else {
        slug[..64] + "--" + semanticLinkStableHash(symbolId)
    }
    "symbols/symbol-${bounded}.html"
}

private func semanticLinkDiagnostic(symbol: public_model.SymbolDoc, code: String,
    message: String): public_model.Diagnostic {
    public_model.Diagnostic("warning", code, message, source: Some(symbol.source), symbolId: Some(symbol.id))
}

private func resolveExternalLink(target: String, resolvers: Array<ExternalDocResolver>): (String, String) {
    var resolvedUrl = ""
    var ambiguous = false
    var unavailable = false
    for (resolver in resolvers) {
        if (resolver.state != "available") {
            unavailable = true
            continue
        }
        let (url, isAmbiguous) = resolver.matchTarget(target)
        if (isAmbiguous) {
            ambiguous = true
        } else if (!url.isEmpty()) {
            if (!resolvedUrl.isEmpty() && resolvedUrl != url) { ambiguous = true }
            resolvedUrl = url
        }
    }
    if (ambiguous) { return ("ambiguous", "") }
    if (!resolvedUrl.isEmpty()) { return ("resolved", resolvedUrl) }
    if (unavailable) { return ("unavailable", "") }
    ("unresolved", "")
}

private func resolveSemanticLinkNode(node: public_model.MarkdownNode, owner: public_model.SymbolDoc,
    declarations: Array<public_model.SymbolDoc>, index: HashMap<String, public_model.SymbolDoc>,
    audience: String, resolvers: Array<ExternalDocResolver>,
    diagnostics: ArrayList<public_model.Diagnostic>): Unit {
    if (node.kind == "semantic_link") {
        match (node.metadata) {
            case Some(metadata) =>
                let target = metadata.semanticTarget.getOrThrow()
                var bestScore: Int64 = -1
                let matches = ArrayList<public_model.SymbolDoc>()
                for (candidate in declarations) {
                    if (!semanticLinkVisible(candidate, audience, index) ||
                        !semanticLinkCandidate(target, owner, candidate)) { continue }
                    let score = semanticLinkScore(target, owner, candidate)
                    if (score > bestScore) {
                        bestScore = score
                        matches.clear()
                        matches.add(candidate)
                    } else if (score == bestScore) {
                        matches.add(candidate)
                    }
                }
                if (matches.size == 1) {
                    let resolved = matches[0]
                    metadata.semanticState = "resolved"
                    metadata.semanticTargetSymbolId = Some(resolved.id)
                    metadata.semanticExternalUrl = Some(semanticLinkLocalUrl(resolved.id))
                } else if (matches.size > 1) {
                    metadata.semanticState = "ambiguous"
                    metadata.semanticTargetSymbolId = None
                    metadata.semanticExternalUrl = None
                    match (semanticLinkSeverity(config, "ambiguous-link")) {
                        case Some(severity) => diagnostics.add(semanticLinkDiagnostic(owner, severity, "CJDOC2030",
                            "semantic link target '${target}' is ambiguous"))
                        case None => ()
                    }
                } else {
                    let (state, url) = resolveExternalLink(target, resolvers)
                    metadata.semanticState = state
                    metadata.semanticTargetSymbolId = None
                    metadata.semanticExternalUrl = if (state == "resolved") { Some(url) } else { None }
                    if (state != "resolved") {
                        let code = if (state == "ambiguous") { "CJDOC2030" }
                            else if (state == "unavailable") { "CJDOC2031" } else { "CJDOC2032" }
                        let message = if (state == "ambiguous") {
                            "semantic link target '${target}' is ambiguous"
                        } else if (state == "unavailable") {
                            "semantic link target '${target}' is unavailable because an external index is stale or missing"
                        } else {
                            "semantic link target '${target}' could not be resolved"
                        }
                        let rule = if (state == "ambiguous") { "ambiguous-link" } else { "unresolved-type-link" }
                        match (semanticLinkSeverity(config, rule)) {
                            case Some(severity) => diagnostics.add(semanticLinkDiagnostic(owner, severity, code, message))
                            case None => ()
                        }
                    }
                }
            case None => ()
        }
    }
    for (child in node.children) {
        resolveSemanticLinkNode(child, owner, declarations, index, audience, resolvers, diagnostics)
    }
}

internal func resolvePublicSemanticLinks(declarations: Array<public_model.SymbolDoc>, audience: String,
    projectRoot: String): Array<public_model.Diagnostic> {
    let index = HashMap<String, public_model.SymbolDoc>()
    for (symbol in declarations) { index[symbol.id] = symbol }
    let resolvers = loadExternalDocResolvers(projectRoot)
    let diagnostics = ArrayList<public_model.Diagnostic>()
    for (symbol in declarations) {
        match (symbol.documentation) {
            case Some(comment) => resolveSemanticLinkNode(comment.markdown, symbol, declarations, index,
                audience, resolvers, diagnostics)
            case None => ()
        }
    }
    diagnostics.toArray()
}
