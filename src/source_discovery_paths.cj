package cjdoc

import std.ast.*
import std.collection.*
import std.fs.*
import std.sort.*

func percentEscapeSymbolPart(value: String): String {
    let builder = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case ':' => builder.append("%3A")
            case '#' => builder.append("%23")
            case '(' => builder.append("%28")
            case ')' => builder.append("%29")
            case ',' => builder.append("%2C")
            case '%' => builder.append("%25")
            case _ => builder.append(rune)
        }
    }
    return builder.toString()
}

func normalizedHostPath(path: String): String {
    // A backslash is a separator on Windows but ordinary filename data on
    // POSIX. Preserve it in absolute POSIX paths so host containment never
    // aliases `a\\b` with `a/b`; logical relative paths reject it below.
    let normalized = if (path.startsWith("/")) { path } else { path.replace("\\", "/") }
    if (normalized.endsWith("/") && normalized != "/" && !normalized.endsWith(":/")) {
        normalized.trimEnd("/")
    } else {
        normalized
    }
}

func hostPathIsWithin(root: String, candidate: String): Bool {
    let normalizedRoot = normalizedHostPath(root)
    let normalizedCandidate = normalizedHostPath(candidate)
    let prefix = if (normalizedRoot.endsWith("/")) { normalizedRoot } else { normalizedRoot + "/" }
    normalizedCandidate == normalizedRoot || normalizedCandidate.startsWith(prefix)
}

internal func safeLogicalSourcePath(path: String, allowEmpty!: Bool = false): Bool {
    if (path.isEmpty()) { return allowEmpty }
    if (path.startsWith("/") || path.contains("\\")) { return false }
    let segments = path.split("/")
    let first = segments[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}

internal func safePackageSourceDirectory(path: String): Bool {
    if (path.isEmpty() || path == ".") { return true }
    safeLogicalSourcePath(path)
}

internal func resolvedPackageSourceRoot(moduleRoot: String,
    configured: ?String): ?String {
    let relative = match (configured) {
        case Some(value) => if (value.isEmpty()) { "src" } else { value }
        case None => "src"
    }
    if (!safePackageSourceDirectory(relative)) { return None }
    let candidate = if (relative == ".") {
        moduleRoot
    } else {
        Path(moduleRoot).join(relative).toString()
    }
    let resolved = try { canonicalize(candidate).toString() } catch (_: Exception) { return None }
    if (!hostPathIsWithin(moduleRoot, resolved)) { return None }
    let directory = try { FileInfo(resolved) } catch (_: Exception) { return None }
    if (!directory.isDirectory() || directory.isSymbolicLink()) { return None }
    Some(resolved)
}

func relativePathFromResolved(root: String, path: String): ?String {
    let base = normalizedHostPath(root)
    let full = normalizedHostPath(path)
    if (full == base) { return Some("") }
    let prefix = if (base.endsWith("/")) { base } else { base + "/" }
    if (!full.startsWith(prefix)) { return None }
    let relative = full[prefix.size..]
    if (!safeLogicalSourcePath(relative)) { return None }
    Some(relative)
}

internal func relativePath(root: String, path: String): ?String {
    let base = canonicalize(root).toString()
    let full = canonicalize(path).toString()
    relativePathFromResolved(base, full)
}

class SourceDirectoryBudget {
    let maxEntries: Int64
    let maxDepth: Int64
    var entries: Int64 = 0
    var limitReached = false
    var unsafeLogicalPath = false

    init(maxEntries!: Int64 = MAX_SOURCE_DIRECTORY_ENTRIES,
        maxDepth!: Int64 = MAX_SOURCE_DIRECTORY_DEPTH) {
        if (maxEntries < 1 || maxDepth < 0) {
            throw IllegalArgumentException("source directory limits are invalid")
        }
        this.maxEntries = maxEntries
        this.maxDepth = maxDepth
    }

    func consume(relative: String): Bool {
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

internal class SourceInputFile {
    let actualPath: String
    let actualRoot: String
    let logicalPath: String
    let module: SourceModule
    let discoveredSize: Int64

    init(actualPath: String, actualRoot: String, logicalPath: String, module: SourceModule,
        discoveredSize: Int64) {
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.logicalPath = logicalPath
        this.module = module
        this.discoveredSize = discoveredSize
    }
}

internal func sortStrings(values: ArrayList<String>): Unit {
    sort(values)
}
