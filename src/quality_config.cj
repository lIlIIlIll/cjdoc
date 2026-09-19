package cjdoc

import std.collection.*
import std.convert.Parsable
import std.fs.*

internal let QUALITY_CONFIG_MAX_BYTES: Int64 = 64 * 1024

internal class DocumentationCoverageThresholds {
    public var symbols: ?Int64 = None
    public var parameters: ?Int64 = None
    public var returns: ?Int64 = None
    public var throwsDocs: ?Int64 = None
    public var examples: ?Int64 = None
    public var deprecated: ?Int64 = None
    public var semanticLinks: ?Int64 = None

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

    func value(key: String): ?Int64 {
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

internal class DocumentationCoveragePackageOverride {
    public let packageName: String
    public let thresholds: DocumentationCoverageThresholds

    init(packageName: String) {
        if (packageName.isEmpty() || packageName.contains(" ") || packageName.contains("\t")) {
            throw IllegalArgumentException("coverage package override requires a safe package name")
        }
        this.packageName = packageName
        this.thresholds = DocumentationCoverageThresholds()
    }
}

internal class DocumentationRuleSeverity {
    public let rule: String
    public let severityValue: String

    init(rule: String, severity: String) {
        this.rule = rule
        this.severityValue = severity
    }
}

internal class DocumentationQualityConfig {
    public var defaultSeverity: String = "warning"
    public let ruleSeverities = ArrayList<DocumentationRuleSeverity>()
    public let coverage = DocumentationCoverageThresholds()
    public let packageOverrides = ArrayList<DocumentationCoveragePackageOverride>()

    func severity(rule: String): String {
        for (entry in ruleSeverities) {
            if (entry.rule == rule) { return entry.severityValue }
        }
        defaultSeverity
    }

    func ruleSeverity(rule: String): ?String {
        for (entry in ruleSeverities) {
            if (entry.rule == rule) { return Some(entry.severityValue) }
        }
        None
    }

    func packageThreshold(packageName: String, metric: String): ?Int64 {
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

private func qualityTomlValue(value: String): String {
    var cleaned = value.trimAscii()
    var quoted = false
    var escaped = false
    var index: Int64 = 0
    while (index < cleaned.size) {
        let byte = cleaned[index]
        if (byte == b'"' && !escaped) { quoted = !quoted }
        if (byte == b'\\' && quoted) {
            escaped = !escaped
            index++
            continue
        }
        if (byte == b'#' && !quoted) {
            cleaned = cleaned[..index].trimAscii()
            break
        }
        escaped = false
        index++
    }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        return cleaned.removePrefix("\"").removeSuffix("\"")
    }
    cleaned
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
        key == "example-not-compiling"
}

private func qualitySectionName(line: String): String {
    line.removePrefix("[").removeSuffix("]").trimAscii()
}

internal func loadDocumentationQualityConfig(projectRoot: String): DocumentationQualityConfig {
    let config = DocumentationQualityConfig()
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return config }
    let text = readTextBounded(path, QUALITY_CONFIG_MAX_BYTES)
    var section = ""
    var packageOverride: ?DocumentationCoveragePackageOverride = None
    let seen = HashSet<String>()
    for (rawLine in text.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            section = qualitySectionName(line)
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
        } else if (section == "coverage") {
            config.coverage.set(key, qualityInteger(rawValue, key))
        } else if (packageOverride.isSome()) {
            packageOverride.getOrThrow().thresholds.set(key, qualityInteger(rawValue, key))
        }
    }
    config
}
