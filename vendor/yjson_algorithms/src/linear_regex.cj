package yjson_algorithms

import yjson.*

import std.collection.*
import std.unicode.*

private const LINEAR_REGEX_MAX_PATTERN_RUNES: Int64 = 16384
private const LINEAR_REGEX_MAX_STATES: Int64 = 65536
private const LINEAR_REGEX_MAX_REPETITION: Int64 = 10000
private const LINEAR_REGEX_MAX_NESTING: Int64 = 256

class LinearRegexBudget {
    private let limit: Int64
    private let dimension: String
    private var consumed: Int64 = 0

    init(limit: Int64, dimension: String) {
        this.limit = limit
        this.dimension = dimension
    }

    func reset(): Unit { consumed = 0 }

    func step(): Unit {
        consumed++
        enforceWorkLimit(consumed, limit, dimension)
    }
}

private enum LinearRegexNodeKind { Empty | Atom | Sequence | Choice | Repetition }

enum LinearRegexAtomKind {
    Literal | Any | CharacterClass | Begin | End | WordBoundary | NonWordBoundary
}

enum LinearRegexClassTermKind {
    Range | Digit | Word | Whitespace | Letter | Uppercase | Lowercase | Number | Any
}

class LinearRegexClassTerm {
    let kind: LinearRegexClassTermKind
    let lower: Rune
    let upper: Rune
    let negated: Bool

    init(kind: LinearRegexClassTermKind, lower!: Rune = r'\u{0000}',
        upper!: Rune = r'\u{0000}', negated!: Bool = false) {
        this.kind = kind
        this.lower = lower
        this.upper = upper
        this.negated = negated
    }

    func matches(value: Rune): Bool {
        let matched = match (kind) {
            case LinearRegexClassTermKind.Range => value >= lower && value <= upper
            case LinearRegexClassTermKind.Digit => value >= r'0' && value <= r'9'
            case LinearRegexClassTermKind.Word => linearRegexIsWord(value)
            case LinearRegexClassTermKind.Whitespace => value.isWhiteSpace() || value == r'\u{FEFF}'
            case LinearRegexClassTermKind.Letter => value.isLetter()
            case LinearRegexClassTermKind.Uppercase => value.isUpperCase()
            case LinearRegexClassTermKind.Lowercase => value.isLowerCase()
            case LinearRegexClassTermKind.Number => value.isNumber()
            case LinearRegexClassTermKind.Any => true
        }
        if (negated) { !matched } else { matched }
    }
}

class LinearRegexCharacterClass {
    let negated: Bool
    let terms: Array<LinearRegexClassTerm>

    init(negated: Bool, terms: Array<LinearRegexClassTerm>) {
        this.negated = negated
        this.terms = terms
    }

    func matches(value: Rune): Bool {
        var matched = false
        for (term in terms) {
            if (term.matches(value)) { matched = true; break }
        }
        if (negated) { !matched } else { matched }
    }
}

class LinearRegexAtom {
    let kind: LinearRegexAtomKind
    let literal: Rune
    let characterClass: Option<LinearRegexCharacterClass>

    init(kind: LinearRegexAtomKind, literal!: Rune = r'\u{0000}',
        characterClass!: Option<LinearRegexCharacterClass> = None<LinearRegexCharacterClass>) {
        this.kind = kind
        this.literal = literal
        this.characterClass = characterClass
    }

    func consumesInput(): Bool {
        match (kind) {
            case LinearRegexAtomKind.Literal | LinearRegexAtomKind.Any |
                LinearRegexAtomKind.CharacterClass => true
            case _ => false
        }
    }

    func matches(value: Rune, iRegexp: Bool): Bool {
        match (kind) {
            case LinearRegexAtomKind.Literal => value == literal
            case LinearRegexAtomKind.Any => if (iRegexp) {
                value != r'\n' && value != r'\r'
            } else {
                !linearRegexIsLineTerminator(value)
            }
            case LinearRegexAtomKind.CharacterClass => characterClass.getOrThrow().matches(value)
            case _ => false
        }
    }
}

private class LinearRegexNode {
    let kind: LinearRegexNodeKind
    let atom: Option<LinearRegexAtom>
    let children: Array<LinearRegexNode>
    let minimum: Int64
    let maximum: Int64

