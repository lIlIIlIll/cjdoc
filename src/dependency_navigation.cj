package cjdoc

import cjdoc.model as link_model
import std.collection.*
import std.sort.*

private func dependencyQualifiedName(symbol: link_model.SymbolDoc): String {
    if (symbol.qualifiedName.startsWith(symbol.packageName + ".")) { return symbol.qualifiedName }
    symbol.packageName + "." + symbol.qualifiedName
}

internal class DependencyNavigationBinder {
    let documentation: link_model.DocumentationSet
    let request: GenerationRequest
    let dependencies: Array<link_model.DependencyInstance>
    let resolvers: Array<ExternalDocResolver>
    let documentSets = ArrayList<link_model.DocumentSetIdentity>()
    let diagnostics = ArrayList<link_model.Diagnostic>()
    private let local = HashMap<String, ArrayList<link_model.SymbolDoc>>()
    private let symbols = HashMap<String, link_model.SymbolDoc>()
    private let sources = HashMap<String, SourceFileOrigin>()
    private let external = HashMap<String, ArrayList<(ExternalDocResolver, ExternalDocEntry)>>()
    private let dependenciesByName = HashMap<String, ArrayList<link_model.DependencyInstance>>()
    private let moduleNames = HashMap<String, String>()
    private let authoritativeModules = HashSet<String>()
    private let importCandidates = HashMap<String, Array<String>>()
    private let importIndexes = HashMap<String, DependencyImportIndex>()
    private let typeShapes = HashMap<String, ?DependencyTypeShape>()
    private let work = DependencyNavigationWork()
    private let actualGraph: DependencyGraphIndex
    private let decisionReasons = HashMap<String, HashMap<String, String>>()

