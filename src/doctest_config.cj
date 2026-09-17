package cjdoc

import std.collection.*
import std.convert.Parsable
import std.fs.*
internal let DOCTEST_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let DOCTEST_DEFAULT_TIMEOUT_MS: Int64 = 2000
internal let DOCTEST_DEFAULT_MEMORY_MB: Int64 = 256
internal let DOCTEST_DEFAULT_JOBS: Int64 = 1

internal class DoctestConfig {
    public let mode: String
    public let timeoutMs: Int64
    public let memoryMb: Int64
    public let jobs: Int64

    init(mode!: String = "off", timeoutMs!: Int64 = DOCTEST_DEFAULT_TIMEOUT_MS,
        memoryMb!: Int64 = DOCTEST_DEFAULT_MEMORY_MB, jobs!: Int64 = DOCTEST_DEFAULT_JOBS) {
        if (mode != "off" && mode != "warn" && mode != "deny") {
            throw IllegalArgumentException("[doctest].mode must be off, warn, or deny")
        }
        if (timeoutMs < 1 || timeoutMs > 600000) {
            throw IllegalArgumentException("[doctest].timeout-ms must be in 1..600000")
        }
        if (memoryMb < 16 || memoryMb > 16384) {
            throw IllegalArgumentException("[doctest].memory-mb must be in 16..16384")
        }
        if (jobs < 1 || jobs > 64) {
            throw IllegalArgumentException("[doctest].jobs must be in 1..64")
        }
        this.mode = mode
        this.timeoutMs = timeoutMs
        this.memoryMb = memoryMb
        this.jobs = jobs
    }
}

private func stripTomlComment(value: String): String {
    var quoted = false
    var escaped = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (byte == b'"' && !escaped) {
            quoted = !quoted
        } else if (byte == b'\\' && quoted) {
            escaped = !escaped
            index++
            continue
        } else if (byte == b'#' && !quoted) {
            return value[..index].trimAscii()
        }
        escaped = false
        index++
    }
    value.trimAscii()
}

private func tomlValue(value: String, key: String): String {
    let cleaned = stripTomlComment(value)
    if (cleaned.isEmpty()) { throw IllegalArgumentException("[doctest].${key} requires a value") }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        cleaned.removePrefix("\"").removeSuffix("\"")
    } else {
        cleaned
    }
}

private func tomlInteger(value: String, key: String): Int64 {
    try { Int64.parse(tomlValue(value, key)) } catch (_: Exception) {
        throw IllegalArgumentException("[doctest].${key} must be an integer")
    }
}

internal func loadDoctestConfig(projectRoot: String): DoctestConfig {
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return DoctestConfig() }
    let text = readTextBounded(path, DOCTEST_CONFIG_MAX_BYTES)
    var section = ""
    var mode = "off"
    var timeoutMs = DOCTEST_DEFAULT_TIMEOUT_MS
    var memoryMb = DOCTEST_DEFAULT_MEMORY_MB
    var jobs = DOCTEST_DEFAULT_JOBS
    let seen = HashSet<String>()
    for (rawLine in text.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            section = line.removePrefix("[").removeSuffix("]").trimAscii()
            continue
        }
        if (section != "doctest") { continue }
        let parts = line.split("=", 2)
        if (parts.size != 2) {
            throw IllegalArgumentException("invalid [doctest] setting")
        }
        let key = parts[0].trimAscii()
        if (key.isEmpty() || seen.contains(key)) {
            throw IllegalArgumentException("duplicate or empty [doctest] setting")
        }
        let _ = seen.add(key)
        match (key) {
            case "mode" => mode = tomlValue(parts[1], key)
            case "timeout-ms" => timeoutMs = tomlInteger(parts[1], key)
            case "memory-mb" => memoryMb = tomlInteger(parts[1], key)
            case "jobs" => jobs = tomlInteger(parts[1], key)
            case _ => throw IllegalArgumentException("unknown [doctest] setting '${key}'")
        }
    }
    DoctestConfig(mode: mode, timeoutMs: timeoutMs, memoryMb: memoryMb, jobs: jobs)
}