    private init(kind: LinearRegexNodeKind,
        atom!: Option<LinearRegexAtom> = None<LinearRegexAtom>,
        children!: Array<LinearRegexNode> = Array<LinearRegexNode>(),
        minimum!: Int64 = 0, maximum!: Int64 = 0) {
        this.kind = kind
        this.atom = atom
        this.children = children
        this.minimum = minimum
        this.maximum = maximum
    }

    static func empty(): LinearRegexNode { LinearRegexNode(LinearRegexNodeKind.Empty) }

    static func atomic(value: LinearRegexAtom): LinearRegexNode {
        LinearRegexNode(LinearRegexNodeKind.Atom, atom: Some(value))
    }

    static func sequence(values: Array<LinearRegexNode>): LinearRegexNode {
        if (values.isEmpty()) { empty() }
        else if (values.size == 1) { values[0] }
        else { LinearRegexNode(LinearRegexNodeKind.Sequence, children: values) }
    }

    static func choice(values: Array<LinearRegexNode>): LinearRegexNode {
        if (values.size == 1) { values[0] }
        else { LinearRegexNode(LinearRegexNodeKind.Choice, children: values) }
    }

    static func repetition(value: LinearRegexNode, minimum: Int64, maximum: Int64): LinearRegexNode {
        LinearRegexNode(LinearRegexNodeKind.Repetition, children: [value],
            minimum: minimum, maximum: maximum)
    }
}

private class LinearRegexClassPiece {
    let term: LinearRegexClassTerm
    let rangeEndpoint: Option<Rune>

    init(term: LinearRegexClassTerm, rangeEndpoint: Option<Rune>) {
        this.term = term
        this.rangeEndpoint = rangeEndpoint
    }
}

private class LinearRegexParser {
    private let runes: Array<Rune>
    private let budget: LinearRegexBudget
    private let syntaxOnly: Bool
    private let namedGroups = ArrayList<String>()
    private let namedReferences = ArrayList<String>()
    private let numericReferences = ArrayList<Int64>()
    private var index: Int64 = 0
    private var depth: Int64 = 0
    private var captureCount: Int64 = 0

    init(pattern: String, budget: LinearRegexBudget, syntaxOnly!: Bool = false) {
        this.runes = pattern.toRuneArray()
        this.budget = budget
        this.syntaxOnly = syntaxOnly
        if (runes.size > LINEAR_REGEX_MAX_PATTERN_RUNES) {
            throw linearRegexError("Pattern exceeds ${LINEAR_REGEX_MAX_PATTERN_RUNES} Unicode scalars")
        }
    }

    func parse(): LinearRegexNode {
        let result = parseChoice()
        if (index != runes.size) { throw linearRegexError("Unexpected '${runes[index]}' at offset ${index}") }
        validateReferences()
        result
    }

    private func parseChoice(): LinearRegexNode {
        enter()
        try {
            let alternatives = ArrayList<LinearRegexNode>()
            alternatives.add(parseSequence())
            while (at(r'|')) {
                consume()
                alternatives.add(parseSequence())
            }
            LinearRegexNode.choice(alternatives.toArray())
        } finally {
            leave()
        }
    }

    private func parseSequence(): LinearRegexNode {
        let values = ArrayList<LinearRegexNode>()
        while (index < runes.size && !at(r'|') && !at(r')')) {
            values.add(parseQuantified())
        }
        LinearRegexNode.sequence(values.toArray())
    }

    private func parseQuantified(): LinearRegexNode {
        var value = parsePrimary()
        if (index >= runes.size) { return value }
        var quantified = false
        match (runes[index]) {
            case r'*' => consume(); value = LinearRegexNode.repetition(value, 0, -1); quantified = true
            case r'+' => consume(); value = LinearRegexNode.repetition(value, 1, -1); quantified = true
            case r'?' => consume(); value = LinearRegexNode.repetition(value, 0, 1); quantified = true
            case r'{' =>
                let saved = index
                match (tryParseBounds()) {
                    case Some(bounds) =>
                        value = LinearRegexNode.repetition(value, bounds[0], bounds[1])
                        quantified = true
                    case None => index = saved
                }
            case _ => ()
        }
        if (quantified && at(r'?')) { consume() }
        if (quantified && index < runes.size &&
            (at(r'*') || at(r'+') || at(r'?') || at(r'{'))) {
            throw linearRegexError("Nested quantifier at offset ${index}")
        }
        value
    }

