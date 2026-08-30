package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let FIXTURES = "tests/fixtures/projects/"
private let TEST_AST_PREFLIGHT = Some("target/release/bin/main")

private func generateFixture(name: String, lintProfile!: String = "off",
    includePathDependencies!: Bool = false, cfgValues!: Array<CfgValue> = []): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(FIXTURES + name,
        lintProfile: lintProfile, audience: "all",
        includePathDependencies: includePathDependencies, cfgValues: cfgValues,
        astPreflightExecutable: TEST_AST_PREFLIGHT))
}

private func containsDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

private func declarationNamed(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.name == name) { return declaration }
    }
    throw IllegalStateException("fixture declaration '${name}' not found")
}

@Test
class SourcePipelineTest {
    @TestCase
    func extractsSupportedLanguageStructures(): Unit {
        let documentation = generateFixture("basic")
        @Expect(documentation.status, "complete")
        @Expect(documentation.declarations.size, 25)
        let kinds = HashSet<String>()
        for (declaration in documentation.declarations) { kinds.add(declaration.kind) }
        for (expected in ["class", "struct", "interface", "enum", "extend", "function",
            "property", "constructor", "typeAlias", "enumCase", "variable"]) {
            @Expect(kinds.contains(expected), true)
        }
        @Expect(declarationNamed(documentation, "解析").qualifiedName, "basic.解析")
        @Expect(declarationNamed(documentation, "identity").genericParameters.size, 1)
    }

