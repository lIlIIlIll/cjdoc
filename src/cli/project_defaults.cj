protected package cjdoc.cli

import cjdoc.documentation.i18n.loadDocumentationLanguages
import std.collection.{ArrayList, HashSet}

// Merge the project defaults into the parsed command once, before the final
// cross-option validation. Explicit CLI values always win, and every configured
// value has already been validated even when it is overridden.
internal func applyProjectCliConfig(options: NewCliOptions): Unit {
    if (options.command != "generate" && options.command != "check" &&
        options.command != "serve") {
        return
    }
    let config = loadProjectCliConfig(options.project)
    applyProjectOutputConfig(options, config.output)
    applyProjectAnalysisConfig(options, config.analysis, config.semanticMode)
}

private func applyProjectOutputConfig(options: NewCliOptions, output: ProjectOutputPolicy): Unit {
    // `[output]` describes produced sites. check writes none, and --stdout is an
    // explicit one-format choice that would otherwise inherit a site format list.
    if (options.command != "check" && !options.stdout) {
        // A CLI --format list replaces the configured list instead of extending it.
        if (!output.formats.isEmpty() && options.formats.isEmpty()) {
            for (format in output.formats) { options.formats.add(format) }
        }
        if (options.output.isNone()) {
            match (output.directory) {
                case Some(value) => options.output = Some(value)
                case None => ()
            }
        }
        // HTML-only settings are defaults for an HTML site. When the resolved
        // formats are JSON-only they would only fail validation, so they are
        // not inherited; the configured values were already validated above.
        let htmlSite = options.command == "serve" || options.formats.contains("html")
        if (htmlSite) {
            if (!options.agentFullExplicit) {
                match (output.agentFull) {
                    case Some(value) => options.agentFull = value
                    case None => ()
                }
            }
            if (options.htmlFontSans.isNone()) {
                match (output.htmlFontSans) {
                    case Some(value) => options.htmlFontSans = Some(value)
                    case None => ()
                }
            }
            if (options.htmlFontMono.isNone()) {
                match (output.htmlFontMono) {
                    case Some(value) => options.htmlFontMono = Some(value)
                    case None => ()
                }
            }
        }
    }
}

private func applyProjectAnalysisConfig(options: NewCliOptions, analysis: ProjectAnalysisPolicy,
    semanticMode: ?String): Unit {
    if (!options.audienceExplicit) {
        match (analysis.audience) {
            case Some(value) => options.audience = value
            case None => ()
        }
    }
    if (!options.jobsExplicit) {
        match (analysis.jobs) {
            case Some(value) => options.jobs = value
            case None => ()
        }
    }
    if (!options.lintProfileExplicit) {
        match (analysis.lintProfile) {
            case Some(value) => options.lintProfile = value
            case None => ()
        }
    }
    if (!options.semanticExplicit) {
        match (semanticMode) {
            case Some(value) => options.semanticMode = value
            case None => ()
        }
    }
    if (!options.includePathDependenciesExplicit) {
        match (analysis.includePathDependencies) {
            case Some(value) => options.includePathDependencies = value
            case None => ()
        }
    }
    if (!options.includeCachedDependenciesExplicit) {
        match (analysis.includeCachedDependencies) {
            case Some(value) => options.includeCachedDependencies = value
            case None => ()
        }
    }
    // A configured cache root only accompanies cache reading. --no-include-cached-
    // dependencies therefore drops it instead of inheriting an unusable pair.
    if (options.cjpmCacheRoot.isNone() && options.includeCachedDependencies) {
        match (analysis.cjpmCache) {
            case Some(value) => options.cjpmCacheRoot = Some(value)
            case None => ()
        }
    }
    // --cache-dir or --no-cache already decided the cache for this command.
    if (options.cacheDirectory.isNone() && !options.noCache && !options.cacheExplicit) {
        match (analysis.cacheDirectory) {
            case Some(value) => options.cacheDirectory = Some(value)
            case None => ()
        }
        if (options.cacheDirectory.isNone() && analysis.noCache.getOrDefault({ => false })) {
            options.noCache = true
        }
    }
    if (!analysis.cfg.isEmpty()) {
        let overridden = HashSet<String>()
        for (value in options.cfgValues) { let _ = overridden.add(value[0]) }
        for (value in analysis.cfg) {
            if (!overridden.contains(value[0])) { options.cfgValues.add(value) }
        }
    }
    if (!analysis.dependencySources.isEmpty()) {
        let overridden = HashSet<String>()
        for (value in options.dependencySources) { let _ = overridden.add(value[0]) }
        for (value in analysis.dependencySources) {
            if (!overridden.contains(value[0])) { options.dependencySources.add(value) }
        }
    }
}

// `--locale` selects interface labels; without it the configured publication
// default language wins over the built-in zh-CN.
protected func selectedCliRenderLocale(options: NewCliOptions): String {
    if (options.localeExplicit) { return options.locale }
    if (options.command != "generate" && options.command != "serve") { return options.locale }
    match (loadDocumentationLanguages(options.project)) {
        case Some(value) => value.defaultLanguage
        case None => options.locale
    }
}
