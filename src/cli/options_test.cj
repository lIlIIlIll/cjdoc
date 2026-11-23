protected package cjdoc.cli

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CliOptionsTest {
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
        // CHIR is the command-line default, so compiler/worker options need no
        // explicit --semantic, while source mode still rejects them.
        @Expect(parseNewCli(["generate", "--cjc", "custom-cjc"]).semanticMode, "chir")
        @Expect(parseNewCli(["generate", "--chir-worker", "worker"]).semanticMode, "chir")
        @ExpectThrows[IllegalArgumentException](parseNewCli([
            "generate", "--semantic", "source", "--chir-worker", "worker"]))
        // serve shares the semantic switch; offline and analysis commands do not.
        @Expect(parseNewCli(["serve", "--semantic", "source"]).semanticMode, "source")
        @ExpectThrows[IllegalArgumentException](parseNewCli(["render", "--semantic", "chir"]))
    }
}
