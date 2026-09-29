package cjdoc

import std.collection.*
import std.env.*
import std.fs.*

private let MAX_EXAMPLE_DEPENDENCY_PACKAGES: Int64 = 128

internal class ExamplePackageArtifact {
    public let packageName: String
    public let moduleId: String
    public let artifactRoot: Path

    init(packageName: String, moduleId: String, artifactRoot: Path) {
        this.packageName = packageName
        this.moduleId = moduleId
        this.artifactRoot = artifactRoot
    }
}

internal class ExampleDependencyPreparation {
    public let workRoot: ?Path
    public let artifacts: Array<ExamplePackageArtifact>
    public let failure: String

    init(workRoot: ?Path, artifacts: Array<ExamplePackageArtifact>, failure: String) {
        this.workRoot = workRoot
        this.artifacts = artifacts
        this.failure = failure
    }
}

private func exampleReachableModules(documentation: DocumentationSet, start: String): HashSet<String> {
    let reachable = HashSet<String>()
    let queue = ArrayList<String>()
    let _ = reachable.add(start)
    queue.add(start)
    var index: Int64 = 0
    while (index < queue.size) {
        let current = queue[index]
        index++
        for (module in documentation.modules where module.id == current) {
            for (dependencyId in module.dependencyIds) {
                if (reachable.add(dependencyId)) { queue.add(dependencyId) }
            }
            break
        }
    }
    reachable
}

private func cachedExampleReachableModules(documentation: DocumentationSet, moduleId: String,
    cache: HashMap<String, HashSet<String>>): HashSet<String> {
    match (cache.get(moduleId)) {
        case Some(value) => value
        case None =>
            let value = exampleReachableModules(documentation, moduleId)
            cache[moduleId] = value
            value
    }
}

private func selectExamplePackage(documentation: DocumentationSet, ownerModuleId: String,
    packageName: String, reachable: HashSet<String>): (?PackageDoc, Bool) {
    var sameModule: ?PackageDoc = None
    let candidates = ArrayList<PackageDoc>()
    for (candidate in documentation.packages where candidate.name == packageName) {
        if (candidate.moduleId == ownerModuleId) {
            if (sameModule.isSome()) { return (None<PackageDoc>, true) }
            sameModule = Some(candidate)
        } else if (reachable.contains(candidate.moduleId)) {
            candidates.add(candidate)
        }
    }
    if (sameModule.isSome()) { return (sameModule, false) }
    if (candidates.size == 1) { return (Some(candidates[0]), false) }
    (None<PackageDoc>, candidates.size > 1)
}

private func addExampleImportedPackage(documentation: DocumentationSet, ownerModuleId: String,
    packageName: String, reachableCache: HashMap<String, HashSet<String>>,
    required: ArrayList<PackageDoc>, seen: HashSet<String>): String {
    let reachable = cachedExampleReachableModules(documentation, ownerModuleId, reachableCache)
    let (selected, ambiguous) = selectExamplePackage(documentation, ownerModuleId,
        packageName, reachable)
    if (ambiguous) { return "imported package '${packageName}' is ambiguous" }
    match (selected) {
        case None => return ""
        case Some(packageDoc) =>
            let key = packageDoc.moduleId + "\n" + packageDoc.name
            if (seen.contains(key)) { return "" }
            if (required.size >= MAX_EXAMPLE_DEPENDENCY_PACKAGES) {
                return "example package dependency limit of ${MAX_EXAMPLE_DEPENDENCY_PACKAGES} was reached"
            }
            let _ = seen.add(key)
            required.add(packageDoc)
    }
    ""
}

