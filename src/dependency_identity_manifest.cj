package cjdoc

import std.collection.*
import std.fs.*

private class DependencyManifestSelection {
    let name: String
    var path = ""
    var version = ""
    var revision = ""
    init(name: String) { this.name = name }
}

private func dependencyManifestSelections(manifest: String, target: String): Array<DependencyManifestSelection> {
    let selections = ArrayList<DependencyManifestSelection>()
    let scanner = TomlLineScanner()
    var mode: Int64 = 0
    var current: ?DependencyManifestSelection = None
    var depth: Int64 = 0
    var entry = StringBuilder()
    for (line in manifest.split("\n")) {
        let code = match (scanner.code(line)) { case Some(value) => value; case None => continue }
        let trimmed = code.trimAscii()
        if (depth == 0 && trimmed.startsWith("[")) {
            let table = tomlTableName(trimmed).getOrDefault({ => "" })
            let (selectedMode, _) = dependencyTableMode(table, if (target.isEmpty()) { None<String> } else { Some(target) })
            mode = selectedMode
            current = None
            if (mode == 2) {
                let segments = table.split(".")
                let name = dependencyName(segments[segments.size - 1] + " = \"\"").value.getOrThrow()
                let selection = DependencyManifestSelection(name)
                selections.add(selection)
                current = Some(selection)
            }
            continue
        }
        if (mode == 0 || trimmed.isEmpty()) { continue }
        if (mode == 2) {
            if (let Some(equals) <- tomlAssignmentEquals(code)) {
                let key = compactTomlBareKey(code[..equals].trimAscii())
                let value = tomlAssignmentString(code, equals).value.getOrDefault({ => "" })
                let selected = current.getOrThrow()
                match (key) {
                    case "path" => selected.path = value
                    case "version" => selected.version = value
                    case "commitId" | "rev" => selected.revision = value
                    case _ => ()
                }
            }
            continue
        }
        entry.append(code)
        entry.append("\n")
        depth += tomlBraceDelta(code)
        if (depth != 0) { continue }
        let assignment = entry.toString()
        entry = StringBuilder()
        let name = dependencyName(assignment).value.getOrThrow()
        let selection = DependencyManifestSelection(name)
        let equals = tomlAssignmentEquals(assignment).getOrThrow()
        if (assignment[equals + 1..].trimAscii().startsWith("{")) {
            let fields = parseTomlInlineStringTable(assignment)
            if (fields.invalid) { throw IllegalArgumentException("invalid dependency selection") }
            selection.path = fields.field("path").getOrDefault({ => "" })
            selection.version = fields.field("version").getOrDefault({ => "" })
            selection.revision = fields.field("commitId").getOrDefault({ => "" })
        } else { selection.version = tomlAssignmentString(assignment, equals).value.getOrThrow() }
        selections.add(selection)
        if (selections.size > 16384) { throw IllegalArgumentException("dependency selection limit exceeded") }
    }
    if (depth != 0) { throw IllegalArgumentException("unfinished dependency selection") }
    selections.toArray()
}

internal func captureManifestDependencySelections(capture: DependencyIdentityCapture,
    owner: DependencyIdentityModule): Unit {
    try {
        for (selection in dependencyManifestSelections(owner.manifest, capture.target)) {
            if (selection.path.isEmpty()) {
                capture.put(owner.id, selection.name, "source", "", "declared", "manifest declaration; actual build selection unknown",
                    version: selection.version, revision: selection.revision)
                continue
            }
            if (selection.path.contains("$")) {
                capture.put(owner.id, selection.name, "source", "", "declared",
                    "manifest path interpolation requires an explicitly resolved build input",
                    version: selection.version, revision: selection.revision)
                capture.diagnostic("CJDOC2302", "source path interpolation has no confirmed build selection")
                continue
            }
            let configured = Path(selection.path)
            let selectedPath = if (configured.isAbsolute()) { configured } else { Path(owner.root).join(selection.path) }
            if (let Some(dependency) <- capture.addModule(selectedPath.toString(), "pathDependency", owner: owner.id)) {
                capture.observe(owner.id, selection.name, dependency.root, "manifest path selection and source bytes")
                if (dependency.root == owner.root) {
                    capture.put(owner.id, selection.name, "source", capture.inputIdentity(dependency.root, true), "conflict",
                        "self-referential source dependency is not a supported build selection")
                    capture.diagnostic("CJDOC2301", "self-referential source dependency is unsupported")
                    continue
                }
                let version = dependencyManifestVersion(dependency.manifest)
                if (!selection.version.isEmpty() && !version.isEmpty() && selection.version != version) {
                    capture.put(owner.id, selection.name, "source", capture.inputIdentity(dependency.root, true), "conflict",
                        "manifest dependency version conflicts with selected path manifest", version: selection.version)
                    capture.diagnostic("CJDOC2301", "manifest dependency version conflicts with observed path source")
                }
            }
        }
    } catch (_: Exception) { capture.diagnostic("CJDOC2302", "named dependency inventory could not be fully observed") }
}
