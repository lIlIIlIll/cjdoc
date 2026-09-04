package cjdoc

import std.ast.*
import std.collection.*

internal func packageNameFrom(program: Program, fallback: String): String {
    var value = program.packageHeader.toTokens().toString().trimAscii()
    if (value.isEmpty()) { return fallback }
    if (value.startsWith("macro package ")) { value = value.removePrefix("macro package ") }
    if (value.startsWith("package ")) { value = value.removePrefix("package ") }
    return value.trimAscii()
}

internal func sourceAggregationKey(left: String, right: String): String {
    "${left.size}:${left}${right}"
}

internal class SourceAggregationIndex {
    private let packages = HashMap<String, SourcePackage>()
    private let modulePackages = HashSet<String>()
    private let packageFiles = HashSet<String>()

    func add(source: SourceSnapshot, input: SourceInputFile, packageName: String): Unit {
        let packageKey = sourceAggregationKey(input.module.id, packageName)
        if (modulePackages.add(packageKey)) { input.module.packageNames.add(packageName) }
        let pkg = match (packages.get(packageKey)) {
            case Some(value) => value
            case None =>
                let value = SourcePackage(packageName, input.module.id)
                packages[packageKey] = value
                source.packages.add(value)
                value
        }
        if (packageFiles.add(sourceAggregationKey(packageKey, input.logicalPath))) {
            pkg.sourceFiles.add(input.logicalPath)
        }
    }
}

internal func hasFatalSourceDiagnostics(source: SourceSnapshot): Bool {
    for (diagnostic in source.diagnostics) {
        if (diagnostic.severity == "error" && diagnostic.code != "CJDOC1011" &&
            diagnostic.code != "CJDOC1012" && diagnostic.code != "CJDOC1020" &&
            diagnostic.code != "CJDOC1028") { return true }
    }
    return false
}

internal func addSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>, message: String): Unit {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return }
    }
    diagnostics.add(Diagnostic("error", "CJDOC1028", message))
}

internal func hasSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return true }
    }
    false
}

// The cache codec is deliberately length-prefixed instead of line based: source
// spellings and documentation may contain arbitrary newlines and Unicode. Every
// entry also carries its SHA-256 content-bound cache key, so a filename-hash
// collision is a safe miss rather than stale documentation.
