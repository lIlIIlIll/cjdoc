protected package cjdoc.render.search

import std.collection.*

/**
 * ASCII-only case folding.
 *
 * Only `A`–`Z` become `a`–`z`. Every other code point, including non-ASCII
 * letters, is preserved, so no locale or compatibility rule can change which
 * declarations a query reaches in a browser and in a CLI.
 */
protected func searchAsciiFold(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (code >= 0x41u32 && code <= 0x5Au32) { out.append(Rune(code + 0x20u32)) }
        else { out.append(rune) }
    }
    out.toString()
}

/**
 * Split free text into searchable tokens.
 *
 * ASCII letters, digits, `_` and every code point at or above U+0080 stay in one
 * token; every other code point separates. Chinese, accented and non-BMP text
 * therefore search as written while punctuation still splits.
 */
protected func searchTokens(value: String): Array<String> {
    let tokens = ArrayList<String>()
    var current = StringBuilder()
    var pending = false
    for (rune in value.runes()) {
        let code = UInt32(rune)
        let wordByte = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) || (code >= 0x61u32 && code <= 0x7Au32) ||
            code == 0x5Fu32
        if (wordByte || code >= 0x80u32) {
            current.append(rune)
            pending = true
        } else if (pending) {
            tokens.add(searchAsciiFold(current.toString()))
            current = StringBuilder()
            pending = false
        }
    }
    if (pending) { tokens.add(searchAsciiFold(current.toString())) }
    tokens.toArray()
}

protected func searchRuneCount(value: String): Int64 {
    var count: Int64 = 0
    for (_ in value.runes()) { count++ }
    count
}

protected func searchRunes(value: String): Array<Rune> {
    let result = ArrayList<Rune>()
    for (rune in value.runes()) { result.add(rune) }
    result.toArray()
}

/**
 * Split an identifier at ASCII case boundaries only.
 *
 * `readJSONFile` becomes read / JSON / File: an acronym keeps its trailing
 * capital with the following word. Non-ASCII code points never split a word.
 */
protected func searchWordParts(value: String): Array<String> {
    let codePoints = ArrayList<UInt32>()
    let upperMatches = ArrayList<Bool>()
    let lowerMatches = ArrayList<Bool>()
    for (rune in value.runes()) {
        let code = UInt32(rune)
        codePoints.add(code)
        upperMatches.add(code >= 0x41u32 && code <= 0x5Au32)
        lowerMatches.add(code >= 0x61u32 && code <= 0x7Au32)
    }
    let words = ArrayList<String>()
    var current = StringBuilder()
    var started = false
    for (index in 0..codePoints.size) {
        let code = codePoints[index]
        let wordByte = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) || (code >= 0x61u32 && code <= 0x7Au32) ||
            code == 0x5Fu32 || code >= 0x80u32
        if (!wordByte) {
            if (started) { words.add(searchAsciiFold(current.toString())) }
            current = StringBuilder()
            started = false
            continue
        }
        if (started && upperMatches[index]) {
            let previousLower = index > 0 && lowerMatches[index - 1]
            let previousUpper = index > 0 && upperMatches[index - 1]
            let nextLower = index + 1 < codePoints.size && lowerMatches[index + 1]
            if (previousLower || (previousUpper && nextLower)) {
                words.add(searchAsciiFold(current.toString()))
                current = StringBuilder()
            }
        }
        current.append(Rune(code))
        started = true
    }
    if (started) { words.add(searchAsciiFold(current.toString())) }
    words.toArray()
}

protected func searchAcronym(words: Array<String>): String {
    let out = StringBuilder()
    for (word in words) {
        for (rune in word.runes()) { out.append(rune); break }
    }
    out.toString()
}

protected func searchOneEditApartRunes(left: Array<Rune>, right: Array<Rune>): Bool {
    let leftSize = left.size
    let rightSize = right.size
    let difference = if (leftSize > rightSize) { leftSize - rightSize } else { rightSize - leftSize }
    if (difference > 1) { return false }
    var leftIndex = 0
    var rightIndex = 0
    var edits: Int64 = 0
    while (leftIndex < leftSize && rightIndex < rightSize) {
        if (left[leftIndex] == right[rightIndex]) {
            leftIndex++
            rightIndex++
            continue
        }
        edits++
        if (edits > 1) { return false }
        if (leftSize == rightSize) {
            leftIndex++
            rightIndex++
        } else if (leftSize > rightSize) {
            leftIndex++
        } else {
            rightIndex++
        }
    }
    if (leftIndex < leftSize || rightIndex < rightSize) { edits++ }
    edits == 1
}

protected func searchContainsAll(haystack: String, tokens: Array<String>): Bool {
    if (tokens.isEmpty()) { return false }
    for (token in tokens) {
        if (!haystack.contains(token)) { return false }
    }
    true
}

protected func searchUtf8ByteLess(left: String, right: String): Bool {
    let common = if (left.size < right.size) { left.size } else { right.size }
    var index: Int64 = 0
    while (index < common) {
        if (left[index] != right[index]) { return left[index] < right[index] }
        index++
    }
    left.size < right.size
}
protected func searchIdentityKey(snapshotId: String, canonicalId: String): String {
    snapshotId + "\u{0}" + canonicalId
}
