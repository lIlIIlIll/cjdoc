package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func requestWithLimitConfig(text: String, overrideMiB!: ?Int64 = None): GenerationRequest {
    let root = Directory.createTemp(canonicalize(getTempDirectory()))
    try {
        File.writeTo(root.join("cjdoc.toml"), text.toArray())
        GenerationRequest(root.toString(), maxDocIrMiB: overrideMiB)
    } finally {
        removeIfExists(root, recursive: true)
    }
}

@Test
class DocIrLimitsTest {
    @TestCase
    func requestUsesDefaultConfigAndExplicitOverride(): Unit {
        @Expect(GenerationRequest("unused").maxDocIrBytes, 64 * 1024 * 1024)
        @Expect(requestWithLimitConfig("\n# Resource policy\n[limits] # resource policy\nmax-doc-ir-mib = 32 # MiB\n\n").maxDocIrBytes,
            32 * 1024 * 1024)
        @Expect(requestWithLimitConfig("[limits]\nmax-doc-ir-mib = 1\n", overrideMiB: 64).maxDocIrBytes,
            64 * 1024 * 1024)
        @Expect(requestWithLimitConfig("[other]\nmax-doc-ir-mib = 0\n[limits]\nmax-doc-ir-mib = 1\n").maxDocIrBytes,
            1024 * 1024)
        @Expect(requestWithLimitConfig("[limits]\n").maxDocIrBytes, 64 * 1024 * 1024)
    }

    @TestCase
    func invalidAndDuplicateLimitsFailEvenWithAnOverride(): Unit {
        for (value in ["0", "65", "-1", "true", "1.5", "\"32\"", "", "99999999999999999999999999"]) {
            @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(
                "[limits]\nmax-doc-ir-mib = " + value + "\n", overrideMiB: 64))
        }
        @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(
            "[limits]\nmax-doc-ir-mib = 32\nmax-doc-ir-mib = 64\n"))
        @ExpectThrows[IllegalArgumentException](requestWithLimitConfig("[limits]\nmax-doc-ir-mb = 32\n"))
        for (value in [0, 65, -1]) {
            @ExpectThrows[IllegalArgumentException](GenerationRequest("unused", maxDocIrMiB: value))
        }
    }

    @TestCase
    func wrongLimitsTableShapesFailEvenWithAnOverride(): Unit {
        for (header in ["[[limits]]", "[[ limits ]]", "[[\"limits\"]]", "[['limits']]",
            "[limits.extra]", "[\"limits\".extra]"]) {
            @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(
                header + "\nmax-doc-ir-mib = 1\n"))
            @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(
                header + "\nmax-doc-ir-mib = 1\n", overrideMiB: 64))
        }
        @Expect(requestWithLimitConfig("[\"limits\"]\nmax-doc-ir-mib = 1\n").maxDocIrBytes, 1024 * 1024)
        @Expect(requestWithLimitConfig("['limits']\nmax-doc-ir-mib = 1\n").maxDocIrBytes, 1024 * 1024)
        @Expect(requestWithLimitConfig("[[other]]\nmax-doc-ir-mib = 0\n").maxDocIrBytes, 64 * 1024 * 1024)
    }

    @TestCase
    func rootLimitsAssignmentsFailEvenWithAnOverride(): Unit {
        for (assignment in ["limits.max-doc-ir-mib = 1", "limits . max-doc-ir-mib = 1",
            "\"limits\".max-doc-ir-mib = 1", "'limits' . max-doc-ir-mib = 1",
            "\"lim\\u0069ts\".max-doc-ir-mib = 1", "\"\\U0000006cimits\" = { max-doc-ir-mib = 1 }",
            "limits = { max-doc-ir-mib = 1 }", "'limits' = { max-doc-ir-mib = 1 }",
            "limits = 1", "limits.extra.max-doc-ir-mib = 1"]) {
            @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(assignment + "\n"))
            @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(assignment + "\n", overrideMiB: 64))
        }
        @Expect(requestWithLimitConfig("other = { max-doc-ir-mib = 0 }\n" +
            "limits-extra.max-doc-ir-mib = 0\n\"limits.max-doc-ir-mib\" = 0\n" +
            "[other]\nlimits.max-doc-ir-mib = 0\n").maxDocIrBytes, 64 * 1024 * 1024)
        @Expect(requestWithLimitConfig("[\"lim\\u0069ts\"]\nmax-doc-ir-mib = 1\n").maxDocIrBytes, 1024 * 1024)
        @ExpectThrows[IllegalArgumentException](requestWithLimitConfig(
            "[\"lim\\u0069ts\".extra]\nmax-doc-ir-mib = 1\n"))
    }

    @TestCase
    func codecEnforcesCallerBudgetAndRejectsInvalidBudgets(): Unit {
        let documentation = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
            api_model.ProjectInfo("budget"), api_model.ConfigurationSnapshot(lintProfile: "off"))
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.decodeDocIr(encoded, maxDocumentBytes: 1024 * 1024).project.name, "budget")
        @Expect(api_render.encodeDocIr(documentation, maxDocumentBytes: 1024 * 1024), encoded)
        for (limit in [0, -1, 64 * 1024 * 1024 + 1, 1]) {
            @ExpectThrows[IllegalArgumentException](api_render.validateDocumentationSet(documentation,
                maxDocumentBytes: limit))
            @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(documentation,
                maxDocumentBytes: limit))
            @ExpectThrows(api_render.decodeDocIr(encoded, maxDocumentBytes: limit))
        }
    }
}
