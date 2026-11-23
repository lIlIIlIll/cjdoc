package cjdoc

import cjdoc.render.codec as render_codec

import cjdoc.highlight.retainedHighlightBackendDiagnostics
import cjdoc.semantic.SemanticBindingStats
import cjdoc.binding.DocumentationSet
import cjdoc.model as public_model
import cjdoc_chir_protocol.CJDOC_PRODUCT_VERSION
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
        case "CJDOC1034" => "CJDOC3034"
        case "CJDOC1035" => "CJDOC3035"
        case "CJDOC1036" => "CJDOC3036"
        case "CJDOC1037" => "CJDOC3037"
        case "CJDOC1038" => "CJDOC3038"
        case "CJDOC1039" => "CJDOC3039"
        case "CJDOC1040" => "CJDOC3040"
        case "CJDOC1041" => "CJDOC3041"
        case "CJDOC1042" => "CJDOC3042"
        case "CJDOC1044" => "CJDOC3044"
        case "CJDOC1045" => "CJDOC3045"
        case "CJDOC1046" => "CJDOC3046"
        case "CJDOC1025" => "CJDOC3025"
        case _ => code
    }
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
        render_codec.docIrFitsEncodedBudget(candidate, request.maxDocIrBytes)) {
        return candidate
    }
    // Generation must return a valid, renderable value even when a hostile or
    // unexpectedly large source/provider field would exceed codec or output
    // transaction limits. Fixed source fields keep this fallback independent of
    // the oversized input that caused it.
    let fallback = public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", CJDOC_PRODUCT_VERSION), "partial",
        public_model.ProjectInfo("resource-limited"),
        public_model.ConfigurationSnapshot(audience: request.audience, lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) {
                "default"
            } else {
                "custom"
            }),
        diagnostics: [public_model.Diagnostic("warning", "CJDOC3027",
            "generated documentation exceeded codec or output resource limits and was replaced by a bounded fallback")],
        languageOptions: candidate.languageOptions, apiCollectionState: Some("unavailable"),
        documentationRevision: candidate.documentationRevision,
        metadata: public_model.DocumentationMetadata())
    for (diagnostic in retainedHighlightBackendDiagnostics(candidate)) {
        fallback.appendDiagnostic(diagnostic)
    }
    if (fallback.documentationRevision.isEmpty() ||
        render_codec.docIrFitsEncodedBudget(fallback, request.maxDocIrBytes)) {
        return fallback
    }
    // Optional publication provenance cannot make the resource fallback itself
    // unencodable. Preserve valid revisions; an unrepresentable one is unknown,
    // with the same persisted resource-limit diagnostic rather than a new cap.
    public_model.DocumentationSet(fallback.generator, fallback.status, fallback.project, fallback.configuration,
        diagnostics: fallback.diagnostics.toArray(), languageOptions: fallback.languageOptions,
        apiCollectionState: Some(fallback.apiCollectionState),
        metadata: public_model.DocumentationMetadata())
}
