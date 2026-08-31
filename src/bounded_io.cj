package cjdoc

import std.collection.*
import std.fs.*
import std.time.*

@When[os != "Windows"]
import std.posix.*

private let BOUNDED_READ_CHUNK_BYTES: Int64 = 64 * 1024

private class BoundedFileSnapshot {
    let size: Int64
    let creationTime: DateTime
    let lastModificationTime: DateTime

    init(size: Int64, creationTime: DateTime, lastModificationTime: DateTime) {
        this.size = size
        this.creationTime = creationTime
        this.lastModificationTime = lastModificationTime
    }
}

// The current std.fs API exposes no stable file identity, so capture scalar metadata immediately.
// Re-reading FileInfo fields later would observe the current path rather than preserve this snapshot.

private func boundedAccessError(path: Path): IllegalArgumentException {
    IllegalArgumentException("bounded read could not access file: '${path}'")
}

private func boundedSnapshot(path: Path): BoundedFileSnapshot {
    let info = try { FileInfo(path) } catch (_: Exception) { throw boundedAccessError(path) }
    let isSymbolicLink = try { info.isSymbolicLink() } catch (_: Exception) {
        throw boundedAccessError(path)
    }
    let isRegular = try { info.isRegular() } catch (_: Exception) { throw boundedAccessError(path) }
    if (isSymbolicLink || !isRegular) {
        throw IllegalArgumentException(
            "bounded read requires a regular non-symbolic-link file: '${path}'")
    }
    try {
        return BoundedFileSnapshot(info.size, info.creationTime, info.lastModificationTime)
    } catch (_: Exception) {
        throw boundedAccessError(path)
    }
}

private func boundedOpenSnapshot(file: File, path: Path): BoundedFileSnapshot {
    let info = try { file.info } catch (_: Exception) { throw boundedAccessError(path) }
    let isSymbolicLink = try { info.isSymbolicLink() } catch (_: Exception) {
        throw boundedAccessError(path)
    }
    let isRegular = try { info.isRegular() } catch (_: Exception) { throw boundedAccessError(path) }
    if (isSymbolicLink || !isRegular) {
        throw IllegalArgumentException(
            "bounded read requires a regular non-symbolic-link file: '${path}'")
    }
    try {
        return BoundedFileSnapshot(info.size, info.creationTime, info.lastModificationTime)
    } catch (_: Exception) {
        throw boundedAccessError(path)
    }
}

private func boundedSnapshotsMatch(left: BoundedFileSnapshot, right: BoundedFileSnapshot): Bool {
    left.size == right.size && left.creationTime == right.creationTime &&
        left.lastModificationTime == right.lastModificationTime
}

private func boundedFileLength(file: File, path: Path): Int64 {
    try { file.length } catch (_: Exception) { throw boundedAccessError(path) }
}

private func boundedReadChunk(file: File, path: Path, buffer: Array<Byte>): Int64 {
    try { file.read(buffer) } catch (_: Exception) { throw boundedAccessError(path) }
}

private func boundedClose(file: File, path: Path): Unit {
    try { file.close() } catch (_: Exception) { throw boundedAccessError(path) }
}

internal func readFileBounded(path: Path, maxBytes: Int64): Array<Byte> {
    if (maxBytes < 0) {
        throw IllegalArgumentException("bounded read maxBytes must be non-negative")
    }

    let before = boundedSnapshot(path)
    if (before.size > maxBytes) {
        throw IllegalArgumentException("bounded read exceeds ${maxBytes} bytes: '${path}'")
    }

    let file = try { File(path, OpenMode.Read) } catch (_: Exception) { throw boundedAccessError(path) }
    let output = ArrayList<Byte>()
    var total: Int64 = 0
    try {
        let opened = boundedOpenSnapshot(file, path)
        if (!boundedSnapshotsMatch(before, opened) || boundedFileLength(file, path) != before.size) {
            throw IllegalArgumentException("bounded read observed a file change: '${path}'")
        }

        while (true) {
            let remaining = maxBytes - total
            let request = if (remaining >= BOUNDED_READ_CHUNK_BYTES) {
                BOUNDED_READ_CHUNK_BYTES
            } else {
                remaining + 1
            }
            let buffer = Array<Byte>(request, repeat: 0)
            let count = boundedReadChunk(file, path, buffer)
            if (count < 0 || count > request) { throw boundedAccessError(path) }
            if (count == 0) { break }
            if (count > remaining) {
                throw IllegalArgumentException("bounded read exceeds ${maxBytes} bytes: '${path}'")
            }
            for (index in 0..count) { output.add(buffer[index]) }
            total += count
        }

        if (total != before.size || boundedFileLength(file, path) != before.size) {
            throw IllegalArgumentException("bounded read observed a file change: '${path}'")
        }
    } finally {
        boundedClose(file, path)
    }

    let after = boundedSnapshot(path)
    if (!boundedSnapshotsMatch(before, after)) {
        throw IllegalArgumentException("bounded read observed a file change: '${path}'")
    }
    return output.toArray()
}

