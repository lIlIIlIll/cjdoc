package cjdoc

import cjdoc.model.*
import std.collection.*
import std.sort.*

// Shared by source-context derivation, external graph comparison and symbol
// candidate matching. Neither a new index nor a recursive child resets it.
internal class DependencyNavigationWork {
    private var steps: Int64 = 262144
    private var bytes: Int64 = 32 * 1024 * 1024
    var exhausted: Bool = false

    func take(): Bool {
        if (exhausted || steps == 0) { exhausted = true; return false }
        steps--
        true
    }

    func consumeBytes(amount: Int64): Bool {
        if (exhausted || amount < 0 || amount > bytes) { exhausted = true; return false }
        bytes -= amount
        true
    }
}

internal class DependencyGraphContext {
    let fingerprint: String
    let complete: Bool
    let cyclic: Bool
    let conflicted: Bool
    init(fingerprint: String, complete: Bool, cyclic!: Bool = false, conflicted!: Bool = false) {
        this.fingerprint = fingerprint; this.complete = complete; this.cyclic = cyclic; this.conflicted = conflicted
    }
}

private func dependencyObserved(value: DependencyInstance): Bool {
    !value.identity.isEmpty() && (value.state == "observed" || value.state == "verified")
}

private func dependencyUnknownStandard(value: DependencyInstance): Bool {
    (value.kind == "std" || value.kind == "stdx" || value.kind == "toolchain") &&
        value.state == "unknown" && value.identity.isEmpty()
}

private func dependencyGraphKeyBefore(left: DependencyInstance, right: DependencyInstance): Bool {
    if (left.name == right.name) { left.kind < right.kind } else { left.name < right.name }
}

private func dependencyGraphPart(out: StringBuilder, value: String, work: DependencyNavigationWork): Bool {
    if (!work.consumeBytes(value.size + 24)) { return false }
    out.append(value.size.toString()); out.append(":"); out.append(value)
    true
}

/** Module IDs are index-local pointers, never global cross-project identities. */
internal class DependencyGraphIndex {
    private let rows = HashMap<String, ArrayList<DependencyInstance>>()
    private let contexts = HashMap<String, DependencyGraphContext>()
    private let comparisons = HashMap<String, HashMap<String, String>>()
    private let unavailable = DependencyGraphContext("", false)
    private let sourcePackages: HashMap<String, String>
    private let selfDeclarations = HashMap<String, ?DependencyInstance>()

    init(entries: ArrayList<DependencyInstance>, sourcePackages!: ?HashMap<String, String> = None) {
        this.sourcePackages = sourcePackages.getOrDefault({ => HashMap<String, String>() })
        if (entries.size > 16384) { throw IllegalArgumentException("dependency graph edge budget exceeded") }
        for (entry in entries) {
            if (entry.kind == "source" && entry.componentModuleId == entry.moduleId) {
                selfDeclarations[entry.moduleId] = if (selfDeclarations.contains(entry.moduleId)) { None<DependencyInstance> } else { Some(entry) }
            }
            match (rows.get(entry.moduleId)) {
                case Some(values) => values.add(entry)
                case None => rows[entry.moduleId] = ArrayList<DependencyInstance>([entry])
            }
        }
        if (rows.size > 4096) { throw IllegalArgumentException("dependency graph module budget exceeded") }
        for ((_, values) in rows) {
            sort(values, lessThan: dependencyGraphKeyBefore, stable: true)
            for (index in 1..values.size) {
                if (values[index - 1].name == values[index].name && values[index - 1].kind == values[index].kind) {
                    throw IllegalArgumentException("duplicate module dependency graph edge")
                }
            }
        }
    }
    func sourcePackage(module: String): String { sourcePackages.get(module).getOrDefault({ => "" }) }
    func sourceDeclaration(module: String): ?DependencyInstance {
        selfDeclarations.get(module).getOrDefault({ => None<DependencyInstance> })
    }

    func context(module: String, work: DependencyNavigationWork): DependencyGraphContext {
        if (!work.consumeBytes(module.size) || module.isEmpty()) { return unavailable }
        if (let Some(value) <- contexts.get(module)) { return value }
        derive(module, work, HashSet<String>(), 0)
    }

    private func derive(module: String, work: DependencyNavigationWork, active: HashSet<String>, depth: Int64): DependencyGraphContext {
        if (!work.consumeBytes(module.size)) { return unavailable }
        if (let Some(value) <- contexts.get(module)) { return value }
        if (depth >= 128 || work.exhausted || module.isEmpty()) { return unavailable }
        if (!active.add(module)) { return DependencyGraphContext("", false, cyclic: true) }
        let values = match (rows.get(module)) {
            case Some(value) => value
            case None => let _ = active.remove(module); contexts[module] = unavailable; return unavailable
        }
        let out = StringBuilder()
        out.append("cjdoc.source-context/1")
        var complete = true
        var cyclic = false
        var conflicted = false
        var selfCount: Int64 = 0
        var standard = false
        var extension = false
        var compiler = false
        for (entry in values) {
            if (!work.take()) { complete = false; break }
            if (entry.kind == "std") { standard = true }
            if (entry.kind == "stdx") { extension = true }
            if (entry.kind == "toolchain") { compiler = true }
            conflicted = conflicted || entry.state == "conflict"
            let isSelf = entry.componentModuleId == module
            if (isSelf && entry.kind == "source") { selfCount++ }
            if (!dependencyObserved(entry) && !dependencyUnknownStandard(entry)) { complete = false }
            if (!dependencyGraphPart(out, entry.name, work) || !dependencyGraphPart(out, entry.kind, work) ||
                !dependencyGraphPart(out, entry.identity, work) || !dependencyGraphPart(out, entry.target, work) ||
                !dependencyGraphPart(out, entry.cfg, work) || !dependencyGraphPart(out, entry.version, work) ||
                !dependencyGraphPart(out, entry.revision, work) || !dependencyGraphPart(out,
                    if (dependencyObserved(entry)) { "selected" } else { entry.state }, work)) {
                complete = false; break
            }
            if (isSelf) {
                if (!dependencyGraphPart(out, "self", work)) { complete = false; break }
            } else if (!entry.componentModuleId.isEmpty()) {
                let child = derive(entry.componentModuleId, work, active, depth + 1)
                complete = complete && child.complete
                cyclic = cyclic || child.cyclic
                conflicted = conflicted || child.conflicted
                if (!dependencyGraphPart(out, child.fingerprint, work)) { complete = false; break }
            } else {
                if (entry.kind == "source") { complete = false }
                if (!dependencyGraphPart(out, "no-source-module", work)) { complete = false; break }
            }
        }
        let _ = active.remove(module)
        let result = DependencyGraphContext(if (work.exhausted || cyclic) { "" } else { Sha256Digest.digest(out.toString()) },
            complete && selfCount == 1 && standard && extension && compiler && !cyclic && !conflicted,
            cyclic: cyclic, conflicted: conflicted)
        contexts[module] = result
        result
    }

