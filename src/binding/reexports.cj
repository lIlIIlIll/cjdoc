protected package cjdoc.binding

import cjdoc.digest.Sha256Digest
import cjdoc.source.{Diagnostic, joinedImportPath, moduleId}
import cjdoc.source.model.{SourceReExport, SourceSnapshot}
import std.collection.*
import std.sort.*

protected let MAX_REEXPORTS: Int64 = 100000
protected let MAX_REEXPORT_BINDINGS: Int64 = 100000
protected let MAX_REEXPORT_LOOKUP_WORK: Int64 = 1000000
// Propagation re-evaluates an import only after an exporter surface changed, so
// this bound only caps the total number of solver steps for pathological chains.
protected let MAX_REEXPORT_PROPAGATION_WORK: Int64 = 1000000

internal func reExportPackageKey(moduleId: String, packageName: String): String {
    "${moduleId}\n${packageName}"
}

protected class ReExportPackageSurface {
    let names = HashMap<String, ArrayList<String>>()

    func copy(): ReExportPackageSurface {
        let result = ReExportPackageSurface()
        for ((name, ids) in names) {
            result.names[name] = ArrayList<String>(ids)
        }
        result
    }

    func add(exposedName: String, targetIds: ArrayList<String>,
        kindById: HashMap<String, String>, maximumNew!: Int64 = MAX_REEXPORT_BINDINGS):
        (String, Int64) {
        if (targetIds.isEmpty()) { return ("unchanged", 0) }
        let existing = match (names.get(exposedName)) {
            case Some(value) => value
            case None =>
                let value = ArrayList<String>()
                names[exposedName] = value
                value
        }
        var different = false
        for (id in targetIds) {
            if (!existing.contains(id)) { different = true; break }
        }
        if (!different) { return ("unchanged", 0) }
        if (!existing.isEmpty()) {
            let kind = kindById.get(existing[0])
            if (kind != Some("function") && kind != Some("macro")) { return ("conflict", 0) }
            for (id in existing) {
                if (kindById.get(id) != kind) { return ("conflict", 0) }
            }
            for (id in targetIds) {
                if (kindById.get(id) != kind) { return ("conflict", 0) }
            }
        }
        var added: Int64 = 0
        for (id in targetIds) { if (!existing.contains(id)) { added++ } }
        if (added > maximumNew) { return ("limit", added) }
        if (added > 0) {
            for (id in targetIds) { if (!existing.contains(id)) { existing.add(id) } }
            sort(existing, lessThan: { left, right => left < right }, stable: true)
            ("added", added)
        } else {
            ("unchanged", 0)
        }
    }
}

protected class ReExportTargetSelection {
    let packageDoc: ?PackageDoc
    let state: String

    init(packageDoc: ?PackageDoc, state: String) {
        this.packageDoc = packageDoc
        this.state = state
    }
}

protected class ReExportLookupIndex {
    let modulesById = HashMap<String, ModuleDoc>()
    let packagesByName = HashMap<String, ArrayList<PackageDoc>>()
    let reachableByModule = HashMap<String, HashSet<String>>()
    var work: Int64 = 0
    var exhausted = false

    init(documentation: DocumentationSet) {
        for (module in documentation.modules) {
            if (!consume()) { break }
            modulesById[module.id] = module
        }
        if (!exhausted) {
            for (pkg in documentation.packages) {
                if (!consume()) { break }
                match (packagesByName.get(pkg.name)) {
                    case Some(values) => values.add(pkg)
                    case None => packagesByName[pkg.name] = ArrayList<PackageDoc>([pkg])
                }
            }
        }
    }

    private func consume(): Bool {
        if (exhausted || work >= MAX_REEXPORT_LOOKUP_WORK) {
            exhausted = true
            return false
        }
        work++
        true
    }

