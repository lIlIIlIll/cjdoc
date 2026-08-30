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
    func versionedSchemaNamesRouteToTheirExactVersions(): Unit {
        @Expect(schemaTextForCli("doc-ir-v7"), DOC_IR_V7_SCHEMA)
        @Expect(schemaTextForCli("doc-ir-v8"), DOC_IR_V8_SCHEMA)
        @Expect(schemaTextForCli("list").contains("doc-ir-v8\n"), true)
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
