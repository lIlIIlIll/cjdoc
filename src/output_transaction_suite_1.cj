package cjdoc

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OutputTransactionSuite1 {
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

}
