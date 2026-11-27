protected package cjdoc.filesystem

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// The root is resolved from positions the compiler wrote into this binary, so these
// cases fail if the resolution ever falls back to the process working directory: the
// anchors are checked as absolute source/binary positions, and the fixture they
// reach must be the checkout's own.
@Test
class TestRootTest {
    @TestCase
    func rootIsTheCheckoutItselfNotTheWorkingDirectory(): Unit {
        let root = testRepositoryRoot()
        @Expect(root.isAbsolute(), true)
        let manifest = root.join("cjpm.toml")
        @Expect(exists(manifest), true)
        @Expect(String.fromUtf8(File.readFrom(manifest)).contains("name = \"cjdoc\""), true)
        @Expect(exists(root.join("src/main.cj")), true)
        // A build-bound anchor is an absolute path inside this checkout, so this file's
        // own source is reachable from the resolved root.
        @Expect(exists(root.join("src/filesystem/test_root.cj")), true)
    }

    @TestCase
    func resolvedRootIsStableAcrossCalls(): Unit {
        let first = testRepositoryRoot()
        let second = testRepositoryRoot()
        @Expect(first.toString(), second.toString())
    }
}
