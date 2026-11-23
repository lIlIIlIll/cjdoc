protected package cjdoc.cli

import cjdoc.documentation.{DocumentationQualityConfig, loadDocumentationQualityConfig}
import cjdoc.model as public_model
import cjdoc.render as public_render

private func coveragePercent(documented: Int64, total: Int64): Int64 {
    if (total == 0) { 100 } else { documented * 100 / total }
}

private func coverageMetric(counts: public_render.DocumentationCoverageCounts, metric: String): (Int64, Int64) {
    match (metric) {
        case "symbols" => (counts.symbols, counts.documentedSymbols)
        case "parameters" => (counts.parameters, counts.documentedParameters)
        case "returns" => (counts.returns, counts.documentedReturns)
        case "throws" => (counts.throwsDocs, counts.documentedThrows)
        case "examples" => (counts.examples, counts.documentedExamples)
        case "deprecated" => (counts.deprecated, counts.documentedDeprecated)
        case "semantic-links" => (counts.semanticLinks, counts.resolvedSemanticLinks)
        case _ => (0, 0)
    }
}

private func checkCoverageThreshold(scope: String, metric: String,
    counts: public_render.DocumentationCoverageCounts, threshold: Int64): Bool {
    let (total, documented) = coverageMetric(counts, metric)
    let percent = coveragePercent(documented, total)
    if (percent < threshold) {
        eprintln("error: ${scope} ${metric} coverage ${percent}% is below ${threshold}%")
        return false
    }
    true
}

private func hasCoverageThresholds(config: DocumentationQualityConfig): Bool {
    !config.packageOverrides.isEmpty() || config.coverage.symbols.isSome() ||
        config.coverage.parameters.isSome() || config.coverage.returns.isSome() ||
        config.coverage.throwsDocs.isSome() || config.coverage.examples.isSome() ||
        config.coverage.deprecated.isSome() || config.coverage.semanticLinks.isSome()
}

private func configuredCoverageGate(documentation: public_model.DocumentationSet,
    projectRoot: String): Bool {
    let config = loadDocumentationQualityConfig(projectRoot)
    if (!hasCoverageThresholds(config)) { return true }
    let report = public_render.documentationCoverageReport(documentation)
    let metrics = ["symbols", "parameters", "returns", "throws", "examples", "deprecated", "semantic-links"]
    var passed = true
    for (metric in metrics) {
        match (config.coverage.value(metric)) {
            case Some(threshold) => passed = checkCoverageThreshold("global", metric, report.metrics, threshold) && passed
            case None => ()
        }
    }
    for (override in config.packageOverrides) {
        var matched = false
        for (group in report.packages where group.name == override.packageName) {
            matched = true
            for (metric in metrics) {
                match (config.packageThreshold(group.name, metric)) {
                    case Some(threshold) =>
                        passed = checkCoverageThreshold("package ${group.name}", metric, group.metrics, threshold) && passed
                    case None => ()
                }
            }
        }
        if (!matched) {
            eprintln("error: package coverage override '${override.packageName}' does not match any selected package")
            passed = false
        }
    }
    passed
}

protected func passesCliCoverageGates(documentation: public_model.DocumentationSet, options: NewCliOptions): Bool {
    var failed = false
    if (options.command != "render" && !configuredCoverageGate(documentation, options.project)) { failed = true }
    if (options.minSymbolCoverage.isSome() || options.minParameterCoverage.isSome()) {
        let (symbols, documentedSymbols, parameters, documentedParameters) =
            public_render.documentationCoverageCounts(documentation)
        let symbolPercent = coveragePercent(documentedSymbols, symbols)
        let parameterPercent = coveragePercent(documentedParameters, parameters)
        eprintln("documentation coverage: symbols " + documentedSymbols.toString() + "/" + symbols.toString() +
            " (" + symbolPercent.toString() + "%), parameters " + documentedParameters.toString() + "/" +
            parameters.toString() + " (" + parameterPercent.toString() + "%)")
        if (options.minSymbolCoverage.isSome() && symbolPercent < options.minSymbolCoverage.getOrThrow()) {
            eprintln("error: symbol documentation coverage is below the configured threshold")
            failed = true
        }
        if (options.minParameterCoverage.isSome() && parameterPercent < options.minParameterCoverage.getOrThrow()) {
            eprintln("error: parameter documentation coverage is below the configured threshold")
            failed = true
        }
    }
    !failed
}
