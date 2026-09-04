package cjdoc

import cjdoc.render.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OutputTransactionSuite3 {
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
    func symbolicLinkAncestorIsRejectedEvenWhenForceOwnedIsEnabled(): Unit {
        let procSelf = Path("/proc/self")
        if (exists(procSelf) && FileInfo(procSelf).isSymbolicLink()) {
            @ExpectThrows(writeOwnedArtifacts(procSelf.join("cjdoc-output").toString(),
                [outputArtifact("docs.json", "blocked")], forceOwned: true))
            @ExpectThrows(writeOwnedArtifacts(Path("/proc/cjdoc-missing/../self/cjdoc-output").toString(),
                [outputArtifact("docs.json", "blocked")], forceOwned: true))
        }
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
        @Expect(staleLockQueryFailureAllowsRecoveryForTest(true), false)
        @Expect(staleLockQueryFailureAllowsRecoveryForTest(false), true)

        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        let lock = parent.join(".cjdoc-output-parent.lock")
        try {
            Directory.create(lock)
            let owner = ("{\"schemaVersion\":\"cjdoc.output-lock/1\", " +
                "\"pid\":\"2147483647\",\"startTime\":\"unknown\", " +
                "\"token\":\"test-token\",\"root\":\"${output}\"}\n").toArray()
            File.writeTo(lock.join("owner.json"), owner)
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "blocked")]))
            @Expect(File.readFrom(lock.join("owner.json")), owner)
            @Expect(!exists(parent.join(".cjdoc-output-parent.retired")))
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
