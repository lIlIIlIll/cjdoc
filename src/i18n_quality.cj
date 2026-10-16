package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.sort.*

internal func withTranslationDiagnostics(value: public_model.DocumentationSet,
    request: GenerationRequest): public_model.DocumentationSet {
    let diagnostics = ArrayList<public_model.Diagnostic>(value.diagnostics.toArray())
    let thresholds = loadDocumentationQualityConfig(request.projectRoot).translationThresholds
    for (language in request.requiredLanguages) { thresholds[language] = 100 }
    let languages = HashSet<String>()
    if (let Some(options) <- value.languageOptions) {
        for (language in options.languages) { let _ = languages.add(language) }
    }
    for ((language, _) in thresholds) { let _ = languages.add(language) }
    for (language in languages) {
        let report = public_render.translationCoverageFor(value, language)
        let severity = match (value.languageOptions) {
            case Some(options) => if (options.missingTranslation == "deny") { "error" } else { "warning" }
            case None => "warning"
        }
        for (entry in report.entries) {
            if (entry.state == "complete") { continue }
            diagnostics.add(public_model.Diagnostic(severity, "CJDOC3108",
                "language " + language + ": " + entry.kind + " '" + entry.subject + "' has " + entry.state +
                " documentation", source: entry.source, symbolId: entry.symbolId))
        }
        if (let Some(threshold) <- thresholds.get(language)) {
            if (report.percent < threshold) {
                diagnostics.add(public_model.Diagnostic("error", "CJDOC3111",
                    "language " + language + " translation coverage " + report.percent.toString() +
                    "% is below " + threshold.toString() + "%"))
            }
        }
    }
    sort(diagnostics, lessThan: { a, b => comparePublicDiagnostic(a, b) < 0 }, stable: true)
    var status = value.status
    for (diagnostic in diagnostics) { if (diagnostic.severity == "error") { status = "partial" } }
    public_model.DocumentationSet(value.generator, status, value.project, value.configuration,
        apiCollectionState: Some(value.apiCollectionState),
        providers: value.providers.toArray(), modules: value.modules.toArray(), packages: value.packages.toArray(),
        files: value.files.toArray(), declarations: value.declarations.toArray(), assets: value.assets.toArray(),
        orphanDocComments: value.orphanDocComments.toArray(), macroInvocations: value.macroInvocations.toArray(),
        unsupportedDeclarations: value.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: value.unboundSemanticDeclarations.toArray(), diagnostics: diagnostics.toArray(),
        languageOptions: value.languageOptions, pages: value.pages.toArray(),
        externalDocumentation: value.externalDocumentation.toArray())
}
