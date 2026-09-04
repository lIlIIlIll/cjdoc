package cjdoc

import std.ast.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*

internal func safeDependencyCacheName(name: String): Bool {
    if (name.isEmpty() || name == "." || name == "..") { return false }
    for (byte in name.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

internal func dependencyInputNamed(inputs: Array<DependencySourceInput>, name: String): ?DependencySourceInput {
    for (input in inputs) {
        if (input.name == name) { return Some(input) }
    }
    None
}

internal func selectedCjpmCacheRoot(cacheRoot: ?String,
    diagnostics: ArrayList<Diagnostic>): ?String {
    let selected: ?String = match (cacheRoot) {
        case Some(value) => Some(value)
        case None => match (getVariable("HOME")) {
            case Some(home) => Some(Path(home).join(".cjpm").toString())
            case None => None
        }
    }
    if (selected.isNone()) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery requires --cjpm-cache or HOME"))
        return None
    }
    selected
}

internal func cachedDependencySource(dependency: CjpmLockedDependency, cacheRoot: String,
    diagnostics: ArrayList<Diagnostic>): ?DependencySourceInput {
    if (!safeDependencyLogicalName(dependency.name)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "locked dependency name is unsafe for cache lookup; skipped"))
        return None
    }
    let candidate: ?String = match ((dependency.commitId, dependency.version)) {
        case (Some(commitId), _) =>
            if (!safeDependencyCacheName(commitId)) { None } else {
                Some(Path(cacheRoot).join("git").join(dependency.name)
                    .join(commitId).toString())
            }
        case (_, Some(version)) =>
            if (version.contains("/") || version.contains("\\") || version.contains("..")) { None } else {
                Some(Path(cacheRoot).join("repository").join("source").join("default")
                    .join("${dependency.name}-${version}").toString())
            }
        case _ => None
    }
    match (candidate) {
        case Some(path) =>
            let resolvedRoot = try {
                canonicalize(cacheRoot).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "selected cjpm cache root is not accessible; cached dependency skipped"))
                return None
            }
            let resolved = try {
                canonicalize(path).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            let manifestPath = Path(resolved).join("cjpm.toml")
            let resolvedManifest = try {
                canonicalize(manifestPath).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            let manifestInfo = try { FileInfo(manifestPath) } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            if (!hostPathIsWithin(resolvedRoot, resolved) ||
                !hostPathIsWithin(resolvedRoot, resolvedManifest) ||
                !manifestInfo.isRegular() || manifestInfo.isSymbolicLink()) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' escapes the selected cjpm cache; skipped"))
                return None
            }
            Some(DependencySourceInput(dependency.name, resolved))
        case None =>
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "locked dependency '${dependency.name}' cannot be mapped to a safe cjpm cache path; skipped"))
            None
    }
}

internal func readLockedDependencies(directory: String, required: Bool,
    diagnostics: ArrayList<Diagnostic>, maxEntries: Int64,
    auxiliaryBudget: SourceAuxiliaryBudget): CjpmLockView {
    let lockPath = Path(directory).join("cjpm.lock")
    if (!exists(lockPath)) {
        if (required) {
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "cached dependency discovery requested but cjpm.lock is missing"))
        }
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, false)
    }
    let lockText = try {
        readAuxiliaryTextBounded(lockPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
    } catch (_: Exception) {
        if (auxiliaryBudget.limitReached()) {
            return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, true)
        }
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery skipped an unreadable cjpm.lock"))
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, false)
    }
    if (!auxiliaryBudget.consumeWork(lockText.size)) {
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, true)
    }
    let parsed = parseCjpmLock(lockText, maxEntries: maxEntries)
    if (parsed.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery skipped invalid lock metadata"))
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), parsed.entryCount,
            parsed.limitReached, invalid: true)
    }
    parsed
}

