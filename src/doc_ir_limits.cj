package cjdoc

import std.convert.Parsable
import std.fs.*

internal func docIrLimitBytes(mebibytes: Int64): Int64 {
    if (mebibytes < 1 || mebibytes > 64) {
        throw IllegalArgumentException("max-doc-ir-mib must be in 1..64")
    }
    mebibytes * 1024 * 1024
}

// Decode only the first key component: a quoted dot belongs to the name.
private func docIrLimitsKeyRoot(rawKey: String): (String, Bool) {
    let key = rawKey.trimAscii()
    if (key.startsWith("\"") || key.startsWith("'")) {
        let decoded = decodeTomlString(key, 0)
        if (decoded.invalid) { return ("", false) }
        return (decoded.value.getOrDefault({ => "" }), key[decoded.nextOffset..].trimAscii().isEmpty())
    }
    let parts = key.split(".", 2)
    (parts[0].trimAscii(), parts.size == 1)
}

private func docIrLimitsSection(header: String): String {
    let arrayTable = header.startsWith("[[") && header.endsWith("]]")
    let section = if (arrayTable) { header[2..header.size - 2].trimAscii() }
        else { header[1..header.size - 1].trimAscii() }
    let (name, singleKey) = docIrLimitsKeyRoot(section)
    if (name == "limits") {
        if (arrayTable || !singleKey) {
            throw IllegalArgumentException("[limits] must be a single table without subtables")
        }
        return "limits"
    }
    section
}

// Match the single-line settings used by the existing project config readers.
// Other tables belong to their respective consumers.
internal func loadDocIrLimit(projectRoot: String, overrideMiB: ?Int64): Int64 {
    let path = Path(projectRoot).join("cjdoc.toml")
    var configured: ?Int64 = None
    if (exists(path)) {
        let text = readTextBounded(path, 64 * 1024)
        var section = ""
        for (rawLine in text.split("\n")) {
            let comment = rawLine.indexOf("#")
            let line = match (comment) {
                case Some(offset) => rawLine[..offset].trimAscii()
                case None => rawLine.trimAscii()
            }
            if (line.isEmpty()) { continue }
            if (line.startsWith("[") && line.endsWith("]")) {
                section = docIrLimitsSection(line)
                continue
            }
            let parts = line.split("=", 2)
            if (section.isEmpty() && docIrLimitsKeyRoot(parts[0])[0] == "limits") {
                throw IllegalArgumentException("configure Doc IR limits with [limits]; dotted keys and inline tables are unsupported")
            }
            if (section != "limits") { continue }
            if (parts.size != 2 || parts[0].trimAscii() != "max-doc-ir-mib") {
                throw IllegalArgumentException("unknown or malformed [limits] setting")
            }
            if (configured.isSome()) {
                throw IllegalArgumentException("duplicate [limits].max-doc-ir-mib")
            }
            let value = parts[1].trimAscii()
            if (value.isEmpty()) {
                throw IllegalArgumentException("[limits].max-doc-ir-mib requires an integer")
            }
            for (byte in value.toArray()) {
                if (byte < b'0' || byte > b'9') {
                    throw IllegalArgumentException("[limits].max-doc-ir-mib requires an integer")
                }
            }
            let mebibytes = try { Int64.parse(value) } catch (_: Exception) {
                throw IllegalArgumentException("[limits].max-doc-ir-mib must be in 1..64")
            }
            let _ = docIrLimitBytes(mebibytes)
            configured = Some(mebibytes)
        }
    }
    let configuredMiB = configured.getOrDefault({ => 64 })
    docIrLimitBytes(overrideMiB.getOrDefault({ => configuredMiB }))
}
