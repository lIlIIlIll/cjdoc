protected package cjdoc.documentation

import cjdoc.filesystem.readTextBounded
import cjdoc.model as public_model
import std.collection.*
import std.convert.Parsable
import std.fs.*

internal let QUALITY_CONFIG_MAX_BYTES: Int64 = 64 * 1024

protected class DocumentationCoverageThresholds {
    protected var symbols: ?Int64 = None
    protected var parameters: ?Int64 = None
    protected var returns: ?Int64 = None
    protected var throwsDocs: ?Int64 = None
    protected var examples: ?Int64 = None
    protected var deprecated: ?Int64 = None
    protected var semanticLinks: ?Int64 = None

    func set(key: String, value: Int64): Unit {
        if (value < 0 || value > 100) {
            throw IllegalArgumentException("coverage thresholds must be in 0..100")
        }
        match (key) {
            case "symbol" | "symbols" => symbols = Some(value)
            case "parameter" | "parameters" => parameters = Some(value)
            case "return" | "returns" => returns = Some(value)
            case "throws" | "throws-docs" => throwsDocs = Some(value)
            case "example" | "examples" => examples = Some(value)
            case "deprecated" => deprecated = Some(value)
            case "semantic-link" | "semantic-links" => semanticLinks = Some(value)
            case _ => throw IllegalArgumentException("unknown [coverage] setting '${key}'")
        }
    }

    protected func value(key: String): ?Int64 {
        match (key) {
            case "symbols" => symbols
            case "parameters" => parameters
            case "returns" => returns
            case "throws" => throwsDocs
            case "examples" => examples
            case "deprecated" => deprecated
            case "semantic-links" => semanticLinks
            case _ => None
        }
    }
}

protected class DocumentationCoveragePackageOverride {
    protected let packageName: String
    let thresholds: DocumentationCoverageThresholds

    init(packageName: String) {
        if (packageName.isEmpty() || packageName.contains(" ") || packageName.contains("\t")) {
            throw IllegalArgumentException("coverage package override requires a safe package name")
        }
        this.packageName = packageName
        this.thresholds = DocumentationCoverageThresholds()
    }
}

internal class DocumentationRuleSeverity {
    let rule: String
    let severityValue: String

    init(rule: String, severity: String) {
        this.rule = rule
        this.severityValue = severity
    }
}

protected class DocumentationQualityConfig {
    var defaultSeverity: String = "warning"
    private let ruleSeverities = ArrayList<DocumentationRuleSeverity>()
    protected let coverage = DocumentationCoverageThresholds()
    protected let packageOverrides = ArrayList<DocumentationCoveragePackageOverride>()
    protected let translationThresholds = HashMap<String, Int64>()

    protected func severity(rule: String): String {
        for (entry in ruleSeverities) {
            if (entry.rule == rule) { return entry.severityValue }
        }
        defaultSeverity
    }

    protected func ruleSeverity(rule: String): ?String {
        for (entry in ruleSeverities) {
            if (entry.rule == rule) { return Some(entry.severityValue) }
        }
        None
    }

    protected func packageThreshold(packageName: String, metric: String): ?Int64 {
        for (override in packageOverrides) {
            if (override.packageName == packageName) {
                let value = override.thresholds.value(metric)
                if (value.isSome()) { return value }
            }
        }
        coverage.value(metric)
    }

    func setRuleSeverity(rule: String, value: String): Unit {
        if (value != "off" && value != "warning" && value != "error") {
            throw IllegalArgumentException("lint severity must be off, warning, or error")
        }
        for (entry in ruleSeverities) {
            if (entry.rule == rule) {
                throw IllegalArgumentException("duplicate [lint] rule '${rule}'")
            }
        }
        ruleSeverities.add(DocumentationRuleSeverity(rule, value))
    }
}

private func qualityInteger(value: String, key: String): Int64 {
    let text = qualityTomlValue(value)
    try { Int64.parse(text) } catch (_: Exception) {
        throw IllegalArgumentException("[coverage].${key} must be an integer")
    }
}

