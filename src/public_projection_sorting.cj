package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*

internal func remapDiagnosticCode(code: String): String {
    match (code) {
        case "CJDOC1001" => "CJDOC3001"
        case "CJDOC1002" => "CJDOC3002"
        case "CJDOC1003" => "CJDOC3003"
        case "CJDOC1004" => "CJDOC3004"
        case "CJDOC1005" => "CJDOC3005"
        case "CJDOC1006" => "CJDOC2006"
        case "CJDOC1007" => "CJDOC2007"
        case "CJDOC1008" => "CJDOC3008"
        case "CJDOC1017" => "CJDOC2017"
        case "CJDOC1022" => "CJDOC3022"
        case "CJDOC1023" => "CJDOC3023"
        case "CJDOC1024" => "CJDOC4024"
        case "CJDOC1025" => "CJDOC3025"
        case _ => code
    }
}

internal func comparePublicString(left: String, right: String): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

internal func comparePublicInt(left: Int64, right: Int64): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

internal func comparePublicOptionalString(left: ?String, right: ?String): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    comparePublicString(left.getOrThrow(), right.getOrThrow())
}

internal func comparePublicSource(left: ?public_model.SourceRange, right: ?public_model.SourceRange): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    let leftValue = left.getOrThrow()
    let rightValue = right.getOrThrow()
    var compared = comparePublicString(leftValue.path, rightValue.path)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.line, rightValue.start.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.column, rightValue.start.column)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.byteOffset, rightValue.start.byteOffset)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.line, rightValue.end.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.column, rightValue.end.column)
    if (compared != 0) {
        return compared
    }
    comparePublicInt(leftValue.end.byteOffset, rightValue.end.byteOffset)
}

internal func comparePublicDiagnostic(left: public_model.Diagnostic, right: public_model.Diagnostic): Int64 {
    var compared = comparePublicSource(left.source, right.source)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.code, right.code)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.severity, right.severity)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.message, right.message)
    if (compared != 0) {
        return compared
    }
    comparePublicOptionalString(left.symbolId, right.symbolId)
}

internal class FinalSemanticStateSummary {
    var total: Int64 = 0
    var resolved: Int64 = 0
    var partial: Int64 = 0
    var unavailable: Int64 = 0
    var ambiguous: Int64 = 0

    func add(state: String): Unit {
        total++
        match (state) {
            case "resolved" => resolved++
            case "partial" => partial++
            case "unavailable" => unavailable++
            case "ambiguous" => ambiguous++
            case _ => partial++
        }
    }
}

internal func summarizeFinalSemanticStates(documentation: DocumentationSet): HashMap<String, FinalSemanticStateSummary> {
    let summaries = HashMap<String, FinalSemanticStateSummary>()
    for (symbol in documentation.symbols) {
        let summary = match (summaries.get(symbol.moduleId)) {
            case Some(value) => value
            case None =>
                let value = FinalSemanticStateSummary()
                summaries[symbol.moduleId] = value
                value
        }
        summary.add(symbol.semanticState)
    }
    summaries
}

internal func aggregateProviderState(binding: SemanticBindingStats, summary: FinalSemanticStateSummary): String {
    if (!binding.capabilities.sourceBinding) {
        return "unavailable"
    }
    if (summary.total > 0 && summary.unavailable == summary.total) {
        return "unavailable"
    }
    if (summary.total > 0 && summary.ambiguous == summary.total) {
        return "ambiguous"
    }
    if (summary.total == 0 || summary.partial > 0 || summary.unavailable > 0 || summary.ambiguous > 0 ||
        binding.missing > 0 || binding.ambiguous > 0 || binding.contractViolations > 0 || binding.extraneous > 0) {
        return "partial"
    }
    "resolved"
}

protected func boundGeneratedDocumentation(candidate: public_model.DocumentationSet,
    request: GenerationRequest, force!: Bool = false): public_model.DocumentationSet {
    if (!force &&
        public_render.docIrFitsEncodedBudget(candidate, public_model.DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES)) {
        return candidate
    }
    // Generation must return a valid, renderable value even when a hostile or
    // unexpectedly large source/provider field would exceed codec or output
    // transaction limits. Fixed strings keep this fallback independent of the
    // oversized input that caused it.
    public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.7.2"), "partial",
        public_model.ProjectInfo("resource-limited"),
        public_model.ConfigurationSnapshot(audience: request.audience, lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) {
                "default"
            } else {
                "custom"
            }),
        diagnostics: [public_model.Diagnostic("warning", "CJDOC3027",
            "generated documentation exceeded codec or output resource limits and was replaced by a bounded fallback")])
}