    @TestCase
    func overloadsHaveStableDistinctSymbolIds(): Unit {
        let documentation = generateFixture("basic")
        let overloadIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse") { overloadIds.add(declaration.id) }
            @Expect(!declaration.id.contains("src/"), true)
            @Expect(!declaration.id.contains(":1:"), true)
        }
        @Expect(overloadIds.size, 2)
        @Expect(overloadIds[0] != overloadIds[1], true)
        @Expect(overloadIds[0].contains("Array<UInt8>") || overloadIds[1].contains("Array<UInt8>"), true)
        @Expect(overloadIds[0].contains("String") || overloadIds[1].contains("String"), true)
    }

    @TestCase
    func filePrivateTopLevelDeclarationsHaveInjectiveSymbolIds(): Unit {
        let documentation = generateFixture("private_file_scope")
        let helperIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "sameHelper") { helperIds.add(declaration.id) }
        }
        @Expect(helperIds.size, 2)
        @Expect(helperIds[0] != helperIds[1], true)
        @Expect(helperIds[0].contains("::file:src/"), true)
        @Expect(helperIds[1].contains("::file:src/"), true)
    }

    @TestCase
    func parsesStructuredCommentsAndMarkdownAst(): Unit {
        let documentation = generateFixture("basic")
        var selected: ?api_model.SymbolDoc = None
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse" && declaration.parameters.size == 1 &&
                declaration.parameters[0].typeRef.spelling == "String") { selected = Some(declaration) }
        }
        let declaration = selected.getOrThrow()
        let comment = declaration.documentation.getOrThrow()
        @Expect(comment.summary, "从文本解析值。")
        @Expect(comment.markdown.kind, "document")
        @Expect(comment.markdown.children.size >= 3, true)
        @Expect(comment.markdown.children[0].kind, "paragraph")
        var tagNames = HashSet<String>()
        for (tag in comment.tags) { tagNames.add(tag.name) }
        for (name in ["param", "return", "throws", "see", "since"]) {
            @Expect(tagNames.contains(name), true)
        }
    }

    @TestCase
    func reportsLintWithoutDroppingDeclarations(): Unit {
        let documentation = generateFixture("lint", lintProfile: "standard")
        @Expect(documentation.declarations.size, 3)
        for (code in ["CJDOC3001", "CJDOC3002", "CJDOC3003", "CJDOC3005", "CJDOC3008"]) {
            @Expect(containsDiagnostic(documentation, code), true)
        }
    }

    @TestCase
    func unsupportedAndBrokenSourcesProducePartialIr(): Unit {
        let unsupported = generateFixture("unsupported")
        @Expect(unsupported.status, "partial")
        @Expect(unsupported.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(unsupported, "CJDOC1009"), true)

        let recovery = generateFixture("recovery")
        @Expect(recovery.status, "partial")
        @Expect(recovery.declarations.size, 1)
        @Expect(containsDiagnostic(recovery, "CJDOC1011"), true)
    }

    @TestCase
    func recordsFrontendGapsWithoutTraversingFunctionBodies(): Unit {
        let documentation = generateFixture("frontend_gaps")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.declarations[0].name, "outer")
        @Expect(documentation.declarations[0].documentation.isSome())
        @Expect(documentation.orphanDocComments.size, 2)
        @Expect(documentation.macroInvocations.size, 1)
        @Expect(documentation.macroInvocations[0].name, "missing.Generate")
        @Expect(documentation.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(documentation, "CJDOC1009"), true)
        @Expect(containsDiagnostic(documentation, "CJDOC1014"), true)
    }

    @TestCase
    func rejectsSemanticallyInvalidSourceCacheEntries(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let cache = temporary.join("cache")
            Directory.create(cache)
            let provider = AstSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("source-cache-contract-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let first = provider.collect(FIXTURES + "basic")
            @Expect(first.declarations.size, 25)
            @Expect(provider.cacheStats.writes, 1)
            let entries = Directory.readFrom(cache)
            @Expect(entries.size, 1)
            let cachePath = entries[0].path
            let corrupted = String.fromUtf8(File.readFrom(cachePath))
                .replace("6:public", "6:bogus!")
            File.writeTo(cachePath, corrupted.toArray())

            let reparsed = provider.collect(FIXTURES + "basic")
            @Expect(reparsed.declarations.size, 25)
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func publicEngineFailsClosedWithoutParserWorker(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            FIXTURES + "basic", lintProfile: "off", audience: "all"))
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(containsDiagnostic(documentation, "CJDOC1020"), true)
    }

    @TestCase
    func scansWorkspaceAndOptInPathDependencies(): Unit {
        let workspace = generateFixture("workspace")
        @Expect(workspace.modules.size, 2)
        @Expect(workspace.packages.size, 2)
        @Expect(workspace.declarations.size, 2)

        let dependencies = generateFixture("path_dependencies", includePathDependencies: true)
        @Expect(dependencies.modules.size, 3)
        @Expect(dependencies.packages.size, 3)
        @Expect(dependencies.declarations.size, 3)
        @Expect(dependencies.diagnostics.size, 0)
    }

    @TestCase
    func explicitCfgSelectsOneConditionalBranch(): Unit {
        let documentation = generateFixture("conditional",
            cfgValues: [CfgValue("os", "Linux")])
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.declarations[0].name, "platformName")
        @Expect(documentation.declarations[0].headerSpelling.contains("linux"), false)
        @Expect(documentation.diagnostics.size, 0)
    }

    @TestCase
    func unresolvedCfgIsReportedAsUnsupportedSource(): Unit {
        let documentation = generateFixture("conditional",
            cfgValues: [CfgValue("arch", "x86_64")])
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(documentation.unsupportedDeclarations.size, 2)
        @Expect(containsDiagnostic(documentation, "CJDOC1019"), true)
    }

    @TestCase
    func generationAndEncodingAreDeterministic(): Unit {
        let first = generateFixture("types", lintProfile: "standard")
        let second = generateFixture("types", lintProfile: "standard")
        let firstJson = api_render.encodeDocIr(first)
        @Expect(api_render.encodeDocIr(second), firstJson)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(firstJson)), firstJson)
        @Expect(!firstJson.contains("/home/"), true)
        @Expect(!firstJson.contains("/tmp/"), true)
    }
}
