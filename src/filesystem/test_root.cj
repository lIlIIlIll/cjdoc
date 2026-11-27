protected package cjdoc.filesystem

import std.collection.ArrayList
import std.env.getCommandLine
import std.fs.*

// Test support: the checkout that owns the fixtures is a fact of the build, not of
// the process that runs the suites. `cjpm test` compiles these sources from this
// tree, but a test process may be started from any working directory, and a bare
// `unittest_bin` executable receives no project environment at all.
//
// Two anchors, cheapest first, both absolute positions the compiler or the loader
// wrote into the binary:
//
// * `argv[0]` of the executing test binary, and
// * the source position of this file, reported by a stack trace.
//
// Either one, walked upward, must reach a directory whose manifest declares this
// module. The process working directory is never consulted, so a fixture path
// cannot silently change with `cd`. There is deliberately no cached result and no
// lock: this file is linked into the product too, and a module-level runtime object
// would then be constructed at static-init time in every CLI process for a helper
// only test processes call.
private let TEST_ROOT_MANIFEST = "cjpm.toml"
private let TEST_ROOT_MANIFEST_MARKER = "name = \"cjdoc\""
private let TEST_ROOT_MAIN_SOURCE = "src/main.cj"

protected func testRepositoryRoot(): Path {
    match (repositoryRootFromCommandLine()) {
        case Some(root) => return root
        case None => ()
    }
    for (anchor in sourcePositionAnchors()) {
        if (let Some(root) <- repositoryRootAbove(anchor)) { return root }
    }
    throw IllegalStateException(
        "cjdoc test root: no checkout above the test binary or its compiled source positions")
}

private func repositoryRootFromCommandLine(): ?Path {
    let command = getCommandLine()
    if (command.isEmpty()) { return None }
    repositoryRootAbove(command[0])
}

// Frames the compiler recorded with a path that is not absolute (stdlib sources)
// cannot anchor a filesystem walk and are skipped.
private func sourcePositionAnchors(): Array<String> {
    let anchors = ArrayList<String>()
    try {
        throw Exception("cjdoc test root anchor")
    } catch (error: Exception) {
        for (element in error.getStackTrace()) {
            if (!element.fileName.isEmpty() && Path(element.fileName).isAbsolute()) {
                anchors.add(element.fileName)
            }
        }
    }
    anchors.toArray()
}

private func repositoryRootAbove(anchor: String): ?Path {
    if (!Path(anchor).isAbsolute()) { return None }
    var directory = Path(anchor).parent
    var found: ?Path = None
    var searching = true
    while (searching) {
        if (isTestCheckout(directory)) {
            found = Some(canonicalize(directory))
            searching = false
        } else {
            let parent = directory.parent
            if (parent.toString() == directory.toString()) {
                searching = false
            } else {
                directory = parent
            }
        }
    }
    found
}

private func isTestCheckout(directory: Path): Bool {
    let manifest = directory.join(TEST_ROOT_MANIFEST)
    if (!exists(manifest) || !exists(directory.join(TEST_ROOT_MAIN_SOURCE))) { return false }
    // The upward walk may pass directories whose manifest this process cannot read;
    // an unreadable candidate is simply not this checkout.
    try {
        String.fromUtf8(File.readFrom(manifest)).contains(TEST_ROOT_MANIFEST_MARKER)
    } catch (_: Exception) {
        false
    }
}