    private func tryParseBounds(): Option<Array<Int64>> {
        consume()
        if (index >= runes.size || !linearRegexIsAsciiDigit(runes[index])) { return None<Array<Int64>> }
        let minimum = parseDecimal()
        var maximum = minimum
        if (at(r',')) {
            consume()
            maximum = if (index < runes.size && linearRegexIsAsciiDigit(runes[index])) {
                parseDecimal()
            } else { -1 }
        }
        if (!at(r'}')) { return None<Array<Int64>> }
        consume()
        if (minimum > LINEAR_REGEX_MAX_REPETITION || maximum > LINEAR_REGEX_MAX_REPETITION) {
            throw linearRegexError("Repetition exceeds ${LINEAR_REGEX_MAX_REPETITION}")
        }
        if (maximum >= 0 && maximum < minimum) {
            throw linearRegexError("Repetition maximum is smaller than minimum")
        }
        Some([minimum, maximum])
    }

    private func parseDecimal(): Int64 {
        var value: Int64 = 0
        while (index < runes.size && linearRegexIsAsciiDigit(runes[index])) {
            budget.step()
            let digit = Int64(UInt32(runes[index]) - UInt32(r'0'))
            if (value > LINEAR_REGEX_MAX_REPETITION) {
                throw linearRegexError("Repetition is too large")
            }
            value = value * 10 + digit
            index++
        }
        value
    }

    private func parsePrimary(): LinearRegexNode {
        if (index >= runes.size) { throw linearRegexError("Expected expression") }
        budget.step()
        let value = runes[index]
        match (value) {
            case r'(' => parseGroup()
            case r'[' => LinearRegexNode.atomic(LinearRegexAtom(LinearRegexAtomKind.CharacterClass,
                characterClass: Some(parseCharacterClass())))
            case r'.' => consume(); LinearRegexNode.atomic(LinearRegexAtom(LinearRegexAtomKind.Any))
            case r'^' => consume(); LinearRegexNode.atomic(LinearRegexAtom(LinearRegexAtomKind.Begin))
            case r'$' => consume(); LinearRegexNode.atomic(LinearRegexAtom(LinearRegexAtomKind.End))
            case r'\\' =>
                consume()
                if (syntaxOnly && at(r'k')) {
                    parseNamedReference()
                    LinearRegexNode.empty()
                } else if (syntaxOnly && index < runes.size &&
                    runes[index] >= r'1' && runes[index] <= r'9') {
                    parseNumericReference()
                    LinearRegexNode.empty()
                } else {
                    LinearRegexNode.atomic(parseEscape(false))
                }
            case r'*' | r'+' | r'?' => throw linearRegexError("Quantifier has no target at offset ${index}")
            case _ => consume(); LinearRegexNode.atomic(LinearRegexAtom(LinearRegexAtomKind.Literal,
                literal: value))
        }
    }

    private func parseGroup(): LinearRegexNode {
        consume()
        var capturing = true
        if (at(r'?')) {
            consume()
            if (at(r':')) {
                consume()
                capturing = false
            } else if (syntaxOnly && (at(r'=') || at(r'!'))) {
                consume()
                capturing = false
            } else if (syntaxOnly && at(r'<')) {
                consume()
                if (at(r'=') || at(r'!')) {
                    consume()
                    capturing = false
                } else {
                    let name = parseGroupName()
                    if (containsString(namedGroups, name)) {
                        throw linearRegexError("Duplicate named capture group ${name}")
                    }
                    namedGroups.add(name)
                }
            } else {
                throw linearRegexError("Lookaround, named groups, and inline flags are not supported")
            }
        }
        if (capturing) { captureCount++ }
        let value = parseChoice()
        if (!at(r')')) { throw linearRegexError("Unclosed group") }
        consume()
        value
    }

    private func parseNamedReference(): Unit {
        consume()
        if (!at(r'<')) { throw linearRegexError("Named backreference requires angle brackets") }
        consume()
        namedReferences.add(parseGroupName())
    }

