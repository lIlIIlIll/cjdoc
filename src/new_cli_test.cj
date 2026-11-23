package cjdoc

import cjdoc.cli.{parseNewCli, schemaTextForCli}
import cjdoc.output.{prepareOutputAndCacheDirectories, withOutputPublication}
import cjdoc.model as public_model
import cjdoc.render as api_render
import cjdoc.schema_data.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func createNewCliTestTempDirectory(): Path {
    Directory.createTemp(canonicalize(getTempDirectory()))
}

@Test
class NewCliRegressionTest {
    @TestCase
    func currentSchemaInventoryRejectsRemovedNames(): Unit {
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("doc-ir-v15"))
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("api-surface-v2"))
        @ExpectThrows[IllegalArgumentException](schemaTextForCli("doctest-results"))
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
            @ExpectThrows(withOutputPublication(output.toString(), false, { _ =>
                File.writeTo(parent.join(".cjdoc-output-parent.lock/owner.json"), "{}".toArray())
                0
            }, afterRelease: { => announced[0] = true }))
            @Expect(announced[0], false)
            @Expect(exists(parent.join(".cjdoc-output-parent.lock")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}

private func cliSpoolInputDocumentation(
    diagnostics!: Array<public_model.Diagnostic> = []): public_model.DocumentationSet {
    public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "test"), "partial",
        public_model.ProjectInfo("spool-cli"), public_model.ConfigurationSnapshot(lintProfile: "off"),
        diagnostics: diagnostics)
}

private func cliSpoolWriteInput(path: Path, documentation: public_model.DocumentationSet): Unit {
    File.writeTo(path, api_render.encodeDocIr(documentation).toArray())
}

@Test
class CliOutputSpoolTest {
    @TestCase
    func rejectedWriteOnFailureRebuildKeepsOldOwnedAndUnownedFiles(): Unit {
        let parent = createNewCliTestTempDirectory()
        let output = parent.join("site")
        let input = parent.join("docs.json")
        try {
            cliSpoolWriteInput(input, cliSpoolInputDocumentation())
            let options = parseNewCli(["render", "--input", input.toString(),
                "--format", "html", "--output", output.toString()])
            let (prepared, cache) = prepareOutputAndCacheDirectories(output.toString(), None<String>)
            // First serve-style rebuild publishes, the second is gated off by a
            // diagnostic error, exactly like serve's writeOnFailure=false.
            @Expect(runServeRebuild(options, prepared, cache, false), 0)
            let accepted = File.readFrom(output.join("html/index.html"))
            File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
            cliSpoolWriteInput(input, cliSpoolInputDocumentation(
                diagnostics: [public_model.Diagnostic("error", "CJDOC4027", "Presentation failed")]))
            @Expect(runServeRebuild(options, prepared, cache, false), 1)
            @Expect(File.readFrom(output.join("html/index.html")), accepted)
            @Expect(File.readFrom(output.join("CNAME")), "docs.example.test\n".toArray())
            // The rejected spool and its lock state must not survive.
            @Expect(!exists(parent.join(".cjdoc-output-parent.lock")))
            @Expect(!exists(parent.join(".cjdoc-output-transaction.preparing")))
            @Expect(!exists(parent.join(".cjdoc-output-transaction.txn")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func rendererResourceFallbackRestartsFromAnEmptySpool(): Unit {
        let parent = createNewCliTestTempDirectory()
        let output = parent.join("site")
        try {
            @Expect(withOutputPublication(output.toString(), false, { publication =>
                let store = publication.begin()
                let _ = store.addText("stale.html", "text/html", "<p>stale</p>")
                let fallback = renderArtifactsIntoWithCommandFallback(store, { => publication.restart() },
                    cliSpoolInputDocumentation(), ["json"], Some(GenerationRequest("unused", lintProfile: "off")),
                    injectResourceLimitForTest: true)
                @Expect(fallback.project.name, "resource-limited")
                @Expect(fallback.apiCollectionState, "unavailable")
                @Expect(fallback.diagnostics[0].code, "CJDOC3027")
                0
            }), 0)
            @Expect(!exists(output.join("stale.html")))
            let published = api_render.decodeDocIr(
                String.fromUtf8(File.readFrom(output.join("docs.json"))))
            @Expect(published.project.name, "resource-limited")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func directoryOutputPublishesVersionAndLanguageHomes(): Unit {
        let parent = createNewCliTestTempDirectory()
        let output = parent.join("multilingual")
        let input = parent.join("docs.json")
        try {
            cliSpoolWriteInput(input, public_model.DocumentationSet(
                public_model.GeneratorInfo("cjdoc", "test"), "partial",
                public_model.ProjectInfo("spool-multilingual"),
                public_model.ConfigurationSnapshot(lintProfile: "off"),
                languageOptions: Some(public_model.DocumentationLanguageOptions("en",
                    languages: ["en", "zh-CN"]))))
            @Expect(runCli(["render", "--input", input.toString(), "--format", "html",
                "--all-languages", "--doc-version", "v1.2.0", "--output", output.toString()]), 0)
            for (language in ["en", "zh-CN"]) {
                let home = String.fromUtf8(File.readFrom(output.join("html/${language}/index.html")))
                @Expect(home.contains("spool-multilingual"))
            }
            let manifest = JsonNode.parse(String.fromUtf8(
                File.readFrom(output.join("site-manifest.json")))).asObject()
            @Expect(manifest["schemaVersion"].asString(), "cjdoc.site-manifest/1")
            @Expect(manifest["version"].asString(), "v1.2.0")
            let version = JsonNode.parse(String.fromUtf8(
                File.readFrom(output.join("html/version.json")))).asObject()
            @Expect(version["schemaVersion"].asString(), "cjdoc.version/1")
            @Expect(version["id"].asString(), "v1.2.0")
            @Expect(version["label"].asString(), "v1.2.0")
            @Expect(version["project"].asString(), "spool-multilingual")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
