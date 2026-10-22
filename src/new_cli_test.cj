package cjdoc

import cjdoc.model as public_model
import cjdoc.schema_data.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func createNewCliTestTempDirectory(): Path {
    Directory.createTemp(canonicalize(getTempDirectory()))
}

@Test
class NewCliRegressionTest {
    @TestCase
    func currentSchemaInventoryRejectsRemovedNames(): Unit {
        @Expect(schemaTextForCli("doc-ir"), DOC_IR_SCHEMA)
        @Expect(schemaTextForCli("doc-ir-v16"), DOC_IR_V16_SCHEMA)
        @Expect(schemaTextForCli("api-surface-v3"), API_SURFACE_SCHEMA)
        @Expect(schemaTextForCli("api-diff-v2"), API_DIFF_SCHEMA)
        @Expect(schemaTextForCli("search-index-v9"), SEARCH_INDEX_SCHEMA)
        @Expect(schemaTextForCli("versions-v2"), VERSIONS_SCHEMA)
        @Expect(schemaTextForCli("list"),
            "doc-ir\ndoc-ir-v16\ndiagnostics\ncfg-matrix\nsearch-index\n" +
                "search-index-v9\nsymbol-index\nnavigation-index\napi-surface\napi-surface-v3\n" +
                "api-diff\napi-diff-v2\ndocumentation-coverage\ndocumentation-quality\n" +
                "versions\nversions-v2\ntranslation-coverage\nsite-manifest\n")
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("doc-ir-v15"))
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("api-surface-v2"))
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("doctest-results"))
    }

    @TestCase
    func namedValuesSplitOnlyTheFirstEqualsSign(): Unit {
        let (dependency, path) = splitNamedValue("dep=C:\\sdk=preview\\pkg", "--dependency-source")
        @Expect(dependency, "dep")
        @Expect(path, "C:\\sdk=preview\\pkg")

        let (name, value) = splitNamedValue("feature=target=linux", "--cfg")
        @Expect(name, "feature")
        @Expect(value, "target=linux")
    }

    @TestCase
    func runtimeErrorsDoNotIncludeCommandUsage(): Unit {
        let parseError = cliErrorText("unknown option", true)
        let runtimeError = cliErrorText("missing input file", false)
        @Expect(parseError.contains("usage:"), true)
        @Expect(runtimeError, "error: missing input file")
        @Expect(runtimeError.contains("usage:"), false)
    }

    @TestCase
    func checkRejectsRendererOnlyLocalizationOptions(): Unit {
        @Expect(runCli(["check", "--locale", "en"]), 2)
    }

    @TestCase
    func removedMarkdownLayoutOptionIsUnknownForEveryValue(): Unit {
        for (layout in ["site", "single"]) {
            for (args in [
                ["generate", "--markdown-layout", layout],
                ["render", "--input", "missing.json", "--markdown-layout", layout],
                ["check", "--markdown-layout", layout]
            ]) {
                try {
                    let _ = parseNewCli(args)
                    @Expect(false)
                } catch (error: IllegalArgumentException) {
                    @Expect(error.message, "unknown option '--markdown-layout'")
                }
                @Expect(runCli(args), 2)
            }
        }
    }
    @TestCase
    func nonDiffCommandsRejectApiDenyFlags(): Unit {
        @Expect(runCli(["check", "--deny-breaking-api"]), 2)
        @Expect(runCli(["generate", "--deny-potentially-breaking-api"]), 2)
        @Expect(runCli(["render", "--input", "missing.json", "--deny-breaking-api"]), 2)
    }

    @TestCase
    func diffParsesApiDenyFlagsAndRejectsGenerationOnlyOptions(): Unit {
        let strict = parseNewCli(["diff", "--baseline", "old.json", "--current", "new.json",
            "--deny-breaking-api", "--format", "json"])
        @Expect(strict.denyBreakingApi, true)
        @Expect(strict.diffFormat, "json")
        let potential = parseNewCli(["diff", "old.json", "new.json",
            "--deny-potentially-breaking-api"])
        @Expect(potential.denyPotentiallyBreakingApi, true)
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "diff", "old.json", "new.json", "--check-examples"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "diff", "old.json", "new.json", "--semantic", "source"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "diff", "old.json", "new.json", "--doc-version", "v1"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "diff", "old.json", "new.json", "--stdlib-doc-version", "1.2.0"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "diff", "old.json", "new.json", "--stdlib-doc-base-url",
            "https://docs.example.test/1.2.0/libs/std"]))
    }

    @TestCase
    func helpListsEverySupportedTopLevelCommandAndDocVersion(): Unit {
        let usage = newUsage()
        @Expect(usage.contains("cjdoc serve"), true)
        @Expect(usage.contains("cjdoc versions compose"), true)
        @Expect(usage.contains("--doc-version"), true)
    }

    @TestCase
    func checkExamplesIsAnExplicitGenerationOption(): Unit {
        let options = parseNewCli(["check", "--check-examples"])
        @Expect(options.checkExamples, true)
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "render", "--input", "docs.json", "--check-examples"]))
    }

    @TestCase
    func chirOptionsAreExplicitAndCommandScoped(): Unit {
        let options = parseNewCli(["generate", "--semantic", "chir", "--cjc", "custom-cjc",
            "--chir-worker", "custom-worker", "--chir-import-path", "dep-a",
            "--chir-import-path", "dep-b"])
        @Expect(options.semanticMode, "chir")
        @Expect(options.cjcExecutable, "custom-cjc")
        @Expect(options.chirWorkerExecutable, Some("custom-worker"))
        @Expect(options.chirImportPaths.toArray(), ["dep-a", "dep-b"])
        @ExpectThrows[IllegalArgumentException](parseNewCli(["generate", "--cjc", "custom-cjc"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli(["generate", "--chir-worker", "worker"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli(["render", "--semantic", "chir"]))
    }

    @TestCase
    func docIrInputMustBeRegularAndWithinTheReadLimit(): Unit {
        let parent = createNewCliTestTempDirectory()
        try {
            @Expect(runCli(["render", "--input", parent.toString(), "--stdout"]), 2)
            let oversized = parent.join("oversized.json")
            File.writeTo(oversized, Array<Byte>(64 * 1024 * 1024 + 1, repeat: 0))
            @Expect(runCli(["render", "--input", oversized.toString(), "--stdout"]), 2)
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func generateRejectsOutputCacheOverlapBeforeCreatingOutput(): Unit {
        let parent = createNewCliTestTempDirectory()
        let output = parent.join("site")
        try {
            @Expect(runCli(["generate", "--project", parent.toString(),
                "--output", output.toString(), "--cache-dir", output.join("cache").toString()]), 2)
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func checkAndStdoutValidateCacheAgainstFutureOutputTransactionState(): Unit {
        let parent = createNewCliTestTempDirectory()
        let lockState = parent.join("target/.cjdoc-output-parent.lock")
        let transactionState = parent.join("target/.cjdoc-output-transaction.txn")
        try {
            Directory.create(parent.join("src"), recursive: true)
            File.writeTo(parent.join("cjpm.toml"), ("[package]\n" +
                "  cjc-version = \"1.1.0\"\n  name = \"cli_cache_isolation\"\n" +
                "  organization = \"\"\n  version = \"0.1.0\"\n" +
                "  output-type = \"static\"\n\n[dependencies]\n").toArray())
            File.writeTo(parent.join("src/api.cj"),
                "package cli_cache_isolation\npublic func answer(): Int64 { 42 }\n".toArray())

            @Expect(runCli(["check", "--project", parent.toString(),
                "--cache-dir", lockState.toString()]), 2)
            @Expect(runCli(["generate", "--project", parent.toString(), "--stdout",
                "--cache-dir", transactionState.toString()]), 2)
            @Expect(!exists(lockState))
            @Expect(!exists(transactionState))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func rendererLimitFallsBackOnlyForGeneratedDocumentationBeforeAnyWrite(): Unit {
        let documentation = public_model.DocumentationSet(
            public_model.GeneratorInfo("cjdoc", "test"), "complete",
            public_model.ProjectInfo("small"), public_model.ConfigurationSnapshot())
        let request = GenerationRequest("unused")
        let (fallback, artifacts) = renderArtifactsWithCommandFallback(documentation,
            ["json"], Some(request), injectResourceLimitForTest: true)
        @Expect(fallback.project.name, "resource-limited")
        @Expect(fallback.diagnostics.size, 1)
        @Expect(fallback.diagnostics[0].code, "CJDOC3027")
        @Expect(artifacts.size, 1)

        let parent = createNewCliTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(renderArtifactsWithCommandFallback(documentation,
                ["json"], None<GenerationRequest>, injectResourceLimitForTest: true))
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func successAnnouncementRunsOnlyAfterStrictLockRelease(): Unit {
        let parent = createNewCliTestTempDirectory()
        let output = parent.join("site")
        let announced = [false]
        try {
            @ExpectThrows(completeLockedOutputCommand(output.toString(), { _ =>
                File.writeTo(parent.join(".cjdoc-output-parent.lock/owner.json"), "{}".toArray())
                0
            }, { => announced[0] = true }))
            @Expect(announced[0], false)
            @Expect(exists(parent.join(".cjdoc-output-parent.lock")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
