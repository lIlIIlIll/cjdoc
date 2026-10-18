package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func navigationCodecFixture(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:navigation-codec"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Anavigation-codec::fixture::function:api#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 30, 29))
    let navigation = TypeNavigation("resolved", "manual", "explicit reference with declared, unverified correspondence",
        dependencyInstanceId: "dependency-one", documentSetId: "docs-one", indexIdentity: "index-content",
        symbolKey: "support.Box|class|1()", url: "https://docs.example.test/box.html",
        apiIdentity: "source-content", language: "en")
    let metadata = MarkdownNodeMetadata.forSemanticLink("support.Box", "unresolved",
        semanticNavigation: Some(navigation))
    let markdown = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [
        MarkdownNode("semantic_link", metadata, children: [MarkdownNode("text", literal: "Box")])])])
    let text = DocumentationText(symbolId + ":doc:see:support.Box", "see", "support.Box", Some("en"), "Box", markdown,
        navigation: Some(navigation))
    let comment = DocComment("Box", "Box", "", markdown,
        tags: [DocTag("see", "support.Box", "Box", navigation: Some(navigation))],
        defaultLanguage: Some("en"), localizedTexts: [text])
    let typeRef = TypeRef("source", "Box", SemanticType("unavailable"), navigation: Some(navigation),
        arguments: [TypeRef("source", "Unknown", SemanticType("unavailable"),
            navigation: Some(TypeNavigation("unavailable", "none", "dependency identity is unknown")))])
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Box", SemanticInfo("partial", "ast"),
        returnType: Some(typeRef), documentation: Some(comment))
    DocumentationSet(GeneratorInfo("cjdoc", "test", toolchain: "test-parser-toolchain"), "complete", ProjectInfo("navigation-codec"),
        ConfigurationSnapshot(lintProfile: "off"),
        apiCollectionState: Some("partial"),
        documentationRevision: "docs-publication",
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "navigation-codec", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol],
        dependencies: [DependencyInstance(moduleId, "navigation-codec", "self-one", "source",
            "source-content", "observed", "source snapshot bytes", componentModuleId: moduleId,
                version: "api-package-declared", revision: "api-source-ref"),
            DependencyInstance(moduleId, "support", "dependency-one", "binary", "binary-content",
                "declared", "manifest dependency", version: "1.2", revision: "release", target: "example-target", cfg: "default")],
        documentSets: [DocumentSetIdentity("docs-one", "support", "source-content", "declared", "portable-index",
            target: "example-target", cfg: "default", language: "en", revision: "release",
            indexIdentity: "index-content", baseUrl: "https://docs.example.test/", moduleId: "cjdoc:module:v1:producer-support",
            apiVersion: "support-api-declared", documentationRevision: "support-doc-revision")])
}

private func pageNavigationCodecFixture(navigation!: ?TypeNavigation = None): DocumentationSet {
    let binding = DocumentationPageBinding("support.Box", "example", "authored", "docs-label", 7,
        navigation: navigation)
    let page = DocumentationPage("binding-codec", "docs/binding.md", "concepts/binding.html", "Guide", "guide", "Guide",
        MarkdownNode("document"), bindings: [binding])
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("page-navigation-codec"),
        ConfigurationSnapshot(lintProfile: "off"), pages: [page])
}

private func navigationEvidenceCodecFixture(): DocumentationSet {
    let navigation = TypeNavigation("resolved", "exact", "selected dependency documentation",
        dependencyInstanceId: "dependency-evidence", documentSetId: "docs-evidence",
        apiIdentity: "api-evidence", language: "en", indexIdentity: "index-evidence",
        url: "https://docs.example.test/evidence.html")
    let page = DocumentationPage("evidence", "docs/evidence.md", "concepts/evidence.html",
        "Evidence", "guide", "", MarkdownNode("document"),
        bindings: [DocumentationPageBinding("support.Box", "example", "authored", "", 1,
            navigation: Some(navigation))])
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("navigation-evidence"),
        ConfigurationSnapshot(lintProfile: "off"), pages: [page],
        dependencies: [DependencyInstance("cjdoc:module:v1:evidence", "support",
            "dependency-evidence", "source", "api-evidence", "observed", "selected source")],
        documentSets: [DocumentSetIdentity("docs-evidence", "support", "api-evidence",
            "declared", "portable-index", language: "en", indexIdentity: "index-evidence")])
}

private func replaceFirstNavigationEvidenceField(encoded: String, field: String, original: String): String {
    let marker = "\"${field}\": \"${original}\""
    let position = encoded.indexOf(marker).getOrThrow()
    encoded[..position] + "\"${field}\": \"different-value\"" + encoded[position + marker.size..]
}

private func ownedExactNavigationCodecDocument(): String {
    let fixture = navigationCodecFixture()
    let moduleId = fixture.modules[0].id
    let navigation = TypeNavigation("resolved", "manual", "selected dependency documentation",
        dependencyInstanceId: "dependency-one", documentSetId: "docs-one",
        apiIdentity: "source-content", language: "en", indexIdentity: "index-content",
        url: "https://docs.example.test/evidence.html")
    let document = DocumentationSet(fixture.generator, "complete", fixture.project, fixture.configuration,
        providers: fixture.providers.toArray(), modules: fixture.modules.toArray(), packages: fixture.packages.toArray(),
        files: fixture.files.toArray(), declarations: fixture.declarations.toArray(),
        dependencies: [
            DependencyInstance(moduleId, "support", "dependency-one", "binary",
                "source-content", "observed", "selected dependency bytes"),
            DependencyInstance("cjdoc:module:v1:unrelated", "support", "dependency-other", "binary",
                "source-content", "observed", "unrelated module dependency bytes")],
        documentSets: fixture.documentSets.toArray(),
        pages: pageNavigationCodecFixture(navigation: Some(navigation)).pages.toArray())
    encodeDocIr(document).replace("\"matchLevel\": \"manual\"", "\"matchLevel\": \"exact\"")
}

