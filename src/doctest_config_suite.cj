package cjdoc

import std.unittest.*
import std.unittest.testmacro.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*

@When[os == "Windows"]
private func doctestSlowCommand(): (String, Array<String>) {
    ("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Milliseconds 900"])
}

@When[os != "Windows"]
private func doctestSlowCommand(): (String, Array<String>) {
    ("/bin/sh", ["-c", "sleep 0.9"])
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
}