    init(documentation: link_model.DocumentationSet, request: GenerationRequest,
        origins: Array<SourceFileOrigin>, externalResolvers!: ?Array<ExternalDocResolver> = None) {
        this.documentation = documentation; this.request = request
        let (capturedDependencies, graph) = captureDependencyIdentities(documentation, request,
            diagnostics: Some(diagnostics), origins: origins, navigationWork: Some(work))
        dependencies = capturedDependencies
        actualGraph = graph
        for (dependency in dependencies) {
            let nameKey = dependency.moduleId + "|" + dependency.name
            match (dependenciesByName.get(nameKey)) {
                case Some(values) => values.add(dependency)
                case None => dependenciesByName[nameKey] = ArrayList<link_model.DependencyInstance>([dependency])
            }
            let packageName = actualGraph.sourcePackage(dependency.componentModuleId)
            if (!packageName.isEmpty() && packageName != dependency.name) {
                let packageKey = dependency.moduleId + "|" + packageName
                match (dependenciesByName.get(packageKey)) {
                    case Some(values) => values.add(dependency)
                    case None => dependenciesByName[packageKey] = ArrayList<link_model.DependencyInstance>([dependency])
                }
            }
        }
        let loaded = externalResolvers.getOrDefault({ => loadDependencyDocSources(request) })
        sort(loaded, lessThan: { left, right =>
            left.baseUrl + "|" + left.fingerprint < right.baseUrl + "|" + right.fingerprint
        }, stable: true)
        resolvers = loaded
        for (module in documentation.modules) {
            moduleNames[module.id] = module.name
            if (let Some(actual) <- dependencyFor(module.id, module.name)) {
                if (!actual.identity.isEmpty() && actual.componentModuleId == module.id) { let _ = authoritativeModules.add(module.id) }
            }
        }
        for (origin in origins) { sources[origin.moduleId + "|" + origin.logicalPath] = origin }
        for (symbol in documentation.declarations) {
            symbols[symbol.id] = symbol
            for (key in [symbol.id, dependencyQualifiedName(symbol)]) {
                match (local.get(key)) {
                    case Some(values) => values.add(symbol)
                    case None => local[key] = ArrayList<link_model.SymbolDoc>([symbol])
                }
            }
        }
        let seenDocumentSets = HashSet<String>()
        for (resolver in resolvers where resolver.state != "available") {
            if (diagnostics.size < 4096) {
                diagnostics.add(link_model.Diagnostic("warning", "CJDOC2312",
                    "documentation source: " + resolver.reason))
            }
        }
        var count: Int64 = 0
        for (resolver in resolvers where resolver.state == "available") {
            for (documentSet in resolver.documentSets) {
                if (seenDocumentSets.add(documentSet.id)) { documentSets.add(documentSet) }
            }
            for ((key, entries) in resolver.entries) {
                count += entries.size
                if (count > 100000) { throw IllegalArgumentException("external navigation entry budget exceeded") }
                for (entry in entries) {
                    match (external.get(key)) {
                        case Some(values) => values.add((resolver, entry))
                        case None => external[key] = ArrayList<(ExternalDocResolver, ExternalDocEntry)>([(resolver, entry)])
                    }
                }
            }
        }
        sort(documentSets, lessThan: { left, right =>
            left.id + "|" + left.baseUrl + "|" + left.indexIdentity <
                right.id + "|" + right.baseUrl + "|" + right.indexIdentity
        }, stable: true)
    }
    private func decisionReason(set: link_model.DocumentSetIdentity, level: String, dependency: Bool): String {
        let key = if (level == "manual" && !dependency) { "documentation-only" } else { level }
        if (let Some(variants) <- decisionReasons.get(set.id)) {
            if (let Some(value) <- variants.get(key)) { return value }
        }
        if (!work.consumeBytes(set.apiVersion.size + set.documentationRevision.size + set.revision.size + set.language.size)) { return "" }
        let out = StringBuilder()
        out.append(match (key) {
            case "exact" => "independent inventory SHA-256 pin and observed source dependency graph match the published API identity/coverage; catalog base URL is a display choice, not authenticated hosting or API/ABI attestation"
            case "compatible" => "explicit scoped API/build-context mapping; compatibility and catalog hosting are user declarations, not attested"
            case "documentation-only" => "explicit documentation-only reference; no project dependency is asserted; publisher API correspondence and catalog hosting remain unverified"
            case _ => "publisher API correspondence or source-graph binding remains unverified; catalog base URL is an unverified display choice"
        })
        out.append("; apiVersion (publisher package declaration)="); out.append(if (set.apiVersion.isEmpty()) { "unknown" } else { set.apiVersion })
        out.append("; documentationRevision="); out.append(if (set.documentationRevision.isEmpty()) { "unknown" } else { set.documentationRevision })
        out.append("; API source revision="); out.append(if (set.revision.isEmpty()) { "unknown" } else { set.revision })
        out.append("; document language="); out.append(if (set.language.isEmpty()) { "unknown" } else { set.language })
        let result = out.toString()
        match (decisionReasons.get(set.id)) {
            case Some(variants) => variants[key] = result
            case None => decisionReasons[set.id] = HashMap<String, String>([(key, result)])
        }
        result
    }


    private func visible(symbol: link_model.SymbolDoc): Bool {
        var current: ?link_model.SymbolDoc = Some(symbol)
        while (let Some(value) <- current) {
            if ((request.audience == "external" && value.visibility != "public" && value.visibility != "protected") ||
                (request.audience == "package" && value.visibility == "private")) { return false }
            current = match (value.ownerId) { case Some(id) => symbols.get(id); case None => None }
        }
        true
    }

    func resolveLocalReference(owner: link_model.SymbolDoc, id: String): link_model.TypeNavigation {
        if (let Some(target) <- symbols.get(id)) {
            if (!visible(target)) {
                return link_model.TypeNavigation("unavailable", "none", "target excluded by documentation audience")
            }
            if (localAllowed(owner.moduleId, target)) {
                return link_model.TypeNavigation("resolved", "exact", "authoritative target in selected module dependency context",
                    symbolKey: target.id, url: semanticLinkLocalUrl(target.id))
            }
        }
        referenceResult(owner, link_model.TypeNavigation("unavailable", "none", "local reference does not belong to the selected module dependency identity"))
    }

