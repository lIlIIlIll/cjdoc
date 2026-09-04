package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite5 {
    @TestCase
    func invalidStructuredProviderBatchFallsBackAtomicallyAfterClose(): Unit {
        for (mode in ["annotation", "type", "deep-type", "diagnostic", "range", "out-of-bounds", "foreign-provider",
            "declaration-budget", "diagnostic-budget", "relationship-annotation-budget", "type-budget", "text-budget",
            "empty-canonical-type", "blank-canonical-type", "empty-canonical-signature", "blank-canonical-signature",
            "unavailable-canonical-signature"]) {
            let lifecycle = ProviderLifecycle()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                    providerFactories: [InvalidBatchFactory(mode, lifecycle)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(lifecycle.opened, 1)
            @Expect(lifecycle.analyzed, 1)
            @Expect(lifecycle.closed, 1)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2998"))
            @Expect(documentation.providers[0].state, "unavailable")
            @Expect(documentation.status, "partial")
            for (declaration in documentation.declarations) {
                @Expect(declaration.semantic.state, "unavailable")
            }
            let encoded = api_render.encodeDocIr(documentation)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        }
    }

    @TestCase
    func providerIdentityCollisionFallsBackWithoutDroppingOverloads(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [IdentityConflictFactory(lifecycle)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
        @Expect(documentation.providers[0].state, "unavailable")
        var overloadCount: Int64 = 0
        let overloadIds = HashSet<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse" && declaration.kind == "function") {
                overloadCount++
                let _ = overloadIds.add(declaration.id)
            }
        }
        @Expect(overloadCount, 2)
        @Expect(overloadIds.size, 2)
    }

    @TestCase
    func partialProviderSpellingDoesNotCollapseSourceOverloads(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "partial_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package partial_identity

                public func overload(value: Int64): Unit {}
                public func overload(value: String): Unit {}
                """
                    .toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    providerFactories: [PartialSpellingCollapseFactory()],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
            @Expect(documentation.providers[0].state, "partial")
            let ids = HashSet<String>()
            let spellings = HashSet<String>()
            var overloads: Int64 = 0
            for (declaration in documentation.declarations) {
                if (declaration.name != "overload") {
                    continue
                }
                overloads++
                let _ = ids.add(declaration.id)
                @Expect(declaration.parameters.size, 1)
                let _ = spellings.add(declaration.parameters[0].typeRef.spelling)
            }
            @Expect(overloads, 2)
            @Expect(ids.size, 2)
            @Expect(spellings.contains("Int64"))
            @Expect(spellings.contains("String"))
            let encoded = api_render.encodeDocIr(documentation)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func lateProviderReferencesFailClosedWithoutDroppingDiagnostics(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [LateReferenceFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2017"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2998"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2999"))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(documentation.providers[0].state, "partial")
        @Expect(documentation.status, "partial")
        var checkedRelationship = false
        for (declaration in documentation.declarations) {
            for (relationship in declaration.symbolRelationships) {
                if (relationship.targetDisplay != "missing") {
                    continue
                }
                @Expect(relationship.state, "unavailable")
                @Expect(relationship.targetSymbolId.isNone())
                checkedRelationship = true
            }
        }
        @Expect(checkedRelationship)
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.symbolId.isNone())
            }
        }
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func diagnosticOnlyUnknownSymbolIdIsDetachedAndMarksProviderPartialOnce(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [DiagnosticOnlyUnknownReferenceFactory()],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(publicDiagnosticCount(documentation, "CJDOC2017"), 1)
        @Expect(publicDiagnosticCount(documentation, "CJDOC2999"), 1)
        @Expect(documentation.providers[0].state, "partial")
        @Expect(documentation.status, "partial")
        for (declaration in documentation.declarations) {
            @Expect(declaration.semantic.state, "resolved")
        }
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.message, "diagnostic-only unknown identity")
                @Expect(diagnostic.symbolId.isNone())
            }
        }
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }


}
