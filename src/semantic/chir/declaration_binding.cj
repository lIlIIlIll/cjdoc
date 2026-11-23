protected package cjdoc.semantic.chir

import cjdoc.model as public_model
import cjdoc.provider as public_provider
import cjdoc_chir_protocol.*
import std.collection.*

// How a source declaration is identified in the worker's structured records, and
// which resolved signature (if any) belongs to it. Evidence only: the provider
// stages results, chir_type_ref.cj renders resolved types, and chir_worker_run.cj
// produces the records.

// The source spelling of a type with any generic argument list removed.
private func chirBaseTypeSpelling(value: String): String {
    match (value.indexOf("<")) {
        case Some(index) => value[..index].trimAscii()
        case None => value.trimAscii()
    }
}

// The simple name the worker records for a type: the last qualified component of
// the source spelling. Extension targets and owner names share this one rule.
private func chirBaseTypeName(value: String): String {
    let base = chirBaseTypeSpelling(value)
    let components = base.split(".")
    if (components.isEmpty()) { return base }
    components[components.size - 1].trimAscii()
}

private func chirSourceTypeIdentity(value: String): (String, String) {
    let base = chirBaseTypeSpelling(value)
    let components = base.split(".")
    if (components.isEmpty()) { return ("", base) }
    let targetName = components[components.size - 1].trimAscii()
    if (components.size == 1) { return ("", targetName) }
    var targetPackageName = components[0].trimAscii()
    var index: Int64 = 1
    while (index < components.size - 1) {
        targetPackageName += "." + components[index].trimAscii()
        index++
    }
    (targetPackageName, targetName)
}

internal func chirExtensionTargetMatch(summary: ChirWorkerSummary,
    extensionPackage: String, sourceName: String): (Int64, String) {
    let sourceIdentity = chirSourceTypeIdentity(sourceName)
    let sourceTargetPackage = sourceIdentity[0]
    let targetName = sourceIdentity[1]
    var targetPackageName = ""
    var candidateCount: Int64 = 0
    var hasMultipleTargetPackages = false
    var exactPackageMatch = false
    for (record in summary.extendRecords) {
        if (record.packageName != extensionPackage || record.targetName != targetName) { continue }
        if (candidateCount == 0) {
            targetPackageName = record.targetPackageName
        } else if (targetPackageName != record.targetPackageName) {
            hasMultipleTargetPackages = true
        }
        candidateCount++
        if (!sourceTargetPackage.isEmpty() && record.targetPackageName == sourceTargetPackage) {
            targetPackageName = record.targetPackageName
            exactPackageMatch = true
        }
    }
    if (candidateCount == 0) { return (0, "") }
    if (exactPackageMatch) { return (1, targetPackageName) }
    if (hasMultipleTargetPackages) { return (2, "") }
    (1, targetPackageName)
}

// The owner identity of a declaration, resolved through the declaration list:
// (owner kind, owner package, owner simple name, source owner spelling).
private func chirOwnerIdentity(view: public_provider.SourceDeclarationView,
    declarations: ReadOnlyList<public_provider.SourceDeclarationView>): (String, String, String, String) {
    let ownerId = match (view.ownerId) {
        case Some(value) => value
        case None => return ("none", "", "", "")
    }
    for (candidate in declarations) {
        if (candidate.id != ownerId) { continue }
        if (candidate.kind == "extend") {
            return ("extend", candidate.packageName, chirBaseTypeName(candidate.name), candidate.name)
        }
        return ("type", candidate.packageName, candidate.name, "")
    }
    ("unknown", "", "", "")
}

internal func chirBacksDeclaration(summary: ChirWorkerSummary,
    view: public_provider.SourceDeclarationView,
    declarations: ReadOnlyList<public_provider.SourceDeclarationView>): Int64 {
    if (view.kind == "class" || view.kind == "interface" ||
        view.kind == "struct" || view.kind == "enum") {
        for (record in summary.typeRecords) {
            if (record.packageName == view.packageName && record.name == view.name) { return 1 }
        }
        return 0
    }
    if (view.kind == "extend") {
        let targetMatch = chirExtensionTargetMatch(summary, view.packageName, view.name)
        return targetMatch[0]
    }
    if (view.kind == "typeAlias" || view.kind == "property") { return 3 }
    if (view.kind == "enumCase") {
        let owner = chirOwnerIdentity(view, declarations)
        for (record in summary.enumCaseRecords) {
            if (record.packageName == view.packageName && record.ownerName == owner[2] &&
                record.name == view.name) { return 1 }
        }
        return 0
    }
    if (view.kind == "variable") {
        let owner = chirOwnerIdentity(view, declarations)
        for (record in summary.memberRecords) {
            if (record.packageName == view.packageName && record.name == view.name &&
                record.ownerPackageName == owner[1] && record.ownerName == owner[2]) {
                return 1
            }
        }
        return chirHasFunction(summary, view, owner)
    }
    if (view.kind == "function" || view.kind == "constructor") {
        return chirHasFunction(summary, view, chirOwnerIdentity(view, declarations))
    }
    0
}

