protected package cjdoc.source.cfg

import std.collection.*
import std.sort.sort

protected struct CfgAssignment {
    protected let name: String
    protected let value: String

    protected init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

protected func canonicalCfgValues<T>(values: Array<T>, key: (T) -> (String, String)): ArrayList<T> {
    let sorted = ArrayList<T>(values)
    sort(sorted, lessThan: { left, right =>
        let (leftName, leftValue) = key(left)
        let (rightName, rightValue) = key(right)
        if (leftName == rightName) { leftValue < rightValue } else { leftName < rightName }
    }, stable: true)
    var kept: Int64 = 0
    for (index in 0..sorted.size) {
        let entry = sorted[index]
        if (kept > 0) {
            let (name, value) = key(entry)
            let (previousName, previousValue) = key(sorted[kept - 1])
            if (name == previousName) {
                if (value != previousValue) {
                    throw IllegalArgumentException("conflicting cfg values for '${name}'")
                }
                continue
            }
        }
        sorted[kept] = entry
        kept++
    }
    while (sorted.size > kept) { sorted.remove(at: sorted.size - 1) }
    sorted
}

// cjc treats these selectors as built-in conditions. They select the target at
// compiler invocation time and cannot be repeated as user --cfg arguments.
// Keep the values in one place so source selection and example compilation
// agree on the target that is actually being built.
@When[os == "Linux"]
private func compilerTargetOs(): String { "Linux" }

@When[os == "Windows"]
private func compilerTargetOs(): String { "Windows" }

@When[os == "macOS"]
private func compilerTargetOs(): String { "macOS" }

@When[os == "iOS"]
private func compilerTargetOs(): String { "iOS" }

@When[arch == "x86_64"]
private func compilerTargetArch(): String { "x86_64" }

@When[arch == "aarch64"]
private func compilerTargetArch(): String { "aarch64" }

@When[arch == "arm"]
private func compilerTargetArch(): String { "arm" }

// Documented values the compiler target accepts for a built-in selector. Only
// used to make an omitted `--cfg` self-explanatory; documentation generation
// still never substitutes a host value for an absent user selection.
protected func compilerBuiltinCfgChoices(name: String): ?Array<String> {
    if (name == "os") { return Some(["Linux", "Windows", "macOS", "iOS"]) }
    if (name == "arch") { return Some(["x86_64", "aarch64", "arm"]) }
    if (name == "debug") { return Some(["true", "false"]) }
    None
}

protected func compilerBuiltinCfgAssignment(name: String): ?String {
    if (name == "os") { return Some(compilerTargetOs()) }
    if (name == "arch") { return Some(compilerTargetArch()) }
    // Neither CHIR workers nor allowlisted examples invoke cjc with -g.
    if (name == "debug") { return Some("false") }
    None
}

internal func compilerCfgProfile(profile: CfgProfile): CfgProfile {
    let values = ArrayList<CfgAssignment>()
    values.add(all: profile.values.toArray())
    for (name in ["os", "arch", "debug"]) {
        if (profile.value(name).isNone()) {
            match (compilerBuiltinCfgAssignment(name)) {
                case Some(value) => values.add(CfgAssignment(name, value))
                case None => ()
            }
        }
    }
    CfgProfile(values: values.toArray())
}

// A validated built-in selector must not be forwarded as a user cfg argument.
protected func validateCompilerBuiltinCfg(cfg: CfgAssignment): Bool {
    match (compilerBuiltinCfgAssignment(cfg.name)) {
        case Some(actual) =>
            if (cfg.value != actual) {
                throw IllegalArgumentException("cfg '" + cfg.name + "=" + cfg.value +
                    "' does not match compiler target '" + cfg.name + "=" + actual + "'")
            }
            true
        case None => false
    }
}

// Append only user-defined values; validate built-ins against the native target.
protected func appendCompilerCfgArguments(arguments: ArrayList<String>,
    profile: CfgProfile): Unit {
    for (cfg in profile.values) {
        if (validateCompilerBuiltinCfg(cfg)) { continue }
        arguments.add("--cfg")
        arguments.add(cfg.name + "=" + cfg.value)
    }
}

protected class CfgProfile {
    protected let values: ArrayList<CfgAssignment>

    protected init(values!: Array<CfgAssignment> = []) {
        this.values = canonicalCfgValues(values, { entry: CfgAssignment => (entry.name, entry.value) })
    }

    protected func value(name: String): ?String {
        for (entry in values) {
            if (entry.name == name) { return Some(entry.value) }
        }
        None
    }
}