    private func parseNumericReference(): Unit {
        var value: Int64 = 0
        while (index < runes.size && linearRegexIsAsciiDigit(runes[index])) {
            budget.step()
            if (value > LINEAR_REGEX_MAX_PATTERN_RUNES) {
                throw linearRegexError("Numeric backreference is too large")
            }
            value = value * 10 + Int64(UInt32(runes[index]) - UInt32(r'0'))
            index++
        }
        numericReferences.add(value)
    }

    private func parseGroupName(): String {
        if (index >= runes.size || !linearRegexIsGroupNameStart(runes[index])) {
            throw linearRegexError("Invalid named capture group")
        }
        let result = StringBuilder()
        result.append(runes[index])
        index++
        budget.step()
        while (index < runes.size && runes[index] != r'>') {
            if (!linearRegexIsGroupNameContinue(runes[index])) {
                throw linearRegexError("Invalid named capture group")
            }
            result.append(runes[index])
            index++
            budget.step()
        }
        if (!at(r'>')) { throw linearRegexError("Unclosed named capture group") }
        consume()
        result.toString()
    }

    private func validateReferences(): Unit {
        for (name in namedReferences) {
            if (!containsString(namedGroups, name)) {
                throw linearRegexError("Unknown named capture group ${name}")
            }
        }
        for (value in numericReferences) {
            if (value <= 0 || value > captureCount) {
                throw linearRegexError("Unknown numeric capture group ${value}")
            }
        }
    }

    private func containsString(values: ArrayList<String>, expected: String): Bool {
        for (value in values) { if (value == expected) { return true } }
        false
    }

    private func parseCharacterClass(): LinearRegexCharacterClass {
        consume()
        let negated = if (at(r'^')) { consume(); true } else { false }
        let terms = ArrayList<LinearRegexClassTerm>()
        while (index < runes.size && !at(r']')) {
            let first = parseClassPiece()
            if (first.rangeEndpoint.isSome() && at(r'-') && index + 1 < runes.size && runes[index + 1] != r']') {
                consume()
                let second = parseClassPiece()
                if (second.rangeEndpoint.isNone()) {
                    throw linearRegexError("Character-class range endpoint must be a literal")
                }
                let lower = first.rangeEndpoint.getOrThrow()
                let upper = second.rangeEndpoint.getOrThrow()
                if (lower > upper) { throw linearRegexError("Character-class range is reversed") }
                terms.add(LinearRegexClassTerm(LinearRegexClassTermKind.Range,
                    lower: lower, upper: upper))
            } else {
                terms.add(first.term)
            }
        }
        if (!at(r']')) { throw linearRegexError("Unclosed character class") }
        consume()
        LinearRegexCharacterClass(negated, terms.toArray())
    }

    private func parseClassPiece(): LinearRegexClassPiece {
        if (index >= runes.size) { throw linearRegexError("Unclosed character class") }
        budget.step()
        if (at(r'\\')) {
            consume()
            let atom = parseEscape(true)
            match (atom.kind) {
                case LinearRegexAtomKind.Literal =>
                    let term = LinearRegexClassTerm(LinearRegexClassTermKind.Range,
                        lower: atom.literal, upper: atom.literal)
                    LinearRegexClassPiece(term, Some(atom.literal))
                case LinearRegexAtomKind.CharacterClass =>
                    let nested = atom.characterClass.getOrThrow()
                    if (nested.terms.size != 1 || nested.negated) {
                        throw linearRegexError("Unsupported nested character-class escape")
                    }
                    LinearRegexClassPiece(nested.terms[0], None<Rune>)
                case _ => throw linearRegexError("Unsupported character-class escape")
            }
        } else {
            let value = runes[index]
            index++
            let term = LinearRegexClassTerm(LinearRegexClassTermKind.Range,
                lower: value, upper: value)
            LinearRegexClassPiece(term, Some(value))
        }
    }