    func binding(actual: DependencyGraphIndex, actualModule: String, publishedModule: String,
        work: DependencyNavigationWork, depth!: Int64 = 0): String {
        if (actualModule.isEmpty() || publishedModule.isEmpty() || depth >= 128 || work.exhausted) { return "unavailable" }
        let leftContext = actual.context(actualModule, work)
        let rightContext = context(publishedModule, work)
        if (leftContext.conflicted || rightContext.conflicted) { return "conflict" }
        if (leftContext.fingerprint.isEmpty() || rightContext.fingerprint.isEmpty() || leftContext.cyclic || rightContext.cyclic) {
            return "unavailable"
        }
        if (leftContext.fingerprint == rightContext.fingerprint) {
            return if (leftContext.complete && rightContext.complete) { "matched" } else { "unavailable" }
        }
        if (let Some(byPublished) <- comparisons.get(leftContext.fingerprint)) {
            if (let Some(result) <- byPublished.get(rightContext.fingerprint)) { return result }
        }
        let left = match (actual.rows.get(actualModule)) { case Some(value) => value; case None => return "unavailable" }
        let right = match (rows.get(publishedModule)) { case Some(value) => value; case None => return "unavailable" }
        var result = "matched"
        var a: Int64 = 0
        var b: Int64 = 0
        while (a < left.size && b < right.size) {
            if (!work.take()) { result = "unavailable"; break }
            let selected = left[a]
            let published = right[b]
            if (selected.name != published.name || selected.kind != published.kind) {
                let extra = if (dependencyGraphKeyBefore(selected, published)) { a++; selected } else { b++; published }
                if (dependencyObserved(extra)) { result = "mismatch"; break }
                result = "unavailable"
                continue
            }
            a++; b++
            if (dependencyObserved(selected) && dependencyObserved(published)) {
                if (selected.identity != published.identity || selected.target != published.target || selected.cfg != published.cfg ||
                    (!selected.version.isEmpty() && !published.version.isEmpty() && selected.version != published.version) ||
                    (!selected.revision.isEmpty() && !published.revision.isEmpty() && selected.revision != published.revision)) {
                    result = "mismatch"; break
                }
                if (selected.version != published.version || selected.revision != published.revision) { result = "unavailable" }
            } else if (!(dependencyUnknownStandard(selected) && dependencyUnknownStandard(published) &&
                selected.target == published.target && selected.cfg == published.cfg && selected.version == published.version &&
                selected.revision == published.revision)) { result = "unavailable" }
            let ownSelected = selected.componentModuleId == actualModule
            let ownPublished = published.componentModuleId == publishedModule
            if (ownSelected && ownPublished) { continue }
            if (!selected.componentModuleId.isEmpty() && !published.componentModuleId.isEmpty()) {
                let child = binding(actual, selected.componentModuleId, published.componentModuleId, work, depth: depth + 1)
                if (child == "mismatch" || child == "conflict") { result = child; break }
                if (child != "matched") { result = "unavailable" }
            } else if (selected.componentModuleId != published.componentModuleId || selected.kind == "source") {
                result = "unavailable"
            }
        }
        if (result != "mismatch" && result != "conflict") {
            while (a < left.size) { if (dependencyObserved(left[a])) { result = "mismatch"; break }; a++; result = "unavailable" }
            while (b < right.size) { if (dependencyObserved(right[b])) { result = "mismatch"; break }; b++; result = "unavailable" }
        }
        if (!leftContext.complete || !rightContext.complete) { if (result == "matched") { result = "unavailable" } }
        match (comparisons.get(leftContext.fingerprint)) {
            case Some(values) => values[rightContext.fingerprint] = result
            case None => comparisons[leftContext.fingerprint] = HashMap<String, String>([(rightContext.fingerprint, result)])
        }
        result
    }
}

internal func dependencyScopedInstance(value: DependencyInstance, context: String, work: DependencyNavigationWork): String {
    let out = StringBuilder()
    out.append("cjdoc.dependency-instance/1")
    if (!dependencyGraphPart(out, value.moduleId, work) || !dependencyGraphPart(out, value.name, work) ||
        !dependencyGraphPart(out, value.kind, work) || !dependencyGraphPart(out, value.identity, work) ||
        !dependencyGraphPart(out, value.target, work) || !dependencyGraphPart(out, value.cfg, work) ||
        !dependencyGraphPart(out, context, work)) { return "" }
    "cjdoc:dependency:v1:" + Sha256Digest.digest(out.toString())
}
