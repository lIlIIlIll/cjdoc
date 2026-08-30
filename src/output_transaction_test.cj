package cjdoc

import cjdoc.render.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func outputArtifact(path: String, content: String): RenderArtifact {
    RenderArtifact(path, "text/plain", content)
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
        let parent = Directory.createTemp(getTempDirectory())
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
    func missingOrCorruptManifestFailsClosedWithoutChangingOutput(): Unit {
        let parent = Directory.createTemp(getTempDirectory())
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
    func injectedCommitFailureRollsBackEveryOwnedByte(): Unit {
        let parent = Directory.createTemp(getTempDirectory())
        let output = parent.join("site")
        try {
            writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "first"),
                outputArtifact("html/index.html", "html")])
            let manifest = File.readFrom(output.join(".cjdoc-output.json"))
            @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "second")],
                faultAfterOperation: Some(1)))
            @Expect(String.fromUtf8(File.readFrom(output.join("docs.json"))), "first")
            @Expect(String.fromUtf8(File.readFrom(output.join("html/index.html"))), "html")
            @Expect(File.readFrom(output.join(".cjdoc-output.json")), manifest)
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }

    @TestCase
    func secondWriterFailsImmediatelyWhileLockOwnerIsAlive(): Unit {
        let parent = Directory.createTemp(getTempDirectory())
        let output = parent.join("site")
        try {
            withOutputLock(output.toString(), { =>
                @ExpectThrows(writeOwnedArtifacts(output.toString(), [outputArtifact("docs.json", "blocked")]))
                @Expect(!exists(output))
            })
        } finally { let _ = removeIfExists(parent, recursive: true) }
    }
}
