package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Windows"]
import std.posix.*

@Test
class BoundedIoTest {
    @TestCase
    func exactLimitAndEmptyFileAreAccepted(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let exact = root.join("exact.txt")
            let empty = root.join("empty.txt")
            File.writeTo(exact, "abc".toArray())
            File.writeTo(empty, Array<Byte>())

            @Expect(readFileBounded(exact, 3), "abc".toArray())
            @Expect(readTextBounded(exact, 3), "abc")
            @Expect(readFileBounded(empty, 0), Array<Byte>())
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func firstByteBeyondLimitIsRejected(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let path = root.join("four-bytes.bin")
            File.writeTo(path, [0x01, 0x02, 0x03, 0x04])

            let error = @AssertThrows[IllegalArgumentException](readFileBounded(path, 3))
            @Expect(error.message, "bounded read exceeds 3 bytes: '${path}'")

            let zeroError = @AssertThrows[IllegalArgumentException](readFileBounded(path, 0))
            @Expect(zeroError.message, "bounded read exceeds 0 bytes: '${path}'")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func negativeLimitFailsBeforeFilesystemAccess(): Unit {
        let path = Path("definitely-missing-bounded-read-input")
        let error = @AssertThrows[IllegalArgumentException](readFileBounded(path, -1))
        @Expect(error.message, "bounded read maxBytes must be non-negative")
    }

    @TestCase
    func nonRegularAndMissingPathsHaveStableErrors(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let directoryError = @AssertThrows[IllegalArgumentException](readFileBounded(root, 1))
            @Expect(directoryError.message,
                "bounded read requires a regular non-symbolic-link file: '${root}'")

            let missing = root.join("missing")
            let missingError = @AssertThrows[IllegalArgumentException](readFileBounded(missing, 1))
            @Expect(missingError.message, "bounded read could not access file: '${missing}'")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func invalidUtf8HasStableTextError(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let path = root.join("invalid-utf8.bin")
            File.writeTo(path, [0xFF])
            let error = @AssertThrows[IllegalArgumentException](readTextBounded(path, 1))
            @Expect(error.message, "bounded text is not valid UTF-8: '${path}'")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}

@When[os != "Windows"]
@Test
class BoundedRelativeIoTest {
    @TestCase
    func nestedRegularFileHonorsTheExactRelativeLimit(): Unit {
        let root = canonicalize(Directory.createTemp(getTempDirectory()))
        try {
            Directory.create(root.join("nested"))
            File.writeTo(root.join("nested/pixel.gif"), "GIF".toArray())

            @Expect(readFileBoundedWithinExpected(root, "nested/pixel.gif", 3, 3), "GIF".toArray())
            @ExpectThrows[IllegalArgumentException](
                readFileBoundedWithinExpected(root, "nested/pixel.gif", 2, 3))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func nonNormalizedRelativeNamesFailClosed(): Unit {
        let root = canonicalize(Directory.createTemp(getTempDirectory()))
        try {
            @ExpectThrows[IllegalArgumentException](readFileBoundedWithinExpected(root, "../outside", 1, 0))
            @ExpectThrows[IllegalArgumentException](readFileBoundedWithinExpected(root, "/absolute", 1, 0))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func symbolicLinkAncestorsAreNeverFollowed(): Unit {
        let temporary = canonicalize(Directory.createTemp(getTempDirectory()))
        try {
            let root = temporary.join("root")
            let real = root.join("real")
            Directory.create(real, recursive: true)
            File.writeTo(real.join("pixel.gif"), "GIF".toArray())
            let nestedLink = root.join("linked")
            @Expect(symlink(real.toString(), nestedLink.toString()), 0)
            @ExpectThrows[IllegalArgumentException](
                readFileBoundedWithinExpected(root, "linked/pixel.gif", 3, 3))

            let rootLink = temporary.join("root-link")
            @Expect(symlink(root.toString(), rootLink.toString()), 0)
            @ExpectThrows[IllegalArgumentException](
                readFileBoundedWithinExpected(rootLink, "real/pixel.gif", 3, 3))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func seekableSpecialFilesAreNotAcceptedAsRegularDescriptors(): Unit {
        @ExpectThrows[IllegalArgumentException](readFileBoundedWithinExpected(Path("/dev"), "null", 0, 0))
    }

    @TestCase
    func openedDescriptorSurvivesAPathReplacementWithoutReopening(): Unit {
        let root = canonicalize(Directory.createTemp(getTempDirectory()))
        try {
            let original = root.join("asset.gif")
            let moved = root.join("opened.gif")
            File.writeTo(original, "old".toArray())
            let bytes = readFileBoundedWithinAfterOpenForTest(root, "asset.gif", 3, { =>
                rename(original, to: moved, overwrite: false)
                File.writeTo(original, "new".toArray())
            })
            @Expect(bytes, "old".toArray())
            @Expect(String.fromUtf8(File.readFrom(original)), "new")
            @ExpectThrows[IllegalArgumentException](
                readFileBoundedWithinExpected(root, "asset.gif", 3, 2))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
