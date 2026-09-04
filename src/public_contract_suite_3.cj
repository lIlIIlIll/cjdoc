package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite3 {
    @TestCase
    func generationFallsBackWithinThePublicMarkdownBudget(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "markdown_limits", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        @Expect(publicHasDiagnostic(documentation, "CJDOC3026"))
        @Expect(documentation.declarations.size, 1)
        let comment = documentation.declarations[0].documentation.getOrThrow()
        @Expect(comment.summary,
            "Documentation omitted because Markdown resource limits were exceeded.")
        @Expect(comment.markdown.children.size, 1)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func strictLintAndProviderLifecycleAreObservable(): Unit {
        let strict = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "strict",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(strict, "CJDOC3004") ||
            publicHasDiagnostic(strict, "CJDOC3025"))

        let lifecycle = ProviderLifecycle()
        let provided = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [LifecycleFactory(lifecycle)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(provided.providers[0].name, "lifecycle-test")
        @Expect(provided.providers[0].version, "2026.08-test")

        let unknown = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [UnknownIdFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(unknown, "CJDOC2001"))
        @Expect(unknown.declarations.size, 25)

        let related = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [RelationshipFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var verifiedRelationship = false
        for (declaration in related.declarations) {
            if (declaration.kind == "class" && declaration.name == "Parser") {
                @Expect(declaration.typeRelationships.size, 1)
                @Expect(declaration.typeRelationships[0].target.semantic.state, "resolved")
                @Expect(declaration.symbolRelationships.size, 1)
                @Expect(declaration.symbolRelationships[0].state, "resolved")
                @Expect(declaration.symbolRelationships[0].targetSymbolId.isSome())
                verifiedRelationship = true
            }
        }
        @Expect(verifiedRelationship)
    }

    @TestCase
    func providerBatchesCommitPerModuleOnlyAfterClose(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
                providerFactories: [WorkspaceTransactionFactory(lifecycle)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 2)
        @Expect(lifecycle.analyzed, 2)
        @Expect(lifecycle.closed, 2)
        @Expect(documentation.providers.size, 2)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        var unavailableModules: Int64 = 0
        var partialModules: Int64 = 0
        for (provider in documentation.providers) {
            if (provider.state == "unavailable") {
                unavailableModules++
            }
            if (provider.state == "partial") {
                partialModules++
            }
        }
        @Expect(unavailableModules, 1)
        @Expect(partialModules, 1)

        var unavailableDeclarations: Int64 = 0
        var partialDeclarations: Int64 = 0
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable") {
                unavailableDeclarations++
            }
            if (declaration.semantic.state == "partial") {
                partialDeclarations++
            }
        }
        @Expect(unavailableDeclarations > 0)
        @Expect(partialDeclarations > 0)
    }

    @TestCase
    func providerCloseFailureDiscardsStagedModuleBatch(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [CloseFailureFactory(lifecycle)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(documentation.providers[0].state, "unavailable")
        for (declaration in documentation.declarations) {
            @Expect(declaration.semantic.state, "unavailable")
            for (parameter in declaration.parameters) {
                @Expect(parameter.typeRef.semantic.state, "unavailable")
                @Expect(parameter.typeRef.semantic.canonical.isNone())
                @Expect(parameter.typeRef.semantic.provider.isNone())
            }
            match (declaration.returnType) {
                case Some(value) =>
                    @Expect(value.semantic.state, "unavailable")
                    @Expect(value.semantic.canonical.isNone())
                    @Expect(value.semantic.provider.isNone())
                case None => ()
            }
            for (relationship in declaration.typeRelationships) {
                @Expect(relationship.target.semantic.state, "unavailable")
                @Expect(relationship.target.semantic.canonical.isNone())
                @Expect(relationship.target.semantic.provider.isNone())
            }
        }
    }


}
