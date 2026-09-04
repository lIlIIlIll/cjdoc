package cjdoc

import std.collection.*
import std.sort.*

internal let MAX_REEXPORTS: Int64 = 100000
internal let MAX_REEXPORT_BINDINGS: Int64 = 100000
internal let MAX_REEXPORT_LOOKUP_WORK: Int64 = 1000000

internal func reExportPackageKey(moduleId: String, packageName: String): String {
    "${moduleId}\n${packageName}"
}

internal func joinedImportPath(parts: ArrayList<String>, tail!: ?String = None): String {
    let out = StringBuilder()
    var first = true
    for (part in parts) {
        if (!first) { out.append(".") }
        out.append(part)
        first = false
    }
    if (let Some(value) <- tail) {
        if (!first) { out.append(".") }
        out.append(value)
    }
    out.toString()
}

internal class ReExportPackageSurface {
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
            for (id in existing) {
                if (kindById.get(id) != Some("function")) { return ("conflict", 0) }
            }
            for (id in targetIds) {
                if (kindById.get(id) != Some("function")) { return ("conflict", 0) }
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

internal class ReExportTargetSelection {
    let packageDoc: ?PackageDoc
    let state: String

    init(packageDoc: ?PackageDoc, state: String) {
        this.packageDoc = packageDoc
        this.state = state
    }
}

internal class ReExportLookupIndex {
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

internal class PendingReExport {
    let source: SourceReExport
    var kind: String
    var targetPackageName: String
    var targetPackage: ?PackageDoc
    var state: String
    let aliasSymbolPackage: ?PackageDoc

    init(source: SourceReExport, kind: String, targetPackageName: String,
        targetPackage: ?PackageDoc, state: String,
        aliasSymbolPackage!: ?PackageDoc = None) {
        this.source = source
        this.kind = kind
        this.targetPackageName = targetPackageName
        this.targetPackage = targetPackage
        this.state = state
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

internal class ReExportBindingResult {
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

internal func addReExportWatcher(watchers: HashMap<String, ArrayList<Int64>>,
    key: String, index: Int64): Unit {
    match (watchers.get(key)) {
        case Some(values) => if (!values.contains(index)) { values.add(index) }
        case None => watchers[key] = ArrayList<Int64>([index])
    }
}

internal func enqueueReExport(queue: ArrayList<Int64>, queued: HashSet<Int64>, index: Int64): Unit {
    if (queued.add(index)) { queue.add(index) }
}

internal func enqueueReExportWatchers(queue: ArrayList<Int64>, queued: HashSet<Int64>,
    watchers: HashMap<String, ArrayList<Int64>>, key: String): Unit {
    match (watchers.get(key)) {
        case Some(values) => for (index in values) { enqueueReExport(queue, queued, index) }
        case None => ()
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

    let namedWatchers = HashMap<String, ArrayList<Int64>>()
    let allWatchers = HashMap<String, ArrayList<Int64>>()
    let queue = ArrayList<Int64>()
    let queued = HashSet<Int64>()
    var pendingIndex: Int64 = 0
    for (item in pending) {
        enqueueReExport(queue, queued, pendingIndex)
        if (item.state == "resolved" && item.kind != "packageAlias") {
            let target = item.targetPackage.getOrThrow()
            let targetKey = reExportPackageKey(target.moduleId, target.name)
            match (item.kind) {
                case "single" | "alias" => addReExportWatcher(namedWatchers,
                    "${targetKey}\n${item.source.identifier}", pendingIndex)
                case "multi" => for (imported in item.source.items) {
                    addReExportWatcher(namedWatchers, "${targetKey}\n${imported.name}", pendingIndex)
                }
                case "all" => addReExportWatcher(allWatchers, targetKey, pendingIndex)
                case _ => ()
            }
        }
        pendingIndex++
    }
    var bindingWork: Int64 = 0
    var queueCursor: Int64 = 0
    while (queueCursor < queue.size) {
        let currentIndex = queue[queueCursor]
        queueCursor++
        let _ = queued.remove(currentIndex)
        let item = pending[currentIndex]
        if (item.state != "resolved" || item.kind == "packageAlias") { continue }
        let result = bindingsForPending(item, surfaces)
        let exporterKey = reExportPackageKey(item.source.moduleId, item.source.packageName)
        let exporter = surfaces[exporterKey]
        if (result.missing && item.kind != "all") {
            item.state = if (result.bindings.isEmpty()) { "unavailable" } else { "partial" }
            continue
        }
        let candidate = exporter.copy()
        let changedNames = ArrayList<String>()
        let seenNames = HashSet<String>()
        var addedForItem: Int64 = 0
        for (binding in result.bindings) {
            if (!seenNames.add(binding.exposedName)) {
                item.state = "ambiguous"
                break
            }
            let ids = ArrayList<String>()
            ids.add(all: binding.targetSymbolIds)
            let newCount = candidate.add(binding.exposedName, ids, kindById,
                maximumNew: MAX_REEXPORT_BINDINGS - bindingWork - addedForItem)
            match (newCount[0]) {
                case "added" =>
                    addedForItem += newCount[1]
                    changedNames.add(binding.exposedName)
                case "conflict" => item.state = "ambiguous"
                case "limit" => item.state = "partial"
                case _ => ()
            }
            if (item.state != "resolved") { break }
        }
        if (item.state == "resolved" && addedForItem > 0) {
            surfaces[exporterKey] = candidate
            bindingWork += addedForItem
            for (name in changedNames) {
                enqueueReExportWatchers(queue, queued, namedWatchers,
                    "${exporterKey}\n${name}")
            }
            enqueueReExportWatchers(queue, queued, allWatchers, exporterKey)
        } else if (item.state == "partial") {
            bindingWork = MAX_REEXPORT_BINDINGS + 1
        }
        if (bindingWork > MAX_REEXPORT_BINDINGS) { break }
    }
    if (bindingWork > MAX_REEXPORT_BINDINGS || lookup.exhausted) {
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1031",
            "public import resolution exceeded the configured work budget"))
        for (item in pending where item.state == "resolved") { item.state = "partial" }
    }

    let occurrences = HashMap<String, Int64>()
    for (item in pending) {
        if (let Some(symbolPackage) <- item.aliasSymbolPackage) {
            match (surfaces.get(reExportPackageKey(symbolPackage.moduleId, symbolPackage.name))) {
                case Some(surface) => if (surface.names.contains(item.source.identifier)) {
                    item.state = "ambiguous"
                }
                case None => item.state = "partial"
            }
        }
        let bindingResult = bindingsForPending(item, surfaces)
        if (item.state == "resolved" && bindingResult.missing && item.kind != "all") {
            item.state = if (bindingResult.bindings.isEmpty()) { "unavailable" } else { "partial" }
        }
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

