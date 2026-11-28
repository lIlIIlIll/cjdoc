package cjdoc

import cjdoc.filesystem.testRepositoryRoot
import std.env.atExit
import std.fs.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

// The checkout is a build fact: `testRepositoryRoot()` resolves it from the
// compiled source position or the test binary's own path, never from the process
// working directory, so a fixture path cannot change when a suite is started
// elsewhere or when a bare `unittest_bin` executable runs without project
// environment.
internal func nativeFixturePath(relative: String): String {
    testRepositoryRoot().join(relative).toString()
}

internal func nativeTestBinary(): String {
    let binary = nativeFixturePath("target/release/bin/main")
    if (exists(binary + ".exe")) { return binary + ".exe" }
    binary
}

// A native runner can split a package across processes. Count actual fallback
// branches in each process; cjpm.toml keeps their reports visible for plain tests.
private class NativeDegradationTally {
    private let recorded = AtomicInt64(0)

    init() {
        atExit({ => eprintln("CJDOC_TEST_DEGRADED_TOTAL ${recorded.load()}") })
    }

    func record(): Unit {
        let _ = recorded.fetchAdd(1)
    }
}

private let NATIVE_DEGRADATION_TALLY = NativeDegradationTally()

internal func reportNativeDegraded(requirement: String, reason: String): Unit {
    NATIVE_DEGRADATION_TALLY.record()
    eprintln("CJDOC_TEST_DEGRADED ${requirement}: ${reason}")
}

internal func reportNativePlatformRefusal(requirement: String, reason: String): Unit {
    // A platform contract the suite verified by refusing to run user code. It is
    // recorded separately: the degraded tally means "a required behavior was not
    // verified", and this line means the opposite on the hosts that require it.
    eprintln("CJDOC_TEST_PLATFORM_REFUSAL ${requirement}: ${reason}")
}

@When[os == "Linux"]
internal func nativeTestHost(): String { "Linux" }

@When[os == "Windows"]
internal func nativeTestHost(): String { "Windows" }

@When[os == "macOS"]
internal func nativeTestHost(): String { "macOS" }

// Any other host target is not one the suite makes platform claims about.
@When[os != "Linux" && os != "Windows" && os != "macOS"]
internal func nativeTestHost(): String { "unsupported" }

@Test
class NativeDegradationReportingTest {
    // The path helper stays anchored to the compiled checkout, so a fixture path
    // cannot start depending on the process working directory again.
    @TestCase
    func fixturePathsStayAnchoredToTheCompiledCheckout(): Unit {
        let root = testRepositoryRoot()
        @Expect(root.isAbsolute(), true)
        let fixture = nativeFixturePath("tests/fixtures/projects")
        @Expect(fixture, root.join("tests/fixtures/projects").toString())
        @Expect(fixture.startsWith(root.toString() + "/") ||
            fixture.startsWith(root.toString() + "\\"), true)
    }
}
