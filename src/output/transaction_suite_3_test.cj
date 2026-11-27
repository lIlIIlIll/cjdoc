protected package cjdoc.output

import cjdoc.digest.Sha256Digest
import cjdoc.render.*
import std.collection.ArrayList
@When[os == "Linux"]
import std.env.{getProcessId}
import std.fs.*
@When[os != "Windows"]
import std.posix.symlink
@When[os == "Linux"]
import std.process.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OutputTransactionSuite3 {
    @TestCase
    func textArtifactsPreserveUtf8AndNulAcrossChunkBoundaries(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            let bytes = Array<Byte>(2 * 64 * 1024 + 13, repeat: UInt8(0x61))
            let boundary: Array<Byte> = [0xE6, 0xB1, 0x89, 0xE5, 0xAD, 0x97, 0]
            for (index in 0..boundary.size) { bytes[64 * 1024 - 1 + index] = boundary[index] }
            let content = String.fromUtf8(bytes)
            writeOwnedArtifacts(output.toString(), [
                RenderArtifact("data.txt", "text/plain; charset=utf-8", content)])
            @Expect(File.readFrom(output.join("data.txt")), bytes)
            let manifest = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            @Expect(manifest.contains("221e3210888ff233c33eb050233161709e0159fff0ca1842b45b7bb1dd76feba"))
            writeOwnedArtifacts(output.toString(), [
                RenderArtifact("data.txt", "text/plain; charset=utf-8", "短")])
            @Expect(String.fromUtf8(File.readFrom(output.join("data.txt"))), "短")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func outputAndCacheOverlapIsRejectedBeforeCreatingEitherDirectory(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(prepareOutputAndCacheDirectories(output.toString(),
                Some(output.join("cache").toString())))
            @Expect(!exists(output))

            let cache = parent.join("cache")
            @ExpectThrows(prepareOutputAndCacheDirectories(cache.join("site").toString(),
                Some(cache.toString())))
            @Expect(!exists(cache))

            @ExpectThrows(prepareOutputAndCacheDirectories(
                parent.join("alias/../same").toString(), Some(parent.join("same").toString())))
            @Expect(!exists(parent.join("same")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func cacheCannotEnterAnyPortableInternalStateNamespace(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let names: Array<String> = [
            ".cjdoc-output-parent.lock",
            ".CJDOC-OUTPUT-PARENT.BOOTSTRAP.",
            ".cjdoc-output-parent.retired",
            ".CJDOC-OUTPUT-TRANSACTION.BOOTSTRAP.",
            ".cjdoc-output-transaction.preparing",
            ".CjDoC-OuTpUt-TrAnSaCtIoN.TxN ",
            ".cjdoc-output-transaction.retired"
        ]
        try {
            for (name in names) {
                @ExpectThrows(prepareOutputAndCacheDirectories(output.toString(),
                    Some(parent.join(name).join("cache/child").toString())))
            }
            @Expect(Directory.isEmpty(parent))
            @ExpectThrows(prepareOutputAndCacheDirectories(
                parent.join(".CJDOC-OUTPUT-TRANSACTION.RETIRED.").toString(),
                Some(parent.join("cache").toString())))
            @Expect(Directory.isEmpty(parent))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func stagedStreamingDigestCrossesChunkBoundaryAndArtifactBudgetsFailEarly(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            let bytes = Array<Byte>(64 * 1024 + 13, repeat: UInt8(0x61))
            writeOwnedArtifacts(output.toString(), [RenderArtifact("asset.bin", "application/octet-stream", bytes)])
            let manifest = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            @Expect(manifest.contains(Sha256Digest.digestBytes(bytes)))

            @ExpectThrows(writeOwnedArtifacts(parent.join("oversized").toString(), [
                RenderArtifact("asset.bin", "application/octet-stream",
                    Array<Byte>(64 * 1024 * 1024 + 1, repeat: 0))]))
            @Expect(!exists(parent.join("oversized")))
            @ExpectThrows(validateOutputArtifactBudgetForTest(
                [64 * 1024 * 1024, 64 * 1024 * 1024, 64 * 1024 * 1024,
                 64 * 1024 * 1024, 64 * 1024 * 1024, 64 * 1024 * 1024,
                 64 * 1024 * 1024, 64 * 1024 * 1024, 1]))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func oversizedGeneratedManifestIsRejectedBeforePreparationPublish(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            let hugePath = String.fromUtf8(Array<Byte>(8 * 1024 * 1024, repeat: UInt8(0x61)))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact(hugePath, "")]))
            @Expect(!exists(output))
            @Expect(!exists(fixedPreparingDirectory(parent)))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func longUtf8ArtifactNamesFitWhenTheirSerializedManifestFits(): Unit {
        let budget = OutputArtifactPathBudget()
        let prefix = String.fromUtf8(Array<Byte>(205, repeat: b'a'))
        let digest = Sha256Digest.digest("")
        let files = ArrayList<OwnedOutputFile>()
        for (index in 0..6500) {
            let path = "目录/${prefix}-${index}.html"
            let allowance = budget.check(path)
            budget.commit(path, allowance)
            files.add(OwnedOutputFile(path, digest))
        }
        let serialized = outputManifest(files.toArray())
        let parsed = parseOwnedManifest(serialized)
        @Expect(parsed.directories, ["目录"])
        @Expect(parsed.files.size, 6500)
        @Expect(parsed.files[6499].path, "目录/${prefix}-6499.html")
    }

    @TestCase
    func oversizedManifestAndTransactionPlanFailBeforeParsing(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            File.writeTo(output.join(".cjdoc-output.json"),
                Array<Byte>(8 * 1024 * 1024 + 1, repeat: 0))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")

            let fresh = parent.join("fresh")
            @ExpectThrows(writeOwnedArtifacts(fresh.toString(), [outputArtifact("docs.json", "next")],
                interruptAfterOperation: Some(1)))
            let transaction = findTransactionDirectory(parent)
            File.writeTo(transaction.join("plan.json"),
                Array<Byte>(64 * 1024 * 1024 + 1, repeat: 0))
            @ExpectThrows(writeOwnedArtifacts(fresh.toString(), [outputArtifact("docs.json", "later")]))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func nearLimitNoncanonicalManifestRemainsSafelyUpdatable(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let canonical = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            let paddingSize = 8 * 1024 * 1024 - canonical.toArray().size
            let padding = String.fromUtf8(Array<Byte>(paddingSize, repeat: UInt8(0x20)))
            File.writeTo(output.join(".cjdoc-output.json"), (padding + canonical).toArray())

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func oversizedLockOwnerFailsBeforeParsing(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(withOutputLock(output.toString(), { =>
                let lock = findLockDirectory(parent)
                File.writeTo(lock.join("owner.json"), Array<Byte>(64 * 1024 + 1, repeat: 0))
                @ExpectThrows(writeOwnedArtifacts(output.toString(),
                    [outputArtifact("docs.json", "blocked")]))
                @Expect(!exists(output))
            }))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func secondWriterFailsImmediatelyWhileLockOwnerIsAlive(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let equivalent = parent.join("nested/../site")
        try {
            withOutputLock(output.toString(), { =>
                @ExpectThrows(writeOwnedArtifacts(equivalent.toString(),
                    [outputArtifact("docs.json", "blocked")]))
                @Expect(!exists(output))
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func lockReleaseOwnershipFailureIsReportedAndLeavesFixedEvidence(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(withOutputLockReleaseFailureForTest(output.toString(), { => }))
            let lock = parent.join(".cjdoc-output-parent.lock")
            @Expect(exists(lock))
            let evidence = File.readFrom(lock.join("owner.json"))
            @Expect(evidence.size <= 64 * 1024)
            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "blocked")]))
            @Expect(exists(lock))
            @Expect(File.readFrom(lock.join("owner.json")), evidence)
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func unknownProcessQueryNeverAuthorizesStaleLockRecovery(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let lock = parent.join(".cjdoc-output-parent.lock")
        // An owner PID outside pid_t can never be proven absent, so recovery
        // must stay refused even though the owner is certainly not this writer.
        let unrepresentablePid = Int64(Int32.Max) + 1
        try {
            Directory.create(lock)
            let owner = outputLockOwnerContent(OutputLockOwner(unrepresentablePid, "unknown",
                outputProcessDomainSha256(), "test-token", output.toString())).toArray()
            File.writeTo(lock.join("owner.json"), owner)
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "blocked")]))
            @Expect(File.readFrom(lock.join("owner.json")), owner)
            @Expect(!exists(parent.join(".cjdoc-output-parent.retired")))
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}

// The absent-owner proof is Linux-only, so the end-to-end recovery of an
// interrupted writer is guarded rather than weakened into a synthetic state.
@When[os == "Linux"]
private func reapedAbsentPid(): Int64 {
    // Recovery reaches the kernel query only for an owner whose std process
    // lookup failed, which is what a reaped PID produces. Rechecking absence here
    // keeps that premise explicit: an unrelated process that recycled the PID
    // would make the state Unknown or Alive, so the loop retries with a new child
    // instead of asserting on the wrong branch.
    var attempt: Int64 = 0
    while (attempt < 8) {
        let child = launch("/bin/sh", ["-c", "exit 0"])
        let pid = child.pid
        let _ = child.wait()
        let absent = match (processPresenceState(pid)) {
            case OutputProcessState.Dead => true
            case OutputProcessState.Alive | OutputProcessState.Unknown => false
        }
        if (absent) { return pid }
        attempt++
    }
    throw IllegalStateException("unable to observe a reaped child process as absent")
}

@When[os == "Linux"]
@Test
class OutputStaleLockAbsenceProofTest {
    @TestCase
    func liveOwnerIsNeverProvenAbsent(): Unit {
        // The proof is only safe in one direction: an owner whose process is
        // still running must stay Alive, or recovery could steal a lock from a
        // writer that is still working.
        let pid = getProcessId()
        let owner = OutputLockOwner(pid, findProcess(pid).startTime.toString(),
            outputProcessDomainSha256(), "live-token", "live-root")
        @Expect(match (ownerProcessState(owner)) {
            case OutputProcessState.Alive => true
            case OutputProcessState.Dead | OutputProcessState.Unknown => false
        })
        @Expect(match (processPresenceState(pid)) {
            case OutputProcessState.Dead => false
            case OutputProcessState.Alive | OutputProcessState.Unknown => true
        })
    }

    @TestCase
    func reapedWriterRecoversItsLockAndSpoolWithoutTouchingPublishedOutput(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let lock = parent.join(OUTPUT_LOCK_NAME)
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
            let publishedManifest = File.readFrom(output.join(".cjdoc-output.json"))

            // The interrupted writer died while its spool still held payloads and
            // was then reaped, which is exactly the case std.process reports only
            // as an opaque query failure.
            let reapedPid = reapedAbsentPid()
            Directory.create(lock)
            let owner = outputLockOwnerContent(OutputLockOwner(reapedPid, "interrupted-writer",
                outputProcessDomainSha256(), "test-token", output.toString())).toArray()
            File.writeTo(lock.join("owner.json"), owner)
            Directory.create(lock.join("spool"))
            File.writeTo(lock.join("spool/0-0.payload"), "half rendered".toArray())
            File.writeTo(lock.join("spool/1-1.payload"), "half rendered page".toArray())

            // Acquisition is the whole recovery point: it must reclaim only the
            // stale fixed state and leave the publication its predecessor wrote.
            let handle = acquireOutputLock(output)
            try {
                @Expect(File.readFrom(output.join(".cjdoc-output.json")), publishedManifest)
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
                @Expect(File.readFrom(output.join("CNAME")), "docs.example.test\n".toArray())
                @Expect(!exists(lock.join("spool")))
                @Expect(readOutputLockOwner(lock).pid, handle.pid)
                @Expect(!exists(parent.join(OUTPUT_RETIRED_LOCK_NAME)))
            } finally { releaseOutputLock(handle) }

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            // The unowned file survives, while the owned artifact the new
            // generation no longer produces is retired with its ownership record.
            @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")
            @Expect(!exists(output.join("html/index.html")))
            @Expect(!exists(lock))
            @Expect(!exists(parent.join(OUTPUT_RETIRED_LOCK_NAME)))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func missingOrForeignProcessDomainNeverReclaimsPublishedOutputOrSpool(): Unit {
        let reapedPid = reapedAbsentPid()
        let currentPid = getProcessId()
        let observations = [(currentPid, findProcess(currentPid).startTime.toString()),
            (currentPid, "other-start-time"), (reapedPid, "interrupted-writer")]
        let domains: Array<Option<String>> = [
            None, Some("0000000000000000000000000000000000000000000000000000000000000000")]
        for (domain in domains) {
            for ((pid, startTime) in observations) {
                let parent = createOutputTestTempDirectory()
                let output = parent.join("site")
                let lock = parent.join(OUTPUT_LOCK_NAME)
                try {
                    writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                        outputArtifact("html/index.html", "published")])
                    File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
                    let manifest = File.readFrom(output.join(OUTPUT_MANIFEST_NAME))
                    Directory.create(lock)
                    let capturedOwner = OutputLockOwner(pid, startTime,
                        domain, "test-token", output.toString())
                    @Expect(match (ownerProcessState(capturedOwner)) {
                        case OutputProcessState.Unknown => true
                        case OutputProcessState.Alive | OutputProcessState.Dead => false
                    })
                    let owner = outputLockOwnerContent(capturedOwner).toArray()
                    File.writeTo(lock.join("owner.json"), owner)
                    Directory.create(lock.join("spool"))
                    File.writeTo(lock.join("spool/0-0.payload"), "private partial output".toArray())
                    @ExpectThrows(writeOwnedArtifacts(output.toString(),
                        [outputArtifact("docs.json", "must not publish")]))
                    @Expect(File.readFrom(lock.join("owner.json")), owner)
                    @Expect(File.readFrom(lock.join("spool/0-0.payload")),
                        "private partial output".toArray())
                    @Expect(File.readFrom(output.join(OUTPUT_MANIFEST_NAME)), manifest)
                    @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
                    @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "published")
                    @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")
                    @Expect(!exists(parent.join(OUTPUT_RETIRED_LOCK_NAME)))
                    @Expect(!exists(parent.join(OUTPUT_PREPARING_NAME)))
                    @Expect(!exists(parent.join(OUTPUT_TRANSACTION_NAME)))
                } finally { let _ = removeIfExists(parent, recursive: true) }
            }
        }
    }

    @TestCase
    func legacyOwnerWithoutProcessDomainNeverAuthorizesRecovery(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let lock = parent.join(OUTPUT_LOCK_NAME)
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
            let manifest = File.readFrom(output.join(OUTPUT_MANIFEST_NAME))
            let pid = reapedAbsentPid()
            Directory.create(lock)
            let owner = ("{\"schemaVersion\":\"cjdoc.output-lock/1\"," +
                "\"pid\":\"${pid}\",\"startTime\":\"interrupted-writer\"," +
                "\"token\":\"test-token\",\"root\":\"${output}\"}\n").toArray()
            File.writeTo(lock.join("owner.json"), owner)
            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "must not publish")]))
            @Expect(File.readFrom(lock.join("owner.json")), owner)
            @Expect(File.readFrom(output.join(OUTPUT_MANIFEST_NAME)), manifest)
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")
            @Expect(!exists(parent.join(OUTPUT_RETIRED_LOCK_NAME)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}

@When[os != "Windows"]
@Test
class OutputSymlinkAncestorTest {
    @TestCase
    func symbolicLinkAncestorIsRejectedEvenWhenForceOwnedIsEnabled(): Unit {
        let parent = createOutputTestTempDirectory()
        try {
            let real = parent.join("real")
            Directory.create(real)
            let link = parent.join("linked")
            @Assert(symlink(real.toString(), link.toString()), 0)
            @ExpectThrows(writeOwnedArtifacts(link.join("cjdoc-output").toString(),
                [outputArtifact("docs.json", "blocked")], forceOwned: true))
            @ExpectThrows(writeOwnedArtifacts(parent.join("missing/../linked/cjdoc-output").toString(),
                [outputArtifact("docs.json", "blocked")], forceOwned: true))
            @Expect(Directory.isEmpty(real))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
