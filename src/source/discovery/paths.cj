protected package cjdoc.source.discovery

import cjdoc.source.model.SourceModule
import cjdoc.source.Diagnostic
import cjdoc.source.{MAX_SOURCE_DIRECTORY_DEPTH, MAX_SOURCE_DIRECTORY_ENTRIES, MAX_SOURCE_MODULES, MAX_SOURCE_DEPENDENCY_EDGES}
import std.collection.*
import std.fs.*
import std.sort.*
import cjdoc.source.{relativePath, relativePathFromResolved, safeLogicalSourcePath}

protected class SourceDirectoryBudget {
    protected let maxEntries: Int64
    protected let maxDepth: Int64
    protected var entries: Int64 = 0
    protected var limitReached = false
    var unsafeLogicalPath = false

    protected init(maxEntries!: Int64 = MAX_SOURCE_DIRECTORY_ENTRIES,
        maxDepth!: Int64 = MAX_SOURCE_DIRECTORY_DEPTH) {
        if (maxEntries < 1 || maxDepth < 0) {
            throw IllegalArgumentException("source directory limits are invalid")
        }
        this.maxEntries = maxEntries
        this.maxDepth = maxDepth
    }

    protected func consume(relative: String): Bool {
        if (entries >= maxEntries) {
            limitReached = true
            return false
        }
        entries++
        let depth = if (relative.isEmpty()) { 0 } else { relative.split("/").size }
        if (depth > maxDepth) {
            limitReached = true
            return false
        }
        true
    }
}

internal func collectSourceFilesInDirectory(rootDirectory: String, directory: String,
    result: ArrayList<String>, limit: Int64, budget: SourceDirectoryBudget): Bool {
    let complete = Array<Bool>(1, repeat: true)
    Directory.walk(Path(directory), { entry =>
        match (relativePathFromResolved(rootDirectory, entry.path.toString())) {
            case None =>
                budget.unsafeLogicalPath = true
                complete[0] = false
                false
            case Some(relative) =>
                if (!budget.consume(relative)) {
                    complete[0] = false
                    false
                } else if (entry.isSymbolicLink() || entry.isHidden()) {
                    true
                } else if (entry.isDirectory()) {
                    if (!collectSourceFilesInDirectory(rootDirectory, entry.path.toString(),
                        result, limit, budget)) {
                        complete[0] = false
                        false
                    } else {
                        true
                    }
                } else if (entry.isRegular() && entry.path.extensionName == "cj" &&
                    !entry.name.endsWith("_test.cj")) {
                    if (result.size >= limit) {
                        budget.limitReached = true
                        complete[0] = false
                        false
                    } else {
                        result.add(entry.path.toString())
                        true
                    }
                } else {
                    true
                }
        }
    })
    complete[0]
}

internal func collectSourceFiles(directory: String, result: ArrayList<String>,
    limit: Int64, budget: SourceDirectoryBudget): Bool {
    let complete = collectSourceFilesInDirectory(directory, directory, result, limit, budget)
    sortStrings(result)
    complete
}

internal func logicalSourcePath(projectRoot: String, module: SourceModuleRoot,
    file: String): ?String {
    let moduleRelative = match (relativePath(module.actualRoot, file)) {
        case Some(value) => value
        case None => return None
    }
    if (module.logicalPrefix.isEmpty()) { return relativePath(projectRoot, file) }
    let logical = module.logicalPrefix + "/" + moduleRelative
    if (safeLogicalSourcePath(logical)) { Some(logical) } else { None }
}

internal class SourceModuleRoot {
    let actualRoot: String
    let actualSourceRoot: String
    let logicalPrefix: String
    let documentation: SourceModule

    init(actualRoot: String, actualSourceRoot: String, logicalPrefix: String,
        documentation: SourceModule) {
        this.actualRoot = actualRoot
        this.actualSourceRoot = actualSourceRoot
        this.logicalPrefix = logicalPrefix
        this.documentation = documentation
    }
}

internal class SourceDiscoveryBudget {
    var dependencyEdges: Int64 = 0
    var limitReached = false
    private var moduleCandidates: Int64 = 0
    private var dependencyCandidates: Int64 = 0
    private var invalidDependencyEdgeReported = false

    func remainingModuleCandidates(): Int64 {
        MAX_SOURCE_MODULES - moduleCandidates
    }

    func remainingDependencyCandidates(): Int64 {
        MAX_SOURCE_DEPENDENCY_EDGES - dependencyCandidates
    }

    func remainingDependencyDiscoveries(): Int64 {
        let modules = remainingModuleCandidates()
        let dependencies = remainingDependencyCandidates()
        if (modules < dependencies) { modules } else { dependencies }
    }

    func consumeModuleCandidates(count: Int64): Unit {
        moduleCandidates += count
    }

    func consumeDependencyCandidates(count: Int64): Unit {
        moduleCandidates += count
        dependencyCandidates += count
    }

    // GenerationRequest already bounds explicit dependencySources. Counting
    // those entries as both module candidates and dependency candidates here
    // charged them twice before any module was actually accepted.
    func consumeExplicitDependencyCandidates(count: Int64): Unit {
        dependencyCandidates += count
    }

    func markLimitReached(): Unit { limitReached = true }

    func canAddModule(currentCount: Int64): Bool {
        if (currentCount >= MAX_SOURCE_MODULES) {
            limitReached = true
            return false
        }
        true
    }

    func addDependency(modules: ArrayList<SourceModuleRoot>, owner: SourceModule,
        dependencyId: String, diagnostics: ArrayList<Diagnostic>): Bool {
        for (existing in owner.dependencyIds) {
            if (existing == dependencyId) { return true }
        }
        if (dependencyWouldCreateCycle(modules, owner.id, dependencyId)) {
            if (!invalidDependencyEdgeReported) {
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "dependency edge would create a self-reference or cycle; skipped"))
                invalidDependencyEdgeReported = true
            }
            return true
        }
        if (dependencyEdges >= MAX_SOURCE_DEPENDENCY_EDGES) {
            limitReached = true
            return false
        }
        owner.dependencyIds.add(dependencyId)
        dependencyEdges++
        true
    }
}

protected func sortStrings(values: ArrayList<String>): Unit {
    sort(values)
}
