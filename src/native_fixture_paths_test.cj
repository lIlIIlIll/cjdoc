package cjdoc

import std.env.*
import std.fs.*

// cjpm's build cwd is not a test input. The STS wrapper supplies the checkout
// root to all test processes, including executables launched from elsewhere.
internal func nativeFixturePath(relative: String): String {
    let root = getVariable("CJDOC_TEST_ROOT").getOrDefault({ => getWorkingDirectory().toString() })
    Path(root).join(relative).toString()
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
