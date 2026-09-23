package cjdoc

import std.collection.*

// The parsed form of an `@example {…}` directive block. Each field maps onto one
// gate behaviour; `problems` holds every grammar violation found, so a single
// parse produces one actionable CJDOC3033 instead of stopping at the first slip.
internal class ExampleDirectives {
    internal var expectsFailure = false
    internal var execute = false
    internal var failureContains: ?String = None
    internal let flags = ArrayList<String>()
    internal let problems = ArrayList<String>()
}

private func isDirectiveName(name: String): Bool {
    name == "must-pass" || name == "must-fail" || name == "run" ||
        name == "error" || name == "flags"
}

private func firstEqualsIndex(value: String): Int64 {
    var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == b'=') { return index }
        index++
    }
    -1
}

// Splits on ASCII space/tab outside double quotes. Quote characters stay in the
// returned items so `name="a b"` keeps its shape until value extraction. The
// second result reports a quote left open at the end of the block.
private func splitDirectiveItems(value: String): (Array<String>, Bool) {
    let items = ArrayList<String>()
    var start: Int64 = -1
    var index: Int64 = 0
    var inQuotes = false
    while (index < value.size) {
        let byte = value[index]
        if (byte == b'"') {
            inQuotes = !inQuotes
            if (start < 0) { start = index }
        } else if ((byte == b' ' || byte == b'\t') && !inQuotes) {
            if (start >= 0) {
                items.add(value[start..index])
                start = -1
            }
        } else if (start < 0) { start = index }
        index++
    }
    if (start >= 0) { items.add(value[start..]) }
    (items.toArray(), inQuotes)
}

private func directiveValue(parsed: ExampleDirectives, item: String, raw: String): ?String {
    if (raw.size < 2 || raw[0] != b'"' || raw[raw.size - 1] != b'"') {
        parsed.problems.add("'<${item}>' needs a complete quoted value")
        return None
    }
    let value = raw[1..raw.size - 1]
    if (value.contains("\"")) {
        parsed.problems.add("'<${item}>' contains an embedded quote")
        return None
    }
    Some(value)
}

internal func parseExampleDirectives(block: String): ExampleDirectives {
    let parsed = ExampleDirectives()
    if (block.size < 2 || block[0] != b'{' || block[block.size - 1] != b'}') {
        parsed.problems.add("'${block}' is not a '{…}' directive block")
        return parsed
    }
    let inner = block[1..block.size - 1]
    if (inner.trimAscii().isEmpty()) { parsed.problems.add("the directive block is empty") }
    let (items, unterminated) = splitDirectiveItems(inner)
    if (unterminated) { parsed.problems.add("the directive block has an unterminated \"") }
    let seen = HashSet<String>()
    var hasMustPass = false
    var hasMustFail = false
    var hasError = false
    for (item in items) {
        let equals = firstEqualsIndex(item)
        let name = if (equals < 0) { item } else { item[..equals] }
        if (name.isEmpty()) {
            parsed.problems.add("'<${item}>' has no directive name")
            continue
        }
        if (!isDirectiveName(name)) {
            parsed.problems.add("unknown directive '<${item}>'")
            continue
        }
        if (!seen.add(name)) {
            parsed.problems.add("duplicate directive '<${name}>'")
            continue
        }
        match (name) {
            case "must-pass" =>
                if (equals >= 0) {
                    parsed.problems.add("'must-pass' does not take a value")
                }
                hasMustPass = true
            case "must-fail" =>
                if (equals >= 0) {
                    parsed.problems.add("'must-fail' does not take a value")
                }
                hasMustFail = true
                parsed.expectsFailure = true
            case "run" =>
                if (equals >= 0) {
                    parsed.problems.add("'run' does not take a value")
                }
                parsed.execute = true
            case "error" => if (equals < 0) {
                parsed.problems.add("'error' needs a quoted value")
            } else {
                hasError = true
                match (directiveValue(parsed, item, item[equals + 1..])) {
                    case Some(value) => if (value.isEmpty()) {
                        parsed.problems.add("'error=\"\"' pins an empty message")
                    } else {
                        parsed.failureContains = Some(value)
                    }
                    case None => ()
                }
            }
            case "flags" => if (equals < 0) {
                parsed.problems.add("'flags' needs a quoted value")
            } else {
                match (directiveValue(parsed, item, item[equals + 1..])) {
                    case Some(value) =>
                        let (tokens, tokensUnterminated) = splitDirectiveItems(value)
                        if (tokensUnterminated || tokens.isEmpty()) {
                            parsed.problems.add("'flags=\"${value}\"' holds no compiler option")
                        }
                        parsed.flags.add(all: tokens)
                    case None => ()
                }
            }
            case _ => ()
        }
    }
    if (hasMustPass && hasMustFail) {
        parsed.problems.add("'must-pass' and 'must-fail' conflict")
    }
    if (parsed.execute && hasMustFail) {
        parsed.problems.add("'run' cannot be combined with 'must-fail'")
    }
    if (hasError && !hasMustFail) {
        parsed.problems.add("'error' requires 'must-fail'")
    }
    parsed
}

