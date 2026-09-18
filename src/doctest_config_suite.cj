package cjdoc

import std.unittest.*
import std.unittest.testmacro.*
import std.env.*
import std.fs.*

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
