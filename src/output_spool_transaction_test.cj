package cjdoc

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Windows"]
import std.posix.*

// White-box regressions for the disk spool -> sealed inventory -> transaction
// chain. They exercise the real spool and the real commit path; only the
// failure injection and the manual inventory tampering are synthetic.
private func withSpoolTestLock(output: Path, action: (OutputLockHandle) -> Unit): Unit {
    let handle = acquireOutputLock(output)
    var actionError: ?Exception = None
    try {
        action(handle)
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

private func spoolPayloadFiles(spoolDirectory: Path): Array<Path> {
    let files = ArrayList<Path>()
    for (entry in Directory.readFrom(spoolDirectory)) {
        files.add(entry.path)
    }
    files.toArray()
}

private func expectNoTransactionState(parent: Path): Unit {
    @Expect(!exists(fixedBootstrapDirectory(parent)))
    @Expect(!exists(fixedPreparingDirectory(parent)))
    @Expect(!exists(fixedTransactionDirectory(parent)))
    @Expect(!exists(fixedRetiredDirectory(parent)))
}

private func spoolCreationRejected(lock: OutputLockHandle): Bool {
    try {
        let _ = OutputArtifactSpool(lock)
        false
    } catch (_: IllegalStateException) { true }
}

private func commitWithRejectedContract(output: Path, spool: OutputArtifactSpool,
    lock: OutputLockHandle): Unit {
    writeOwnedSpoolLocked(output.toString(), spool, false, None<Int64>, None<Int64>,
        None<String>, lock, { => throw IllegalStateException("contract gate rejected the site") })
}

@Test
class OutputSpoolTransactionTest {
    @TestCase
    func discardedHalfRenderPublishesNothingAndPreservesTheOwnedSite(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second"),
                    outputArtifact("html/index.html", "half rendered")])
                @Expect(spoolPayloadFiles(spool.path).size, 2)
                // The renderer aborts before it ever asks for a transaction.
                spool.discard()
                @Expect(!exists(spool.path))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
                @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                expectNoTransactionState(parent)
            })
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
            @Expect(!exists(parent.join(OUTPUT_LOCK_NAME)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func abortBeforeCommitLeavesTheOldSiteAndARecoverableTransaction(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second"),
                    outputArtifact("markdown/index.md", "markdown")])
                @ExpectThrows(commitWithRejectedContract(output, spool, lock))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                @Expect(exists(fixedTransactionDirectory(parent)))
            })

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
            @Expect(!exists(output.join("markdown")))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func unregisteredSpoolInventoryEntryBlocksPublication(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second")])
                let _ = spool.seal()
                File.writeTo(spool.path.join("stray.payload"), "stray".toArray())
                @ExpectThrows(writeOwnedSpoolWithLockHeld(output.toString(), spool, lock))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                expectNoTransactionState(parent)
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func sealedPayloadDigestTamperingBlocksPublication(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second"),
                    outputArtifact("html/index.html", "html")])
                let _ = spool.seal()
                let payloads = spoolPayloadFiles(spool.path)
                @Expect(payloads.size, 2)
                // Same size, different bytes: only the recorded digest can tell.
                for (payload in payloads) {
                    File.writeTo(payload, Array<Byte>(FileInfo(payload).size, repeat: UInt8(0x7A)))
                }
                @ExpectThrows(writeOwnedSpoolWithLockHeld(output.toString(), spool, lock))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(!exists(output.join("html")))
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                expectNoTransactionState(parent)
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func unsealedSpoolCannotBeStaged(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second")])
                let strayStage = parent.join("stray-stage")
                Directory.create(strayStage)
                @ExpectThrows(spool.stageInto(strayStage))
                @Expect(!exists(strayStage.join("docs.json")))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                expectNoTransactionState(parent)
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func replacementChargesOnlyThePayloadDeltaAgainstTheLoweredBudget(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock, artifactLimit: 22, totalLimit: 22, entryLimit: 4)
                let first = spool.addText("a.txt", "text/plain", "0123456789")
                let _ = spool.addText("b.txt", "text/plain", "0123456789")
                // 20 of 22 bytes are stored. The replacement final total is
                // 12 + 10 = 22, so exactly 22 proves only the delta was charged;
                // charging the replaced 10 bytes again would need 32 and fail.
                spool.replaceText(first, "0123456789ab")
                @Expect(spool.readText(first, 64), "0123456789ab")
                // 13 + 10 = 23 genuinely exceeds the lowered budget.
                @ExpectThrows(spool.replaceText(first, "0123456789abc"))
                @Expect(spool.readText(first, 64), "0123456789ab")
                writeOwnedSpoolWithLockHeld(output.toString(), spool, lock)
            })
            @Expect(String.fromUtf8(File.readFrom(output.join("a.txt"))), "0123456789ab")
            @Expect(String.fromUtf8(File.readFrom(output.join("b.txt"))), "0123456789")
            let manifest = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            @Expect(manifest.contains(Sha256Digest.digest("0123456789ab")))
            @Expect(manifest.contains(Sha256Digest.digest("0123456789")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func existingUnknownSpoolIsRejectedAndPreserved(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spoolDirectory = lock.path.join("spool")
                Directory.create(spoolDirectory)
                File.writeTo(spoolDirectory.join("unknown.payload"), "unknown".toArray())
                @Expect(spoolCreationRejected(lock), true)
                @Expect(exists(spoolDirectory.join("unknown.payload")))
                @Expect(String.fromUtf8(File.readFrom(spoolDirectory.join("unknown.payload"))),
                    "unknown")
            })
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}

@When[os != "Windows"]
@Test
class OutputSpoolSymlinkTamperTest {
    @TestCase
    func symbolicLinkPayloadIsRejectedBeforePublication(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            withSpoolTestLock(output, { lock =>
                let spool = OutputArtifactSpool(lock)
                spool.appendArtifacts([outputArtifact("docs.json", "second")])
                let _ = spool.seal()
                let payloads = spoolPayloadFiles(spool.path)
                @Expect(payloads.size, 1)
                let decoy = parent.join("decoy.txt")
                File.writeTo(decoy, "second".toArray())
                let _ = removeIfExists(payloads[0])
                @Expect(symlink(decoy.toString(), payloads[0].toString()), 0)
                @ExpectThrows(writeOwnedSpoolWithLockHeld(output.toString(), spool, lock))
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
                expectNoTransactionState(parent)
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