    private func parseEscape(inClass: Bool): LinearRegexAtom {
        if (index >= runes.size) { throw linearRegexError("Trailing escape") }
        budget.step()
        let escaped = runes[index]
        index++
        match (escaped) {
            case r'd' => classAtom(LinearRegexClassTermKind.Digit)
            case r'D' => classAtom(LinearRegexClassTermKind.Digit, negated: true)
            case r'w' => classAtom(LinearRegexClassTermKind.Word)
            case r'W' => classAtom(LinearRegexClassTermKind.Word, negated: true)
            case r's' => classAtom(LinearRegexClassTermKind.Whitespace)
            case r'S' => classAtom(LinearRegexClassTermKind.Whitespace, negated: true)
            case r'p' => propertyAtom(false)
            case r'P' => propertyAtom(true)
            case r'b' => if (inClass) { literalAtom(r'\u{0008}') }
                else { LinearRegexAtom(LinearRegexAtomKind.WordBoundary) }
            case r'B' => if (inClass) { literalAtom(r'B') }
                else { LinearRegexAtom(LinearRegexAtomKind.NonWordBoundary) }
            case r'n' => literalAtom(r'\n')
            case r'r' => literalAtom(r'\r')
            case r't' => literalAtom(r'\t')
            case r'f' => literalAtom(r'\u{000C}')
            case r'v' => literalAtom(r'\u{000B}')
            case r'0' =>
                if (index < runes.size && linearRegexIsAsciiDigit(runes[index])) {
                    throw linearRegexError("Legacy octal and backreferences are not supported")
                }
                literalAtom(r'\u{0000}')
            case r'x' => literalAtom(Rune(readFixedHex(2)))
            case r'u' => literalAtom(readUnicodeEscape())
            case r'c' =>
                if (index >= runes.size || !runes[index].isAsciiLetter()) {
                    throw linearRegexError("Invalid control escape")
                }
                let code = UInt32(runes[index].toAsciiUpperCase()) - UInt32(r'A') + 1u32
                index++
                literalAtom(Rune(code))
            case r'1' | r'2' | r'3' | r'4' | r'5' | r'6' | r'7' | r'8' | r'9' =>
                throw linearRegexError("Backreferences are not supported")
            case _ =>
                if (escaped.isAsciiLetter()) {
                    throw linearRegexError("Unsupported escape \\${escaped}")
                }
                literalAtom(escaped)
        }
    }

    private func propertyAtom(negated: Bool): LinearRegexAtom {
        if (!at(r'{')) { throw linearRegexError("Unicode property escape requires braces") }
        consume()
        let builder = StringBuilder()
        while (index < runes.size && !at(r'}')) {
            builder.append(runes[index])
            index++
            budget.step()
        }
        if (!at(r'}')) { throw linearRegexError("Unclosed Unicode property escape") }
        consume()
        let kind = match (builder.toString()) {
            case "L" | "Letter" | "Alphabetic" => LinearRegexClassTermKind.Letter
            case "Lu" | "Uppercase_Letter" => LinearRegexClassTermKind.Uppercase
            case "Ll" | "Lowercase_Letter" => LinearRegexClassTermKind.Lowercase
            case "N" | "Number" | "Nd" | "Decimal_Number" | "digit" => LinearRegexClassTermKind.Number
            case "Any" => LinearRegexClassTermKind.Any
            case name => throw linearRegexError("Unsupported Unicode property ${name}")
        }
        classAtom(kind, negated: negated)
    }

    private func classAtom(kind: LinearRegexClassTermKind, negated!: Bool = false): LinearRegexAtom {
        LinearRegexAtom(LinearRegexAtomKind.CharacterClass,
            characterClass: Some(LinearRegexCharacterClass(false,
                [LinearRegexClassTerm(kind, negated: negated)])))
    }

    private func literalAtom(value: Rune): LinearRegexAtom {
        LinearRegexAtom(LinearRegexAtomKind.Literal, literal: value)
    }