internal func readTextBounded(path: Path, maxBytes: Int64): String {
    let bytes = readFileBounded(path, maxBytes)
    try { String.fromUtf8(bytes) } catch (_: Exception) {
        throw IllegalArgumentException("bounded text is not valid UTF-8: '${path}'")
    }
}

@When[os != "Windows"]
private func boundedCloseDescriptor(fd: Int32, path: String): Unit {
    if (close(fd) != 0) {
        throw IllegalArgumentException("bounded relative read could not close '${path}'")
    }
}

@When[os != "Windows"]
private func boundedCloseDescriptorBestEffort(fd: Int32): Unit {
    if (fd >= 0) { let _ = close(fd) }
}

@When[os != "Windows"]
private func boundedOpenDirectoryPath(root: Path): Int32 {
    let path = root.toString()
    if (!path.startsWith("/") || path.contains("\\")) {
        throw IllegalArgumentException("bounded relative read requires an absolute root")
    }
    var directory = openat(AT_FDCWD, "/",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if (directory < 0) {
        throw IllegalArgumentException("bounded relative read could not open root '${root}'")
    }
    try {
        for (part in path.split("/")) {
            if (part.isEmpty()) { continue }
            if (part == "." || part == "..") {
                throw IllegalArgumentException("bounded relative read requires a normalized root")
            }
            let next = openat(directory, part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if (next < 0) {
                throw IllegalArgumentException(
                    "bounded relative read rejected root '${root}'")
            }
            let previous = directory
            directory = -1
            if (close(previous) != 0) {
                boundedCloseDescriptorBestEffort(next)
                throw IllegalArgumentException(
                    "bounded relative read could not close root '${root}'")
            }
            directory = next
        }
        return directory
    } catch (error: Exception) {
        boundedCloseDescriptorBestEffort(directory)
        throw error
    }
}

@When[os != "Windows"]
private func boundedOpenRelative(root: Path, relativePath: String): Int32 {
    let parts = relativePath.split("/")
    if (parts.isEmpty()) {
        throw IllegalArgumentException("bounded relative read requires a relative file path")
    }
    for (part in parts) {
        if (part.isEmpty() || part == "." || part == ".." || part.contains("\\")) {
            throw IllegalArgumentException("bounded relative read requires a normalized path")
        }
    }
    var directory = boundedOpenDirectoryPath(root)
    var index: Int64 = 0
    try {
        while (index + 1 < parts.size) {
            let next = openat(directory, parts[index],
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if (next < 0) {
                throw IllegalArgumentException(
                    "bounded relative read rejected path '${relativePath}'")
            }
            let previous = directory
            directory = -1
            if (close(previous) != 0) {
                boundedCloseDescriptorBestEffort(next)
                throw IllegalArgumentException(
                    "bounded relative read could not close '${relativePath}'")
            }
            directory = next
            index++
        }
        let file = openat(directory, parts[index],
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if (file < 0) {
            throw IllegalArgumentException("bounded relative read rejected path '${relativePath}'")
        }
        let previous = directory
        directory = -1
        if (close(previous) != 0) {
            boundedCloseDescriptorBestEffort(file)
            throw IllegalArgumentException(
                "bounded relative read could not close '${relativePath}'")
        }
        return file
    } catch (error: Exception) {
        boundedCloseDescriptorBestEffort(directory)
        throw error
    }
}

@When[os != "Windows"]
private func boundedReadDescriptor(fd: Int32, request: Int64): (Array<Byte>, Int64) {
    let buffer = Array<Byte>(request, repeat: 0)
    let count = unsafe {
        let handle = acquireArrayRawData(buffer)
        try { Int64(read(fd, handle.pointer, UIntNative(request))) } finally {
            releaseArrayRawData(handle)
        }
    }
    (buffer, count)
}

@When[os != "Windows"]
private func boundedRequireRegularDescriptor(fd: Int32, path: String): Unit {
    for (prefix in ["/proc/self/fd", "/dev/fd"]) {
        try {
            let target = canonicalize(Path("${prefix}/${fd}"))
            if (FileInfo(target).isRegular()) { return }
        } catch (_: Exception) { }
    }
    throw IllegalArgumentException(
        "bounded relative read could not verify a regular descriptor: '${path}'")
}

@When[os != "Windows"]
private func readFileBoundedWithinCore(root: Path, relativePath: String,
    maxBytes: Int64, expectedSize: ?Int64, afterOpen: () -> Unit): Array<Byte> {
    if (maxBytes < 0) {
        throw IllegalArgumentException("bounded relative read maxBytes must be non-negative")
    }
    let file = boundedOpenRelative(root, relativePath)
    try {
        boundedRequireRegularDescriptor(file, relativePath)
        let openedSize = lseek(file, 0, SEEK_END)
        if (openedSize < 0 || lseek(file, 0, SEEK_SET) != 0) {
            throw IllegalArgumentException(
                "bounded relative read requires a bounded regular file: '${relativePath}'")
        }
        match (expectedSize) {
            case Some(size) => if (size != openedSize) {
                throw IllegalArgumentException(
                    "bounded relative read observed a pre-open file change: '${relativePath}'")
            }
            case None => ()
        }
        if (openedSize > maxBytes) {
            throw IllegalArgumentException(
                "bounded relative read exceeds ${maxBytes} bytes: '${relativePath}'")
        }
        afterOpen()
        boundedRequireRegularDescriptor(file, relativePath)
        if (lseek(file, 0, SEEK_END) != openedSize || lseek(file, 0, SEEK_SET) != 0) {
            throw IllegalArgumentException(
                "bounded relative read observed a post-open file change: '${relativePath}'")
        }
        let output = ArrayList<Byte>()
        var total: Int64 = 0
        while (true) {
            let remaining = maxBytes - total
            let request = if (remaining >= BOUNDED_READ_CHUNK_BYTES) {
                BOUNDED_READ_CHUNK_BYTES
            } else {
                remaining + 1
            }
            let (buffer, count) = boundedReadDescriptor(file, request)
            if (count < 0 || count > request) {
                throw IllegalArgumentException(
                    "bounded relative read failed for '${relativePath}'")
            }
            if (count == 0) { break }
            if (count > remaining) {
                throw IllegalArgumentException(
                    "bounded relative read exceeds ${maxBytes} bytes: '${relativePath}'")
            }
            for (index in 0..count) { output.add(buffer[index]) }
            total += count
        }
        let finalSize = lseek(file, 0, SEEK_END)
        boundedRequireRegularDescriptor(file, relativePath)
        if (total != openedSize || finalSize != openedSize) {
            throw IllegalArgumentException(
                "bounded relative read observed a file change: '${relativePath}'")
        }
        output.toArray()
    } finally {
        boundedCloseDescriptor(file, relativePath)
    }
}

@When[os != "Windows"]
internal func readFileBoundedWithin(root: Path, relativePath: String,
    maxBytes: Int64): Array<Byte> {
    readFileBoundedWithinCore(root, relativePath, maxBytes, None<Int64>, { => })
}

@When[os != "Windows"]
internal func readFileBoundedWithinExpected(root: Path, relativePath: String,
    maxBytes: Int64, expectedSize: Int64): Array<Byte> {
    if (expectedSize < 0 || expectedSize > maxBytes) {
        throw IllegalArgumentException("bounded relative read expectedSize is invalid")
    }
    readFileBoundedWithinCore(root, relativePath, maxBytes, Some(expectedSize), { => })
}

@When[os != "Windows"]
internal func readFileBoundedWithinAfterOpenForTest(root: Path, relativePath: String,
    maxBytes: Int64, afterOpen: () -> Unit): Array<Byte> {
    readFileBoundedWithinCore(root, relativePath, maxBytes, None<Int64>, afterOpen)
}

@When[os == "Windows"]
internal func readFileBoundedWithin(root: Path, relativePath: String,
    maxBytes: Int64): Array<Byte> {
    throw IllegalArgumentException(
        "bounded relative reads are unavailable on Windows")
}

@When[os == "Windows"]
internal func readFileBoundedWithinExpected(root: Path, relativePath: String,
    maxBytes: Int64, expectedSize: Int64): Array<Byte> {
    throw IllegalArgumentException(
        "bounded relative reads are unavailable on Windows")
}

@When[os == "Windows"]
internal func readFileBoundedWithinAfterOpenForTest(root: Path, relativePath: String,
    maxBytes: Int64, afterOpen: () -> Unit): Array<Byte> {
    throw IllegalArgumentException(
        "bounded relative reads are unavailable on Windows")
}
