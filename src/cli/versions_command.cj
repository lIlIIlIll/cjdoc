protected package cjdoc.cli

import std.collection.*

private func parseVersionAssignment(options: NewCliOptions, args: Array<String>, index: Int64,
    option: String, target: HashMap<String, String>, assignmentIds: ArrayList<String>): Int64 {
    let (id, value) = splitNamedValue(requireNonEmptyCliValue(args, index, option), option)
    if (target.contains(id)) { throw IllegalArgumentException("duplicate versions assignment") }
    target[id] = value
    assignmentIds.add(id)
    index + 2
}

internal func parseVersionsCommand(args: Array<String>): NewCliOptions {
    if (args.size < 3 || args[1] != "compose") {
        throw IllegalArgumentException("versions requires the compose subcommand")
    }
    let options = NewCliOptions()
    options.command = "versions"
    options.versionSubcommand = "compose"
    var index: Int64 = 2
    while (index < args.size) {
        match (args[index]) {
            case "--version" =>
                let (id, path) = splitNamedValue(requireNonEmptyCliValue(args, index, "--version"), "--version")
                options.versionInputs.add(id + "=" + path)
                index += 2
            case "--label" => index = parseVersionAssignment(options, args, index, "--label", options.versionLabels, options.versionAssignmentIds)
            case "--channel" => index = parseVersionAssignment(options, args, index, "--channel", options.versionChannels, options.versionAssignmentIds)
            case "--status" => index = parseVersionAssignment(options, args, index, "--status", options.versionStatuses, options.versionAssignmentIds)
            case "--base-path" => index = parseVersionAssignment(options, args, index, "--base-path", options.versionBasePaths, options.versionAssignmentIds)
            case "--release" => index = parseVersionAssignment(options, args, index, "--release", options.versionReleases, options.versionAssignmentIds)
            case "--diff" => index = parseVersionAssignment(options, args, index, "--diff", options.versionDiffs, options.versionAssignmentIds)
            case "--latest" =>
                options.latestVersion = Some(requireNonEmptyCliValue(args, index, "--latest"))
                index += 2
            case "--output" =>
                options.output = Some(requireNonEmptyCliValue(args, index, "--output"))
                index += 2
            case "--force-owned" =>
                options.forceOwned = true
                index++
            case _ => throw IllegalArgumentException("${args[index]} is not valid for versions compose")
        }
    }
    if (options.versionInputs.isEmpty()) {
        throw IllegalArgumentException("versions compose requires --version ID=PATH")
    }
    if (options.output.isNone()) {
        throw IllegalArgumentException("versions compose requires --output")
    }
    options
}
