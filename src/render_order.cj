package cjdoc

import std.collection.*
import std.sort.*

private func sortStringList(values: ArrayList<String>): Unit {
    sort(values)
}

private func optionalString(value: ?String): String {
    match (value) { case Some(text) => text case None => "" }
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
            left.kind < right.kind ||
                (left.kind == right.kind && left.target.display < right.target.display) ||
                (left.kind == right.kind && left.target.display == right.target.display &&
                    left.target.state < right.target.state) ||
                (left.kind == right.kind && left.target.display == right.target.display &&
                    left.target.state == right.target.state &&
                    optionalString(left.target.canonical) < optionalString(right.target.canonical))
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
        let pathLeft = match (left.source) { case Some(v) => v.path case None => "" }
        let pathRight = match (right.source) { case Some(v) => v.path case None => "" }
        let lineLeft = match (left.source) { case Some(v) => v.startLine case None => 0 }
        let lineRight = match (right.source) { case Some(v) => v.startLine case None => 0 }
        pathLeft < pathRight || (pathLeft == pathRight && lineLeft < lineRight) ||
            (pathLeft == pathRight && lineLeft == lineRight && left.code < right.code)
    }, stable: true)
}