    private func readUnicodeEscape(): Rune {
        if (at(r'{')) {
            consume()
            var code: UInt32 = 0
            var digits: Int64 = 0
            while (index < runes.size && !at(r'}')) {
                code = checkedHexAppend(code, readHexDigit())
                digits++
                if (digits > 6) { throw linearRegexError("Unicode escape is too long") }
            }
            if (digits == 0 || !at(r'}')) { throw linearRegexError("Invalid Unicode escape") }
            consume()
            return checkedRune(code)
        }
        let first = readFixedHex(4)
        if (first >= 0xD800u32 && first <= 0xDBFFu32) {
            if (index + 6 > runes.size || runes[index] != r'\\' || runes[index + 1] != r'u') {
                throw linearRegexError("High surrogate must be followed by a low surrogate")
            }
            index += 2
            let second = readFixedHex(4)
            if (second < 0xDC00u32 || second > 0xDFFFu32) {
                throw linearRegexError("Invalid low surrogate")
            }
            return Rune(0x10000u32 + ((first - 0xD800u32) << 10) + second - 0xDC00u32)
        }
        checkedRune(first)
    }

    private func readFixedHex(count: Int64): UInt32 {
        var value: UInt32 = 0
        for (_ in 0..count) { value = checkedHexAppend(value, readHexDigit()) }
        value
    }

    private func readHexDigit(): UInt32 {
        if (index >= runes.size) { throw linearRegexError("Incomplete hexadecimal escape") }
        budget.step()
        let value = runes[index]
        index++
        if (value >= r'0' && value <= r'9') { return UInt32(value) - UInt32(r'0') }
        if (value >= r'a' && value <= r'f') { return UInt32(value) - UInt32(r'a') + 10u32 }
        if (value >= r'A' && value <= r'F') { return UInt32(value) - UInt32(r'A') + 10u32 }
        throw linearRegexError("Invalid hexadecimal escape")
    }

    private func checkedHexAppend(value: UInt32, digit: UInt32): UInt32 {
        let result = value * 16u32 + digit
        if (result > 0x10FFFFu32) { throw linearRegexError("Unicode code point is out of range") }
        result
    }

    private func checkedRune(value: UInt32): Rune {
        if (value > 0x10FFFFu32 || (value >= 0xD800u32 && value <= 0xDFFFu32)) {
            throw linearRegexError("Invalid Unicode scalar value")
        }
        Rune(value)
    }

    private func enter(): Unit {
        depth++
        if (depth > LINEAR_REGEX_MAX_NESTING) { throw linearRegexError("Pattern nesting is too deep") }
    }

    private func leave(): Unit { depth-- }

    private func at(value: Rune): Bool { index < runes.size && runes[index] == value }

    private func consume(): Unit { budget.step(); index++ }
}

enum LinearRegexStateKind { Epsilon | Split | Atom | Accept }

class LinearRegexState {
    let kind: LinearRegexStateKind
    let atom: Option<LinearRegexAtom>
    var out1: Int64
    var out2: Int64

    init(kind: LinearRegexStateKind, atom!: Option<LinearRegexAtom> = None<LinearRegexAtom>,
        out1!: Int64 = -1, out2!: Int64 = -1) {
        this.kind = kind
        this.atom = atom
        this.out1 = out1
        this.out2 = out2
    }
}

private class LinearRegexPatch {
    let state: Int64
    let second: Bool
    init(state: Int64, second!: Bool = false) { this.state = state; this.second = second }
}

private class LinearRegexFragment {
    let start: Int64
    let patches: ArrayList<LinearRegexPatch>
    init(start: Int64, patches: ArrayList<LinearRegexPatch>) {
        this.start = start
        this.patches = patches
    }
}

private class LinearRegexCompiler {
    private let states = ArrayList<LinearRegexState>()
    private let budget: LinearRegexBudget
    private let iRegexp: Bool

    init(budget: LinearRegexBudget, iRegexp: Bool) {
        this.budget = budget
        this.iRegexp = iRegexp
    }

    func compile(node: LinearRegexNode): LinearRegex {
        let fragment = compileNode(node)
        let accept = addState(LinearRegexState(LinearRegexStateKind.Accept))
        patch(fragment.patches, accept)
        LinearRegex(states.toArray(), fragment.start, iRegexp)
    }

    private func compileNode(node: LinearRegexNode): LinearRegexFragment {
        budget.step()
        match (node.kind) {
            case LinearRegexNodeKind.Empty => emptyFragment()
            case LinearRegexNodeKind.Atom => atomFragment(node.atom.getOrThrow())
            case LinearRegexNodeKind.Sequence => compileSequence(node.children)
            case LinearRegexNodeKind.Choice => compileChoice(node.children)
            case LinearRegexNodeKind.Repetition => compileRepetition(
                node.children[0], node.minimum, node.maximum)
        }
    }

