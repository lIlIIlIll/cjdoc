package cjdoc

import std.ast.*
import std.collection.*

// Source structure is navigation evidence, not compiler type resolution. Every
// candidate still requires a matching visible declaration in a validated index.
internal class DependencyTypeShape {
    let head: String
    let kind: String
    let children: Array<DependencyTypeShape>
    let spelling: String
    let nullable: Bool

    init(head: String, kind: String, children: Array<DependencyTypeShape>,
        spelling: String, nullable: Bool) {
        this.head = head
        this.kind = kind
        this.children = children
        this.spelling = spelling
        this.nullable = nullable
    }
}

private func dependencyNodeSpelling(node: TypeNode, source: IndexedSourceBuffer): String {
    let tokens = node.toTokens()
    var end = tokens.size
    while (end > 0 && (tokens[end - 1].kind == NL || tokens[end - 1].value == ",")) { end-- }
    if (end == 0) { return "" }
    let first = tokens[0]
    let last = tokens[end - 1]
    let (endLine, endColumn) = tokenEndPosition(last)
    match (sourceLocationFromAstRange("", source, Int64(first.pos.line),
        Int64(first.pos.column), endLine, endColumn)) {
        case Some(location) => source.slice(location).trimAscii()
        case None => ""
    }
}

private func dependencyTypeChildren(nodes: ArrayList<TypeNode>, source: IndexedSourceBuffer,
    depth: Int64): ?Array<DependencyTypeShape> {
    let result = ArrayList<DependencyTypeShape>()
    for (node in nodes) {
        match (dependencyShapeFromAst(node, source, depth + 1)) {
            case Some(shape) => result.add(shape)
            case None => return None
        }
    }
    Some(result.toArray())
}

private func dependencyNamedShape(head: String, arguments: ArrayList<TypeNode>,
    spelling: String, source: IndexedSourceBuffer, depth: Int64): ?DependencyTypeShape {
    if (head.isEmpty()) { return None }
    let children = match (dependencyTypeChildren(arguments, source, depth)) {
        case Some(value) => value
        case None => return None
    }
    Some(DependencyTypeShape(head, if (children.isEmpty()) { "named" } else { "generic" },
        children, spelling, false))
}

private func dependencyOptionalShape(node: PrefixType, source: IndexedSourceBuffer,
    depth: Int64): ?DependencyTypeShape {
    var inner = match (dependencyShapeFromAst(node.baseType, source, depth + 1)) {
        case Some(value) => value
        case None => return None
    }
    let operators = node.prefixOps
    var index = operators.size
    if (index == 0) { return None }
    let baseTokens = node.baseType.toTokens()
    var baseEnd = baseTokens.size
    while (baseEnd > 0 && (baseTokens[baseEnd - 1].kind == NL ||
        baseTokens[baseEnd - 1].value == ",")) { baseEnd-- }
    if (baseEnd == 0) { return None }
    let (endLine, endColumn) = tokenEndPosition(baseTokens[baseEnd - 1])
    while (index > 0) {
        index--
        if (operators[index].value != "?") { return None }
        let location = match (sourceLocationFromAstRange("", source,
            Int64(operators[index].pos.line), Int64(operators[index].pos.column), endLine, endColumn)) {
            case Some(value) => value
            case None => return None
        }
        inner = DependencyTypeShape("", "optional", [inner], source.slice(location).trimAscii(), true)
    }
    Some(inner)
}

private func dependencyFunctionShape(node: FuncType, spelling: String,
    source: IndexedSourceBuffer, depth: Int64): ?DependencyTypeShape {
    let parameters = match (dependencyTypeChildren(node.types, source, depth)) {
        case Some(value) => value
        case None => return None
    }
    let result = match (dependencyShapeFromAst(node.returnType, source, depth + 1)) {
        case Some(value) => value
        case None => return None
    }
    let children = ArrayList<DependencyTypeShape>(parameters)
    children.add(result)
    Some(DependencyTypeShape("", "function", children.toArray(), spelling, false))
}