    private func reachable(start: String): ?HashSet<String> {
        if (exhausted) { return None<HashSet<String>> }
        match (reachableByModule.get(start)) {
            case Some(value) => return Some(value)
            case None => ()
        }
        let result = HashSet<String>()
        let queue = ArrayList<String>()
        let _ = result.add(start)
        queue.add(start)
        var cursor: Int64 = 0
        while (cursor < queue.size && cursor <= modulesById.size) {
            if (!consume()) { return None<HashSet<String>> }
            let current = queue[cursor]
            cursor++
            match (modulesById.get(current)) {
                case Some(module) => for (dependency in module.dependencyIds) {
                    if (!consume()) { return None<HashSet<String>> }
                    if (result.add(dependency)) { queue.add(dependency) }
                }
                case None => ()
            }
        }
        reachableByModule[start] = result
        Some(result)
    }

    func select(exporterModuleId: String, packageName: String,
        organization: ?String): ReExportTargetSelection {
        if (packageName.isEmpty()) {
            return ReExportTargetSelection(None<PackageDoc>, "unavailable")
        }
        let reachableModules = match (reachable(exporterModuleId)) {
            case Some(value) => value
            case None => return ReExportTargetSelection(None<PackageDoc>, "partial")
        }
        let packages = match (packagesByName.get(packageName)) {
            case Some(value) => value
            case None => return ReExportTargetSelection(None<PackageDoc>, "unavailable")
        }
        var sameModule: ?PackageDoc = None
        let candidates = ArrayList<PackageDoc>()
        for (pkg in packages) {
            if (!consume()) { return ReExportTargetSelection(None<PackageDoc>, "partial") }
            if (let Some(expectedOrganization) <- organization) {
                let actualOrganization = match (modulesById.get(pkg.moduleId)) {
                    case Some(module) => module.organization
                    case None => None<String>
                }
                if (actualOrganization != Some(expectedOrganization)) { continue }
            }
            if (pkg.moduleId == exporterModuleId) {
                if (sameModule.isSome()) {
                    return ReExportTargetSelection(None<PackageDoc>, "ambiguous")
                }
                sameModule = Some(pkg)
            } else if (reachableModules.contains(pkg.moduleId)) {
                candidates.add(pkg)
            }
        }
        if (sameModule.isSome()) { return ReExportTargetSelection(sameModule, "resolved") }
        if (candidates.size == 1) { return ReExportTargetSelection(Some(candidates[0]), "resolved") }
        if (candidates.size > 1) { return ReExportTargetSelection(None<PackageDoc>, "ambiguous") }
        ReExportTargetSelection(None<PackageDoc>, "unavailable")
    }
}

protected class PendingReExport {
    let source: SourceReExport
    let kind: String
    let targetPackageName: String
    let targetPackage: ?PackageDoc
    // The package lookup verdict is fixed once computed. Absence of a binding is
    // not a verdict: an upstream package may still expose it after propagation.
    let selection: String
    var state: String
    var conflict = false
    var limited = false
    var degraded = false
    let aliasSymbolPackage: ?PackageDoc

    init(source: SourceReExport, kind: String, targetPackageName: String,
        targetPackage: ?PackageDoc, selection: String,
        aliasSymbolPackage!: ?PackageDoc = None) {
        this.source = source
        this.kind = kind
        this.targetPackageName = targetPackageName
        this.targetPackage = targetPackage
        this.selection = selection
        this.state = selection
        this.aliasSymbolPackage = aliasSymbolPackage
    }
}

