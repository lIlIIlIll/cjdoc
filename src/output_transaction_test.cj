package cjdoc

import cjdoc.render.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func outputArtifact(path: String, content: String): RenderArtifact {
    RenderArtifact(path, "text/plain", content)
}

private func createOutputTestTempDirectory(): Path {
    Directory.createTemp(canonicalize(getTempDirectory()))
}

private func findTransactionDirectory(parent: Path): Path {
    for (entry in Directory.readFrom(parent)) {
        if (entry.name.startsWith(".cjdoc-output-") && entry.name.endsWith(".txn")) {
            return entry.path
        }
    }
    throw IllegalStateException("missing output transaction directory")
}

private func findLockDirectory(parent: Path): Path {
    for (entry in Directory.readFrom(parent)) {
        if (entry.name.startsWith(".cjdoc-output-") && entry.name.endsWith(".lock")) {
            return entry.path
        }
    }
    throw IllegalStateException("missing output lock directory")
}

private func fixedTransactionDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.txn")
}

private func fixedPreparingDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.preparing")
}

private func fixedBootstrapDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.bootstrap")
}

private func fixedRetiredDirectory(parent: Path): Path {
    parent.join(".cjdoc-output-transaction.retired")
}

private func expectOriginalOutput(output: Path, manifest: Array<Byte>): Unit {
    @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
    @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
    @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
}

