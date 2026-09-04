package cjdoc

import std.ast.*
import std.collection.*
import std.fs.*
import std.sort.*

func dependencyPrefix(name: String): String {
    if (!safeDependencyLogicalName(name)) {
        throw IllegalArgumentException("dependency name cannot form a logical source prefix")
    }
    "dependencies/" + name
}

internal func moduleId(role: String, name: String, logicalPrefix: String): String {
    if (role == "root") { return "cjdoc:module:v1:root" }
    if (role == "workspace") { return "cjdoc:module:v1:workspace:${logicalPrefix}" }
    if (role == "externalDependency") { return "cjdoc:module:v1:external:${percentEscapeSymbolPart(name)}" }
    "cjdoc:module:v1:path:${percentEscapeSymbolPart(name)}"
}

internal func findSourceModule(modules: ArrayList<SourceModuleRoot>, actualRoot: String): ?SourceModuleRoot {
    for (module in modules) {
        if (module.actualRoot == actualRoot) { return Some(module) }
    }
    None
}

internal func findSourceModuleById(modules: ArrayList<SourceModuleRoot>, id: String): ?SourceModuleRoot {
    for (module in modules) {
        if (module.documentation.id == id) { return Some(module) }
    }
    None
}

internal func dependencyWouldCreateCycle(modules: ArrayList<SourceModuleRoot>,
    ownerId: String, dependencyId: String): Bool {
    if (ownerId == dependencyId) { return true }
    let pending = ArrayList<String>()
    let visited = HashSet<String>()
    pending.add(dependencyId)
    var cursor: Int64 = 0
    var checkedEdges: Int64 = 0
    while (cursor < pending.size) {
        let currentId = pending[cursor]
        cursor++
        if (currentId == ownerId) { return true }
        if (!visited.add(currentId)) { continue }
        let current = match (findSourceModuleById(modules, currentId)) {
            case Some(value) => value
            case None => return true
        }
        for (next in current.documentation.dependencyIds) {
            checkedEdges++
            if (checkedEdges > MAX_SOURCE_DEPENDENCY_EDGES) { return true }
            if (!visited.contains(next)) { pending.add(next) }
        }
    }
    false
}

internal func sourceModuleCollision(modules: ArrayList<SourceModuleRoot>,
    candidate: SourceModuleRoot): Bool {
    for (existing in modules) {
        if (existing.actualRoot == candidate.actualRoot ||
            existing.logicalPrefix == candidate.logicalPrefix ||
            existing.documentation.id == candidate.documentation.id ||
            hostPathIsWithin(existing.actualSourceRoot, candidate.actualSourceRoot) ||
            hostPathIsWithin(candidate.actualSourceRoot, existing.actualSourceRoot)) {
            return true
        }
    }
    false
}

internal func addModuleRoot(workspaceRoot: String, candidate: String, roots: ArrayList<String>,
    seen: HashSet<String>, diagnostics: ArrayList<Diagnostic>, required!: Bool = false): Bool {
    let severity = if (required) { "error" } else { "warning" }
    let resolved = try {
        canonicalize(candidate).toString()
    } catch (_: Exception) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member is not accessible"))
        return false
    }
    if (!hostPathIsWithin(workspaceRoot, resolved)) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member escapes project root; skipped"))
        return false
    }
    if (relativePathFromResolved(workspaceRoot, resolved).isNone()) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member cannot be represented by a portable logical path; skipped"))
        return false
    }
    if (!exists(Path(resolved).join("cjpm.toml"))) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member must contain cjpm.toml; skipped"))
        return false
    }
    if (!seen.add(resolved)) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace members resolve to a duplicate module root; skipped"))
        return false
    }
    roots.add(resolved)
    return true
}

internal func discoverModuleRoots(root: String, manifest: String,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): ArrayList<String> {
    let roots = ArrayList<String>()
    let seen = HashSet<String>()
    let rootPackage = parseCjpmPackageNameChecked(manifest)
    if (rootPackage.value.isSome()) {
        let _ = addModuleRoot(root, root, roots, seen, diagnostics, required: true)
    }
    if (!auxiliaryBudget.consumeWork(manifest.size)) {
        budget.markLimitReached()
        return roots
    }
    let workspace = parseCjpmWorkspaceMembers(manifest, budget.remainingModuleCandidates())
    budget.consumeModuleCandidates(workspace.entryCount)
    if (workspace.invalid) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace metadata contains an invalid TOML string; source discovery stopped"))
        return roots
    }
    for (member in workspace.values) {
        if (!safeLogicalSourcePath(member)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1010",
                "workspace member cannot be represented by a portable logical path; skipped"))
            continue
        }
        let _ = addModuleRoot(root, Path(root).join(member).toString(), roots, seen, diagnostics)
    }
    if (workspace.limitReached) { budget.markLimitReached() }
    if (roots.isEmpty()) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "project must declare a source package or workspace members"))
    }
    sortStrings(roots)
    return roots
}

