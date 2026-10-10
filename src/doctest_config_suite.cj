package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import cjdoc.render as public_render

@When[os == "Windows"]
private func doctestSlowCommand(): (String, Array<String>) {
    ("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Milliseconds 900"])
}

@When[os != "Windows"]
private func doctestSlowCommand(): (String, Array<String>) {
    ("/bin/sh", ["-c", "sleep 0.9"])
}

@When[os == "Windows"]
private func doctestStderrOverflowCommand(): (String, Array<String>, Int64) {
    ("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
        "[Console]::Error.WriteLine('exceeds-bound'); Start-Sleep -Seconds 5"], 2500)
}

@When[os != "Windows"]
private func doctestStderrOverflowCommand(): (String, Array<String>, Int64) {
    // Avoid spawning a second process that could inherit a pipe after the
    // bounded shell is terminated by the output-limit watchdog.
    ("/bin/sh", ["-c", "printf 'exceeds-bound' 1>&2; while :; do :; done"], 700)
}

@Test
class DoctestConfigSuite {
    @TestCase
    func defaultsDisableExecution(): Unit {
        let config = DoctestConfig()
        @Expect(config.mode, "off")
        @Expect(config.timeoutMs, 2000)
        @Expect(config.memoryMb, 2048)
        @Expect(config.jobs, 1)
    }

    @TestCase
    func warningModeKeepsConfiguredBudgets(): Unit {
        let config = DoctestConfig(mode: "warn", timeoutMs: 1500, memoryMb: 4096, jobs: 4)
        @Expect(config.mode, "warn")
        @Expect(config.timeoutMs, 1500)
        @Expect(config.memoryMb, 4096)
        @Expect(config.jobs, 4)
    }