private func requiredExamplePackages(documentation: DocumentationSet,
    unit: ExampleCompilationUnit): (Array<PackageDoc>, String) {
    let required = ArrayList<PackageDoc>()
    let seen = HashSet<String>()
    let reachableCache = HashMap<String, HashSet<String>>()
    var ownerModuleId = unit.moduleId
    var index: Int64 = 0
    while (index < unit.sourceOrigins.size) {
        let origin = unit.sourceOrigins[index]
        for (packageName in origin.packageImports) {
            let failure = addExampleImportedPackage(documentation, ownerModuleId, packageName,
                reachableCache, required, seen)
            if (!failure.isEmpty()) { return ([], failure) }
        }
        index++
    }
    index = 0
    while (index < required.size) {
        let packageDoc = required[index]
        index++
        ownerModuleId = packageDoc.moduleId
        for (origin in documentation.sourceFileOrigins where
            origin.moduleId == packageDoc.moduleId && origin.packageName == packageDoc.name) {
            for (packageName in origin.packageImports) {
                let failure = addExampleImportedPackage(documentation, ownerModuleId, packageName,
                    reachableCache, required, seen)
                if (!failure.isEmpty()) { return ([], failure) }
            }
        }
    }
    var sourceBytes = unit.sourceBytes
    for (packageDoc in required) {
        var foundOrigin = false
        for (origin in documentation.sourceFileOrigins where
            origin.moduleId == packageDoc.moduleId && origin.packageName == packageDoc.name) {
            foundOrigin = true
            let size = origin.capturedSource.toArray().size
            if (size > MAX_EXAMPLE_SOURCE_FILE_BYTES ||
                sourceBytes > MAX_EXAMPLE_SOURCE_BYTES - size) {
                return ([], "imported package sources exceed the ${MAX_EXAMPLE_SOURCE_BYTES}-byte limit")
            }
            sourceBytes += size
        }
        if (!foundOrigin) {
            return ([], "source for imported package '${packageDoc.name}' is unavailable")
        }
    }
    (required.toArray(), "")
}

private func exampleModule(documentation: DocumentationSet, moduleId: String): ?ModuleDoc {
    for (module in documentation.modules) {
        if (module.id == moduleId) { return Some(module) }
    }
    None
}

private func compileExampleDependency(documentation: DocumentationSet, packageDoc: PackageDoc,
    workRoot: Path, artifacts: ArrayList<ExamplePackageArtifact>, index: Int64):
    (?ExamplePackageArtifact, String) {
    let module = match (exampleModule(documentation, packageDoc.moduleId)) {
        case Some(value) => value
        case None => return (None<ExamplePackageArtifact>,
            "module for imported package '${packageDoc.name}' is unavailable")
    }
    let sourceRoot = match (discoveredPackageSourceRoot(module.id, module.sourcePrefix,
        packageDoc.sourceFiles.toArray(), documentation.sourceFileOrigins.toArray())) {
        case Some(value) => value
        case None => return (None<ExamplePackageArtifact>,
            "source root for imported package '${packageDoc.name}' is unavailable")
    }
    let artifactRoot = workRoot.join("package-${index}")
    try { Directory.create(artifactRoot, recursive: true) } catch (_: Exception) {
        return (None<ExamplePackageArtifact>, "cannot prepare imported package '${packageDoc.name}'")
    }
    let arguments = ArrayList<String>()
    arguments.add("-Woff"); arguments.add("all")
    arguments.add("--diagnostic-format"); arguments.add("noColor")
    arguments.add("--error-count-limit"); arguments.add("8")
    for (cfg in documentation.cfgProfile.values) {
        arguments.add("--cfg"); arguments.add(cfg.name + "=" + cfg.value)
    }
    for (artifact in artifacts) {
        arguments.add("--import-path"); arguments.add(artifact.artifactRoot.toString())
        arguments.add("--library-path"); arguments.add(artifact.artifactRoot.toString())
    }
    arguments.add("--output-type"); arguments.add("staticlib")
    arguments.add("--output-dir"); arguments.add(artifactRoot.toString())
    arguments.add("-p"); arguments.add(sourceRoot)
    let (exitCode, stdout, stderr) = executeWithBoundedOutput("cjc", arguments.toArray(),
        workingDirectory: Some(workRoot))
    if (exitCode != 0) {
        let output = compilerOutput(stdout, stderr, Path(sourceRoot), workRoot)
            .replace("<generated-example>", "<package-source>")
        return (None<ExamplePackageArtifact>,
            "imported package '${packageDoc.name}' could not be compiled: " + output)
    }
    (Some(ExamplePackageArtifact(packageDoc.name, packageDoc.moduleId, artifactRoot)), "")
}