private func isQualityRule(key: String): Bool {
    key == "missing-summary" || key == "missing-symbol-doc" || key == "missing-param" ||
        key == "missing-return" || key == "missing-throws" || key == "missing-example" ||
        key == "empty-description" || key == "broken-link" || key == "ambiguous-link" ||
        key == "unresolved-type-link" || key == "invalid-since-version" ||
        key == "deprecated-without-message" || key == "duplicate-param" ||
        key == "duplicate-return" || key == "duplicate-throws" ||
        key == "example-not-compiling" || key == "trivial-summary" ||
        key == "trivial-param-description" || key == "trivial-return-description"
}

private func qualitySectionName(line: String): String {
    line.removePrefix("[").removeSuffix("]").trimAscii()
}

protected func loadDocumentationQualityConfig(projectRoot: String): DocumentationQualityConfig {
    let config = DocumentationQualityConfig()
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return config }
    let text = readTextBounded(path, QUALITY_CONFIG_MAX_BYTES)
    var section = ""
    var packageOverride: ?DocumentationCoveragePackageOverride = None
    let seen = HashSet<String>()
    for (rawLine in text.split("\n")) {
        let line = qualityTomlLine(rawLine)
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            section = qualitySectionName(line)
            if (section == "doctest") {
                throw IllegalArgumentException("[doctest] is no longer supported; use --check-examples and @example {run}")
            }
            packageOverride = if (section.startsWith("coverage.package.")) {
                let normalized = section.removePrefix("coverage.package.")
                var found: ?DocumentationCoveragePackageOverride = None
                for (candidate in config.packageOverrides) {
                    if (candidate.packageName == normalized) { found = Some(candidate) }
                }
                match (found) {
                    case Some(value) => Some(value)
                    case None =>
                        let created = DocumentationCoveragePackageOverride(normalized)
                        config.packageOverrides.add(created)
                        Some(created)
                }
            } else { None }
            continue
        }
        // Other consumers own [docs], [[docs.pages]], and [external-docs.*].
        // Repeated array-table keys there must not enter this parser's duplicate-key scope.
        if (section != "lint" && section != "coverage" && section != "coverage.translation" && packageOverride.isNone()) {
            continue
        }
        let equals = line.indexOf("=")
        if (equals.isNone()) { continue }
        let key = line[..equals.getOrThrow()].trimAscii()
        if (key.isEmpty()) { throw IllegalArgumentException("quality configuration has an empty key") }
        let identity = "${section}:${key}"
        if (!seen.add(identity)) { throw IllegalArgumentException("duplicate quality configuration setting '${identity}'") }
        let rawValue = line[equals.getOrThrow() + 1..]
        if (section == "lint") {
            let value = qualityTomlValue(rawValue)
            if (key == "severity") {
                config.defaultSeverity = value
                if (value != "off" && value != "warning" && value != "error") {
                    throw IllegalArgumentException("lint severity must be off, warning, or error")
                }
            } else if (isQualityRule(key)) {
                config.setRuleSeverity(key, value)
            } else {
                throw IllegalArgumentException("unknown [lint] setting '${key}'")
            }
        } else if (section == "coverage.translation") {
            let language = public_model.documentationLanguage(qualityTomlValue(key))
            let threshold = qualityInteger(rawValue, key)
            if (threshold < 0 || threshold > 100) { throw IllegalArgumentException("translation threshold must be in 0..100") }
            if (config.translationThresholds.contains(language)) { throw IllegalArgumentException("duplicate translation language threshold") }
            config.translationThresholds[language] = threshold
        } else if (section == "coverage") {
            config.coverage.set(key, qualityInteger(rawValue, key))
        } else if (packageOverride.isSome()) {
            packageOverride.getOrThrow().thresholds.set(key, qualityInteger(rawValue, key))
        }
    }
    config
}
