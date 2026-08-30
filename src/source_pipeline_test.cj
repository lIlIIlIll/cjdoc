package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let FIXTURES = "tests/fixtures/projects/"

private func generateFixture(name: String, lintProfile!: String = "off",
    includePathDependencies!: Bool = false, cfgValues!: Array<CfgValue> = []): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(FIXTURES + name,
        lintProfile: lintProfile, audience: "all",
        includePathDependencies: includePathDependencies, cfgValues: cfgValues))
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
