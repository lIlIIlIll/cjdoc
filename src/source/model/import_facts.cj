protected package cjdoc.source.model

import cjdoc.source.{SourceLocation, joinedImportPath}
import std.collection.*

// One source import statement, described by the facts the AST reports: visibility
// modifier, organization qualifier, path prefix, imported member, alias, package
// selector, and per-item names. The CHIR dependency selection and the example
// dependency selection both consume these facts, so legal spellings (extra
// whitespace, comments, `private`/`internal`, aliases, `{...}` lists) cannot
// change which package a statement selects.
protected class SourceImportFacts {
    protected let modifier: String
    protected let kind: String
    protected let organization: String
    protected let prefixPaths = ArrayList<String>()
    protected let member: String
    protected let alias: ?String
    // Each `{...}` entry, including any nested prefix, as a dotted name.
    protected let items = ArrayList<SourceImportItem>()
    protected let source: ?SourceLocation

    protected init(modifier: String, kind: String, organization: String,
        prefixPaths!: Array<String> = [], member!: String = "", alias!: ?String = None,
        items!: Array<SourceImportItem> = [], source!: ?SourceLocation = None) {
        this.modifier = modifier
        this.kind = kind
        this.organization = organization
        this.prefixPaths.add(all: prefixPaths)
        this.member = member
        this.alias = alias
        this.items.add(all: items)
        this.source = source
    }

    // The path segments before any selector. A `*` or `{...}` statement selects
    // this package directly; otherwise the deepest segment may be a member.
    protected func packagePath(): String {
        joinedImportPath(prefixPaths)
    }

    private func dottedPath(): String {
        let tail = if (member.isEmpty() || member == "*") { None<String> } else { Some(member) }
        joinedImportPath(prefixPaths, tail: tail)
    }

    private func appendDistinct(result: ArrayList<String>, value: String): Unit {
        if (!value.isEmpty() && !result.contains(value)) { result.add(value) }
    }

    // Deepest path each entry names, relative to the organization. Consumers
    // resolve them against real packages and shorten the path themselves, so no
    // consumer has to guess whether the last segment names a member or a package.
    protected func referencePaths(): Array<String> {
        let result = ArrayList<String>()
        match (kind) {
            case "multi" =>
                for (item in items) { appendDistinct(result, packagePath() + "." + item.name) }
                appendDistinct(result, packagePath())
            case "all" => appendDistinct(result, packagePath())
            case _ => appendDistinct(result, dottedPath())
        }
        result.toArray()
    }

    // Verification reparses the same import statements in a compact temporary
    // program. Its positions differ, so compare syntax without positions.
    protected func hasSameStatement(other: SourceImportFacts): Bool {
        if (modifier != other.modifier || kind != other.kind || organization != other.organization ||
            member != other.member || alias != other.alias ||
            prefixPaths.size != other.prefixPaths.size || items.size != other.items.size) {
            return false
        }
        for (index in 0..prefixPaths.size) {
            if (prefixPaths[index] != other.prefixPaths[index]) { return false }
        }
        for (index in 0..items.size) {
            if (items[index].name != other.items[index].name ||
                items[index].alias != other.items[index].alias) { return false }
        }
        true
    }
}

private func importFactSegmentValid(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in value.toArray()) {
        if (byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r') { return false }
    }
    true
}

// Structural invariants of a fact set; std.ast never produces anything else, so a
// decoded cache entry that violates them is rejected rather than trusted.
protected func sourceImportFactsValid(facts: SourceImportFacts): Bool {
    match (facts.modifier) {
        case "" | "public" | "protected" | "internal" | "private" => ()
        case _ => return false
    }
    match (facts.kind) {
        case "single" | "alias" | "all" | "multi" => ()
        case _ => return false
    }
    if (!facts.organization.isEmpty() && !importFactSegmentValid(facts.organization)) { return false }
    for (part in facts.prefixPaths) {
        if (!importFactSegmentValid(part)) { return false }
    }
    match (facts.kind) {
        case "multi" =>
            if (facts.items.isEmpty()) { return false }
            for (item in facts.items) {
                if (!importFactSegmentValid(item.name)) { return false }
            }
        case "alias" =>
            if (!importFactSegmentValid(facts.member)) { return false }
            if (facts.alias.isNone()) { return false }
        case _ =>
            if (!importFactSegmentValid(facts.member)) { return false }
    }
    !facts.referencePaths().isEmpty()
}
