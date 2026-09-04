package cjdoc

import cjdoc.render.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

internal func outputArtifact(path: String, content: String): RenderArtifact {
    RenderArtifact(path, "text/plain", content)
}

internal func createOutputTestTempDirectory(): Path {
    Directory.createTemp(canonicalize(getTempDirectory()))
}

internal func findTransactionDirectory(parent: Path): Path {
    for (entry in Directory.readFrom(parent)) {
        if (entry.name.startsWith(".cjdoc-output-") && entry.name.endsWith(".txn")) {
            return entry.path
        }
    }
    throw IllegalStateException("missing output transaction directory")
}

internal func findLockDirectory(parent: Path): Path {
    for (entry in Directory.readFrom(parent)) {
        if (entry.name.startsWith(".cjdoc-output-") && entry.name.endsWith(".lock")) {
            return entry.path
        }
    }
    throw IllegalStateException("missing output lock directory")
}

internal func fixedTransactionDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.txn")
}

internal func fixedPreparingDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.preparing")
}

internal func fixedBootstrapDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.bootstrap")
}

internal func fixedRetiredDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.retired")
}

internal func expectOriginalOutput(output: Path, manifest: Array<Byte>): Unit {
    @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
    @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
    @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
}

