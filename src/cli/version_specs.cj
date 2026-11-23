protected package cjdoc.cli

import cjdoc.output.isSafeOutputPath
import cjdoc.versions.{VERSION_MAX_SITES, VersionComposeSpec, versionSafeId}
import std.collection.*
import std.sort.*

private func versionPathContainsLatest(value: String): Bool {
    value == "latest" || value.startsWith("latest/") || value.endsWith("/latest") ||
        value.contains("/latest/")
}
private func versionSafeBasePath(value: String): Bool {
    !versionPathContainsLatest(value) && isSafeOutputPath(value) && !value.startsWith(".") &&
        !value.contains("#") && !value.contains("?")
}

private func parseVersionInput(value: String): (String, String) {
    let parts = value.split("=", 2)
    if (parts.size != 2 || !versionSafeId(parts[0]) || parts[1].trimAscii().isEmpty()) {
        throw IllegalArgumentException("--version requires SAFE_ID=LOCAL_HTML_DIRECTORY")
    }
    (parts[0], parts[1])
}

private func versionAssignment(values: HashMap<String, String>, id: String): String {
    match (values.get(id)) {
        case Some(value) => value
        case None => ""
    }
}

internal func buildVersionSpecs(options: NewCliOptions): (ArrayList<VersionComposeSpec>, String, String) {
    if (options.versionInputs.isEmpty()) {
        throw IllegalArgumentException("versions compose requires at least one --version ID=PATH")
    }
    if (options.versionInputs.size > VERSION_MAX_SITES) {
        throw IllegalArgumentException("versions compose exceeds ${VERSION_MAX_SITES} versions")
    }
    let specs = ArrayList<VersionComposeSpec>()
    let ids = HashSet<String>()
    var firstId = ""
    for (raw in options.versionInputs) {
        let (id, source) = parseVersionInput(raw)
        if (!ids.add(id)) { throw IllegalArgumentException("duplicate version id '${id}'") }
        if (firstId.isEmpty()) { firstId = id }
        let spec = VersionComposeSpec(id, source)
        let label = versionAssignment(options.versionLabels, id)
        let channel = versionAssignment(options.versionChannels, id)
        let status = versionAssignment(options.versionStatuses, id)
        let basePath = versionAssignment(options.versionBasePaths, id)
        let release = versionAssignment(options.versionReleases, id)
        let apiDiff = versionAssignment(options.versionDiffs, id)
        if (!label.isEmpty()) { spec.label = label }
        if (!channel.isEmpty()) { spec.channel = channel }
        if (!status.isEmpty()) { spec.status = status }
        if (!basePath.isEmpty()) { spec.basePath = basePath }
        if (!release.isEmpty()) { spec.release = Some(release) }
        if (!apiDiff.isEmpty()) { spec.apiDiffSource = Some(apiDiff) }
        if (!versionSafeBasePath(spec.basePath)) {
            throw IllegalArgumentException("unsafe version base path '${spec.basePath}'")
        }
        specs.add(spec)
    }
    for (assignmentId in options.versionAssignmentIds) {
        if (!ids.contains(assignmentId)) {
            throw IllegalArgumentException("version metadata assignment names unknown version '${assignmentId}'")
        }
    }
    let seenPaths = HashSet<String>()
    for (spec in specs) {
        if (!seenPaths.add(spec.basePath)) {
            throw IllegalArgumentException("duplicate version base path '${spec.basePath}'")
        }
        if (spec.basePath == "index.html" || spec.basePath.startsWith("index.html/") ||
            spec.basePath == "versions.json" || spec.basePath.startsWith("versions.json/") ||
            spec.basePath == "version-navigation.js" || spec.basePath.startsWith("version-navigation.js/")) {
            throw IllegalArgumentException("version base path collides with publisher files '${spec.basePath}'")
        }
        if (spec.basePath == "latest" || spec.basePath.startsWith("latest/")) {
            throw IllegalArgumentException("version base path collides with latest alias '${spec.basePath}'")
        }
    }
    let ordered = specs.toArray()
    sort(ordered, lessThan: { left, right => left.basePath < right.basePath }, stable: true)
    var firstPath = ""
    for (left in ordered) {
        if (firstPath.isEmpty()) { firstPath = left.basePath; continue }
        if (left.basePath.startsWith(firstPath + "/") || firstPath.startsWith(left.basePath + "/")) {
            throw IllegalArgumentException("version base paths overlap")
        }
        firstPath = left.basePath
    }
    let latest = match (options.latestVersion) {
        case Some(value) =>
            if (!ids.contains(value)) { throw IllegalArgumentException("--latest names an unknown version '${value}'") }
            value
        case None => firstId
    }
    let policy = if (options.latestVersion.isSome()) { "explicit" } else { "first-listed" }
    (ArrayList<VersionComposeSpec>(ordered), latest, policy)
}