    private func referenceResult(owner: link_model.SymbolDoc, decision: link_model.TypeNavigation): link_model.TypeNavigation {
        if (decision.state != "resolved" && visible(owner) && diagnostics.size < 4096 &&
            decision.reason != "target excluded by documentation audience" &&
            (!request.documentSources.isEmpty() || request.buildContext.isSome())) {
            diagnostics.add(link_model.Diagnostic(if (request.lintProfile == "strict") { "error" } else { "warning" },
                "CJDOC2311", "documentation reference: " + decision.reason,
                source: Some(owner.source), symbolId: Some(owner.id)))
        }
        decision
    }

    private func dependencyFor(moduleId: String, library: String): ?link_model.DependencyInstance {
        var found: ?link_model.DependencyInstance = None
        let values = match (dependenciesByName.get(moduleId + "|" + library)) {
            case Some(entries) => entries
            case None => return None
        }
        for (dependency in values) {
            if (let Some(previous) <- found) {
                if (previous.instanceId != dependency.instanceId || previous.state != dependency.state) { return None }
            }
            found = Some(dependency)
        }
        found
    }

    private func localAllowed(moduleId: String, candidate: link_model.SymbolDoc): Bool {
        if (candidate.moduleId == moduleId) { return true }
        let name = match (moduleNames.get(candidate.moduleId)) { case Some(value) => value; case None => return false }
        let actual = dependencyFor(candidate.moduleId, name)
        if (actual.isNone()) { return false }
        let right = actual.getOrThrow()
        let packageName = actualGraph.sourcePackage(right.componentModuleId)
        let selected = dependencyFor(moduleId, if (packageName.isEmpty()) { name } else { packageName })
        if (let Some(left) <- selected) {
            if (left.identity.isEmpty() || left.identity != right.identity ||
                (left.state != "observed" && left.state != "verified") ||
                (right.state != "observed" && right.state != "verified")) { return false }
            if (actualGraph.context(left.componentModuleId, work).conflicted) { return false }
            return left.componentModuleId == candidate.moduleId ||
                actualGraph.binding(actualGraph, left.componentModuleId, candidate.moduleId, work) == "matched"
        }
        false
    }

    func genericReference(owner: link_model.SymbolDoc, target: String): Bool {
        scopedGenericReference(owner, target, symbols)
    }

    private func cachedTypeShape(spelling: String): ?DependencyTypeShape {
        match (typeShapes.get(spelling)) {
            case Some(shape) => return shape
            case None => ()
        }
        let shape = if (work.consumeBytes(spelling.size)) { dependencyTypeShape(spelling) } else { None<DependencyTypeShape> }
        typeShapes[spelling] = shape
        shape
    }

    private func candidateNames(owner: link_model.SymbolDoc, name: String): Array<String> {
        let names = ArrayList<String>()
        names.add(owner.packageName + "." + name)
        var scope: ?link_model.SymbolDoc = Some(owner)
        while (let Some(current) <- scope) {
            names.add(dependencyQualifiedName(current) + "." + name)
            scope = match (current.ownerId) { case Some(id) => symbols.get(id); case None => None }
        }
        let sourceKey = owner.moduleId + "|" + owner.source.path
        if (let Some(origin) <- sources.get(sourceKey)) {
            let key = sourceKey + "|" + name
            let candidates = match (importCandidates.get(key)) {
                case Some(values) => values
                case None =>
                    let index = match (importIndexes.get(sourceKey)) {
                        case Some(value) => value
                        case None =>
                            let value = DependencyImportIndex(origin, work)
                            importIndexes[sourceKey] = value
                            value
                    }
                    let values: Array<String> = if (let Some(shape) <- cachedTypeShape(name)) {
                        if (shape.kind == "named" || shape.kind == "generic") { index.candidates(shape.head, work) } else { [] }
                    } else { [] }
                    importCandidates[key] = values
                    values
            }
            for (candidate in candidates) {
                if (!names.contains(candidate)) { names.add(candidate) }
            }
        }
        names.toArray()
    }
    private func standardImportDisambiguatesCoreTarget(imports: Array<String>,
        implicitCoreName: String, docsVersion: String, sourceKey: String, head: String): Bool {
        if (!isValidStandardLibraryDocsVersion(docsVersion)) { return false }
        var foundStandardImport = false
        for (candidate in imports where candidate != implicitCoreName) {
            if (!candidate.startsWith("std.")) { return false }
            if (!hasStandardLibraryDocTarget(docsVersion, candidate,
                baseUrlOverride: request.standardLibraryDocsBaseUrl)) {
                let index = match (importIndexes.get(sourceKey)) {
                    case Some(value) => value
                    case None => return false
                }
                let packageName = match (index.wildcardPackage(head, candidate, work)) {
                    case Some(value) => value
                    case None => return false
                }
                // A wildcard synthesizes names, not declarations. An absent entry
                // in a known std documentation package must not invent a conflict.
                // This selects a manual documentation route, never a canonical type.
                if (!hasStandardLibraryDocPackage(packageName)) { return false }
            }
            foundStandardImport = true
        }
        foundStandardImport
    }

