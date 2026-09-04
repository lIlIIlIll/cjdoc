package cjdoc

import std.ast.*
import std.collection.*
import std.fs.*
import std.sort.*

class AstSourceProvider <: SourceProvider {
    private let includePathDependencies: Bool
    private let dependencySources: Array<DependencySourceInput>
    private let jobs: Int64
    private let cacheDirectory: ?String
    private let cacheFingerprint: String
    private let astPreflightExecutable: ?String
    private let includeCachedDependencies: Bool
    private let cjpmCacheRoot: ?String
    private let sourceDirectoryEntryLimit: Int64
    private let sourceAuxiliaryByteLimit: Int64
    private let sourceAuxiliaryWorkLimit: Int64
    public let cacheStats = SourceCacheStats()

    public init(includePathDependencies!: Bool = false,
        dependencySources!: Array<DependencySourceInput> = [], jobs!: Int64 = 1,
        cacheDirectory!: ?String = None, cacheFingerprint!: ?String = None,
        astPreflightExecutable!: ?String = None,
        includeCachedDependencies!: Bool = false, cjpmCacheRoot!: ?String = None,
        sourceDirectoryEntryLimit!: Int64 = MAX_SOURCE_DIRECTORY_ENTRIES,
        sourceAuxiliaryByteLimit!: Int64 = MAX_SOURCE_AUXILIARY_BYTES,
        sourceAuxiliaryWorkLimit!: Int64 = MAX_SOURCE_AUXILIARY_WORK) {
        if (sourceDirectoryEntryLimit < 1 || sourceAuxiliaryByteLimit < 0 ||
            sourceAuxiliaryWorkLimit < 0) {
            throw IllegalArgumentException("source safety limits are invalid")
        }
        this.includePathDependencies = includePathDependencies
        this.dependencySources = dependencySources
        this.jobs = if (jobs < 1) { 1 } else if (jobs > 64) { 64 } else { jobs }
        this.cacheDirectory = cacheDirectory
        this.cacheFingerprint = match (cacheFingerprint) {
            case Some(value) => value
            case None => if (cacheDirectory.isSome()) { defaultSourceCacheFingerprint() } else { "cache-disabled" }
        }
        this.astPreflightExecutable = astPreflightExecutable
        this.includeCachedDependencies = includeCachedDependencies
        this.cjpmCacheRoot = cjpmCacheRoot
        this.sourceDirectoryEntryLimit = sourceDirectoryEntryLimit
        this.sourceAuxiliaryByteLimit = sourceAuxiliaryByteLimit
        this.sourceAuxiliaryWorkLimit = sourceAuxiliaryWorkLimit
    }

