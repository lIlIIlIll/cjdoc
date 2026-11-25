protected package cjdoc.binding

import cjdoc.source.{Diagnostic, SourceLocation}
import std.collection.*

/**
 * Report the structural problems of a project comment policy.
 *
 * These are errors of the authored syntax, not lint findings: an attribute on a
 * custom field line or a repeated single-value field fails the run even when
 * lint is off.
 */
protected func reportCommentStructures(documentation: DocumentationSet): Unit {
    for (symbol in documentation.symbols) {
        let comment = match (symbol.documentation) {
            case Some(value) => value
            case None => continue
        }
        for (problem in comment.problems) {
            let severity = "error"
            documentation.diagnostics.add(Diagnostic(severity, problem.code, problem.message,
                source: problem.source, symbolId: Some(symbol.id)))
        }
    }
}

/**
 * Evaluate module comment rules over the current audience.
 *
 * Only declarations visible to the requested audience are checked, including the
 * case where no comment was captured at all: a `when-present` trigger is an
 * authored appearance, so an undocumented declaration simply never triggers it.
 */
protected func evaluateCommentRules(documentation: DocumentationSet, audience: String): Unit {
    if (documentation.commentSpecs.isEmpty()) { return }
    let visible = renderableSymbolIds(documentation, audience)
    for (symbol in documentation.symbols) {
        let spec = match (documentation.commentSpecs.get(symbol.moduleId)) {
            case Some(value) => value
            case None => continue
        }
        if (spec.rules.isEmpty()) { continue }
        if (!visible.contains(symbol.id)) { continue }
        let first = HashMap<String, ?SourceLocation>()
        let satisfied = HashSet<String>()
        if (let Some(comment) <- symbol.documentation) {
            for (occurrence in comment.occurrences) {
                if (!first.contains(occurrence.name)) { first[occurrence.name] = occurrence.source }
                if (spec.requires(occurrence.name) && !satisfied.contains(occurrence.name) &&
                    occurrence.payload) {
                    let _ = satisfied.add(occurrence.name)
                }
            }
        }
        for (rule in spec.rules) {
            let triggered = match (rule.whenPresent) {
                case Some(trigger) => first.contains(trigger)
                case None => true
            }
            if (!triggered || satisfied.contains(rule.required)) { continue }
            let location = first.get(rule.required).getOrDefault({ => None<SourceLocation> })
            documentation.diagnostics.add(Diagnostic(rule.severity, "CJDOC3142",
                "declaration '${symbol.qualifiedName}' is missing required @" + rule.required +
                commentRuleTriggerText(rule.whenPresent),
                source: if (location.isSome()) { location } else { symbol.source },
                symbolId: Some(symbol.id)))
        }
    }
}

private func commentRuleTriggerText(whenPresent: ?String): String {
    match (whenPresent) {
        case Some(value) => " (required when @" + value + " is present)"
        case None => ""
    }
}
