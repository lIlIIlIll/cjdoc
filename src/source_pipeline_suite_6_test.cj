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
    func genericWhereBoundsReachPublicIrWithoutLinkingTypeParameters(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"))
            File.writeTo(temporary.join("cjpm.toml"),
                "[package]\nname = \"constraints\"\n".toArray())
            File.writeTo(temporary.join("src/api.cj"), """
                package constraints
                public interface Widget {}
                public interface Other {}
                public interface Container<T> {}
                public class BoundedClass<T> <: Other where T <: Widget & Other {
                    public func nested<U>(input: U): U where U <: Container<T> { input }
                }
                public struct BoundedStruct<T> where T <: Widget {}
                public interface BoundedInterface<T> where T <: Widget {}
                public enum BoundedEnum<T> where T <: Widget { | Item(T) }
                extend<T> BoundedStruct<T> where T <: Widget { public func extensionApi(): Unit {} }
                public func constrained<T, U>(input: T, other: U): T
                    where T <: Widget & Other, U <: Container<T> { input }
                public func shadowed<Widget, T>(input: T): T where T <: Container<Widget> { input }
                public func plain(): Unit {}
                """.toArray())
            let documentation = DocumentationEngine().generate(GenerationRequest(
                temporary.toString(), lintProfile: "off", audience: "external",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "complete")
            let constrained = declarationNamed(documentation, "constrained")
            @Assert(constrained.typeRelationships.size, 3)
            @Expect(constrained.typeRelationships[0].kind, "genericConstraint")
            @Expect(constrained.typeRelationships[2].target.spelling, "Widget")
            @Expect(constrained.typeRelationships[2].target.navigation.getOrThrow().state, "resolved")
            @Expect(constrained.typeRelationships[2].target.navigation.getOrThrow().symbolKey,
                declarationNamed(documentation, "Widget").id)
            @Expect(constrained.typeRelationships[1].target.spelling, "Other")
            let container = constrained.typeRelationships[0].target
            @Expect(container.spelling.replace(" ", ""), "Container<T>")
            @Expect(container.navigation.getOrThrow().state, "resolved")
            @Assert(container.arguments.size, 1)
            @Expect(container.arguments[0].spelling, "T")
            @Expect(container.arguments[0].kind, "typeParameter")
            @Expect(container.arguments[0].navigation.isNone(), true)
            @Expect(constrained.parameters[0].typeRef.kind, "typeParameter")
            @Expect(constrained.parameters[0].typeRef.navigation.isNone(), true)
            for (name in ["BoundedStruct", "BoundedInterface", "BoundedEnum"]) {
                let symbol = declarationNamed(documentation, name)
                @Assert(symbol.typeRelationships.size, 1)
                @Expect(symbol.typeRelationships[0].kind, "genericConstraint")
                @Expect(symbol.typeRelationships[0].target.spelling, "Widget")
            }
            let owner = declarationNamed(documentation, "BoundedClass")
            @Assert(owner.typeRelationships.size, 3)
            @Expect(owner.typeRelationships[0].kind, "genericConstraint")
            @Expect(owner.typeRelationships[1].kind, "genericConstraint")
            @Expect(owner.typeRelationships[2].kind, "superType")
            let nested = declarationNamed(documentation, "nested")
            @Expect(nested.ownerId, Some(owner.id))
            @Assert(nested.typeRelationships.size, 1)
            @Expect(nested.typeRelationships[0].target.arguments[0].kind, "typeParameter")
            @Expect(nested.typeRelationships[0].target.arguments[0].navigation.isNone(), true)
            let shadowed = declarationNamed(documentation, "shadowed")
            @Assert(shadowed.typeRelationships.size, 1)
            @Expect(shadowed.typeRelationships[0].target.spelling.replace(" ", ""), "Container<Widget>")
            @Expect(shadowed.typeRelationships[0].target.navigation.getOrThrow().state, "resolved")
            @Assert(shadowed.typeRelationships[0].target.arguments.size, 1)
            @Expect(shadowed.typeRelationships[0].target.arguments[0].kind, "typeParameter")
            @Expect(shadowed.typeRelationships[0].target.arguments[0].navigation.isNone(), true)
            @Expect(declarationNamed(documentation, "plain").typeRelationships.isEmpty(), true)
            var extensionFound = false
            for (symbol in documentation.declarations) {
                if (symbol.kind != "extend") { continue }
                extensionFound = true
                @Assert(symbol.typeRelationships.size, 2)
                @Expect(symbol.typeRelationships[0].kind, "extensionTarget")
                @Expect(symbol.typeRelationships[1].kind, "genericConstraint")
            }
            @Expect(extensionFound, true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

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
        var sourceParserFailure = ""
        for (diagnostic in punctuation.diagnostics) {
            if (diagnostic.code == "CJDOC1011" || diagnostic.code == "CJDOC1012" ||
                diagnostic.code == "CJDOC1020") {
                sourceParserFailure = diagnostic.code + ": " + diagnostic.message
            }
        }
        @Expect(sourceParserFailure, "")
        if (punctuation.status != "complete") {
            var failureDetails = ""
            for (diagnostic in punctuation.diagnostics) {
                failureDetails = failureDetails + diagnostic.code + ": " + diagnostic.message + "; "
            }
            for (diagnostic in punctuation.diagnostics) {
                if (diagnostic.code == "CJDOC1014") {
                    if (let Some(source) <- diagnostic.source) {
                        failureDetails = failureDetails +
                            "orphan source ${source.start.line}:${source.start.column}/${source.start.byteOffset}-" +
                            "${source.end.line}:${source.end.column}/${source.end.byteOffset}; "
                    }
                }
            }
            var nestedRangeDetails = "Nested declaration not found; "
            for (declaration in punctuation.declarations) {
                if (declaration.name == "Nested") {
                    nestedRangeDetails = "Nested source " + declaration.source.start.line.toString() + ":" +
                        declaration.source.start.column.toString() + "/" +
                        declaration.source.start.byteOffset.toString() + "-" +
                        declaration.source.end.line.toString() + ":" +
                        declaration.source.end.column.toString() + "/" +
                        declaration.source.end.byteOffset.toString() + "; "
                    break
                }
            }
            failureDetails = failureDetails + nestedRangeDetails
            for (unsupported in punctuation.unsupportedDeclarations) {
                failureDetails = failureDetails + "unsupported " + unsupported.kind + " " +
                    unsupported.name + ": " + unsupported.reason + "; "
            }
            for (provider in punctuation.providers) {
                failureDetails = failureDetails + "provider " + provider.name + ": " + provider.state + "; "
            }
            for (unbound in punctuation.unboundSemanticDeclarations) {
                failureDetails = failureDetails + "unbound " + unbound.provider + " " +
                    unbound.display + ": " + unbound.reason + "; "
            }
            @Expect(failureDetails, "")
        }
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
