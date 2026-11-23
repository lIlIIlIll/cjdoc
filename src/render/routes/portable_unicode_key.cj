protected package cjdoc.render.routes

import std.collection.*
import std.sort.*

// The file spelling stays unchanged. Decompose only the comparison key, including
// authored filenames, which need not contain only Cangjie identifier characters.
protected func portableCanonicalUnicode(value: String): String {
    let key = PortableCanonicalKey(value.size)
    for (rune in value.runes()) { key.append(UInt32(rune)) }
    key.finish()
}

private class PortableCanonicalKey {
    private let out: StringBuilder
    private let marks = ArrayList<(UInt32, UInt32, Int64)>()
    private var needsSort = false

    init(capacity: Int64) { out = StringBuilder(capacity) }

    func append(code: UInt32): Unit {
        // Hangul syllable decomposition is algorithmic (Unicode §3.12).
        if (code >= 0xAC00 && code < 0xD7A4) {
            let syllable = code - 0xAC00
            appendScalar(0x1100 + syllable / 588)
            appendScalar(0x1161 + syllable % 588 / 28)
            let trail = syllable % 28
            if (trail != 0) { appendScalar(0x11A7 + trail) }
            return
        }
        let record = unicodeKeyRecord(PORTABLE_UNICODE_DECOMPOSITIONS, 30, code)
        if (record < 0) {
            appendScalar(code)
            return
        }
        for (field in 1..5) {
            let part = unicodeKeyField(PORTABLE_UNICODE_DECOMPOSITIONS, record + field * 6)
            if (part == 0) { break }
            appendScalar(part)
        }
    }

    private func appendScalar(code: UInt32): Unit {
        let record = unicodeKeyRecord(PORTABLE_UNICODE_COMBINING_CLASSES, 12, code)
        if (record < 0) {
            flushMarks()
            out.append(Rune(code))
            return
        }
        let rank = unicodeKeyField(PORTABLE_UNICODE_COMBINING_CLASSES, record + 6)
        if (!marks.isEmpty() && marks[marks.size - 1][0] > rank) { needsSort = true }
        marks.add((rank, code, marks.size))
    }

    private func flushMarks(): Unit {
        if (needsSort) {
            sort(marks, lessThan: { a, b => a[0] < b[0] || (a[0] == b[0] && a[2] < b[2]) })
        }
        for ((_, code, _) in marks) { out.append(Rune(code)) }
        marks.clear()
        needsSort = false
    }

    func finish(): String {
        flushMarks()
        out.toString()
    }
}

private func unicodeKeyField(table: String, start: Int64): UInt32 {
    var value: UInt32 = 0
    for (i in start..start + 6) {
        let digit = table[i]
        value = (value << 4) + UInt32(if (digit <= b'9') { digit - b'0' } else { digit - b'a' + 10 })
    }
    value
}

private func unicodeKeyRecord(table: String, width: Int64, code: UInt32): Int64 {
    if (code < 0x80) { return -1 }
    var low = 0
    var high = table.size / width
    while (low < high) {
        let middle = low + (high - low) / 2
        let offset = middle * width
        let candidate = unicodeKeyField(table, offset)
        if (candidate == code) { return offset }
        if (candidate < code) { low = middle + 1 } else { high = middle }
    }
    -1
}