    private func emptyFragment(): LinearRegexFragment {
        let state = addState(LinearRegexState(LinearRegexStateKind.Epsilon))
        LinearRegexFragment(state, patches(LinearRegexPatch(state)))
    }

    private func atomFragment(atom: LinearRegexAtom): LinearRegexFragment {
        let state = addState(LinearRegexState(LinearRegexStateKind.Atom, atom: Some(atom)))
        LinearRegexFragment(state, patches(LinearRegexPatch(state)))
    }

    private func compileSequence(children: Array<LinearRegexNode>): LinearRegexFragment {
        var result = compileNode(children[0])
        for (index in 1..children.size) {
            result = concatenate(result, compileNode(children[index]))
        }
        result
    }

    private func compileChoice(children: Array<LinearRegexNode>): LinearRegexFragment {
        var result = compileNode(children[0])
        for (index in 1..children.size) {
            let right = compileNode(children[index])
            let split = addState(LinearRegexState(LinearRegexStateKind.Split,
                out1: result.start, out2: right.start))
            appendPatches(result.patches, right.patches)
            result = LinearRegexFragment(split, result.patches)
        }
        result
    }

    private func compileRepetition(child: LinearRegexNode,
        minimum: Int64, maximum: Int64): LinearRegexFragment {
        var result = emptyFragment()
        for (_ in 0..minimum) { result = concatenate(result, compileNode(child)) }
        if (maximum < 0) {
            result = concatenate(result, zeroOrMore(compileNode(child)))
        } else {
            for (_ in minimum..maximum) {
                result = concatenate(result, optional(compileNode(child)))
            }
        }
        result
    }

    private func zeroOrMore(child: LinearRegexFragment): LinearRegexFragment {
        let split = addState(LinearRegexState(LinearRegexStateKind.Split,
            out1: child.start))
        patch(child.patches, split)
        LinearRegexFragment(split, patches(LinearRegexPatch(split, second: true)))
    }

    private func optional(child: LinearRegexFragment): LinearRegexFragment {
        let split = addState(LinearRegexState(LinearRegexStateKind.Split,
            out1: child.start))
        child.patches.add(LinearRegexPatch(split, second: true))
        LinearRegexFragment(split, child.patches)
    }

    private func concatenate(left: LinearRegexFragment,
        right: LinearRegexFragment): LinearRegexFragment {
        patch(left.patches, right.start)
        LinearRegexFragment(left.start, right.patches)
    }

    private func patch(values: ArrayList<LinearRegexPatch>, target: Int64): Unit {
        for (value in values) {
            if (value.second) { states[value.state].out2 = target }
            else { states[value.state].out1 = target }
        }
    }

    private func appendPatches(target: ArrayList<LinearRegexPatch>,
        source: ArrayList<LinearRegexPatch>): Unit {
        for (value in source) { target.add(value) }
    }

    private func patches(value: LinearRegexPatch): ArrayList<LinearRegexPatch> {
        let result = ArrayList<LinearRegexPatch>()
        result.add(value)
        result
    }

    private func addState(state: LinearRegexState): Int64 {
        budget.step()
        if (states.size >= LINEAR_REGEX_MAX_STATES) {
            throw linearRegexError("Compiled pattern exceeds ${LINEAR_REGEX_MAX_STATES} states")
        }
        let result = states.size
        states.add(state)
        result
    }
}

class LinearRegex {
    private let states: Array<LinearRegexState>
    private let start: Int64
    private let iRegexp: Bool

    init(states: Array<LinearRegexState>, start: Int64, iRegexp: Bool) {
        this.states = states
        this.start = start
        this.iRegexp = iRegexp
    }

    static func compile(pattern: String, budget: LinearRegexBudget,
        iRegexp!: Bool = false): LinearRegex {
        let syntax = LinearRegexParser(pattern, budget).parse()
        LinearRegexCompiler(budget, iRegexp).compile(syntax)
    }