    private func selectedStandardLibraryDocsVersion(moduleId: String): ?String {
        if (let Some(version) <- request.standardLibraryDocsVersion) { return Some(version) }
        var selected = ""
        var found = false
        for (dependency in dependencies where dependency.moduleId == moduleId && dependency.kind == "std") {
            if (dependency.state == "conflict") { return None }
            if (!dependency.version.isEmpty()) {
                if (dependency.state != "verified" && dependency.state != "observed") { return None }
                if (found && selected != dependency.version) { return None }
                selected = dependency.version
                found = true
            }
        }
        if (!found) { return Some(defaultStandardLibraryDocsVersion()) }
        if (isValidStandardLibraryDocsVersion(selected) &&
            (hasBuiltInStandardLibraryDocsBase(selected) || request.standardLibraryDocsBaseUrl.isSome())) {
            return Some(selected)
        }
        None
    }


    private func scopeMatches(dependency: link_model.DependencyInstance,
        set: link_model.DocumentSetIdentity): Bool {
        set.audience == request.audience &&
            (set.target == dependency.target || set.target == "*") &&
            (set.cfg == dependency.cfg || set.cfg == "*")
    }

    private func resolve(moduleId: String, packageName: String, names: Array<String>, explicit!: Bool = false,
        typesOnly!: Bool = false, genericArity!: Int64 = -1, sourceAmbiguity!: Bool = false,
        sourceHeader!: String = ""): link_model.TypeNavigation {
        var localTarget: ?link_model.SymbolDoc = None
        var blocked = false
        for (name in names) {
            if (let Some(candidates) <- local.get(name)) {
                for (candidate in candidates where localAllowed(moduleId, candidate)) {
                    if (!work.take() || (!sourceHeader.isEmpty() && !work.consumeBytes(candidate.headerSpelling.size))) {
                        return link_model.TypeNavigation("unavailable", "none", "navigation matching work budget exceeded")
                    }
                    if (typesOnly && !["class", "struct", "enum", "interface", "typeAlias"].contains(candidate.kind)) { continue }
                    if (typesOnly && genericArity >= 0 && candidate.genericParameters.size != genericArity) { continue }
                    if (!visible(candidate)) { blocked = true; continue }
                    if (!sourceHeader.isEmpty() && candidate.headerSpelling != sourceHeader) { continue }
                    if (let Some(previous) <- localTarget) {
                        if (previous.id != candidate.id) {
                            return link_model.TypeNavigation("ambiguous", "none", "multiple authoritative local targets")
                        }
                    }
                    localTarget = Some(candidate)
                }
            }
        }
        if (let Some(target) <- localTarget) {
            if (sourceAmbiguity && (target.moduleId != moduleId || target.packageName != packageName)) {
                return link_model.TypeNavigation("unavailable", "none", "source imports cannot exclude an implicit std.core conflict; qualify the type or use a canonical provider")
            }
            return link_model.TypeNavigation("resolved", "exact", "authoritative target in selected module dependency context",
                symbolKey: target.id, url: semanticLinkLocalUrl(target.id))
        }
        if (blocked) { return link_model.TypeNavigation("unavailable", "none", "target excluded by documentation audience") }
        if (sourceAmbiguity) {
            return link_model.TypeNavigation("unavailable", "none", "source imports cannot exclude an implicit std.core conflict; qualify the type or use a canonical provider")
        }
        var selected: ?(ExternalDocResolver, ExternalDocEntry, ?link_model.DependencyInstance) = None
        var best: Int64 = -9223372036854775807
        var ambiguous = false
        var reason = if (sourceHeader.isEmpty()) { "no documentation symbol in the selected module dependency context" }
            else { "no matching source-header witness for this exact guide selector" }
        var matchLevel = "none"
        for (name in names) {
            let candidates = match (external.get(name)) {
                case Some(values) => values
                case None => continue
            }
            for ((resolver, entry) in candidates) {
                let set = entry.documentSet
                if (!work.take() || !work.consumeBytes(entry.symbolKey.size + entry.name.size + entry.url.size +
                    set.identity.size + set.moduleId.size + set.library.size + set.target.size + set.cfg.size + set.language.size +
                    if (sourceHeader.isEmpty()) { 0 } else { entry.sourceHeader.size })) {
                    return link_model.TypeNavigation("unavailable", "none", "navigation matching work budget exceeded")
                }
                if (typesOnly && !["class", "struct", "enum", "interface", "typeAlias"].contains(entry.kind)) { continue }
                if (typesOnly && genericArity >= 0 && entry.genericArity != genericArity) { continue }
                if (!sourceHeader.isEmpty() && entry.sourceHeader != sourceHeader) { continue }
                let dependency = dependencyFor(moduleId, set.library)
                var level = "manual"
                if (let Some(dependency) <- dependency) {
                    if (!work.consumeBytes(dependency.identity.size + dependency.target.size + dependency.cfg.size)) {
                        return link_model.TypeNavigation("unavailable", "none", "navigation matching work budget exceeded")
                    }
                    if (dependency.state == "unknown" || dependency.state == "conflict" || dependency.identity.isEmpty()) {
                        reason = "selected dependency identity is unknown or conflicts with build inputs"; continue
                    }
                    if (!dependency.componentModuleId.isEmpty() && authoritativeModules.contains(dependency.componentModuleId)) {
                        reason = "authoritative documented module has no visible target; external fallback is suppressed"; continue
                    }
                    if (!dependency.componentModuleId.isEmpty() && actualGraph.context(dependency.componentModuleId, work).conflicted) {
                        reason = "selected source dependency graph contains conflicting build inputs"; continue
                    }
                    let instanceMapping = request.linkCompatible && resolver.compatibilityMappings.get(
                        dependencyCompatibilityKey(dependency.instanceId, dependency.target, dependency.cfg)) == Some(set.identity)
                    var compatible = false
                    if (dependency.identity != set.identity) {
                        compatible = instanceMapping || (request.linkCompatible &&
                            resolver.compatibilityMappings.get(dependencyCompatibilityKey(dependency.identity, dependency.target, dependency.cfg)) == Some(set.identity))
                        if (!compatible) { reason = "API identity mismatch; no latest or neighbouring-version fallback"; continue }
                    }
                    if (set.audience != request.audience || (!scopeMatches(dependency, set) && !compatible)) {
                        reason = "document coverage does not match target, cfg or audience"; continue
                    }
                    var binding = "unavailable"
                    if (dependency.identity == set.identity) {
                        if (let Some(publishedGraph) <- resolver.sourceGraph) {
                            binding = publishedGraph.binding(actualGraph, dependency.componentModuleId, set.moduleId, work)
                        }
                        if (binding == "conflict") { reason = "published or selected dependency graph contains conflicting build inputs"; continue }
                        if (binding == "mismatch") {
                            if (!instanceMapping) { reason = "source bytes match but selected transitive dependency/build context differs"; continue }
                            compatible = true
                        }
                    }
                    level = if (compatible) { "compatible" } else if (resolver.inventoryPinned && binding == "matched" &&
                        (dependency.state == "observed" || dependency.state == "verified") && set.state == "declared") { "exact" } else { "manual" }
                } else {
                    if (dependenciesByName.contains(moduleId + "|" + set.library)) {
                        reason = "multiple selected dependency components share this package scope"; continue
                    }
                    if (!explicit || typesOnly) { reason = "documented library is not a selected dependency of this module"; continue }
                    if (set.audience != request.audience) { reason = "documentation-only reference has a different audience"; continue }
                }
                var score = resolver.priority * 4 + match (level) {
                    case "exact" => 300000
                    case "compatible" => 200000
                    case _ => 100000
                }
                if (!request.linkLanguage.isEmpty()) {
                    // 10000 exceeds the full priority span (8000); together they stay below the smallest level gap (100000).
                    if (set.language == request.linkLanguage) { score += 10000 }
                    else if (!request.linkLanguageFallback) { reason = "selected API identity has no requested language"; continue }
                }
                if (score > best) {
                    best = score; selected = Some((resolver, entry, dependency)); ambiguous = false; matchLevel = level
                } else if (score == best) {
                    if (let Some((_, previous, previousDependency)) <- selected) {
                        let previousId = if (let Some(value) <- previousDependency) { value.instanceId } else { "" }
                        let selectedId = if (let Some(value) <- dependency) { value.instanceId } else { "" }
                        // Shared publication routes do not make distinct declarations or document sets the same target.
                        if (previous.symbolKey != entry.symbolKey || previous.documentSet.id != set.id ||
                            previous.url != entry.url || previous.documentSet.identity != set.identity ||
                            previousId != selectedId) { ambiguous = true }
                    }
                }
            }
        }
        if (ambiguous) { return link_model.TypeNavigation("ambiguous", "none", "conflicting equal-priority documentation targets") }
        if (let Some((resolver, entry, dependency)) <- selected) {
            let reason = decisionReason(entry.documentSet, matchLevel, dependency.isSome())
            if (reason.isEmpty()) { return link_model.TypeNavigation("unavailable", "none", "navigation metadata work budget exceeded") }
            return link_model.TypeNavigation("resolved", matchLevel, reason,
                dependencyInstanceId: if (let Some(value) <- dependency) { value.instanceId } else { "" }, documentSetId: entry.documentSet.id,
                indexIdentity: resolver.fingerprint, symbolKey: entry.symbolKey, url: entry.url,
                apiIdentity: entry.documentSet.identity, language: entry.documentSet.language)
        }
        if (explicit && sourceHeader.isEmpty()) {
            var url = ""
            for (resolver in resolvers where resolver.format == "cjdoc.symbol-index/1" && resolver.state == "available") {
                for (name in names) {
                    let (candidate, duplicate) = resolver.matchTarget(name)
                    if (duplicate || (!url.isEmpty() && !candidate.isEmpty() && url != candidate)) {
                        return link_model.TypeNavigation("ambiguous", "none", "ambiguous manual legacy documentation reference")
                    }
                    if (!candidate.isEmpty()) { url = candidate }
                }
            }
            if (!url.isEmpty()) {
                return link_model.TypeNavigation("resolved", "manual", "legacy /1 explicit reference has no dependency identity evidence", url: url)
            }
        }
        link_model.TypeNavigation("unresolved", "none", reason)
    }

