protected package cjdoc.semantic.chir

import cjdoc.source.discovery.sourcePackagePathPrefixLength
import cjdoc.source.model.{SourcePackage, SourceFileOrigin, SourceSnapshot}
import std.collection.*
import std.fs.*
import std.sort.*

// Which captured source files belong to a package, which modules it may depend on,
// and which candidate packages its imports actually select. Source evidence only:
// nothing here reads worker output.
private func chirModuleDependencyIds(source: SourceSnapshot, moduleId: String): Array<String> {
    for (module in source.modules) {
        if (module.id == moduleId) {
            let dependencies = ArrayList<String>()
            dependencies.add(all: module.dependencyIds)
            sort(dependencies)
            return dependencies.toArray()
        }
    }
    []
}

internal func chirPackageOrigins(source: SourceSnapshot, moduleId: String,
    packageName: String): Array<SourceFileOrigin> {
    let result = ArrayList<SourceFileOrigin>()
    for (origin in source.sourceFileOrigins where
        origin.moduleId == moduleId && origin.packageName == packageName) {
        result.add(origin)
    }
    sort(result, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
    result.toArray()
}

private func chirImportMatchingPathLength(importedPath: String, packageName: String): Int64 {
    let length = sourcePackagePathPrefixLength(packageName, importedPath)
    if (length < 0 || importedPath.size == length) { return length }
    let boundary = importedPath[length]
    if (boundary == b'.' || boundary == b'{' || boundary == b'*' || boundary == b' ' ||
        boundary == b'\n' || boundary == b'\r') { length } else { -1 }
}

private func chirImportMatchesOrganization(packageDoc: SourcePackage,
    organization: String, moduleOrganization: ?String): Bool {
    if (organization.isEmpty()) { return true }
    if (let Some(index) <- packageDoc.name.indexOf("::")) {
        return index == organization.size && packageDoc.name.startsWith(organization)
    }
    match (moduleOrganization) {
        case Some(value) => value == organization
        case None => false
    }
}

internal func chirPackageDependencies(source: SourceSnapshot, moduleId: String,
    packageName: String): Array<SourcePackage> {
    let allowedModules = HashSet<String>()
    let _ = allowedModules.add(moduleId)
    for (dependencyId in chirModuleDependencyIds(source, moduleId)) {
        let _ = allowedModules.add(dependencyId)
    }
    let organizations = HashMap<String, ?String>()
    for (module in source.modules where allowedModules.contains(module.id)) {
        organizations[module.id] = module.organization
    }
    let candidates = ArrayList<SourcePackage>()
    for (pkg in source.packages) {
        if (!allowedModules.contains(pkg.moduleId) ||
            (pkg.moduleId == moduleId && pkg.name == packageName)) { continue }
        candidates.add(pkg)
    }
    let selectedPackages = HashSet<String>()
    let longestMatches = ArrayList<SourcePackage>()
    for (origin in source.sourceFileOrigins where
        origin.moduleId == moduleId && origin.packageName == packageName) {
        for (facts in origin.importFacts) {
            for (reference in facts.referencePaths()) {
                longestMatches.clear()
                var longest: Int64 = -1
                for (pkg in candidates) {
                    if (!chirImportMatchesOrganization(pkg, facts.organization,
                        organizations.get(pkg.moduleId).getOrDefault({ => None<String> }))) { continue }
                    let length = chirImportMatchingPathLength(reference, pkg.name)
                    if (length < 0 || length < longest) { continue }
                    if (length > longest) { longestMatches.clear(); longest = length }
                    longestMatches.add(pkg)
                }
                for (pkg in longestMatches) { let _ = selectedPackages.add(pkg.moduleId + ":" + pkg.name) }
            }
        }
    }
    let dependencies = ArrayList<SourcePackage>()
    for (pkg in candidates where selectedPackages.contains(pkg.moduleId + ":" + pkg.name)) {
        dependencies.add(pkg)
    }
    sort(dependencies, lessThan: { left, right =>
        if (left.moduleId == right.moduleId) { left.name < right.name }
        else { left.moduleId < right.moduleId }
    }, stable: true)
    dependencies.toArray()
}

// The configured import paths plus the retained artifact roots of the package's
// dependencies, each canonicalized once and deduplicated in first-seen order.
internal func chirDependencyImportPaths(source: SourceSnapshot, options: ChirExecutionOptions,
    moduleId: String, packageName: String,
    artifactRoots: HashMap<String, String>): ArrayList<String> {
    let paths = ArrayList<String>()
    let seen = HashSet<String>()
    for (path in options.importPaths) { chirAppendImportPath(paths, seen, path) }
    for (dependency in chirPackageDependencies(source, moduleId, packageName)) {
        let key = dependency.moduleId + ":" + dependency.name
        if (let Some(path) <- artifactRoots.get(key)) {
            chirAppendImportPath(paths, seen, path)
        }
    }
    paths
}

private func chirCanonicalImportPath(value: String): String {
    let path = Path(value)
    let info = try {
        FileInfo(path)
    } catch (_: Exception) {
        throw IllegalArgumentException("CHIR import path is unavailable")
    }
    if (!info.isDirectory() || info.isSymbolicLink()) {
        throw IllegalArgumentException("CHIR import path must be a regular non-symbolic-link directory")
    }
    try {
        canonicalize(path).toString()
    } catch (_: Exception) {
        throw IllegalArgumentException("CHIR import path cannot be canonicalized")
    }
}

private func chirAppendImportPath(paths: ArrayList<String>, seen: HashSet<String>,
    value: String): Unit {
    let canonical = chirCanonicalImportPath(value)
    if (seen.add(canonical)) { paths.add(canonical) }
}
