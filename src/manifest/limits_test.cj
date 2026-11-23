protected package cjdoc.manifest

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ManifestIntakeLimitsTest {
    @TestCase
    func sharesTomlByteAndWorkLimitsAcrossAllParsedArrays(): Unit {
        let text = "[package]\nname = \"sample\"\n" +
            "[workspace]\nmembers = [\"a\", \"b\"]\n" +
            "[dependencies]\ndep = { path = \"../dep\" }\n"
        let byteLimited = parseCjpmManifest(text, maxBytes: text.size - 1)
        @Expect(byteLimited.limitReached, true)
        @Expect(byteLimited.workspaceMembers.size, 0)
        @Expect(byteLimited.pathDependencies.size, 0)

        let workLimited = parseCjpmManifest(text, maxWork: text.size + 1)
        @Expect(workLimited.limitReached, true)
        let lockText = "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n"
        let lockLimited = parseCjpmLock(lockText, maxWork: lockText.size - 1)
        @Expect(lockLimited.limitReached, true)
    }

    @TestCase
    func ignoresTomlHeadersInsideMultilineStringsAndBoundsAdapterEntries(): Unit {
        let basicFence = "\"\"\""
        let literalFence = "'''"
        let manifest = parseCjpmManifest(
            "[package]\nname = \"sample\"\ndescription = ${basicFence}\n" +
            "[workspace] # example only\nmembers = [\"ghost\"]\n${basicFence}\n" +
            "notes = ${literalFence}\n[dependencies] # example only\n" +
            "ghost = { path = \"../ghost\" }\n${literalFence}\n" +
            "[workspace] # real\nmembers = [\"member\"]\n" +
            "[dependencies] # real\ndep = { path = \"../dep\" }\n")
        @Expect(manifest.packageName, Some("sample"))
        @Expect(manifest.workspaceMembers.size, 1)
        @Expect(manifest.workspaceMembers[0], "member")
        @Expect(manifest.pathDependencies.size, 1)
        @Expect(manifest.pathDependencies[0], "../dep")

        let lock = parseCjpmLock(
            "notes = ${basicFence}\n[requires] # example only\n" +
            "ghost = { version = \"0.0.0\" }\n${basicFence}\n" +
            "[requires] # real\ndep = { version = \"1.0.0\" }\n")
        @Expect(lock.dependencies.size, 1)
        @Expect(lock.dependencies[0].name, "dep")

        let members = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"a\", \"b\", \"c\"]\n", 2)
        @Expect(members.values.size, 2)
        @Expect(members.values[0], "a")
        @Expect(members.values[1], "b")
        @Expect(members.entryCount, 2)
        @Expect(members.limitReached, true)

        let paths = parseCjpmPathDependencies(
            "[dependencies]\na = { path = \"a\" }\nb = { path = \"b\" }\n", 1)
        @Expect(paths.values.size, 1)
        @Expect(paths.values[0], "a")
        @Expect(paths.limitReached, true)

        let boundedLock = parseCjpmLock(
            "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n",
            maxEntries: 1)
        @Expect(boundedLock.dependencies.size, 1)
        @Expect(boundedLock.entryCount, 1)
        @Expect(boundedLock.limitReached, true)
    }
}