    // Short-lived children once raced SubProcess.wait() closing their pipes,
    // so check the same bounded reader with repeated fast exits.
    @TestCase
    func subprocessPipesDrainBeforeReapingShortLivedChildren(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            for (_ in 0..12) {
                let result = runBoundedProcess("cjc", ["-v"], root, 5000,
                    DOCTEST_MAX_OUTPUT_BYTES)
                @Expect(result.exitCode, 0)
                @Expect(result.timedOut, false)
                @Expect(result.outputLimit, false)
                @Expect(!result.stdout.isEmpty() || !result.stderr.isEmpty(), true)
            }
            let capped = runBoundedProcess("cjc", ["-v"], root, 5000, 1)
            @Expect(capped.outputLimit, true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func stderrOverflowWinsBeforeBlockedStdoutTimesOut(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let (command, arguments, timeoutMs) = doctestStderrOverflowCommand()
            let result = runBoundedProcess(command, arguments, root, timeoutMs, 1)
            @Expect(result.outputLimit, true)
            @Expect(result.timedOut, false)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func subprocessPipeWaitDeadlineRemainsTimeoutNotOutputLimit(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let (command, arguments) = doctestSlowCommand()
            // Non-multiples of 25 ms exercise the gap before the watchdog poll.
            let deadlines: Array<Int64> = [71, 83, 97]
            for (timeout in deadlines) {
                let result = runBoundedProcess(command, arguments, root, timeout,
                    DOCTEST_MAX_OUTPUT_BYTES)
                @Expect(result.timedOut, true)
                @Expect(result.outputLimit, false)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    // Deterministic regression for a watchdog being descheduled until after
    // a short-lived child has already exited and been reaped.
    @TestCase
    func watchdogDoesNotTimeoutAnAlreadyExitedChild(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let process = launch("cjc", ["-v"], workingDirectory: Some(root),
                stdOut: Pipe, stdErr: Pipe)
            let _ = process.wait()
            let state = AtomicInt64(0)
            @Expect(claimDoctestWatchdogTimeout(process, state), false)
            @Expect(state.load(), 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func invalidModeIsRejected(): Unit {
        @ExpectThrows[IllegalArgumentException](DoctestConfig(mode: "report"))
    }

    @TestCase
    func unsafeBudgetsAreRejected(): Unit {
        @ExpectThrows[IllegalArgumentException](DoctestConfig(timeoutMs: 0))
        @ExpectThrows[IllegalArgumentException](DoctestConfig(memoryMb: 2047))
        @ExpectThrows[IllegalArgumentException](DoctestConfig(jobs: 0))
    }

    @TestCase
    func trailingCommentsAfterHeadersAreAccepted(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            File.writeTo(root.join("cjdoc.toml"),
                "[doctest] # enable the CI gate\nmode = \"deny\" # keep this explicit\n".toArray())
            let config = loadDoctestConfig(root.toString())
            @Expect(config.mode, "deny")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func severalExamplesOnOneSymbolKeepUniqueResultIds(): Unit {
        let moduleId = "cjdoc:module:v1:doctest-examples"
        let symbolId = "cjdoc:v2:example::fixture::function:multi#g0()"
        let source = public_model.SourceRange("src/api.cj", public_model.SourcePosition(1, 1, 0),
            public_model.SourcePosition(1, 2, 1))
        let tags = [
            public_model.DocTag("example", "first", "```cj\nlet a = 1\n```"),
            public_model.DocTag("example", "second", "```cj\nlet b = 2\n```"),
            public_model.DocTag("example", "third", "```cj\nlet c = 3\n```")
        ]
        let symbol = public_model.SymbolDoc(symbolId, "function", "multi", "fixture.multi",
            "fixture", moduleId, "public", source, "public func multi(): Unit",
            public_model.SemanticInfo("partial", "ast"),
            documentation: Some(public_model.DocComment("raw", "s", "",
                public_model.MarkdownNode("document", children: []), tags: tags)))
        let documentation = public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "test"),
            "complete", public_model.ProjectInfo("doctest-examples"),
            public_model.ConfigurationSnapshot(lintProfile: "off"),
            providers: [public_model.ProviderInfo("ast", "builtin", moduleId, "partial",
                public_model.SemanticCapabilities(false, false, false, false, false))],
            modules: [public_model.ModuleDoc(moduleId, "doctest-examples", "root", "",
                packageNames: ["fixture"])],
            packages: [public_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
                symbolIds: [symbolId])],
            files: [public_model.FileDoc("src/api.cj", moduleId, "fixture")],
            declarations: [symbol])
        let snippets = collectSnippets(documentation)
        @Expect(snippets.size, 3)
        let ids = HashSet<String>()
        for (snippet in snippets) { let _ = ids.add(snippet.id) }
        @Expect(ids.size, 3)
    }

    @TestCase
    func conflictingExampleStatusesCarryNoClaim(): Unit {
        // Two blocks can share one example title; one may fail while another
        // passes. The key is dropped so a failure never renders as verified.
        let key = public_render.exampleEvidenceKey("sym", "case")
        let cases = [
            doctestEvidenceResult(key, "sym", "case", "passed"),
            doctestEvidenceResult(key, "sym", "case", "failed"),
        ]
        let report = DoctestReport(DoctestConfig(), cases)
        let evidence = exampleEvidenceMap(Some(report))
        @Expect(evidence.contains(key), false)
    }

    @TestCase
    func oneStatusPerKeyKeepsItsClaim(): Unit {
        let key = public_render.exampleEvidenceKey("sym", "case")
        let report = DoctestReport(DoctestConfig(), [doctestEvidenceResult(key, "sym", "case", "passed")])
        let evidence = exampleEvidenceMap(Some(report))
        @Expect(evidence.get(key), Some("passed"))
    }
}

private func doctestEvidenceResult(id: String, symbolId: String, title: String,
    status: String): DoctestCaseResult {
    let snippet = DoctestSnippet(id, symbolId, "fixture", "fixture.api", title, "cj", "let a = 1")
    DoctestCaseResult(snippet, status)
 (fix(example): keep per-block status distinct and fix the evidence link)
}