private func examplePackageArtifactAvailable(artifacts: ArrayList<ExamplePackageArtifact>,
    packageDoc: PackageDoc): Bool {
    for (artifact in artifacts) {
        if (artifact.moduleId == packageDoc.moduleId && artifact.packageName == packageDoc.name) {
            return true
        }
    }
    false
}

private func examplePackageWasRequired(required: Array<PackageDoc>, packageDoc: PackageDoc): Bool {
    for (candidate in required) {
        if (candidate.moduleId == packageDoc.moduleId && candidate.name == packageDoc.name) {
            return true
        }
    }
    false
}

private func examplePackageDependenciesReady(documentation: DocumentationSet,
    packageDoc: PackageDoc, required: Array<PackageDoc>,
    artifacts: ArrayList<ExamplePackageArtifact>,
    reachableCache: HashMap<String, HashSet<String>>): Bool {
    let reachable = cachedExampleReachableModules(documentation, packageDoc.moduleId, reachableCache)
    for (origin in documentation.sourceFileOrigins where
        origin.moduleId == packageDoc.moduleId && origin.packageName == packageDoc.name) {
        for (packageName in origin.packageImports) {
            let (selected, _) = selectExamplePackage(documentation, packageDoc.moduleId,
                packageName, reachable)
            match (selected) {
                case Some(dependency) =>
                    if (dependency.moduleId == packageDoc.moduleId &&
                        dependency.name == packageDoc.name) { return false }
                    if (examplePackageWasRequired(required, dependency) &&
                        !examplePackageArtifactAvailable(artifacts, dependency)) { return false }
                case None => ()
            }
        }
    }
    true
}

internal func prepareExampleDependencies(documentation: DocumentationSet,
    unit: ExampleCompilationUnit): ExampleDependencyPreparation {
    let (required, requirementFailure) = requiredExamplePackages(documentation, unit)
    if (!requirementFailure.isEmpty()) {
        return ExampleDependencyPreparation(None<Path>, [], requirementFailure)
    }
    if (required.isEmpty()) { return ExampleDependencyPreparation(None<Path>, [], "") }
    let workRoot = try {
        Directory.createTemp(getTempDirectory())
    } catch (_: Exception) {
        return ExampleDependencyPreparation(None<Path>, [],
            "cannot create a temporary directory for imported packages")
    }
    let pending = ArrayList<PackageDoc>()
    pending.add(all: required)
    let artifacts = ArrayList<ExamplePackageArtifact>()
    let reachableCache = HashMap<String, HashSet<String>>()
    var index: Int64 = 0
    while (!pending.isEmpty()) {
        let deferred = ArrayList<PackageDoc>()
        var compiledAny = false
        for (packageDoc in pending) {
            if (!examplePackageDependenciesReady(documentation, packageDoc, required,
                artifacts, reachableCache)) {
                deferred.add(packageDoc)
                continue
            }
            let (artifact, failure) = compileExampleDependency(documentation, packageDoc,
                workRoot, artifacts, index)
            index++
            match (artifact) {
                case Some(value) => artifacts.add(value); compiledAny = true
                case None =>
                    try { let _ = removeIfExists(workRoot, recursive: true) } catch (_: Exception) {}
                    return ExampleDependencyPreparation(None<Path>, [], failure)
            }
        }
        if (!compiledAny) {
            try { let _ = removeIfExists(workRoot, recursive: true) } catch (_: Exception) {}
            return ExampleDependencyPreparation(None<Path>, [],
                "imported package dependencies contain an unresolved cycle")
        }
        pending.clear()
        pending.add(all: deferred.toArray())
    }
    ExampleDependencyPreparation(Some(workRoot), artifacts.toArray(), "")
}

internal func releaseExampleDependencies(preparation: ExampleDependencyPreparation): Unit {
    match (preparation.workRoot) {
        case Some(path) => try { let _ = removeIfExists(path, recursive: true) } catch (_: Exception) {}
        case None => ()
    }
}