// Contract-unit input uses the actual v14 eight-field binding shape, not a v15 downgrade.
private let LEGACY14_PAGE_BINDING_CONTRACT = """
{"id":"legacy14-binding-contract","source":"docs/binding.md","route":"concepts/legacy14-binding.html","title":"Legacy binding contract","kind":"guide","packageName":"","language":null,"defaultLanguage":null,"text":"Guide","markdown":{"kind":"document","literal":"","source":null,"metadata":null,"children":[]},"sections":[],"targetSymbolIds":[],"bindings":[{"target":"support.Box","selector":"example","provenance":"authored","version":"docs-label","sourceLine":7,"language":"markdown","state":"unresolved","targetSymbolId":null}]}
"""

@Test
class ModelCodecV15Contracts {
    @TestCase
    func externalExactNavigationRejectsEmptyApiIdentity(): Unit {
        let encoded = ownedExactNavigationCodecDocument()
        let corrupted = encoded.replace("\"apiIdentity\": \"source-content\"", "\"apiIdentity\": \"\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.apiIdentity"))
        for (level in ["compatible", "manual"]) {
            let allowed = corrupted.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
            @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
        }
    }

    @TestCase
    func externalExactNavigationRejectsEmptyIndexIdentity(): Unit {
        let encoded = ownedExactNavigationCodecDocument()
        let marker = "\"indexIdentity\": \"index-content\""
        let position = encoded.indexOf(marker).getOrThrow()
        let corrupted = encoded[..position] + "\"indexIdentity\": \"\"" + encoded[position + marker.size..]
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.indexIdentity"))
        for (level in ["compatible", "manual"]) {
            let allowed = corrupted.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
            @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
        }
    }

    @TestCase
    func externalExactNavigationRejectsDifferentIndexIdentity(): Unit {
        let encoded = ownedExactNavigationCodecDocument()
        let mismatched = replaceFirstNavigationEvidenceField(encoded, "indexIdentity", "index-content")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(mismatched))
        @Expect(error.message.contains(".navigation.indexIdentity"))
    }

    @TestCase
    func externalExactNavigationBindsDependencyOwnerAtEveryOccurrence(): Unit {
        let encoded = ownedExactNavigationCodecDocument()
        let marker = "\"dependencyInstanceId\": \"dependency-one\""
        let parts = encoded.split(marker)
        @Expect(parts.size, 7)
        let paths = HashSet<String>()
        for (occurrence in 1..parts.size) {
            let corrupted = StringBuilder()
            corrupted.append(parts[0])
            for (position in 1..parts.size) {
                corrupted.append(if (position == occurrence) {
                    "\"dependencyInstanceId\": \"dependency-other\""
                } else { marker })
                corrupted.append(parts[position])
            }
            let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted.toString()))
            @Expect(error.message.contains("owning module"))
            for (path in [".returnType.navigation.dependencyInstanceId",
                ".metadata.semanticNavigation.dependencyInstanceId",
                ".localizedTexts.navigation.dependencyInstanceId", ".tags.navigation.dependencyInstanceId",
                ".pages.bindings.navigation.dependencyInstanceId"]) {
                if (error.message.contains(path)) { let _ = paths.add(path) }
            }
            for (level in ["compatible", "manual"]) {
                let allowed = corrupted.toString().replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
                @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
            }
        }
        @Expect(paths.size, 5)
    }

    @TestCase
    func fullyEvidencedExternalExactNavigationStillRoundTrips(): Unit {
        let encoded = ownedExactNavigationCodecDocument()
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        @Expect(decodeDocIr(encoded).pages[0].bindings[0].navigation.getOrThrow().matchLevel, "exact")
    }

    @TestCase
    func exactNavigationRejectsBothMissingEvidenceReferences(): Unit {
        let encoded = encodeDocIr(pageNavigationCodecFixture(navigation: Some(TypeNavigation(
            "resolved", "manual", "explicit reference", symbolKey: "support.Box|class|1()",
            url: "https://docs.example.test/Box.html"))))
        let corrupted = encoded.replace("\"matchLevel\": \"manual\"", "\"matchLevel\": \"exact\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.documentSetId"))
    }

    @TestCase
    func exactNavigationRejectsMissingDependencyReference(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let corrupted = encoded.replace("\"dependencyInstanceId\": \"dependency-evidence\"",
            "\"dependencyInstanceId\": \"\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.dependencyInstanceId"))
    }

    @TestCase
    func exactNavigationRejectsMissingDocumentSetReference(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let corrupted = encoded.replace("\"documentSetId\": \"docs-evidence\"",
            "\"documentSetId\": \"\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.documentSetId"))
    }

    @TestCase
    func compatibleAndManualNavigationKeepOptionalEvidenceReferences(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        for (level in ["compatible", "manual"]) {
            let allowed = encoded.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
            let noDependency = allowed.replace("\"dependencyInstanceId\": \"dependency-evidence\"",
                "\"dependencyInstanceId\": \"\"")
            let noDocuments = allowed.replace("\"documentSetId\": \"docs-evidence\"", "\"documentSetId\": \"\"")
            let neither = noDependency.replace("\"documentSetId\": \"docs-evidence\"", "\"documentSetId\": \"\"")
            for (document in [noDependency, noDocuments, neither]) {
                @Expect(encodeDocIr(decodeDocIr(document)), document)
            }
        }
    }

    @TestCase
    func localExactNavigationRequiresAnExistingSymbolAndItsLocalRoute(): Unit {
        let fixture = navigationCodecFixture()
        let target = fixture.declarations[0]
        let navigation = TypeNavigation("resolved", "exact", "authoritative local source target",
            symbolKey: target.id, url: symbolPagePath(target))
        let document = DocumentationSet(fixture.generator, "complete", fixture.project, fixture.configuration,
            providers: fixture.providers.toArray(), modules: fixture.modules.toArray(), packages: fixture.packages.toArray(),
            files: fixture.files.toArray(), declarations: fixture.declarations.toArray(),
            dependencies: fixture.dependencies.toArray(), documentSets: fixture.documentSets.toArray(),
            pages: pageNavigationCodecFixture(navigation: Some(navigation)).pages.toArray())
        let encoded = encodeDocIr(document)
        let restored = decodeDocIr(encoded).pages[0].bindings[0].navigation.getOrThrow()
        @Expect(restored.matchLevel, "exact")
        @Expect(restored.dependencyInstanceId, "")
        @Expect(restored.documentSetId, "")
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        let external = encoded.replace("\"url\": \"${navigation.url}\"",
            "\"url\": \"https://docs.example.test/pretend-local.html\"")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(external))
        let absent = encoded.replace("\"symbolKey\": \"${target.id}\"",
            "\"symbolKey\": \"cjdoc:v2:absent\"")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(absent))
    }

    @TestCase
    func exactNavigationRejectsInadmissibleDependencyStates(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        for (state in ["conflict", "unknown", "declared"]) {
            let corrupted = encoded.replace("\"state\": \"observed\"", "\"state\": \"${state}\"")
            @Expect(corrupted != encoded)
            @ExpectThrows[IllegalArgumentException](decodeDocIr(corrupted))
            for (level in ["compatible", "manual"]) {
                let allowed = corrupted.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
                @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
            }
        }
    }

    @TestCase
    func exactNavigationRejectsUndeclaredDocumentSetStates(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        for (state in ["observed", "verified", "unknown"]) {
            let corrupted = encoded.replace("\"state\": \"declared\"", "\"state\": \"${state}\"")
            @Expect(corrupted != encoded)
            @ExpectThrows[IllegalArgumentException](decodeDocIr(corrupted))
            for (level in ["compatible", "manual"]) {
                let allowed = corrupted.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
                @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
            }
        }
    }

    @TestCase
    func dependencyInstanceIdsMustBeUniqueAcrossModules(): Unit {
        let document = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("duplicate-instance"),
            ConfigurationSnapshot(lintProfile: "off"),
            dependencies: [
                DependencyInstance("cjdoc:module:v1:first", "support", "first-instance",
                    "source", "first-api", "observed", "selected source"),
                DependencyInstance("cjdoc:module:v1:second", "support", "second-instance",
                    "source", "second-api", "verified", "selected source")])
        let encoded = encodeDocIr(document)
        let corrupted = encoded.replace("\"instanceId\": \"second-instance\"", "\"instanceId\": \"first-instance\"")
        @Expect(corrupted != encoded)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(corrupted))
    }

    @TestCase
    func exactNavigationAcceptsObservedAndVerifiedDependenciesWithDeclaredDocumentSet(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        for (state in ["observed", "verified"]) {
            let admissible = encoded.replace("\"state\": \"observed\"", "\"state\": \"${state}\"")
            let restored = decodeDocIr(admissible)
            @Expect(restored.dependencies[0].state, state)
            @Expect(restored.documentSets[0].state, "declared")
            @Expect(restored.pages[0].bindings[0].navigation.getOrThrow().matchLevel, "exact")
            @Expect(encodeDocIr(restored), admissible)
        }
    }

    @TestCase
    func navigationRejectsDanglingDocumentSetEvidence(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let corrupted = encoded.replace("\"documentSetId\": \"docs-evidence\"",
            "\"documentSetId\": \"missing-documents\"")
        @Expect(corrupted != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.documentSetId"))
        @Expect(error.message.contains("documentSets"))
    }

    @TestCase
    func navigationRejectsDanglingDependencyInstanceEvidence(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let corrupted = encoded.replace("\"dependencyInstanceId\": \"dependency-evidence\"",
            "\"dependencyInstanceId\": \"missing-dependency\"")
        @Expect(corrupted != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.dependencyInstanceId"))
        @Expect(error.message.contains("dependencies"))
    }

    @TestCase
    func navigationRejectsMismatchedDocumentSetApiEvidence(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let corrupted = encoded.replace("\"apiIdentity\": \"api-evidence\"",
            "\"apiIdentity\": \"different-api\"")
        @Expect(corrupted != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
        @Expect(error.message.contains(".navigation.apiIdentity"))
        @Expect(error.message.contains("documentSets"))
    }

    @TestCase
    func navigationEvidenceIsCheckedAtEveryEncodedOccurrence(): Unit {
        let encoded = encodeDocIr(navigationCodecFixture())
        let marker = "\"apiIdentity\": \"source-content\""
        let parts = encoded.split(marker)
        @Expect(parts.size, 6)
        let paths = HashSet<String>()
        for (occurrence in 1..parts.size) {
            let corrupted = StringBuilder()
            corrupted.append(parts[0])
            for (position in 1..parts.size) {
                corrupted.append(if (position == occurrence) {
                    "\"apiIdentity\": \"different-api\""
                } else { marker })
                corrupted.append(parts[position])
            }
            let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted.toString()))
            @Expect(error.message.contains("documentSets"))
            for (path in [".returnType.navigation.apiIdentity",
                ".metadata.semanticNavigation.apiIdentity",
                ".localizedTexts.navigation.apiIdentity", ".tags.navigation.apiIdentity"]) {
                if (error.message.contains(path)) { let _ = paths.add(path) }
            }
        }
        @Expect(paths.size, 4)
    }

    @TestCase
    func navigationEvidenceRejectsMismatchedLanguageIndexAndExactDependency(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        for ((field, original) in [("language", "en"), ("indexIdentity", "index-evidence")]) {
            let corrupted = replaceFirstNavigationEvidenceField(encoded, field, original)
            let error = @AssertThrows[IllegalArgumentException](decodeDocIr(corrupted))
            @Expect(error.message.contains(".navigation." + field))
        }
        let wrongDependency = replaceFirstNavigationEvidenceField(encoded, "identity", "api-evidence")
        @Expect(wrongDependency != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(wrongDependency))
        @Expect(error.message.contains(".navigation.apiIdentity"))
        @Expect(error.message.contains("dependencies"))
        for (level in ["compatible", "manual"]) {
            let allowed = wrongDependency.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"${level}\"")
            @Expect(encodeDocIr(decodeDocIr(allowed)), allowed)
        }
    }

    @TestCase
    func manualNavigationMayKeepUnverifiedDocumentSetWithoutARecord(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let manual = encoded.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"manual\"")
        let missingDocuments = manual.replace("\"documentSetId\": \"docs-evidence\"",
            "\"documentSetId\": \"uncaptured-documents\"")
        let restored = decodeDocIr(missingDocuments)
        @Expect(restored.pages[0].bindings[0].navigation.getOrThrow().documentSetId, "uncaptured-documents")
        @Expect(encodeDocIr(restored), missingDocuments)
        let missingDependency = missingDocuments.replace("\"dependencyInstanceId\": \"dependency-evidence\"",
            "\"dependencyInstanceId\": \"missing-dependency\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(missingDependency))
        @Expect(error.message.contains(".navigation.dependencyInstanceId"))
    }

    @TestCase
    func manualNavigationStillMustAgreeWithACapturedDocumentSet(): Unit {
        let encoded = encodeDocIr(navigationEvidenceCodecFixture())
        let manual = encoded.replace("\"matchLevel\": \"exact\"", "\"matchLevel\": \"manual\"")
        let mismatched = manual.replace("\"apiIdentity\": \"api-evidence\"", "\"apiIdentity\": \"different-api\"")
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(mismatched))
        @Expect(error.message.contains(".navigation.apiIdentity"))
        @Expect(error.message.contains("documentSets"))
    }

    @TestCase
    func existingGoldenDocumentsAndFrozenMigrationsKeepRoundTripping(): Unit {
        for (directory in ["golden-v6", "golden-v7", "golden-v8", "golden-v9", "golden-v10",
            "golden-v11", "golden-v12", "golden-v13", "golden-v14", "golden-v15", "legacy13", "legacy14"]) {
            for (fixture in ["basic", "conditional-linux", "extend", "functions", "path-dependencies",
                "source-edges", "types", "unsupported", "workspace"]) {
                let frozen = String.fromUtf8(File.readFrom(Path("tests/fixtures/${directory}/${fixture}.docs.json")))
                let encoded = encodeDocIr(decodeDocIr(frozen))
                @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
            }
        }
    }

    @TestCase
    func flatTypeSemanticFactsRemainCompleteAndIndependentOfNavigation(): Unit {
        for (semantic in [SemanticType("resolved", canonical: Some("fixture.类型"), provider: Some("types")),
            SemanticType("partial", canonical: Some("fixture.类型"), provider: Some("types")),
            SemanticType("partial", provider: Some("types")), SemanticType("ambiguous", provider: Some("types")),
            SemanticType("unavailable")]) {
            let child = TypeRef("named", "Child", semantic)
            let outer = TypeRef("generic", "Outer<Child>", SemanticType("unavailable"),
                arguments: [child], navigation: Some(TypeNavigation("resolved", "manual",
                    "Explicit navigation does not promote type semantics", url: "https://docs.example.test/Outer.html")))
            let encoded = encodeDocIr(codecTypeDocument(outer, canonicalTypes: true))
            let wire = JsonNode.parse(encoded).asObject().get("declarations").getOrThrow()
                .asArray().get(0).getOrThrow().asObject().get("returnType").getOrThrow().asObject()
            @Expect(wire.get("semantic").isNone())
            @Expect(wire.get("semanticState").getOrThrow().asString(), "unavailable")
            @Expect(wire.get("semanticCanonical").getOrThrow().isNull)
            @Expect(wire.get("semanticProvider").getOrThrow().isNull)
            let stored = decodeDocIr(encoded).declarations[0].returnType.getOrThrow()
            @Expect(stored.semantic.state, "unavailable")
            @Expect(stored.navigation.getOrThrow().state, "resolved")
            @Expect(stored.arguments[0].semantic.state, semantic.state)
            @Expect(stored.arguments[0].semantic.canonical, semantic.canonical)
            @Expect(stored.arguments[0].semantic.provider, semantic.provider)
            @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
            @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace(
                "\"semanticState\": \"unavailable\"", "\"semanticState\": 42")))
            @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace(
                "\"semanticCanonical\": null", "\"semanticCanonical\": 42")))
            @ExpectThrows[JsonException](decodeDocIr(encoded.replace(
                "\"semanticProvider\":", "\"semanticProvider\":null,\"semanticProvider\":")))
            @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace(
                "\"semanticState\": \"unavailable\"",
                "\"semantic\": {\"state\":\"unavailable\",\"canonical\":null,\"provider\":null}")))
        }
    }

    @TestCase
    func contextFreeNavigationFailuresUseStrictTwoValueWireAndKeepPublicFacts(): Unit {
        let reason = "中文\n\t\"quoted\"\\tail" + String.fromUtf8([0u8])
        for (state in ["unresolved", "ambiguous", "unavailable"]) {
            let value = TypeNavigation(state, "none", reason)
            let encoded = encodeDocIr(pageNavigationCodecFixture(navigation: Some(value)))
            let decoded = decodeDocIr(encoded)
            let restored = decoded.pages[0].bindings[0].navigation.getOrThrow()
            @Expect(restored.state, state)
            @Expect(restored.matchLevel, "none")
            @Expect(restored.reason, reason)
            @Expect(restored.dependencyInstanceId, "")
            @Expect(restored.documentSetId, "")
            @Expect(restored.indexIdentity, "")
            @Expect(restored.symbolKey, "")
            @Expect(restored.url, "")
            @Expect(restored.apiIdentity, "")
            @Expect(restored.language, "")
            @Expect(encodeDocIr(decoded), encoded)
            let compact = StringBuilder()
            appendNavigationDecision(compact, restored)
            let tuple = JsonNode.parse(compact.toString()).asArray()
            @Expect(tuple.size(), 2)
            @Expect(tuple.get(0).getOrThrow().asString(), state)
            @Expect(tuple.get(1).getOrThrow().asString(), reason)
        }
        let good = encodeDocIr(pageNavigationCodecFixture(
            navigation: Some(TypeNavigation("unavailable", "none", "TupleOnlyReason"))))
        for (replacement in ["42", "\"\"", "\"TupleOnlyReason\", \"extra\""]) {
            @ExpectThrows[IllegalArgumentException](decodeDocIr(good.replace("\"TupleOnlyReason\"", replacement)))
        }
        @ExpectThrows[IllegalArgumentException](decodeDocIr(good.replace("\"unavailable\"", "\"resolved\"")))
        for (invalid in ["[]", "[\"unavailable\"]", "[\"resolved\",\"reason\"]", "[\"unknown\",\"reason\"]",
            "[\"unavailable\",false]", "[1,\"reason\"]", "[\"unavailable\",\"reason\",\"extra\"]"]) {
            @ExpectThrows[IllegalArgumentException](decodeNavigationDecision(JsonNode.parse(invalid), "$"))
        }
    }

    @TestCase
    func contextualNavigationNeverLosesAnyIdentityOrMatchLevelToCompactWire(): Unit {
        let values = [
            TypeNavigation("unavailable", "none", "context", dependencyInstanceId: "dependency"),
            TypeNavigation("unavailable", "none", "context", documentSetId: "documents"),
            TypeNavigation("unavailable", "none", "context", indexIdentity: "index"),
            TypeNavigation("unavailable", "none", "context", symbolKey: "symbol"),
            TypeNavigation("unavailable", "none", "context", apiIdentity: "api"),
            TypeNavigation("unavailable", "none", "context", language: "en"),
            TypeNavigation("unavailable", "manual", "manual reference without a target")
        ]
        for (value in values) {
            let compact = StringBuilder()
            appendNavigationDecision(compact, value)
            @Expect(JsonNode.parse(compact.toString()).kind(), JsonKind.Object)
            let restored = decodeNavigationDecision(JsonNode.parse(compact.toString()), "$")
            @Expect(restored.matchLevel, value.matchLevel)
            @Expect(restored.dependencyInstanceId, value.dependencyInstanceId)
            @Expect(restored.documentSetId, value.documentSetId)
            @Expect(restored.indexIdentity, value.indexIdentity)
            @Expect(restored.symbolKey, value.symbolKey)
            @Expect(restored.apiIdentity, value.apiIdentity)
            @Expect(restored.language, value.language)
            let encoded = encodeDocIr(pageNavigationCodecFixture(navigation: Some(value)))
            @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        }
        let noncanonical = "{\"state\":\"unavailable\",\"matchLevel\":\"none\",\"reason\":\"explanation\"," +
            "\"dependencyInstanceId\":\"\",\"documentSetId\":\"\",\"indexIdentity\":\"\",\"symbolKey\":\"\"," +
            "\"url\":\"\",\"apiIdentity\":\"\",\"language\":\"\"}"
        @ExpectThrows[IllegalArgumentException](decodeNavigationDecision(JsonNode.parse(noncanonical), "$"))
    }

    @TestCase
    func pageBindingNavigationRoundTripsWithoutPromotingLocalAssociation(): Unit {
        let navigation = TypeNavigation("resolved", "manual", "explicit external documentation reference",
            url: "https://docs.example.test/guide-api", symbolKey: "support.Box|class|1()")
        let encoded = encodeDocIr(pageNavigationCodecFixture(navigation: Some(navigation)))
        let decoded = decodeDocIr(encoded)
        let binding = decoded.pages[0].bindings[0]
        @Expect(binding.state, "unresolved")
        @Expect(binding.targetSymbolId.isNone())
        @Expect(binding.navigation.getOrThrow().state, "resolved")
        @Expect(binding.navigation.getOrThrow().url, "https://docs.example.test/guide-api")
        @Expect(projectDocumentationLanguage(decoded, "en").pages[0].bindings[0].navigation.getOrThrow().url,
            navigation.url)
        @Expect(encodeDocIr(decoded), encoded)
        let withoutNavigation = decodeDocIr(encodeDocIr(pageNavigationCodecFixture()))
        @Expect(withoutNavigation.pages[0].bindings[0].navigation.isNone())
        @ExpectThrows[IllegalArgumentException](DocumentationPageBinding("support.Box", "example", "authored", "", 7,
            state: "resolved", navigation: Some(navigation)))
        @ExpectThrows[IllegalArgumentException](DocumentationPageBinding("support.Box", "example", "authored", "", 7,
            state: "unavailable", navigation: Some(navigation)))
        let redacted = DocumentationPageBinding("", "", "authored", "", 7, state: "unavailable",
            navigation: Some(TypeNavigation("unavailable", "none", "binding hidden for this audience")))
        @Expect(redacted.navigation.getOrThrow().url, "")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("https://docs.example.test/guide-api", "javascript:alert(1)")))
    }

    @TestCase
    func currentPageBindingMissingNavigationIsRejectedByDecoderItself(): Unit {
        let encoded = encodeDocIr(pageNavigationCodecFixture())
        let missing = encoded.replace(",\n          \"navigation\": null", "")
        @Expect(missing != encoded)
        let pages = JsonNode.parse(missing).asObject().get("pages")
        @ExpectThrows[IllegalArgumentException](decodeDocumentationPages(pages, HashMap<String, String>(), false))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(missing))
    }

    @TestCase
    func actualV14ShapeBindingMigratesToNullNavigationContractUnit(): Unit {
        let frozen = String.fromUtf8(File.readFrom(Path("tests/fixtures/legacy14/basic.docs.json")))
        let legacy = frozen.replace("\"project\": {", "\"pages\": [" + LEGACY14_PAGE_BINDING_CONTRACT + "], \"project\": {")
        @Expect(legacy != frozen)
        let migrated = decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(migrated.pages[0].bindings[0].state, "unresolved")
        @Expect(migrated.pages[0].bindings[0].navigation.isNone())
        @Expect(migrated.pages[0].bindings[0].targetSymbolId.isNone())
        let current = encodeDocIr(migrated)
        @Expect(encodeDocIr(decodeDocIr(current)), current)
        let invalidLegacy = legacy.replace("\"targetSymbolId\":null", "\"targetSymbolId\":null,\"navigation\":null")
        @Expect(invalidLegacy != legacy)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(invalidLegacy))
    }

    @TestCase
    func frozenV14RetainsIndependentCollectionStateWithoutInventingNavigation(): Unit {
        let legacy = String.fromUtf8(File.readFrom(Path("tests/fixtures/legacy14/basic.docs.json")))
        let original = JsonNode.parse(legacy).asObject()
        let originalState = original.get("apiCollectionState").getOrThrow().asString()
        let migrated = decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(migrated.apiCollectionState, originalState)
        @Expect(migrated.generator.toolchain, "")
        @Expect(migrated.documentationRevision, "")
        @Expect(migrated.dependencies.isEmpty())
        @Expect(migrated.documentSets.isEmpty())
        let encoded = encodeDocIr(migrated)
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(legacy.replace("\"apiCollectionState\":", "\"missingCollectionState\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(legacy.replace("\"schemaVersion\":", "\"dependencies\":[],\"schemaVersion\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(legacy.replace("\"generator\": {", "\"generator\": {\"toolchain\":\"invented\",")))
    }

    @TestCase
    func collectionStateDefaultsOnlyAtConstructionAndRejectsInvalidValues(): Unit {
        let documentSet = DocumentSetIdentity("defaults", "library", "", "unknown", "manual")
        @Expect(documentSet.apiVersion, "")
        @Expect(documentSet.documentationRevision, "")
        let generator = GeneratorInfo("cjdoc", "test")
        let project = ProjectInfo("collection-state")
        let configuration = ConfigurationSnapshot(lintProfile: "off")
        @Expect(DocumentationSet(generator, "complete", project, configuration).apiCollectionState, "resolved")
        @Expect(DocumentationSet(generator, "complete", project, configuration).documentationRevision, "")
        @Expect(DocumentationSet(generator, "partial", project, configuration).apiCollectionState, "partial")
        @Expect(DocumentationSet(generator, "unknown", project, configuration).apiCollectionState, "unavailable")
        for (state in ["resolved", "partial", "unavailable"]) {
            let value = DocumentationSet(generator, "complete", project, configuration,
                apiCollectionState: Some(state))
            @Expect(decodeDocIr(encodeDocIr(value)).apiCollectionState, state)
            @Expect(projectDocumentationLanguage(value, "en").apiCollectionState, state)
        }
        @ExpectThrows[IllegalArgumentException](DocumentationSet(generator, "complete", project, configuration,
            apiCollectionState: Some("complete")))
    }
    @TestCase
    func navigationRoundTripsWithoutPromotingSemanticEvidence(): Unit {
        let encoded = encodeDocIr(navigationCodecFixture())
        let decoded = decodeDocIr(encoded)
        @Expect(decoded.schemaVersion, "cjdoc.doc-ir/15")
        @Expect(decoded.generator.toolchain, "test-parser-toolchain")
        @Expect(decoded.apiCollectionState, "partial")
        @Expect(decoded.documentationRevision, "docs-publication")
        @Expect(projectDocumentationLanguage(decoded, "en").documentationRevision, "docs-publication")
        @Expect(projectDocumentationLanguage(decoded, "en").apiCollectionState, "partial")
        @Expect(apiContractSnapshotForDocumentation(decoded).collectionState, "partial")
        @Expect(encodeDocIr(decoded), encoded)
        @Expect(decoded.dependencies.size, 2)
        @Expect(decoded.dependencies[0].componentModuleId, "cjdoc:module:v1:navigation-codec")
        @Expect(decoded.dependencies[1].componentModuleId, "")
        @Expect(decoded.documentSets[0].moduleId, "cjdoc:module:v1:producer-support")
        @Expect(decoded.documentSets[0].apiVersion, "support-api-declared")
        @Expect(decoded.documentSets[0].documentationRevision, "support-doc-revision")
        @Expect(decoded.documentSets[0].revision, "release")
        @Expect(decoded.dependencies[1].kind, "binary")
        @Expect(decoded.dependencies[1].state, "declared")
        @Expect(decoded.dependencies[1].evidence, "manifest dependency")
        @Expect(decoded.dependencies[1].version, "1.2")
        @Expect(decoded.dependencies[1].revision, "release")
        @Expect(decoded.dependencies[1].target, "example-target")
        @Expect(decoded.dependencies[1].cfg, "default")
        @Expect(decoded.documentSets[0].source, "portable-index")
        @Expect(decoded.documentSets[0].indexIdentity, "index-content")
        let symbol = decoded.declarations[0]
        let typeRef = symbol.returnType.getOrThrow()
        @Expect(typeRef.semantic.state, "unavailable")
        @Expect(typeRef.semantic.canonical.isNone())
        @Expect(typeRef.semantic.provider.isNone())
        let navigation = typeRef.navigation.getOrThrow()
        @Expect(navigation.state, "resolved")
        @Expect(navigation.matchLevel, "manual")
        @Expect(navigation.dependencyInstanceId, "dependency-one")
        @Expect(navigation.documentSetId, "docs-one")
        @Expect(navigation.apiIdentity, "source-content")
        @Expect(navigation.language, "en")
        @Expect(typeRef.arguments[0].navigation.getOrThrow().state, "unavailable")
        let comment = symbol.documentation.getOrThrow()
        @Expect(comment.tags[0].referenceState, "unavailable")
        @Expect(comment.tags[0].navigation.getOrThrow().url, navigation.url)
        @Expect(comment.localizedTexts[0].referenceState, "unavailable")
        @Expect(comment.localizedTexts[0].navigation.getOrThrow().indexIdentity, "index-content")
        let metadata = comment.markdown.children[0].children[0].metadata.getOrThrow()
        @Expect(metadata.semanticState.getOrThrow(), "unresolved")
        @Expect(metadata.semanticExternalUrl.isNone())
        @Expect(metadata.semanticNavigation.getOrThrow().symbolKey, "support.Box|class|1()")
    }

    @TestCase
    func frozenV13MigratesWithNoInventedIdentityOrNavigation(): Unit {
        let legacy = String.fromUtf8(File.readFrom(Path("tests/fixtures/legacy13/basic.docs.json")))
        let migrated = decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(migrated.generator.toolchain, "")
        @Expect(migrated.documentationRevision, "")
        @Expect(migrated.dependencies.isEmpty())
        @Expect(migrated.documentSets.isEmpty())
        let types = ArrayList<TypeRef>()
        for (symbol in migrated.declarations) {
            for (parameter in symbol.parameters) { types.add(parameter.typeRef) }
            if (let Some(value) <- symbol.returnType) { types.add(value) }
            for (relation in symbol.typeRelationships) { types.add(relation.target) }
            if (let Some(comment) <- symbol.documentation) {
                for (tag in comment.tags) { @Expect(tag.navigation.isNone()) }
                for (text in comment.localizedTexts) { @Expect(text.navigation.isNone()) }
            }
        }
        @Expect(!types.isEmpty())
        while (!types.isEmpty()) {
            let value = types.remove(at: types.size - 1)
            @Expect(value.navigation.isNone())
            for (argument in value.arguments) { types.add(argument) }
        }
        let encoded = encodeDocIr(migrated)
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        @Expect(migrated.apiCollectionState, if (migrated.status == "complete") { "resolved" } else { "partial" })
        let invalidLegacy = legacy.replace("\"schemaVersion\":", "\"dependencies\":[],\"schemaVersion\":")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(invalidLegacy))
    }

    @TestCase
    func currentSchemaRequiresMetadataAndRejectsUnknownNavigationFields(): Unit {
        let encoded = encodeDocIr(navigationCodecFixture())
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"apiCollectionState\": \"partial\",", "")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"apiCollectionState\": \"partial\"", "\"apiCollectionState\": null")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("cjdoc.doc-ir/15", "cjdoc.doc-ir/14")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"dependencies\":", "\"dependencyInstances\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"documentationRevision\": \"docs-publication\",", "")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"apiVersion\":", "\"missingApiVersion\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"documentationRevision\": \"support-doc-revision\",", "")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"componentModuleId\":", "\"missingComponentModuleId\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"moduleId\": \"cjdoc:module:v1:producer-support\",", "")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"matchLevel\":", "\"matchLevell\":")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("\"manual\"", "\"guessed\"")))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encoded.replace("https://docs.example.test/box.html", "javascript:alert(1)")))
        @ExpectThrows[IllegalArgumentException](TypeNavigation("resolved", "none", "no identity", url: "box.html"))
        @ExpectThrows[IllegalArgumentException](TypeNavigation("ambiguous", "none", "multiple matches", url: "box.html"))
        @ExpectThrows[IllegalArgumentException](TypeNavigation("unavailable", "none", ""))
        @ExpectThrows[IllegalArgumentException](DocumentSetIdentity("docs", "support", "", "unknown", "/host/private"))
    }

    @TestCase
    func portableKeysKeepPackagePrefixAndOverloadIdentity(): Unit {
        @Expect(portableSymbolKey("fixture", "fixture.Box", "class", 1), "fixture.Box|class|1()")
        @Expect(portableSymbolKey("fixture", "Box", "class", 1), "fixture.Box|class|1()")
        let integer = portableSymbolKey("fixture", "Box.add", "function", 0, parameterTypes: ["Int64"])
        let text = portableSymbolKey("fixture", "fixture.Box.add", "function", 0, parameterTypes: ["String"])
        @Expect(integer, "fixture.Box.add|function|0(Int64)")
        @Expect(integer != text)
    }

    @TestCase
    func inventorySharesProducerIdentityAndKeepsHrefPrefixesDistinct(): Unit {
        let documentation = navigationCodecFixture()
        let standalone = SymbolIndexDocumentationRenderer().render(documentation)[0].content
        let index = JsonNode.parse(standalone).asObject()
        @Expect(index.get("schemaVersion").getOrThrow().asString(), "cjdoc.symbol-index/2")
        @Expect(index.get("dependencies").getOrThrow().asArray().size(), 2)
        let dependency = index.get("dependencies").getOrThrow().asArray().get(0).getOrThrow().asObject()
        @Expect(dependency.get("componentModuleId").getOrThrow().asString(), "cjdoc:module:v1:navigation-codec")
        let entry = index.get("entries").getOrThrow().asArray().get(0).getOrThrow().asObject()
        @Expect(entry.get("identity").getOrThrow().asString(), "source-content")
        @Expect(entry.get("symbolKey").getOrThrow().asString(), "fixture.api|function|0()")
        @Expect(!entry.get("documentSetId").getOrThrow().asString().isEmpty())
        let sets = index.get("documentSets").getOrThrow().asArray()
        var foundProducer = false
        for (position in 0..sets.size()) {
            let producer = sets.get(position).getOrThrow().asObject()
            if (producer.get("id").getOrThrow().asString() == entry.get("documentSetId").getOrThrow().asString()) {
                @Expect(producer.get("moduleId").getOrThrow().asString(), "cjdoc:module:v1:navigation-codec")
                @Expect(producer.get("apiVersion").getOrThrow().asString(), "api-package-declared")
                @Expect(producer.get("revision").getOrThrow().asString(), "api-source-ref")
                @Expect(producer.get("documentationRevision").getOrThrow().asString(), "docs-publication")
                foundProducer = true
            }
        }
        @Expect(foundProducer)
        let href = entry.get("href").getOrThrow().asString()
        @Expect(href.startsWith("html/"))
        @Expect(!href.startsWith("html/html/"))
        var embedded = ""
        for (artifact in HtmlDocumentationRenderer().render(documentation)) {
            if (artifact.path == "html/symbol-index.json") { embedded = artifact.content }
        }
        @Expect(!embedded.isEmpty())
        let embeddedEntry = JsonNode.parse(embedded).asObject().get("entries").getOrThrow().asArray().get(0).getOrThrow().asObject()
        @Expect("html/" + embeddedEntry.get("href").getOrThrow().asString(), href)
        @Expect(embeddedEntry.get("identity").getOrThrow().asString(), "source-content")
        @Expect(entry.get("semanticState").getOrThrow().asString(), "partial")
        @Expect(entry.get("typeNavigations").getOrThrow().asArray().size(), 2)
    }
}
