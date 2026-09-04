package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite6 {
    @TestCase
    func headerlessDependencyUsesItsModuleNameForSerialAndParallelJobs(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("headerless")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), (
                "[package]\nname = \"headerless_root\"\n" +
                "[dependencies]\ndep = { path = \"dep\" }\n").toArray())
            File.writeTo(root.join("dep/cjpm.toml"),
                "[package]\nname = \"dep_module\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package headerless_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/one.cj"),
                "public func headerlessOne(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/two.cj"),
                "public func headerlessTwo(): Unit {}\n".toArray())

            let serial = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                jobs: 1, astPreflightExecutable: TEST_AST_PREFLIGHT))
            let parallel = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                jobs: 4, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(serial.status, "complete")
            @Expect(declarationNamed(serial, "headerlessOne").packageName, "dep_module")
            @Expect(declarationNamed(serial, "headerlessTwo").packageName, "dep_module")
            @Expect(api_render.encodeDocIr(parallel), api_render.encodeDocIr(serial))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func punctuationDoesNotTriggerBinaryDepthGuard(): Unit {
        let punctuation = generateFixture("binary_punctuation")
        @Expect(punctuation.status, "complete")
        @Expect(containsDiagnostic(punctuation, "CJDOC1012"), false)
        @Expect(declarationNamed(punctuation, "ManyCases").kind, "enum")
        @Expect(declarationNamed(punctuation, "Nested").kind, "typeAlias")

        let expression = generateFixture("deep_binary")
        @Expect(expression.status, "partial")
        @Expect(containsDiagnostic(expression, "CJDOC1012"), true)
    }

    @TestCase
    func dependencyLogicalNamesAreValidatedBeforePathConstruction(): Unit {
        @ExpectThrows[IllegalArgumentException](DependencySourceInput("../escape",
            FIXTURES + "types"))
        @ExpectThrows[IllegalArgumentException](DependencySourceInput("bad/name",
            FIXTURES + "types"))

        let documentation = generateFixture("basic", dependencySources: [
            DependencySourceInput("vendor.types", FIXTURES + "types")])
        @Expect(documentation.status, "complete")
        @Expect(documentation.modules.size, 2)
        @Expect(declarationNamed(documentation, "State").source.path.startsWith(
            "dependencies/vendor.types/"), true)
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
    func missingCfgOmitsConditionalDeclarationsExplicitly(): Unit {
        let documentation = generateFixture("conditional")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(documentation.unsupportedDeclarations.size, 2)
        @Expect(containsDiagnostic(documentation, "CJDOC1019"), true)
    }

    @TestCase
    func rejectsConflictingCfgFactsAndDeduplicatesIdenticalFacts(): Unit {
        @Expect(isExactWhenAnnotation("@When[os == \"Linux\"]"), true)
        @Expect(isExactWhenAnnotation("  @When [os == \"Linux\"]  "), true)
        @Expect(isExactWhenAnnotation("@Whenever[os == \"Linux\"]"), false)
        @Expect(isExactWhenAnnotation("@WhenEnabled[os == \"Linux\"]"), false)

        @ExpectThrows[IllegalArgumentException](GenerationRequest(FIXTURES + "conditional",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("os", "Windows")]))
        @ExpectThrows[IllegalArgumentException](GenerationRequest(FIXTURES + "conditional",
            cfgValues: [CfgValue("os", "Windows"), CfgValue("os", "Linux")]))

        let single = generateFixture("conditional", cfgValues: [CfgValue("os", "Linux")])
        let duplicate = generateFixture("conditional",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("os", "Linux")])
        @Expect(api_render.encodeDocIr(duplicate), api_render.encodeDocIr(single))
    }

    @TestCase
    func excludedCfgOwnersSuppressChildEvaluationAndFalseDominatesUnknown(): Unit {
        let selected = generateFixture("cfg_owner",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("docs", "false")])
        @Expect(selected.status, "complete")
        @Expect(selected.declarations.size, 0)
        @Expect(selected.unsupportedDeclarations.size, 0)
        @Expect(containsDiagnostic(selected, "CJDOC1019"), false)

        let unresolvedOwner = generateFixture("cfg_owner",
            cfgValues: [CfgValue("docs", "false")])
        @Expect(unresolvedOwner.status, "partial")
        @Expect(unresolvedOwner.declarations.size, 0)
        @Expect(unresolvedOwner.unsupportedDeclarations.size, 1)
        @Expect(unresolvedOwner.unsupportedDeclarations[0].name, "WindowsOnly")
        @Expect(diagnosticCount(unresolvedOwner, "CJDOC1019"), 1)
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
        @Expect(declarationNamed(first, "Idle").documentation.isSome(), true)
        @Expect(declarationNamed(first, "Failed").documentation.isSome(), true)
        let firstJson = api_render.encodeDocIr(first)
        @Expect(api_render.encodeDocIr(second), firstJson)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(firstJson)), firstJson)
        @Expect(!firstJson.contains("/home/"), true)
        @Expect(!firstJson.contains("/tmp/"), true)
    }

}