private func dependencyShapeFromAst(node: TypeNode, source: IndexedSourceBuffer,
    depth: Int64): ?DependencyTypeShape {
    if (depth > 64) { return None }
    let spelling = dependencyNodeSpelling(node, source)
    if (spelling.isEmpty()) { return None }
    match (node) {
        case primitive: PrimitiveType =>
            Some(DependencyTypeShape(primitive.keyword.value, "primitive", [], spelling, false))
        case reference: RefType =>
            dependencyNamedShape(reference.identifier.value, reference.typeArguments, spelling, source, depth)
        case qualified: QualifiedType =>
            let base = match (dependencyShapeFromAst(qualified.baseType, source, depth + 1)) {
                case Some(value) => value
                case None => return None
            }
            // A generic receiver is a member-type lookup, not a package path.
            if (base.kind != "named") { return None }
            dependencyNamedShape(base.head + "." + qualified.identifier.value,
                qualified.typeArguments, spelling, source, depth)
        case prefix: PrefixType => dependencyOptionalShape(prefix, source, depth)
        case tuple: TupleType =>
            match (dependencyTypeChildren(tuple.types, source, depth)) {
                case Some(children) => Some(DependencyTypeShape("", "tuple", children, spelling, false))
                case None => None
            }
        case function: FuncType => dependencyFunctionShape(function, spelling, source, depth)
        case parenthesized: ParenType =>
            match (dependencyShapeFromAst(parenthesized.parenthesizedType, source, depth + 1)) {
                case Some(inner) => Some(DependencyTypeShape(inner.head, inner.kind,
                    inner.children, spelling, inner.nullable))
                case None => None
            }
        case _ => None
    }
}

// The parser sees only a type fragment. Checking its consumed token range keeps
// an otherwise valid prefix of malformed input from becoming binding evidence.
internal func dependencyTypeShape(spelling: String): ?DependencyTypeShape {
    if (spelling.trimAscii().isEmpty()) { return None }
    try {
        let tokens = sourceLexerTokens(spelling)
        let (node, end) = parseTypeFragment(tokens)
        for (index in end..tokens.size) {
            if (tokens[index].kind != NL && tokens[index].kind != COMMENT &&
                !tokens[index].value.isEmpty()) { return None }
        }
        dependencyShapeFromAst(node, IndexedSourceBuffer(spelling), 0)
    } catch (_: Exception) {
        None
    }
}


private func dependencyImportedSuffix(head: String, localName: String): ?String {
    if (localName.isEmpty()) { return None }
    if (head == localName) { return Some("") }
    if (head.startsWith(localName + ".")) {
        let member = head.removePrefix(localName + ".")
        // A package exposes its members, not its subpackages.
        if (!member.contains(".")) { return Some("." + member) }
    }
    None
}

private func dependencyImportPath(prefix: String, tail: String): String {
    if (prefix.isEmpty()) { return tail }
    if (tail.isEmpty()) { return prefix }
    prefix + "." + tail
}

private class DependencyImportBinding {
    let localName: String
    let target: String
    let conditional: Bool
    init(localName: String, target: String, conditional: Bool) {
        this.localName = localName; this.target = target; this.conditional = conditional
    }
}

// Parse each captured file/import fragment once. Only compact lexical selectors,
// not AST nodes or host paths, survive into candidate lookups.
internal class DependencyImportIndex {
    private let named = HashMap<String, ArrayList<DependencyImportBinding>>()
    private let wildcards = ArrayList<DependencyImportBinding>()
    private var failed: Bool = false

