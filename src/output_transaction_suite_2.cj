package cjdoc

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OutputTransactionSuite2 {
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

}