internal func addExternalSourceModule(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, input: DependencySourceInput,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): ?SourceModuleRoot {
    if (!safeDependencyLogicalName(input.name)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source has an unsafe logical name; skipped"))
        return None
    }
    let resolved = try {
        canonicalize(input.path).toString()
    } catch (_: Exception) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' is not accessible; skipped"))
        return None
    }
    if (seen.contains(resolved)) {
        let existing = findSourceModule(modules, resolved)
        if (let Some(module) <- existing) {
            let expectedPrefix = dependencyPrefix(input.name)
            let expectedId = moduleId("externalDependency", input.name, expectedPrefix)
            if (module.logicalPrefix != expectedPrefix || module.documentation.id != expectedId) {
                diagnostics.add(Diagnostic("warning", "CJDOC1018",
                    "configured dependency source collides with an existing module identity; skipped"))
                return None
            }
        }
        return existing
    }
    let manifestPath = Path(resolved).join("cjpm.toml")
    if (!exists(manifestPath)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' must contain cjpm.toml; skipped"))
        return None
    }
    let dependencyManifest = try {
        readAuxiliaryTextBounded(manifestPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
    } catch (_: Exception) {
        if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); return None }
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' manifest is not readable; skipped"))
        return None
    }
    if (!auxiliaryBudget.consumeWork(dependencyManifest.size)) {
        budget.markLimitReached()
        return None
    }
    let packageView = parseCjpmPackageNameChecked(dependencyManifest)
    if (packageView.limitReached) {
        budget.markLimitReached()
        return None
    }
    if (packageView.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source manifest contains invalid metadata; skipped"))
        return None
    }
    let packageName = match (packageView.value) {
        case Some(value) => value
        case None => input.name
    }
    let sourceRoot = match (resolvedPackageSourceRoot(resolved,
        packageView.sourceDirectory)) {
        case Some(value) => value
        case None =>
            diagnostics.add(Diagnostic("warning", "CJDOC1018",
                "configured dependency source has an invalid or unavailable package.src-dir; skipped"))
            return None
    }
    let prefix = dependencyPrefix(input.name)
    for (module in modules) {
        if (module.logicalPrefix == prefix && module.actualRoot != resolved) {
            diagnostics.add(Diagnostic("warning", "CJDOC1018",
                "configured dependency source '${input.name}' has a duplicate logical name; skipped"))
            return None
        }
    }
    let moduleDoc = SourceModule(moduleId("externalDependency", input.name, prefix),
        packageName, "externalDependency", prefix, organization: packageView.organization)
    let module = SourceModuleRoot(resolved, sourceRoot, prefix, moduleDoc)
    if (sourceModuleCollision(modules, module)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source collides with an existing module identity or source root; skipped"))
        return None
    }
    if (!budget.canAddModule(modules.size)) { return None }
    let _ = seen.add(resolved)
    modules.add(module)
    Some(module)
}

internal func addExternalSourceModules(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, inputs: Array<DependencySourceInput>, ownerCount: Int64,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    if (inputs.isEmpty() || ownerCount == 0 || budget.limitReached) { return }
    let sortedInputs = ArrayList<DependencySourceInput>()
    let remaining = budget.remainingDependencyDiscoveries()
    var inputIndex: Int64 = 0
    while (inputIndex < inputs.size && sortedInputs.size < remaining) {
        sortedInputs.add(inputs[inputIndex])
        inputIndex++
    }
    let truncated = inputIndex < inputs.size
    budget.consumeExplicitDependencyCandidates(sortedInputs.size)
    sort(sortedInputs, lessThan: { left, right =>
        if (left.name == right.name) { left.path < right.path } else { left.name < right.name }
    }, stable: true)
    for (input in sortedInputs) {
        if (budget.limitReached) { break }
        if (let Some(dependency) <- addExternalSourceModule(modules, seen, input, diagnostics,
            budget, auxiliaryBudget)) {
            var ownerIndex: Int64 = 0
            while (ownerIndex < ownerCount) {
                if (!budget.addDependency(modules, modules[ownerIndex].documentation,
                    dependency.documentation.id, diagnostics)) { break }
                ownerIndex++
            }
        }
    }
    if (truncated) { budget.markLimitReached() }
}