// `cjc` options an example may add. Output paths, source lists and package/import
// flags stay owned by the fixed argv, so they are not on this list.
private let EXAMPLE_WARNING_GROUPS: Array<String> = [
    "all", "unused", "unused-main", "deprecated", "unsupport-compile-source",
    "package-import", "parser", "semantics", "interpreter", "apilevel-check"]
// `driver-arg` is deliberately absent: suppressing it would hide the file-less
// bad-argument error that the pin attribution rule depends on.
private let EXAMPLE_OVERFLOW_MODES: Array<String> = ["throwing", "wrapping", "saturating"]
private let EXAMPLE_VALUELESS_OPTIONS: Array<String> = [
    "--experimental", "-O0", "-O1", "-O2", "-Os", "-Oz"]

private func isAsciiLetter(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
}

private func isAsciiDigit(byte: Byte): Bool { byte >= b'0' && byte <= b'9' }

private func isUserConditionKey(value: String): Bool {
    if (value.isEmpty()) { return false }
    let first = value[0]
    if (!isAsciiLetter(first) && first != b'_') { return false }
    var index: Int64 = 1
    while (index < value.size) {
        let byte = value[index]
        if (!isAsciiLetter(byte) && !isAsciiDigit(byte) && byte != b'_') { return false }
        index++
    }
    true
}

private func isUserConditionValue(value: String): Bool {
    if (value.isEmpty()) { return false }
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (!isAsciiLetter(byte) && !isAsciiDigit(byte) && byte != b'_' && byte != b'.' &&
            byte != b'+' && byte != b'-') { return false }
        index++
    }
    true
}

// Built-in `--cfg` keys (`os`, `arch`, `debug`, …) are not enumerated here: `cjc`
// rejects them with a driver-level error naming no source file, and the pin
// attribution rule turns that into a visible CJDOC3031/CJDOC3034 instead of a second,
// drifting local list. A user key is accepted on the command line but cannot gate
// `@When[...]`, so `flags=` changes compilation behaviour; it does not switch an
// optional example on and off.
private func isUserCondition(value: String): Bool {
    let equals = firstEqualsIndex(value)
    equals >= 0 && isUserConditionKey(value[..equals]) && isUserConditionValue(value[equals + 1..])
}

internal func validateExampleFlags(flags: Array<String>): (Array<String>, Array<String>) {
    let accepted = ArrayList<String>()
    let problems = ArrayList<String>()
    var index: Int64 = 0
    while (index < flags.size) {
        let token = flags[index]
        if (token == "--cfg" || token == "-Woff" || token == "-Won" || token == "--int-overflow") {
            if (index + 1 >= flags.size) {
                problems.add("compiler option '${token}' requires a value")
                return (accepted.toArray(), problems.toArray())
            }
            let value = flags[index + 1]
            let valid = if (token == "--cfg") {
                isUserCondition(value)
            } else if (token == "--int-overflow") {
                EXAMPLE_OVERFLOW_MODES.contains(value)
            } else {
                EXAMPLE_WARNING_GROUPS.contains(value)
            }
            if (!valid) {
                problems.add("invalid compiler option '${token} ${value}'")
            } else {
                accepted.add(token)
                accepted.add(value)
            }
            index += 2
            continue
        }
        if (EXAMPLE_VALUELESS_OPTIONS.contains(token)) {
            accepted.add(token)
            index++
            continue
        }
        // One mistake, one report: an unrecognised option is shown together with the
        // following value-shaped token instead of splitting into two problems.
        let following = if (index + 1 < flags.size) { flags[index + 1] } else { "" }
        if (token.startsWith("-") && !following.isEmpty() && !following.startsWith("-")) {
            problems.add("invalid compiler option '${token} ${following}'")
            index += 2
            continue
        }
        problems.add("invalid compiler option '${token}'")
        index++
    }
    (accepted.toArray(), problems.toArray())
}