internal func pendingReExport(index: ReExportLookupIndex, source: SourceReExport): PendingReExport {
    let prefix = joinedImportPath(source.prefixPaths)
    if (source.kind != "alias") {
        let selected = index.select(source.moduleId, prefix, source.organization)
        return PendingReExport(source, source.kind, prefix, selected.packageDoc, selected.state)
    }
    let symbolTarget = index.select(source.moduleId, prefix, source.organization)
    let packageName = joinedImportPath(source.prefixPaths, tail: Some(source.identifier))
    let packageTarget = index.select(source.moduleId, packageName, source.organization)
    if (symbolTarget.state == "resolved" && packageTarget.state == "resolved") {
        return PendingReExport(source, "packageAlias", packageName,
            packageTarget.packageDoc, "resolved",
            aliasSymbolPackage: symbolTarget.packageDoc)
    }
    if (symbolTarget.state == "partial" || packageTarget.state == "partial") {
        return PendingReExport(source, "alias", prefix, None<PackageDoc>, "partial")
    }
    if (symbolTarget.state == "ambiguous" || packageTarget.state == "ambiguous") {
        return PendingReExport(source, "alias", prefix, None<PackageDoc>, "ambiguous")
    }
    if (packageTarget.state == "resolved") {
        return PendingReExport(source, "packageAlias", packageName,
            packageTarget.packageDoc, "resolved")
    }
    if (symbolTarget.state == "resolved") {
        return PendingReExport(source, "alias", prefix, symbolTarget.packageDoc, "resolved")
    }
    PendingReExport(source, "alias", prefix, None<PackageDoc>, "unavailable")
}

protected class ReExportBindingResult {
    let bindings = ArrayList<ReExportBinding>()
    var missing = false
}

internal func addResolvedBinding(result: ReExportBindingResult, surface: ReExportPackageSurface,
    sourceName: String, exposedName: String): Unit {
    match (surface.names.get(sourceName)) {
        case Some(ids) => result.bindings.add(ReExportBinding(exposedName, targetSymbolIds: ids.toArray()))
        case None => result.missing = true
    }
}

internal func bindingsForPending(pending: PendingReExport,
    surfaces: HashMap<String, ReExportPackageSurface>): ReExportBindingResult {
    let result = ReExportBindingResult()
    let target = match (pending.targetPackage) {
        case Some(value) => value
        case None => result.missing = true; return result
    }
    let surface = match (surfaces.get(reExportPackageKey(target.moduleId, target.name))) {
        case Some(value) => value
        case None => result.missing = true; return result
    }
    match (pending.kind) {
        case "single" =>
            addResolvedBinding(result, surface, pending.source.identifier, pending.source.identifier)
        case "alias" =>
            addResolvedBinding(result, surface, pending.source.identifier,
                pending.source.alias.getOrThrow())
        case "multi" =>
            for (item in pending.source.items) {
                addResolvedBinding(result, surface, item.name,
                    match (item.alias) { case Some(value) => value; case None => item.name })
            }
        case "all" =>
            let names = ArrayList<String>()
            for ((name, _) in surface.names) { names.add(name) }
            sort(names, lessThan: { left, right => left < right }, stable: true)
            for (name in names) {
                addResolvedBinding(result, surface, name, name)
            }
        case "packageAlias" => ()
        case _ => result.missing = true
    }
    result
}

internal func reExportSourceLess(left: SourceReExport, right: SourceReExport): Bool {
    if (left.source.path != right.source.path) { return left.source.path < right.source.path }
    if (left.normalizedSpec != right.normalizedSpec) { return left.normalizedSpec < right.normalizedSpec }
    if (left.source.startLine != right.source.startLine) { return left.source.startLine < right.source.startLine }
    left.source.startColumn < right.source.startColumn
}

internal func appendReExportDiagnostic(documentation: DocumentationSet, pending: PendingReExport): Unit {
    match (pending.state) {
        case "ambiguous" => documentation.diagnostics.add(Diagnostic("warning", "CJDOC1030",
            "public import '${pending.source.normalizedSpec}' is ambiguous or collides with an existing exposure",
            source: pending.source.source))
        case "partial" | "unavailable" => documentation.diagnostics.add(Diagnostic("warning", "CJDOC1029",
            "public import '${pending.source.normalizedSpec}' could not be completely resolved",
            source: pending.source.source))
        case _ => ()
    }
}

