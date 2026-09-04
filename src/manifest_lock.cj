package cjdoc

import std.collection.*
import std.sort.*

func parseCjpmLock(lockText: String,
    maxEntries!: Int64 = MAX_MANIFEST_ADAPTER_ENTRIES,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmLockView {
    if (maxEntries < 0) { throw IllegalArgumentException("lock entry limit must be non-negative") }
    let dependencies = ArrayList<CjpmLockedDependency>()
    let scanner = TomlLineScanner()
    var inRequires = false
    var entry = StringBuilder()
    var entryStarted = false
    var braceDepth: Int64 = 0
    var entryCount: Int64 = 0
    var limitReached = false
    var invalid = false
    let budget = TomlParseBudget(lockText, maxBytes, maxWork)
    let lines = TomlLineCursor(lockText, budget)
    while (true) {
        let line = match (lines.next()) {
            case Some(value) => value
            case None => break
        }
        let code = match (scanner.code(line)) {
            case Some(value) => value
            case None => continue
        }
        let trimmed = code.trimAscii()
        if (braceDepth == 0 && trimmed.startsWith("[")) {
            inRequires = trimmed == "[requires]"
            continue
        }
        if (!inRequires || (braceDepth == 0 && trimmed.isEmpty())) {
            continue
        }
        if (braceDepth == 0) {
            if (entryCount >= maxEntries) { limitReached = true; break }
            entryCount++
            entry = StringBuilder()
            entryStarted = false
        }
        if (entryStarted) { entry.append("\n") }
        entry.append(code)
        entryStarted = true
        braceDepth += tomlBraceDelta(code)
        if (braceDepth < 0) {
            invalid = true
            break
        }
        if (braceDepth == 0) {
            if (!addLockedDependency(entry.toString(), dependencies)) {
                invalid = true
                break
            }
            entry = StringBuilder()
            entryStarted = false
        }
    }
    if ((entryStarted || braceDepth != 0) && !budget.limitReached) { invalid = true }
    sort(dependencies, lessThan: { left, right => left.name < right.name }, stable: true)
    CjpmLockView(dependencies, entryCount, limitReached || budget.limitReached,
        invalid: invalid)
}