private func chirHasFunction(summary: ChirWorkerSummary,
    view: public_provider.SourceDeclarationView,
    owner: (String, String, String, String)): Int64 {
    var targetPackageName = ""
    if (owner[0] == "extend") {
        let targetMatch = chirExtensionTargetMatch(summary, owner[1], owner[3])
        if (targetMatch[0] != 1) { return targetMatch[0] }
        targetPackageName = targetMatch[1]
    }
    var candidates: Int64 = 0
    var shaped: Int64 = 0
    for (record in summary.functionRecords) {
        if (record.packageName != view.packageName || record.name != view.name) { continue }
        let ownerMatches = if (owner[0] == "none") {
            record.ownerKind == "none"
        } else if (owner[0] == "type") {
            record.ownerKind == "type" && record.ownerPackageName == owner[1] &&
                record.ownerName == owner[2]
        } else if (owner[0] == "extend") {
            record.ownerKind == "extend" && record.ownerPackageName == owner[1] &&
                record.targetPackageName == targetPackageName && record.targetName == owner[2]
        } else {
            false
        }
        if (!ownerMatches) { continue }
        candidates++
        if (record.genericArity == view.genericArity &&
            record.parameterCount == view.parameters.size) {
            shaped++
        }
    }
    if (candidates == 0) { return 0 }
    if (candidates == 1 || shaped == 1) { return 1 }
    2
}

// A CHIR-resolved signature for one declaration: the pre-order node list plus
// the top-level node index of each parameter and of the return type. Nodes are
// matched positionally by owner/name, never by spelling.
internal class ChirResolvedSignature {
    private let nodes: ArrayList<ChirTypeNode>
    private let parameters: ArrayList<Int64>
    private let returnNode: ?Int64

    init(nodes: ArrayList<ChirTypeNode>, parameters: ArrayList<Int64>, returnNode: ?Int64) {
        this.nodes = nodes
        this.parameters = parameters
        this.returnNode = returnNode
    }

    // The resolved type at a parameter position, when the worker reported one.
    func parameterTypeRef(index: Int64, sourceDisplay: String): ?public_model.TypeRef {
        if (index < 0 || index >= parameters.size) { return None }
        Some(chirTypeRefFromNodes(nodes, parameters[index], sourceDisplay))
    }

    // The resolved return type, when the record described one.
    func returnTypeRef(sourceDisplay: String): ?public_model.TypeRef {
        match (returnNode) {
            case Some(node) => Some(chirTypeRefFromNodes(nodes, node, sourceDisplay))
            case None => None
        }
    }
}

internal func chirResolvedSignature(summary: ChirWorkerSummary,
    view: public_provider.SourceDeclarationView,
    declarations: ReadOnlyList<public_provider.SourceDeclarationView>): ?ChirResolvedSignature {
    // Match the same owner and shape constraints the declaration binding uses, so
    // two same-named declarations (or equal-shaped overloads) in one package
    // cannot take each other's resolved types.
    let owner = chirOwnerIdentity(view, declarations)
    var targetPackageName = ""
    if (owner[0] == "extend") {
        let targetMatch = chirExtensionTargetMatch(summary, owner[1], owner[3])
        if (targetMatch[0] != 1) { return None }
        targetPackageName = targetMatch[1]
    }
    var matched: ?ChirWorkerSignatureRecord = None
    for (record in summary.signatureRecords) {
        if (record.packageName != view.packageName || record.name != view.name) { continue }
        if (!chirSignatureOwnerMatches(record, owner, targetPackageName)) { continue }
        if (record.genericArity != view.genericArity) { continue }
        if (record.paramCount != view.parameters.size) { continue }
        // More than one record fits: the identity is ambiguous, so no resolved
        // type is claimed at all.
        if (matched.isSome()) { return None }
        matched = Some(record)
    }
    let record = match (matched) {
        case Some(value) => value
        case None => return None
    }
    let parameters = ArrayList<Int64>()
    var index: Int64 = 0
    var topLevel: Int64 = 0
    for (node in record.types) {
        if (node.depth == 0) {
            if (topLevel < record.paramCount) { parameters.add(index) }
            topLevel++
        }
        index++
    }
    if (parameters.size != record.paramCount) { return None }
    let returnNode: ?Int64 = if (topLevel > record.paramCount) {
        Some(topLevelNodeIndex(record.types, record.paramCount))
    } else {
        None
    }
    Some(ChirResolvedSignature(record.types, parameters, returnNode))
}

// The same owner comparison the declaration binding applies, so a signature
// record can only back the declaration its function record backed.
private func chirSignatureOwnerMatches(record: ChirWorkerSignatureRecord,
    owner: (String, String, String, String), targetPackageName: String): Bool {
    if (owner[0] == "none") { return record.ownerKind == "none" }
    if (owner[0] == "type") {
        return record.ownerKind == "type" && record.ownerPackageName == owner[1] &&
            record.ownerName == owner[2]
    }
    if (owner[0] == "extend") {
        return record.ownerKind == "extend" && record.ownerPackageName == owner[1] &&
            record.targetPackageName == targetPackageName && record.targetName == owner[2]
    }
    false
}

// Top-level node index of the (count)th depth-0 entry.
private func topLevelNodeIndex(nodes: ArrayList<ChirTypeNode>, count: Int64): Int64 {
    var seen: Int64 = 0
    var index: Int64 = 0
    while (index < nodes.size) {
        if (nodes[index].depth == 0) {
            if (seen == count) { return index }
            seen++
        }
        index++
    }
    -1
}