    func resolveReference(owner: link_model.SymbolDoc, target: String, importScope!: Bool = true,
        preferredLocalId!: ?String = None): link_model.TypeNavigation {
        if (genericReference(owner, target)) {
            return link_model.TypeNavigation("unavailable", "none", "reference denotes a generic parameter in declaration scope")
        }
        if (let Some(id) <- preferredLocalId) {
            if (let Some(candidate) <- symbols.get(id)) {
                if (localAllowed(owner.moduleId, candidate)) { return resolveLocalReference(owner, id) }
            }
        }
        let opening = target.indexOf("(").getOrDefault({ => target.size })
        let base = target[..opening]
        let signature = target[opening..].replace(" ", "").replace("\t", "")
        let names = ArrayList<String>([target])
        if (importScope) {
            for (candidate in candidateNames(owner, base)) {
                let value = candidate + signature
                if (!names.contains(value)) { names.add(value) }
            }
        }
        referenceResult(owner, resolve(owner.moduleId, owner.packageName, names.toArray(), explicit: true))
    }

    // A page has a real module context, not a fabricated declaration. Guide
    // selectors retain their exact source-spelling contract from local binding.
    func resolvePageReference(moduleId: String, target: String, selector: String,
        source: String, line: Int64, preferredLocalId!: ?String = None): link_model.TypeNavigation {
        if (moduleId.isEmpty()) {
            return link_model.TypeNavigation("unavailable", "none", "guide has no unambiguous documented module context")
        }
        let header = if (selector.startsWith("signature:")) { selector.removePrefix("signature:") } else { "" }
        if ((selector.startsWith("signature:") && header.isEmpty()) ||
            !work.consumeBytes(target.size + header.size + moduleId.size)) {
            return link_model.TypeNavigation("unavailable", "none", "guide selector is empty or exceeds navigation work budget")
        }
        let names = ArrayList<String>([target])
        if (target.startsWith("id:")) { names.add(target.removePrefix("id:")) }
        if (let Some(id) <- preferredLocalId) {
            if (let Some(symbol) <- symbols.get(id)) {
                if (localAllowed(moduleId, symbol) && (header.isEmpty() || symbol.headerSpelling == header)) {
                    if (!names.contains(symbol.id)) { names.add(symbol.id) }
                }
            }
        }
        let decision = resolve(moduleId, "", names.toArray(), explicit: true, sourceHeader: header)
        if (decision.state != "resolved" && decision.reason != "target excluded by documentation audience" &&
            diagnostics.size < 4096 && (!request.documentSources.isEmpty() || request.buildContext.isSome())) {
            let location = source + if (line > 0) { ":" + line.toString() } else { "" }
            diagnostics.add(link_model.Diagnostic(if (request.lintProfile == "strict") { "error" } else { "warning" },
                "CJDOC2311", "guide " + location + " in module " + moduleId + ": " + decision.reason))
        }
        decision
    }

