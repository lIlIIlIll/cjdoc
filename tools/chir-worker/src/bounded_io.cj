package cjdoc_chir_worker

import std.collection.*
import std.fs.*
import std.time.*

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