@Test
class OutputTransactionTest {
    @TestCase
    func sha256MatchesPublishedVectors(): Unit {
        @Expect(Sha256Digest.digest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        @Expect(Sha256Digest.digest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @TestCase
    func ownershipConflictRequiresExplicitForceAndPreservesUnownedFiles(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            File.writeTo(output.join("CNAME"), "docs.example.test\n".toArray())
            File.writeTo(output.join("docs.json"), "user edit".toArray())
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")]))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "user edit")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
            @Expect(exists(output.join("html/index.html")))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")], forceOwned: true)
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            @Expect(!exists(output.join("html")))
            @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("CNAME", "owned")],
                forceOwned: true))
            @Expect(String.fromUtf8(File.readFrom(output.join("CNAME"))), "docs.example.test\n")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func staleNestedOwnedDirectoriesArePrunedDeepestFirstWithoutDeletingUnownedContent(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "index"),
                outputArtifact("html/assets/app.js", "app"),
                outputArtifact("html/api/types.html", "types")])

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")])
            @Expect(!exists(output.join("html")))

            writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "third"),
                outputArtifact("html/index.html", "index"),
                outputArtifact("html/assets/app.js", "app")])
            File.writeTo(output.join("html/user.txt"), "preserve me".toArray())

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "fourth")])
            @Expect(String.fromUtf8(File.readFrom(output.join("html/user.txt"))), "preserve me")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func preExistingEmptyDirectoryRequiresForceBeforeAdoptionAndLaterPruning(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            Directory.create(output.join("html"))
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "second"),
                outputArtifact("html/index.html", "index")]))
            @Expect(Directory.isEmpty(output.join("html")))
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)

            writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "second"),
                outputArtifact("html/index.html", "index")], forceOwned: true)
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(!exists(output.join("html")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func legacyV2NestedDirectoriesRequireForceForExplicitMigration(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "index")])
            let docsDigest = Sha256Digest.digest("first")
            let htmlDigest = Sha256Digest.digest("index")
            let legacy = "{\n  \"schemaVersion\": \"cjdoc.output/2\",\n" +
                "  \"digestAlgorithm\": \"sha256\",\n  \"files\": [\n" +
                "    {\"path\": \"docs.json\", \"sha256\": \"${docsDigest}\"},\n" +
                "    {\"path\": \"html/index.html\", \"sha256\": \"${htmlDigest}\"}\n  ]\n}\n"
            File.writeTo(output.join(".cjdoc-output.json"), legacy.toArray())

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")]))
            @Expect(exists(output.join("html/index.html")))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true)
            @Expect(!exists(output.join("html")))
            let migrated = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            @Expect(migrated.contains("cjdoc.output/3"))
            @Expect(migrated.contains("\"directories\""))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func forcedRollbackRestoresActualBytesAndExactNoncanonicalManifest(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            File.writeTo(output.join("docs.json"), "user edit".toArray())
            let canonical = String.fromUtf8(File.readFrom(output.join(".cjdoc-output.json")))
            let noncanonical = " \n${canonical} \n".toArray()
            File.writeTo(output.join(".cjdoc-output.json"), noncanonical)

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true, faultAfterOperation: Some(1)))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "user edit")
            @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), noncanonical)

            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true, interruptAfterOperation: Some(3)))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")],
                transactionFaultPoint: Some("before-recovery-retire")))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "user edit")
            @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), noncanonical)

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")], forceOwned: true)
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func missingOrCorruptManifestFailsClosedWithoutChangingOutput(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let validManifest = File.readFrom(output.join(".cjdoc-output.json"))
            let _ = removeIfExists(output.join(".cjdoc-output.json"))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")

            File.writeTo(output.join(".cjdoc-output.json"), "{}".toArray())
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                forceOwned: true))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            File.writeTo(output.join(".cjdoc-output.json"), validManifest)
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func injectedPrecommitFailureMatrixRollsBackEveryOwnedByte(): Unit {
        let parent = createOutputTestTempDirectory()
        try {
            for (fault in 1..6) {
                let output = parent.join("site-${fault}")
                writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                    outputArtifact("html/index.html", "html")])
                let manifest = File.readFrom(output.join(".cjdoc-output.json"))
                @ExpectThrows(writeOwnedArtifacts(output.toString(), [
                    outputArtifact("docs.json", "second"),
                    outputArtifact("markdown/index.md", "markdown")],
                    faultAfterOperation: Some(fault)))
                expectOriginalOutput(output, manifest)
            }
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func failureAtManifestCommitPointPreservesNewOutputForRecovery(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [
                outputArtifact("docs.json", "second"),
                outputArtifact("markdown/index.md", "markdown")],
                faultAfterOperation: Some(6)))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            @Expect(!exists(output.join("html/index.html")))
            @Expect(String.fromUtf8(File.readFrom(output.join("markdown/index.md"))), "markdown")
            @Expect(exists(fixedTransactionDirectory(parent)))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
            @Expect(!exists(output.join("markdown")))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func interruptedCommitMatrixIsRecoveredByNextWriter(): Unit {
        let parent = createOutputTestTempDirectory()
        try {
            for (fault in 1..7) {
                let output = parent.join("site-${fault}")
                writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                    outputArtifact("html/index.html", "html")])
                @ExpectThrows(writeOwnedArtifacts(output.toString(), [
                    outputArtifact("docs.json", "second"),
                    outputArtifact("markdown/index.md", "markdown")],
                    interruptAfterOperation: Some(fault)))
                @Expect(exists(findTransactionDirectory(parent)))

                writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
                @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
                @Expect(!exists(output.join("html")))
                @Expect(!exists(output.join("markdown")))
            }
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func preparingPublishInterruptionIsRetiredBeforeTheNextWrite(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "interrupted")],
                transactionFaultPoint: Some("after-preparing-publish")))
            @Expect(exists(fixedPreparingDirectory(parent)))
            @Expect(!exists(fixedTransactionDirectory(parent)))
            @Expect(!exists(output))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "recovered")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "recovered")
            @Expect(!exists(fixedPreparingDirectory(parent)))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func relocatedPreparationMarkerFailsClosedWithoutTouchingEitherParent(): Unit {
        let firstParent = createOutputTestTempDirectory()
        let secondParent = createOutputTestTempDirectory()
        let firstOutput = firstParent.join("site")
        let secondOutput = secondParent.join("site")
        try {
            @ExpectThrows(writeOwnedArtifacts(firstOutput.toString(),
                [outputArtifact("docs.json", "interrupted")],
                transactionFaultPoint: Some("after-preparing-publish")))
            rename(fixedPreparingDirectory(firstParent),
                to: fixedPreparingDirectory(secondParent), overwrite: false)
            let relocated = fixedPreparingDirectory(secondParent)
            let marker = File.readFrom(relocated.join("marker.json"))

            @ExpectThrows(writeOwnedArtifacts(secondOutput.toString(),
                [outputArtifact("docs.json", "other")]))
            @Expect(!exists(firstOutput))
            @Expect(!exists(secondOutput))
            @Expect(exists(relocated))
            @Expect(File.readFrom(relocated.join("marker.json")), marker)
            @Expect(!exists(relocated.join("stage")))
            @Expect(!exists(relocated.join("backup")))
            @Expect(!exists(relocated.join("plan.json")))
        } finally {
            let _ = removeIfExists(firstParent, recursive: true)
            let _ = removeIfExists(secondParent, recursive: true)
        }
    }

    @TestCase
    func repeatedPrePublishInterruptionsLeaveOneRecoverableBoundedBootstrap(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            for (_ in 0..3) {
                @ExpectThrows(writeOwnedArtifacts(output.toString(),
                    [outputArtifact("docs.json", "interrupted")],
                    transactionFaultPoint: Some("before-preparing-publish")))
                @Expect(!exists(fixedPreparingDirectory(parent)))
                @Expect(!exists(fixedTransactionDirectory(parent)))
                @Expect(!exists(fixedRetiredDirectory(parent)))
                @Expect(!exists(output))
                let bootstrap = fixedBootstrapDirectory(parent)
                @Expect(exists(bootstrap))
                @Expect(FileInfo(bootstrap.join("marker.json")).size <= 64 * 1024)
                @Expect(!exists(bootstrap.join("stage")))
                @Expect(!exists(bootstrap.join("backup")))
                @Expect(!exists(bootstrap.join("plan.json")))
            }

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "recovered")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "recovered")
            @Expect(!exists(fixedBootstrapDirectory(parent)))
            @Expect(!exists(fixedRetiredDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func transactionPublishInterruptionIsRecoveredBeforeTheNextWrite(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "interrupted")],
                transactionFaultPoint: Some("after-transaction-publish")))
            @Expect(!exists(fixedPreparingDirectory(parent)))
            @Expect(exists(fixedTransactionDirectory(parent)))
            @Expect(!exists(output))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "recovered")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "recovered")
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func renamedAndRecreatedParentInvalidatesTheHeldLockBeforeMutation(): Unit {
        let outer = createOutputTestTempDirectory()
        let parent = outer.join("parent")
        let moved = outer.join("moved-parent")
        let output = parent.join("site")
        Directory.create(parent)
        try {
            @ExpectThrows(withOutputLockRaceForTest(output.toString(), { =>
                rename(parent, to: moved, overwrite: false)
                Directory.create(parent)
            }, { => Directory.create(output) }))
            @Expect(!exists(output))
            @Expect(!exists(moved.join("site")))
        } finally { let _ = removeIfExists(outer, recursive: true) }
    }

    @TestCase
    func copiedOwnerCannotReplayLockAfterParentReplacement(): Unit {
        let outer = createOutputTestTempDirectory()
        let parent = outer.join("parent")
        let moved = outer.join("moved-parent")
        let output = parent.join("site")
        Directory.create(parent)
        try {
            @ExpectThrows(withOutputLockRaceForTest(output.toString(), { =>
                rename(parent, to: moved, overwrite: false)
                Directory.create(parent)
                Directory.create(parent.join(".cjdoc-output-parent.lock"))
                File.writeTo(parent.join(".cjdoc-output-parent.lock/owner.json"),
                    File.readFrom(moved.join(".cjdoc-output-parent.lock/owner.json")))
            }, { => Directory.create(output) }))
            @Expect(!exists(output))
            @Expect(!exists(moved.join("site")))
        } finally { let _ = removeIfExists(outer, recursive: true) }
    }

    @TestCase
    func outputRootCannotCollideWithAnyPortableInternalSiblingName(): Unit {
        let parent = createOutputTestTempDirectory()
        let names: Array<String> = [
            ".cjdoc-output-parent.lock",
            ".cjdoc-output-parent.bootstrap",
            ".cjdoc-output-parent.retired",
            ".cjdoc-output-transaction.bootstrap",
            ".CJDOC-OUTPUT-TRANSACTION.TXN",
            ".cjdoc-output-transaction.preparing.",
            ".CJDOC-OUTPUT-TRANSACTION.RETIRED "
        ]
        try {
            for (name in names) {
                @ExpectThrows(writeOwnedArtifacts(parent.join(name).toString(),
                    [outputArtifact("docs.json", "blocked")]))
            }
            @Expect(!exists(fixedPreparingDirectory(parent)))
            @Expect(!exists(fixedTransactionDirectory(parent)))
            @Expect(!exists(parent.join(".cjdoc-output-parent.lock")))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func exactPlanDigestRejectsOtherwiseParseablePlanByteChanges(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "interrupted")],
                transactionFaultPoint: Some("after-transaction-publish")))
            let transaction = fixedTransactionDirectory(parent)
            let planPath = transaction.join("plan.json")
            let original = String.fromUtf8(File.readFrom(planPath))
            File.writeTo(planPath, (original + " \n").toArray())

            @ExpectThrows(writeOwnedArtifacts(output.toString(),
                [outputArtifact("docs.json", "blocked")]))
            @Expect(!exists(output))
            @Expect(exists(transaction))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func unexpectedStagedEntryIsRejectedBeforeAnyOwnedOutputMove(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            @ExpectThrows(writeOwnedArtifactsWithBeforeCommitForTest(output.toString(),
                [outputArtifact("docs.json", "second")], { =>
                    File.writeTo(fixedTransactionDirectory(parent).join("stage/unexpected.txt"),
                        "unexpected".toArray())
                }))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
            @Expect(exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func ownershipChangeAfterPreflightIsPreservedAndRecoveryFailsClosed(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            @ExpectThrows(writeOwnedArtifactsWithBeforeCommitForTest(output.toString(),
                [outputArtifact("docs.json", "second")], { =>
                    File.writeTo(output.join("docs.json"), "user edit".toArray())
                }))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "user edit")
            @Expect(exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func rollbackNeverDeletesSameDigestContentWithoutMoveProvenance(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            @ExpectThrows(writeOwnedArtifactsWithBeforeCommitForTest(output.toString(),
                [outputArtifact("docs.json", "planned")], { =>
                    Directory.create(output)
                    File.writeTo(output.join("docs.json"), "planned".toArray())
                }))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "planned")
            @Expect(exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func commitRetirementFailureCannotReportSuccessAndIsRecoverable(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                transactionFaultPoint: Some("before-commit-retire")))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            @Expect(exists(fixedTransactionDirectory(parent)))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func retiredJournalDeleteFailureIsNamedReportedAndRecovered(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first")])
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                transactionFaultPoint: Some("before-retired-delete")))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "second")
            @Expect(!exists(fixedTransactionDirectory(parent)))
            @Expect(exists(fixedRetiredDirectory(parent)))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
            @Expect(!exists(fixedRetiredDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func recoveryInterruptionLeavesAResumableTransaction(): Unit {
        let parent = createOutputTestTempDirectory()
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                interruptAfterOperation: Some(1)))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")],
                transactionFaultPoint: Some("before-recovery-retire")))
            expectOriginalOutput(output, manifest)
            @Expect(exists(fixedTransactionDirectory(parent)))

            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "third")])
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "third")
            @Expect(!exists(output.join("html")))
            @Expect(!exists(fixedTransactionDirectory(parent)))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func relocatedOperationThreeTransactionFailsClosedWithoutTouchingEitherParent(): Unit {
        let firstParent = createOutputTestTempDirectory()
        let secondParent = createOutputTestTempDirectory()
        let firstOutput = firstParent.join("site")
        let secondOutput = secondParent.join("site")
        try {
            writeOwnedArtifacts(firstOutput.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            @ExpectThrows(writeOwnedArtifacts(firstOutput.toString(), [outputArtifact("docs.json", "second")],
                interruptAfterOperation: Some(3)))
            @Expect(!exists(firstOutput.join("docs.json")))
            @Expect(!exists(firstOutput.join("html/index.html")))
            @Expect(!exists(firstOutput.join(".cjdoc-output.json")))
            rename(fixedTransactionDirectory(firstParent),
                to: fixedTransactionDirectory(secondParent), overwrite: false)
            let relocated = fixedTransactionDirectory(secondParent)
            let plan = File.readFrom(relocated.join("plan.json"))
            let marker = File.readFrom(relocated.join("marker.json"))
            let backupDocs = File.readFrom(relocated.join("backup/docs.json"))
            let backupHtml = File.readFrom(relocated.join("backup/html/index.html"))
            let backupManifest = File.readFrom(relocated.join("backup/.cjdoc-output.json"))

            @ExpectThrows(writeOwnedArtifacts(secondOutput.toString(),
                [outputArtifact("docs.json", "other")]))
            @Expect(!exists(firstOutput.join("docs.json")))
            @Expect(!exists(firstOutput.join("html/index.html")))
            @Expect(!exists(firstOutput.join(".cjdoc-output.json")))
            @Expect(!exists(secondOutput))
            @Expect(exists(relocated))
            @Expect(File.readFrom(relocated.join("plan.json")), plan)
            @Expect(File.readFrom(relocated.join("marker.json")), marker)
            @Expect(File.readFrom(relocated.join("backup/docs.json")), backupDocs)
            @Expect(File.readFrom(relocated.join("backup/html/index.html")), backupHtml)
            @Expect(File.readFrom(relocated.join("backup/.cjdoc-output.json")), backupManifest)
        } finally {
            let _ = removeIfExists(firstParent, recursive: true)
            let _ = removeIfExists(secondParent, recursive: true)
        }
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
            let owner = ("{\"schemaVersion\":\"cjdoc.output-lock/1\"," +
                "\"pid\":\"2147483647\",\"startTime\":\"unknown\"," +
                "\"token\":\"test-token\",\"root\":\"${output}\"}\n").toArray()
            File.writeTo(lock.join("owner.json"), owner)
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "blocked")]))
            @Expect(File.readFrom(lock.join("owner.json")), owner)
            @Expect(!exists(parent.join(".cjdoc-output-parent.retired")))
            @Expect(!exists(output))
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
