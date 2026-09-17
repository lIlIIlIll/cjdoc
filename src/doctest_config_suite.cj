package cjdoc

import std.unittest.*
import std.unittest.testmacro.*

@Test
class DoctestConfigSuite {
    @TestCase
    func defaultsDisableExecution(): Unit {
        let config = DoctestConfig()
        @Expect(config.mode, "off")
        @Expect(config.timeoutMs, 2000)
        @Expect(config.memoryMb, 256)
        @Expect(config.jobs, 1)
    }

    @TestCase
    func warningModeKeepsConfiguredBudgets(): Unit {
        let config = DoctestConfig(mode: "warn", timeoutMs: 1500, memoryMb: 512, jobs: 4)
        @Expect(config.mode, "warn")
        @Expect(config.timeoutMs, 1500)
        @Expect(config.memoryMb, 512)
        @Expect(config.jobs, 4)
    }

    @TestCase
    func invalidModeIsRejected(): Unit {
        @ExpectThrows[IllegalArgumentException](DoctestConfig(mode: "report"))
    }

    @TestCase
    func unsafeBudgetsAreRejected(): Unit {
        @ExpectThrows[IllegalArgumentException](DoctestConfig(timeoutMs: 0))
        @ExpectThrows[IllegalArgumentException](DoctestConfig(memoryMb: 1))
        @ExpectThrows[IllegalArgumentException](DoctestConfig(jobs: 0))
    }
}
