package cjdoc

import std.collection.*
import std.sort.*

private func sortStringList(values: ArrayList<String>): Unit {
    sort(values)
}

private func optionalString(value: ?String): String {
    match (value) { case Some(text) => text case None => "" }
}

private func compareString(left: String, right: String): Int64 {
    if (left < right) { return -1 }
    if (right < left) { return 1 }
    0
}

private func compareInt(left: Int64, right: Int64): Int64 {
    if (left < right) { return -1 }
    if (right < left) { return 1 }
    0
}

private func compareBool(left: Bool, right: Bool): Int64 {
    if (left == right) { return 0 }
    if (!left && right) { -1 } else { 1 }
}

private func compareOptionalString(left: ?String, right: ?String): Int64 {
    if (left.isNone()) { return if (right.isNone()) { 0 } else { -1 } }
    if (right.isNone()) { return 1 }
    compareString(left.getOrThrow(), right.getOrThrow())
}

private func compareTypeRef(left: TypeRef, right: TypeRef): Int64 {
    var compared = compareString(left.kind, right.kind)
    if (compared != 0) { return compared }
    compared = compareString(left.display, right.display)
    if (compared != 0) { return compared }
    compared = compareBool(left.nullable, right.nullable)
    if (compared != 0) { return compared }
    compared = compareString(left.state, right.state)
    if (compared != 0) { return compared }
    compared = compareOptionalString(left.canonical, right.canonical)
    if (compared != 0) { return compared }
    var index: Int64 = 0
    while (index < left.arguments.size && index < right.arguments.size) {
        compared = compareTypeRef(left.arguments[index], right.arguments[index])
        if (compared != 0) { return compared }
        index++
    }
    compareInt(left.arguments.size, right.arguments.size)
}

private func compareSource(left: ?SourceLocation, right: ?SourceLocation): Int64 {
    if (left.isNone()) { return if (right.isNone()) { 0 } else { -1 } }
    if (right.isNone()) { return 1 }
    let leftValue = left.getOrThrow()
    let rightValue = right.getOrThrow()
    var compared = compareString(leftValue.path, rightValue.path)
    if (compared != 0) { return compared }
    compared = compareInt(leftValue.startLine, rightValue.startLine)
    if (compared != 0) { return compared }
    compared = compareInt(leftValue.startColumn, rightValue.startColumn)
    if (compared != 0) { return compared }
    compared = compareInt(leftValue.endLine, rightValue.endLine)
    if (compared != 0) { return compared }
    compareInt(leftValue.endColumn, rightValue.endColumn)
}

private func compareDiagnostic(left: Diagnostic, right: Diagnostic): Int64 {
    var compared = compareSource(left.source, right.source)
    if (compared != 0) { return compared }
    compared = compareString(left.code, right.code)
    if (compared != 0) { return compared }
    compared = compareString(left.severity, right.severity)
    if (compared != 0) { return compared }
    compared = compareString(left.message, right.message)
    if (compared != 0) { return compared }
    compareOptionalString(left.symbolId, right.symbolId)
}

private func moduleRoleRank(role: String): Int64 {
    match (role) {
        case "root" => 0
        case "workspace" => 1
        case "pathDependency" => 2
        case "externalDependency" => 3
        case _ => 3
    }
}

func sortDocumentationDeterministically(documentation: DocumentationSet): Unit {
    sort(documentation.modules, lessThan: { left, right =>
        let leftRank = moduleRoleRank(left.role)
        let rightRank = moduleRoleRank(right.role)
        leftRank < rightRank || (leftRank == rightRank && left.name < right.name) ||
            (leftRank == rightRank && left.name == right.name && left.id < right.id)
    }, stable: true)
    for (module in documentation.modules) {
        sortStringList(module.packageNames)
        sortStringList(module.dependencyIds)
    }
    sort(documentation.packages, lessThan: { left, right =>
        left.moduleId < right.moduleId || (left.moduleId == right.moduleId && left.name < right.name)
    }, stable: true)
    for (pkg in documentation.packages) {
        sortStringList(pkg.sourceFiles)
        sortStringList(pkg.symbolIds)
    }
    sort(documentation.symbols, lessThan: { left, right =>
        left.moduleId < right.moduleId ||
            (left.moduleId == right.moduleId && left.packageName < right.packageName) ||
            (left.moduleId == right.moduleId && left.packageName == right.packageName && left.id < right.id)
    }, stable: true)
    for (symbol in documentation.symbols) {
        sort(symbol.relationships, lessThan: { left, right =>
            let comparedKind = compareString(left.kind, right.kind)
            comparedKind < 0 ||
                (comparedKind == 0 && compareTypeRef(left.target, right.target) < 0)
        }, stable: true)
        sort(symbol.symbolRelationships, lessThan: { left, right =>
            left.kind < right.kind ||
                (left.kind == right.kind && left.targetDisplay < right.targetDisplay) ||
                (left.kind == right.kind && left.targetDisplay == right.targetDisplay &&
                    left.state < right.state) ||
                (left.kind == right.kind && left.targetDisplay == right.targetDisplay &&
                    left.state == right.state &&
                    optionalString(left.targetSymbolId) < optionalString(right.targetSymbolId))
        }, stable: true)
    }
    sort(documentation.orphanDocComments, lessThan: { left, right =>
        left.source.path < right.source.path ||
            (left.source.path == right.source.path && left.source.startLine < right.source.startLine) ||
            (left.source.path == right.source.path && left.source.startLine == right.source.startLine &&
                left.source.startColumn < right.source.startColumn)
    }, stable: true)
    sort(documentation.macroInvocations, lessThan: { left, right =>
        left.source.path < right.source.path ||
            (left.source.path == right.source.path && left.source.startLine < right.source.startLine) ||
            (left.source.path == right.source.path && left.source.startLine == right.source.startLine &&
                left.source.startColumn < right.source.startColumn) ||
            (left.source.path == right.source.path && left.source.startLine == right.source.startLine &&
                left.source.startColumn == right.source.startColumn && left.name < right.name)
    }, stable: true)
    sort(documentation.unsupportedDeclarations, lessThan: { left, right =>
        left.source.path < right.source.path ||
            (left.source.path == right.source.path && left.source.startLine < right.source.startLine) ||
            (left.source.path == right.source.path && left.source.startLine == right.source.startLine &&
                left.name < right.name)
    }, stable: true)
    sort(documentation.diagnostics, lessThan: { left, right =>
        compareDiagnostic(left, right) < 0
    }, stable: true)
}
