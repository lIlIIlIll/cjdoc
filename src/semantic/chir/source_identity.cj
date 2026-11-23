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

private func chirModuleOrganization(source: SourceSnapshot, moduleId: String): ?String {
    for (module in source.modules) {
        if (module.id == moduleId) { return module.organization }
    }
    None
}

internal func chirPackageOrigins(source: SourceSnapshot, moduleId: String,
    packageName: String): Array<SourceFileOrigin> {
    let result = ArrayList<SourceFileOrigin>()
    for (pkg in source.packages) {
        if (pkg.moduleId != moduleId || pkg.name != packageName) { continue }
        for (logicalPath in pkg.sourceFiles) {
            for (origin in source.sourceFileOrigins) {
                if (origin.moduleId == moduleId && origin.logicalPath == logicalPath) { result.add(origin) }
            }
        }
    }
    sort(result, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
    result.toArray()
}

private func chirImportAliasSeparator(value: String): ?Int64 {
    let bytes = value.toArray()
    var index: Int64 = 0
    while (index + 1 < bytes.size) {
        if (bytes[index] == b'a' && bytes[index + 1] == b's') {
            let before = index == 0 || bytes[index - 1] == b' ' || bytes[index - 1] == b'\t'
            let after = index + 2 >= bytes.size || bytes[index + 2] == b' ' ||
                bytes[index + 2] == b'\t'
            if (before && after) { return Some(index) }
        }
        index++
    }
    None
}

private func chirImportReference(importText: String): (String, String) {
    let trimmed = importText.trimAscii()
    let value = if (trimmed.startsWith("public ")) {
        trimmed.removePrefix("public ").trimAscii()
    } else {
        trimmed
    }
    if (!value.startsWith("import ")) { return ("", "") }
    var importedName = value[7..].trimAscii()
    if (let Some(alias) <- chirImportAliasSeparator(importedName)) {
        importedName = importedName[..alias].trimAscii()
    }
    match (importedName.indexOf("::")) {
        case Some(index) =>
            if (index <= 0 || index + 2 >= importedName.size) { return ("", "") }
            (importedName[..index].trimAscii(), importedName[index + 2..].trimAscii())
        case None => ("", importedName)
    }
}

private func chirImportMatchingPathLength(importedPath: String, packageName: String): Int64 {
    let length = sourcePackagePathPrefixLength(packageName, importedPath)
    if (length < 0 || importedPath.size == length) { return length }
    let boundary = importedPath[length]
    if (boundary == b'.' || boundary == b'{' || boundary == b'*' || boundary == b' ' ||
        boundary == b'\n' || boundary == b'\r') { length } else { -1 }
}

// An import selects a package only when it names that package's longest matching
// path, so a sibling whose name merely shares a prefix is not a dependency.
private func chirImportReferencesPackage(importText: String, dependencyPackage: SourcePackage,
    candidates: Array<SourcePackage>, source: SourceSnapshot): Bool {
    let reference = chirImportReference(importText)
    let organization = reference[0]
    let importedPath = reference[1]
    if (!chirImportMatchesOrganization(dependencyPackage, organization,
        chirModuleOrganization(source, dependencyPackage.moduleId))) { return false }
    let selectedLength = chirImportMatchingPathLength(importedPath, dependencyPackage.name)
    if (selectedLength < 0) { return false }
    var longest: Int64 = -1
    for (candidate in candidates) {
        if (!chirImportMatchesOrganization(candidate, organization,
            chirModuleOrganization(source, candidate.moduleId))) { continue }
        let length = chirImportMatchingPathLength(importedPath, candidate.name)
        if (length > longest) { longest = length }
    }
    selectedLength == longest
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

private func chirPackageDependsOn(source: SourceSnapshot, moduleId: String, packageName: String,
    dependency: SourcePackage, candidates: Array<SourcePackage>): Bool {
    for (pkg in source.packages) {
        if (pkg.moduleId != moduleId || pkg.name != packageName) { continue }
        for (logicalPath in pkg.sourceFiles) {
            for (origin in source.sourceFileOrigins) {
                if (origin.moduleId != moduleId || origin.logicalPath != logicalPath) { continue }
                for (importText in origin.imports) {
                    if (chirImportReferencesPackage(importText, dependency, candidates, source)) {
                        return true
                    }
                }
            }
        }
    }
    false
}

internal func chirPackageDependencies(source: SourceSnapshot, moduleId: String,
    packageName: String): Array<SourcePackage> {
    let allowedModules = HashSet<String>()
    let _ = allowedModules.add(moduleId)
    for (dependencyId in chirModuleDependencyIds(source, moduleId)) {
        let _ = allowedModules.add(dependencyId)
    }
    let candidates = ArrayList<SourcePackage>()
    for (pkg in source.packages) {
        if (!allowedModules.contains(pkg.moduleId) ||
            (pkg.moduleId == moduleId && pkg.name == packageName)) { continue }
        candidates.add(pkg)
    }
    let dependencies = ArrayList<SourcePackage>()
    let candidateValues = candidates.toArray()
    for (pkg in candidateValues) {
        if (chirPackageDependsOn(source, moduleId, packageName, pkg, candidateValues)) {
            dependencies.add(pkg)
        }
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