    public func collect(projectRoot: String): SourceSnapshot {
        cacheStats.reset()
        let auxiliaryBudget = SourceAuxiliaryBudget(sourceAuxiliaryByteLimit,
            sourceAuxiliaryWorkLimit)
        let root = try {
            canonicalize(projectRoot).toString()
        } catch (_: Exception) {
            let requestedName = Path(projectRoot).fileName
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "project path is not accessible"))
            return source
        }
        let manifestPath = Path(root).join("cjpm.toml")
        let requestedName = Path(root).fileName
        if (!exists(manifestPath)) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "project must contain cjpm.toml"))
            return source
        }
        let manifest = try {
            readAuxiliaryTextBounded(manifestPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
        } catch (_: Exception) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.modules.add(SourceModule(moduleId("root", source.projectName, ""),
                source.projectName, "root", ""))
            if (auxiliaryBudget.limitReached()) {
                addSourceLimitDiagnostic(source.diagnostics,
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; source parsing skipped")
            } else {
                source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                    "failed to read cjpm.toml"))
            }
            return source
        }
        if (!auxiliaryBudget.consumeWork(manifest.size)) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.modules.add(SourceModule(moduleId("root", source.projectName, ""),
                source.projectName, "root", ""))
            addSourceLimitDiagnostic(source.diagnostics,
                "source metadata or cache exceeded the configured aggregate byte/work safety budget; source parsing skipped")
            return source
        }
        let packageView = parseCjpmPackageNameChecked(manifest)
        let projectName = match (packageView.value) {
            case Some(name) => name
            case None => if (requestedName.isEmpty()) { "project" } else { requestedName }
        }
        let sourceSnapshot = SourceSnapshot(projectName)
        if (packageView.limitReached) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics,
                "source metadata exceeded the configured byte or work safety budget; source parsing skipped")
            return sourceSnapshot
        }
        if (packageView.invalid) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
            sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "cjpm.toml contains an invalid TOML string; source parsing skipped"))
            return sourceSnapshot
        }
        let moduleRoots = discoverSourceModules(root, manifest, includePathDependencies,
            dependencySources,
            includeCachedDependencies, cjpmCacheRoot,
            sourceSnapshot.diagnostics, auxiliaryBudget)
        for (module in moduleRoots) { sourceSnapshot.modules.add(module.documentation) }
        if (sourceSnapshot.modules.isEmpty()) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
        }
        if (auxiliaryBudget.limitReached()) {
            return sourceSnapshot
        }
        if (hasSourceLimitDiagnostic(sourceSnapshot.diagnostics)) { return sourceSnapshot }
        if (hasFatalSourceDiagnostics(sourceSnapshot)) { return sourceSnapshot }
        let files = ArrayList<SourceInputFile>()
        let logicalPaths = HashSet<String>()
        let directoryBudget = SourceDirectoryBudget(maxEntries: sourceDirectoryEntryLimit)
        var scanLimitReached = false
        var logicalPathFailure = false
        var totalSourceBytes: Int64 = 0
        for (module in moduleRoots) {
            if (files.size >= MAX_SOURCE_FILES) { scanLimitReached = true; break }
            try {
                let moduleFiles = ArrayList<String>()
                let complete = collectSourceFiles(module.actualSourceRoot,
                    moduleFiles, MAX_SOURCE_FILES - files.size, directoryBudget)
                if (!complete && directoryBudget.limitReached) { scanLimitReached = true }
                if (directoryBudget.unsafeLogicalPath && !logicalPathFailure) {
                    sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                        "source path cannot be represented by a portable logical path; source scan stopped"))
                    logicalPathFailure = true
                }
                for (file in moduleFiles) {
                    if (logicalPathFailure) { break }
                    let logicalPathValue = logicalSourcePath(root, module, file)
                    if (logicalPathValue.isNone()) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                            "source path cannot be represented by a portable logical path; source scan stopped"))
                        logicalPathFailure = true
                        continue
                    }
                    let logicalPath = logicalPathValue.getOrThrow()
                    if (!logicalPaths.add(logicalPath)) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                            "source files collide at one logical path; source scan stopped"))
                        logicalPathFailure = true
                        continue
                    }
                    let size: ?Int64 = try {
                        let info = FileInfo(file)
                        if (!info.isRegular() || info.isSymbolicLink() || info.size < 0) {
                            throw IllegalArgumentException("source file is not regular")
                        }
                        Some(info.size)
                    } catch (_: Exception) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1011",
                            "failed to inspect '${logicalPath}'",
                            source: SourceLocation(logicalPath, 1, 1, 1, 1)))
                        None
                    }
                    if (size.isNone()) { continue }
                    let actualSize = size.getOrThrow()
                    if (actualSize <= MAX_SOURCE_FILE_BYTES &&
                        actualSize > MAX_TOTAL_SOURCE_BYTES - totalSourceBytes) {
                        scanLimitReached = true
                        break
                    }
                    if (actualSize <= MAX_SOURCE_FILE_BYTES) { totalSourceBytes += actualSize }
                    files.add(SourceInputFile(file, module.actualRoot, logicalPath,
                        module.documentation, actualSize))
                }
            } catch (_: Exception) {
                sourceSnapshot.diagnostics.add(Diagnostic(
                    if (module.documentation.role == "root") { "error" } else { "warning" },
                    "CJDOC1027",
                    "failed to scan source module '${module.documentation.id}'"))
            }
            if (scanLimitReached || logicalPathFailure) { break }
        }
        if (scanLimitReached) {
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics,
                "source scan exceeded the configured file, directory entry, directory depth, " +
                "or readable-byte safety budget; source parsing skipped")
            // Directory iteration order is host dependent. Once discovery is
            // truncated, emitting only the stable module graph and diagnostic
            // avoids making the selected declaration subset nondeterministic.
            return sourceSnapshot
        }
        sort(files, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
        if (hasFatalSourceDiagnostics(sourceSnapshot)) { return sourceSnapshot }
        let usableCacheDirectory: ?String = match (cacheDirectory) {
            case None => None
            case Some(directory) => try {
                let path = Path(directory)
                if (!exists(path)) { Directory.create(path, recursive: true) }
                Some(canonicalize(path).toString())
            } catch (_: Exception) {
                None
            }
        }
        parseAllSourceFiles(sourceSnapshot, files, jobs, usableCacheDirectory,
            cacheFingerprint, cacheStats, astPreflightExecutable, auxiliaryBudget)
        return sourceSnapshot
    }
}