// One propagation pass may publish at most MAX_REEXPORT_BINDINGS new exposures
// across every import, independent of how often a chain is re-evaluated.
protected class ReExportBindingBudget {
    var work: Int64 = 0
    var exceeded = false

    func spend(amount: Int64): Bool {
        if (exceeded || amount <= 0) { return !exceeded }
        if (work + amount > MAX_REEXPORT_BINDINGS) {
            exceeded = true
            return false
        }
        work += amount
        true
    }
}

// Publish everything one import currently exposes. A still-unbound name is not a
// failure here: a later pass re-runs this import after its target package grows.
internal func applyReExportBindings(item: PendingReExport,
    surfaces: HashMap<String, ReExportPackageSurface>, kindById: HashMap<String, String>,
    budget: ReExportBindingBudget): Bool {
    if (item.kind == "packageAlias" || budget.exceeded) { return false }
    // An ambiguous or over-budget import publishes nothing, so it must not leak
    // names into its own package surface either.
    if (item.conflict || item.limited || item.degraded) { return false }
    if (item.targetPackage.isNone()) { return false }
    let exporterKey = reExportPackageKey(item.source.moduleId, item.source.packageName)
    let exporter = match (surfaces.get(exporterKey)) {
        case Some(value) => value
        case None => return false
    }
    let result = bindingsForPending(item, surfaces)
    let candidate = exporter.copy()
    var added: Int64 = 0
    for (binding in result.bindings) {
        let ids = ArrayList<String>()
        ids.add(all: binding.targetSymbolIds)
        let outcome = candidate.add(binding.exposedName, ids, kindById,
            maximumNew: MAX_REEXPORT_BINDINGS)
        match (outcome[0]) {
            case "added" => added += outcome[1]
            case "conflict" => item.conflict = true; return false
            case "limit" => item.limited = true; return false
            case _ => ()
        }
    }
    if (added == 0) { return false }
    if (!budget.spend(added)) {
        item.limited = true
        return false
    }
    surfaces[exporterKey] = candidate
    true
}

// Decide the published state only after propagation has reached its fixed point.
internal func finalizeReExportState(item: PendingReExport,
    surfaces: HashMap<String, ReExportPackageSurface>): Unit {
    if (let Some(symbolPackage) <- item.aliasSymbolPackage) {
        match (surfaces.get(reExportPackageKey(symbolPackage.moduleId, symbolPackage.name))) {
            case Some(surface) => if (surface.names.contains(item.source.identifier)) {
                item.state = "ambiguous"
                return
            }
            case None => item.state = "partial"
            return
        }
    }
    if (item.conflict) {
        item.state = "ambiguous"
        return
    }
    if (item.limited) {
        item.state = "partial"
        return
    }
    if (item.degraded) {
        item.state = "partial"
        return
    }
    if (item.selection != "resolved") {
        item.state = item.selection
        return
    }
    if (item.kind == "packageAlias") {
        item.state = "resolved"
        return
    }
    let result = bindingsForPending(item, surfaces)
    item.state = if (!result.missing) {
        "resolved"
    } else if (result.bindings.isEmpty()) {
        "unavailable"
    } else {
        "partial"
    }
}