internal func addLockedDependency(modules: ArrayList<SourceModuleRoot>, seen: HashSet<String>,
    owners: Array<SourceModuleRoot>, dependency: CjpmLockedDependency,
    cacheRoot: String, explicitInputs: Array<DependencySourceInput>,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    let input = match (dependencyInputNamed(explicitInputs, dependency.name)) {
        case Some(explicit) => Some(explicit)
        case None => cachedDependencySource(dependency, cacheRoot, diagnostics)
    }
    if (let Some(sourceInput) <- input) {
        if (let Some(dependencyModule) <- addExternalSourceModule(modules, seen,
            sourceInput, diagnostics, budget, auxiliaryBudget)) {
            for (owner in owners) {
                if (!budget.addDependency(modules, owner.documentation,
                    dependencyModule.documentation.id, diagnostics)) { break }
            }
        }
    }
}

internal func safeCjpmTargetName(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

internal func currentCjpmTarget(): ?String {
    try {
        let (exitCode, output, _) = executeWithOutput("cjc", ["--version"])
        if (exitCode != 0 || output.size > 64 * 1024) { return None }
        let text = String.fromUtf8(output)
        for (line in text.split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.startsWith("Target:")) {
                let value = trimmed.removePrefix("Target:").trimAscii()
                if (safeCjpmTargetName(value)) { return Some(value) }
                return None
            }
        }
    } catch (_: Exception) {}
    None
}

internal func addPathDependencies(modules: ArrayList<SourceModuleRoot>, seen: HashSet<String>,
    owners: Array<SourceModuleRoot>, baseRoot: String, manifest: String,
    selectedTarget: ?String, diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    if (owners.isEmpty() || budget.limitReached) { return }
    if (!auxiliaryBudget.consumeWork(manifest.size)) {
        budget.markLimitReached()
        return
    }
    let pathDependencies = parseCjpmPathDependencies(manifest,
        budget.remainingDependencyDiscoveries(), selectedTarget: selectedTarget)
    budget.consumeDependencyCandidates(pathDependencies.entryCount)
    if (pathDependencies.partial) {
        diagnostics.add(Diagnostic("warning", "CJDOC1016",
            "path dependency metadata contains a legal form that is not fully supported; dependency graph is partial"))
    }
    if (pathDependencies.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1016",
            "path dependency metadata contains invalid TOML; skipped"))
        return
    }
    for (dependencyPath in pathDependencies.values) {
        let candidatePath = Path(baseRoot).join(dependencyPath).toString()
        let resolved = try {
            canonicalize(candidatePath).toString()
        } catch (_: Exception) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency is not accessible; skipped"))
            continue
        }
        if (seen.contains(resolved)) {
            if (let Some(existing) <- findSourceModule(modules, resolved)) {
                for (owner in owners) {
                    let _ = budget.addDependency(modules, owner.documentation,
                        existing.documentation.id, diagnostics)
                    if (budget.limitReached) { break }
                }
            }
            if (budget.limitReached) { break }
            continue
        }
        let dependencyManifestPath = Path(resolved).join("cjpm.toml")
        if (!exists(dependencyManifestPath)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1015",
                "path dependency is not a Cangjie source package; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencyManifest = try {
            readAuxiliaryTextBounded(dependencyManifestPath, MAX_SOURCE_FILE_BYTES,
                auxiliaryBudget)
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest is not readable; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        if (!auxiliaryBudget.consumeWork(dependencyManifest.size)) {
            budget.markLimitReached()
            break
        }
        let dependencyPackage = parseCjpmPackageNameChecked(dependencyManifest)
        if (dependencyPackage.limitReached) {
            budget.markLimitReached()
            break
        }
        if (dependencyPackage.invalid) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest contains invalid metadata; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencyName = match (dependencyPackage.value) {
            case Some(name) => name
            case None => Path(resolved).fileName
        }
        if (!safeDependencyLogicalName(dependencyName)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency has an unsafe logical name; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencySourceRoot = match (resolvedPackageSourceRoot(resolved,
            dependencyPackage.sourceDirectory)) {
            case Some(value) => value
            case None =>
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "path dependency has an invalid or unavailable package.src-dir; skipped"))
                let _ = seen.add(resolved)
                continue
        }
        let prefix = dependencyPrefix(dependencyName)
        let dependencyDoc = SourceModule(moduleId("pathDependency", dependencyName, prefix),
            dependencyName, "pathDependency", prefix,
            organization: dependencyPackage.organization)
        if (!budget.canAddModule(modules.size)) { break }
        let dependencyModule = SourceModuleRoot(resolved, dependencySourceRoot,
            prefix, dependencyDoc)
        if (sourceModuleCollision(modules, dependencyModule)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency module identity, source root, or logical prefix collides; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let _ = seen.add(resolved)
        modules.add(dependencyModule)
        for (owner in owners) {
            let _ = budget.addDependency(modules, owner.documentation,
                dependencyDoc.id, diagnostics)
            if (budget.limitReached) { break }
        }
        if (budget.limitReached) { break }
    }
    if (pathDependencies.limitReached) { budget.markLimitReached() }
}