    init(origin: SourceFileOrigin, work: DependencyNavigationWork) {
        if (!work.consumeBytes(origin.capturedSource.size)) { failed = true; return }
        try {
            let imports = if (origin.capturedSource.isEmpty()) { origin.imports } else {
                sourceImportTextsFromSource(origin.logicalPath, origin.capturedSource, true).toArray()
            }
            for (text in imports) {
                if (!work.take() || !work.consumeBytes(text.size)) { failed = true; return }
                let tokens = sourceLexerTokens(text)
                var conditional = false
                for (token in tokens) { if (token.kind == AT) { conditional = true; break } }
                let importTokens = if (conditional) {
                    let statements = sourceImportTextsFromSource(origin.logicalPath, text, false)
                    if (statements.size != 1) { failed = true; return }
                    sourceLexerTokens(statements[0])
                } else { tokens }
                let program = parseProgram(importTokens)
                for (item in program.importLists) { capture(item.content, "", "", conditional, work, 0) }
                if (failed) { return }
            }
        } catch (_: Exception) { failed = true }
    }

    private func capture(content: ImportContent, inheritedPrefix: String, inheritedOrganization: String,
        conditional: Bool, work: DependencyNavigationWork, depth: Int64): Unit {
        if (depth >= 128 || !work.take()) { failed = true; return }
        let prefix = dependencyImportPath(inheritedPrefix,
            joinedImportPath(ArrayList<String>(importPrefixPaths(content.prefixPaths))))
        let organization = if (content.orgName.value.isEmpty()) { inheritedOrganization } else { content.orgName.value }
        let organizationPrefix = if (organization.isEmpty()) { "" } else { organization + "::" }
        match (content.importKind) {
            case ImportKind.Multi =>
                for (item in content.items) { capture(item, prefix, organization, conditional, work, depth + 1) }
            case ImportKind.All => wildcards.add(DependencyImportBinding("", organizationPrefix + prefix, conditional))
            case ImportKind.Single | ImportKind.Alias =>
                let imported = content.identifier.value
                let localName = importAliasName(content.importAlias).getOrDefault({ => imported })
                let binding = DependencyImportBinding(localName,
                    organizationPrefix + dependencyImportPath(prefix, imported), conditional)
                match (named.get(localName)) {
                    case Some(values) => values.add(binding)
                    case None => named[localName] = ArrayList<DependencyImportBinding>([binding])
                }
        }
    }

    private func appendMatches(bindings: ArrayList<DependencyImportBinding>, head: String,
        candidates: ArrayList<String>, seen: HashSet<String>, work: DependencyNavigationWork): Bool {
        for (binding in bindings) {
            if (!work.take() || !work.consumeBytes(binding.target.size + head.size + 1)) { return false }
            let candidate = if (binding.localName.isEmpty()) { dependencyImportPath(binding.target, head) }
                else if (let Some(suffix) <- dependencyImportedSuffix(head, binding.localName)) { binding.target + suffix }
                else { continue }
            if (binding.conditional) { return false }
            if (seen.add(candidate)) { candidates.add(candidate) }
        }
        true
    }

    func candidates(head: String, work: DependencyNavigationWork): Array<String> {
        if (failed || !work.consumeBytes(head.size)) { return [] }
        let result = ArrayList<String>()
        let seen = HashSet<String>()
        let dot = head.indexOf(".").getOrDefault({ => head.size })
        if (let Some(bindings) <- named.get(head[..dot])) {
            if (!appendMatches(bindings, head, result, seen, work)) { return [] }
        }
        if (dot == head.size) {
            if (!appendMatches(wildcards, head, result, seen, work)) { return [] }
            // Verified language-level implicit package import, not a whitelist
            // of names guessed to belong to whichever SDK runs the generator.
            let implicit = "std.core." + head
            if (seen.add(implicit)) { result.add(implicit) }
        }
        result.toArray()
    }
}

internal func dependencyImportCandidates(origin: SourceFileOrigin, spelling: String): Array<String> {
    let shape = match (dependencyTypeShape(spelling)) { case Some(value) => value; case None => return [] }
    if (shape.kind != "named" && shape.kind != "generic") { return [] }
    let work = DependencyNavigationWork()
    DependencyImportIndex(origin, work).candidates(shape.head, work)
}
