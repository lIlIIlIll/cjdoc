package cjdoc

import cjdoc.filesystem.testRepositoryRoot
import std.fs.*

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

internal func reportNativeDegraded(requirement: String, reason: String): Unit {
    // The STS wrapper runs without unittest output capture and tallies these
    // bounded, test-authored records. Product messages are not tally inputs.
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