internal func resolveReExports(documentation: DocumentationSet, source: SourceSnapshot): Unit {
    if (source.reExports.size > MAX_REEXPORTS) {
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1031",
            "public import resolution exceeded the configured work budget"))
        return
    }
    let surfaces = HashMap<String, ReExportPackageSurface>()
    for (pkg in documentation.packages) {
        surfaces[reExportPackageKey(pkg.moduleId, pkg.name)] = ReExportPackageSurface()
    }
    let kindById = HashMap<String, String>()
    for (symbol in documentation.symbols) {
        kindById[symbol.id] = symbol.kind
        if (symbol.ownerId.isSome() ||
            (symbol.visibility != "public" && symbol.visibility != "protected")) { continue }
        let key = reExportPackageKey(symbol.moduleId, symbol.packageName)
        let surface = match (surfaces.get(key)) {
            case Some(value) => value
            case None =>
                let value = ReExportPackageSurface()
                surfaces[key] = value
                value
        }
        let ids = ArrayList<String>([symbol.id])
        let _ = surface.add(symbol.name, ids, kindById)
    }

    let ordered = ArrayList<SourceReExport>()
    ordered.add(all: source.reExports)
    sort(ordered, lessThan: reExportSourceLess, stable: true)
    let pending = ArrayList<PendingReExport>()
    let lookup = ReExportLookupIndex(documentation)
    for (item in ordered) { pending.add(pendingReExport(lookup, item)) }

    var propagationExceeded = false
    let budget = ReExportBindingBudget()
    // Import propagation must reach a fixed point before any binding is
    // published: a name an upstream package has not exposed yet is pending, not
    // missing. Surfaces only grow, so re-running exactly the imports that observe
    // a changed package terminates and is independent of file order.
    let dependents = HashMap<String, ArrayList<Int64>>()
    let queue = ArrayList<Int64>()
    let queued = HashSet<Int64>()
    var dependentIndex: Int64 = 0
    for (item in pending) {
        if (item.selection == "resolved" && item.kind != "packageAlias") {
            let _ = queued.add(dependentIndex)
            queue.add(dependentIndex)
            if (let Some(target) <- item.targetPackage) {
                let key = reExportPackageKey(target.moduleId, target.name)
                match (dependents.get(key)) {
                    case Some(values) => values.add(dependentIndex)
                    case None => dependents[key] = ArrayList<Int64>([dependentIndex])
                }
            }
        }
        dependentIndex++
    }
    var work: Int64 = 0
    var queueCursor: Int64 = 0
    while (queueCursor < queue.size) {
        let current = queue[queueCursor]
        queueCursor++
        let _ = queued.remove(current)
        let item = pending[current]
        work++
        if (work > MAX_REEXPORT_PROPAGATION_WORK) {
            propagationExceeded = true
            break
        }
        if (!applyReExportBindings(item, surfaces, kindById, budget)) { continue }
        let exporterKey = reExportPackageKey(item.source.moduleId, item.source.packageName)
        match (dependents.get(exporterKey)) {
            case Some(values) => for (index in values) {
                if (queued.add(index)) { queue.add(index) }
            }
            case None => ()
        }
    }
    if (propagationExceeded || budget.exceeded || lookup.exhausted) {
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1031",
            "public import resolution exceeded the configured work budget"))
        for (item in pending) {
            if (item.selection == "resolved") { item.degraded = true }
        }
    }

    let occurrences = HashMap<String, Int64>()
    for (item in pending) {
        finalizeReExportState(item, surfaces)
        let bindingResult = bindingsForPending(item, surfaces)
        let occurrenceKey = "${item.source.moduleId}\n${item.source.packageName}\n${item.source.source.path}\n${item.source.normalizedSpec}"
        let ordinal = match (occurrences.get(occurrenceKey)) { case Some(value) => value; case None => 0 }
        occurrences[occurrenceKey] = ordinal + 1
        let identityInput = "${occurrenceKey}\n${ordinal}"
        let id = "cjdoc:reexport:v1:${Sha256Digest.digest(identityInput)}"
        let targetModuleId = match (item.targetPackage) {
            case Some(value) => Some(value.moduleId)
            case None => None<String>
        }
        let publishedBindings = if (item.state == "resolved") {
            bindingResult.bindings.toArray()
        } else {
            Array<ReExportBinding>()
        }
        let doc = ReExportDoc(id, item.kind, item.source.organization, item.targetPackageName,
            targetModuleId, item.source.alias, item.state, item.source.source,
            bindings: publishedBindings)
        getDocPackage(documentation, item.source.moduleId, item.source.packageName).reExports.add(doc)
        appendReExportDiagnostic(documentation, item)
    }
}