    static func validateEcmaSyntax(pattern: String, budget: LinearRegexBudget): Bool {
        try {
            let _ = LinearRegexParser(pattern, budget, syntaxOnly: true).parse()
            true
        } catch (error: JsonException) {
            if (error.code == "invalid_regex") { false } else { throw error }
        }
    }

    func find(input: String, budget: LinearRegexBudget, full!: Bool = false): Bool {
        let runes = input.toRuneArray()
        var current = ArrayList<Int64>()
        var currentSeen = Array<Bool>(states.size, repeat: false)
        for (position in 0..(runes.size + 1)) {
            if (!full || position == 0) {
                addClosure(current, currentSeen, start, position, runes, budget)
            }
            if (containsAccept(current) && (!full || position == runes.size)) { return true }
            if (position == runes.size) { break }
            let next = ArrayList<Int64>()
            let nextSeen = Array<Bool>(states.size, repeat: false)
            for (stateIndex in current) {
                let state = states[stateIndex]
                match (state.kind) {
                    case LinearRegexStateKind.Atom =>
                        let atom = state.atom.getOrThrow()
                        if (atom.consumesInput()) {
                            budget.step()
                            if (atom.matches(runes[position], iRegexp)) {
                                addClosure(next, nextSeen, state.out1,
                                    position + 1, runes, budget)
                            }
                        }
                    case _ => ()
                }
            }
            current = next
            currentSeen = nextSeen
        }
        false
    }

    private func addClosure(target: ArrayList<Int64>, seen: Array<Bool>, initial: Int64,
        position: Int64, input: Array<Rune>, budget: LinearRegexBudget): Unit {
        let stack = ArrayList<Int64>()
        stack.add(initial)
        while (!stack.isEmpty()) {
            let last = stack.size - 1
            let stateIndex = stack[last]
            stack.remove(at: last)
            if (stateIndex < 0 || seen[stateIndex]) { continue }
            seen[stateIndex] = true
            budget.step()
            let state = states[stateIndex]
            match (state.kind) {
                case LinearRegexStateKind.Epsilon => stack.add(state.out1)
                case LinearRegexStateKind.Split => stack.add(state.out2); stack.add(state.out1)
                case LinearRegexStateKind.Accept => target.add(stateIndex)
                case LinearRegexStateKind.Atom =>
                    let atom = state.atom.getOrThrow()
                    match (atom.kind) {
                        case LinearRegexAtomKind.Begin =>
                            if (position == 0) { stack.add(state.out1) }
                        case LinearRegexAtomKind.End =>
                            if (position == input.size) { stack.add(state.out1) }
                        case LinearRegexAtomKind.WordBoundary | LinearRegexAtomKind.NonWordBoundary =>
                            let before = position > 0 && linearRegexIsWord(input[position - 1])
                            let after = position < input.size && linearRegexIsWord(input[position])
                            let boundary = before != after
                            let allowed = match (atom.kind) {
                                case LinearRegexAtomKind.WordBoundary => boundary
                                case _ => !boundary
                            }
                            if (allowed) { stack.add(state.out1) }
                        case _ => target.add(stateIndex)
                    }
            }
        }
    }

    private func containsAccept(values: ArrayList<Int64>): Bool {
        for (value in values) {
            match (states[value].kind) {
                case LinearRegexStateKind.Accept => return true
                case _ => ()
            }
        }
        false
    }
}

private func linearRegexError(message: String): JsonException {
    JsonException(message, code: "invalid_regex")
}

private func linearRegexIsAsciiDigit(value: Rune): Bool { value >= r'0' && value <= r'9' }

private func linearRegexIsWord(value: Rune): Bool {
    value == r'_' || (value >= r'0' && value <= r'9') ||
        (value >= r'A' && value <= r'Z') || (value >= r'a' && value <= r'z')
}

private func linearRegexIsGroupNameStart(value: Rune): Bool {
    value == r'_' || value == r'$' || value.isLetter()
}

private func linearRegexIsGroupNameContinue(value: Rune): Bool {
    linearRegexIsGroupNameStart(value) || value.isNumber()
}

private func linearRegexIsLineTerminator(value: Rune): Bool {
    value == r'\n' || value == r'\r' || value == r'\u{2028}' || value == r'\u{2029}'
}