    private func sameSourceShape(left: DependencyTypeShape, right: DependencyTypeShape): Bool {
        if (left.kind != right.kind || left.head != right.head || left.nullable != right.nullable ||
            left.children.size != right.children.size) { return false }
        for (index in 0..left.children.size) {
            if (!sameSourceShape(left.children[index], right.children[index])) { return false }
        }
        true
    }

    private func unboundStructure(typeRef: link_model.TypeRef, depth: Int64): link_model.TypeRef {
        if (depth >= link_model.DOC_IR_MAX_TYPE_DEPTH) { return typeRef }
        let arguments = ArrayList<link_model.TypeRef>()
        for (child in typeRef.arguments) { arguments.add(unboundStructure(child, depth + 1)) }
        link_model.TypeRef(typeRef.kind, typeRef.spelling, typeRef.semantic, nullable: typeRef.nullable,
            arguments: arguments.toArray(), navigation: Some(link_model.TypeNavigation("unavailable", "none",
                "source and provider structured type roles could not be correlated")))
    }

    func bindType(owner: link_model.SymbolDoc, typeRef: link_model.TypeRef,
        depth!: Int64 = 0, sourceShape!: ?DependencyTypeShape = None): link_model.TypeRef {
        if (depth >= link_model.DOC_IR_MAX_TYPE_DEPTH) { return typeRef }
        let shape = if (sourceShape.isSome()) { sourceShape } else { cachedTypeShape(typeRef.spelling) }
        if (shape.isNone()) {
            return link_model.TypeRef(typeRef.kind, typeRef.spelling, typeRef.semantic, nullable: typeRef.nullable,
                arguments: typeRef.arguments.toArray(), navigation: Some(link_model.TypeNavigation("unavailable", "none", "unsupported source type structure")))
        }
        let value = shape.getOrThrow()
        if (!typeRef.arguments.isEmpty()) {
            var aligned = typeRef.arguments.size == value.children.size
            if (aligned) {
                for (position in 0..typeRef.arguments.size) {
                    let actual = cachedTypeShape(typeRef.arguments[position].spelling)
                    if (actual.isNone() || !sameSourceShape(actual.getOrThrow(), value.children[position])) {
                        aligned = false; break
                    }
                }
            }
            if (!aligned) { return unboundStructure(typeRef, depth) }
        }
        let arguments = ArrayList<link_model.TypeRef>()
        var index: Int64 = 0
        for (child in value.children) {
            if (index < typeRef.arguments.size) {
                // Preserve the complete provider subtree, not merely its head
                // semantic record: nested generic grandchildren are evidence.
                arguments.add(bindType(owner, typeRef.arguments[index], depth: depth + 1, sourceShape: Some(child)))
            } else {
                arguments.add(bindType(owner, link_model.TypeRef(child.kind, child.spelling,
                    if (typeRef.semantic.provider.isSome()) {
                        link_model.SemanticType("partial", provider: typeRef.semantic.provider)
                    } else { link_model.SemanticType("unavailable") },
                    nullable: child.nullable), depth: depth + 1, sourceShape: Some(child)))
            }
            index++
        }
        let parameter = scopedGenericParameter(owner, value.head, symbols)
        let provider = typeRef.semantic.provider.getOrDefault({ => "" })
        let canonical = typeRef.semantic.state == "resolved" && !provider.isEmpty() &&
            provider != "ast" && provider != "source" && typeRef.semantic.canonical.isSome()
        var decision: ?link_model.TypeNavigation = None
        if (!parameter && (value.kind == "named" || value.kind == "generic" || canonical)) {
            let names = ArrayList<String>(candidateNames(owner, value.head))
            if (canonical) {
                if (let Some(identity) <- typeRef.semantic.canonical) { names.clear(); names.add(identity) }
            }
            if (!canonical && value.head.startsWith("std.") && !names.contains(value.head)) {
                names.add(value.head)
            }
            let docsVersion = selectedStandardLibraryDocsVersion(owner.moduleId)
            var sourceAmbiguity = false
            var standardImportAmbiguity = false
            if (!canonical && !value.head.contains(".")) {
                let sourceKey = owner.moduleId + "|" + owner.source.path
                let key = sourceKey + "|" + value.head
                let implicitCoreName = "std.core." + value.head
                if (let Some(imports) <- importCandidates.get(key)) {
                    sourceAmbiguity = imports.size > 1 && imports.contains(implicitCoreName)
                    if (sourceAmbiguity) {
                        standardImportAmbiguity = standardImportDisambiguatesCoreTarget(imports,
                            implicitCoreName, docsVersion.getOrDefault({ => "" }),
                            sourceKey, value.head)
                    }
                }
            }
            var navigation = resolve(owner.moduleId, owner.packageName, names.toArray(),
                typesOnly: true, sourceAmbiguity: sourceAmbiguity && !standardImportAmbiguity,
                genericArity: value.children.size)
            // Only scoped resolution may suppress the fallback; unrelated inventory
            // entries and declarations rejected by arity are not binding evidence.
            if (navigation.state == "unresolved") {
                if (let Some(version) <- docsVersion) {
                    if (let Some(pinned) <- standardLibraryTypeNavigation(version, names.toArray(),
                        baseUrlOverride: request.standardLibraryDocsBaseUrl)) {
                        navigation = pinned
                    }
                }
            }
            decision = Some(navigation)
            if (navigation.state != "resolved" && diagnostics.size < 4096 && visible(owner) &&
                (!request.documentSources.isEmpty() || request.buildContext.isSome())) {
                diagnostics.add(link_model.Diagnostic(if (request.lintProfile == "strict") { "error" } else { "warning" },
                    "CJDOC2310", "type '" + value.head + "': " + navigation.reason,
                    source: Some(owner.source), symbolId: Some(owner.id)))
            }
        } else if (!parameter && value.kind == "primitive") {
            if (let Some(version) <- selectedStandardLibraryDocsVersion(owner.moduleId)) {
                decision = standardLibraryTypeNavigation(version, ["std.core." + value.head],
                    baseUrlOverride: request.standardLibraryDocsBaseUrl)
            }
        }
        let kind = if (parameter) { "typeParameter" } else if (["primitive", "optional", "tuple", "function"].contains(value.kind)) { value.kind } else { typeRef.kind }
        link_model.TypeRef(kind, typeRef.spelling, typeRef.semantic, nullable: typeRef.nullable || value.nullable,
            arguments: arguments.toArray(), navigation: decision)
    }
}