internal func discoverSourceModules(root: String, manifest: String, includePathDependencies: Bool,
    dependencySources: Array<DependencySourceInput>,
    includeCachedDependencies: Bool, cjpmCacheRoot: ?String,
    diagnostics: ArrayList<Diagnostic>, auxiliaryBudget: SourceAuxiliaryBudget): ArrayList<SourceModuleRoot> {
    let modules = ArrayList<SourceModuleRoot>()
    let seen = HashSet<String>()
    let budget = SourceDiscoveryBudget()
    for (moduleRoot in discoverModuleRoots(root, manifest, diagnostics, budget, auxiliaryBudget)) {
        if (budget.limitReached) { break }
        if (!budget.canAddModule(modules.size)) { break }
        let _ = seen.add(moduleRoot)
        let moduleManifest = try {
            if (moduleRoot == root) { manifest } else {
                readAuxiliaryTextBounded(Path(moduleRoot).join("cjpm.toml"),
                    MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
            }
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                "CJDOC1010", "workspace member manifest is not readable; skipped"))
            continue
        }
        if (!auxiliaryBudget.consumeWork(moduleManifest.size)) {
            budget.markLimitReached()
            break
        }
        let packageView = parseCjpmPackageNameChecked(moduleManifest)
        if (packageView.limitReached) {
            budget.markLimitReached()
            break
        }
        if (packageView.invalid) {
            diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                "CJDOC1010", "workspace member manifest contains invalid metadata; skipped"))
            continue
        }
        let name = match (packageView.value) {
            case Some(actual) => actual
            case None => Path(moduleRoot).fileName
        }
        let sourceRoot = match (resolvedPackageSourceRoot(moduleRoot,
            packageView.sourceDirectory)) {
            case Some(value) => value
            case None =>
                diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                    "CJDOC1010",
                    "workspace member has an invalid or unavailable package.src-dir; skipped"))
                continue
        }
        let role = if (moduleRoot == root) { "root" } else { "workspace" }
        let prefix = if (moduleRoot == root) {
            ""
        } else {
            match (relativePath(root, moduleRoot)) {
                case Some(value) => value
                case None =>
                    diagnostics.add(Diagnostic("error", "CJDOC1010",
                        "workspace member cannot form a portable logical prefix; skipped"))
                    continue
            }
        }
        let moduleDoc = SourceModule(moduleId(role, name, prefix), name, role, prefix,
            organization: packageView.organization)
        let module = SourceModuleRoot(moduleRoot, sourceRoot, prefix, moduleDoc)
        if (sourceModuleCollision(modules, module)) {
            diagnostics.add(Diagnostic("error", "CJDOC1010",
                "workspace module identity, source root, or logical prefix collides; skipped"))
            continue
        }
        modules.add(module)
    }
    let initialOwnerCount = modules.size
    addExternalSourceModules(modules, seen, dependencySources, initialOwnerCount, diagnostics,
        budget, auxiliaryBudget)
    let selectedCacheRoot: ?String = if (includeCachedDependencies) {
        selectedCjpmCacheRoot(cjpmCacheRoot, diagnostics)
    } else {
        None
    }
    if (let Some(cacheRoot) <- selectedCacheRoot) {
        if (!budget.limitReached) {
            let owners = ArrayList<SourceModuleRoot>()
            var ownerIndex: Int64 = 0
            while (ownerIndex < initialOwnerCount) {
                owners.add(modules[ownerIndex])
                ownerIndex++
            }
            let locked = readLockedDependencies(root, true, diagnostics,
                budget.remainingDependencyDiscoveries(), auxiliaryBudget)
            budget.consumeDependencyCandidates(locked.entryCount)
            for (dependency in locked.dependencies) {
                if (budget.limitReached) { break }
                addLockedDependency(modules, seen, owners.toArray(), dependency,
                    cacheRoot, dependencySources, diagnostics, budget, auxiliaryBudget)
            }
            if (locked.limitReached) { budget.markLimitReached() }
        }
    }
    if (!includePathDependencies && !includeCachedDependencies) {
        if (budget.limitReached) {
            addSourceLimitDiagnostic(diagnostics, if (auxiliaryBudget.limitReached()) {
                "source metadata or cache exceeded the configured aggregate byte/work safety budget; source discovery stopped"
            } else {
                "source discovery exceeded 4096 modules or 16384 dependency edges; remaining modules skipped"
            })
        }
        return modules
    }

    let selectedTarget: ?String = if (includePathDependencies) {
        currentCjpmTarget()
    } else {
        None<String>
    }
    if (includePathDependencies && findSourceModule(modules, root).isNone() &&
        initialOwnerCount > 0 && !budget.limitReached) {
        let workspaceOwners = ArrayList<SourceModuleRoot>()
        var ownerIndex: Int64 = 0
        while (ownerIndex < initialOwnerCount) {
            workspaceOwners.add(modules[ownerIndex])
            ownerIndex++
        }
        // A pure workspace root may declare public path dependencies even
        // though it is not itself a source module. Those edges are inherited
        // by every initial workspace member.
        addPathDependencies(modules, seen, workspaceOwners.toArray(), root, manifest,
            selectedTarget, diagnostics, budget, auxiliaryBudget)
    }

    var moduleIndex: Int64 = 0
    while (moduleIndex < modules.size && !budget.limitReached) {
        let module = modules[moduleIndex]
        if (let Some(cacheRoot) <- selectedCacheRoot) {
            // The root lock was already attached to every initial module. Each
            // non-root module owns its own lock edges, so newly discovered
            // cached dependencies are traversed breadth-first without network.
            if (module.actualRoot != root) {
                let locked = readLockedDependencies(module.actualRoot, false, diagnostics,
                    budget.remainingDependencyDiscoveries(), auxiliaryBudget)
                budget.consumeDependencyCandidates(locked.entryCount)
                for (dependency in locked.dependencies) {
                    if (budget.limitReached) { break }
                    addLockedDependency(modules, seen, [module], dependency,
                        cacheRoot, dependencySources, diagnostics, budget, auxiliaryBudget)
                }
                if (locked.limitReached) { budget.markLimitReached() }
            }
        }
        if (budget.limitReached) { break }
        if (!includePathDependencies) {
            moduleIndex++
            continue
        }
        let moduleManifest = try {
            readAuxiliaryTextBounded(Path(module.actualRoot).join("cjpm.toml"),
                MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest is not readable; dependency traversal stopped for one package"))
            moduleIndex++
            continue
        }
        addPathDependencies(modules, seen, [module], module.actualRoot, moduleManifest,
            selectedTarget, diagnostics, budget, auxiliaryBudget)
        moduleIndex++
    }
    if (budget.limitReached) {
        addSourceLimitDiagnostic(diagnostics, if (auxiliaryBudget.limitReached()) {
            "source metadata or cache exceeded the configured aggregate byte/work safety budget; source discovery stopped"
        } else {
            "source discovery exceeded 4096 modules or 16384 dependency edges; remaining modules skipped"
        })
    }
    modules
}
