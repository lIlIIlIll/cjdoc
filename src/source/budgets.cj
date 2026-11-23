protected package cjdoc.source

import cjdoc.filesystem.{BoundedFileRead, readFileBoundedSnapshot, readTextBounded}
import std.fs.*
import std.sync.AtomicInt64

protected let SOURCE_CACHE_FORMAT = "cjdoc-source-cache-v21"
protected let MAX_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
protected let MAX_SOURCE_CACHE_BYTES: Int64 = 64 * 1024 * 1024
protected let MAX_SOURCE_CACHE_ITEMS: Int64 = 100000
protected let MAX_SOURCE_FILES: Int64 = 100000
protected let MAX_SOURCE_DIRECTORY_DEPTH: Int64 = 128
protected let MAX_SOURCE_DIRECTORY_ENTRIES: Int64 = 100000
protected let MAX_TOTAL_SOURCE_BYTES: Int64 = 512 * 1024 * 1024
protected let MAX_SOURCE_MODULES: Int64 = 4096
protected let MAX_SOURCE_DEPENDENCY_EDGES: Int64 = 16384
protected let MAX_SOURCE_OWNER_DEPTH: Int64 = 128
protected let MAX_SOURCE_AUXILIARY_BYTES: Int64 = 512 * 1024 * 1024
protected let MAX_SOURCE_AUXILIARY_WORK: Int64 = 1024 * 1024 * 1024

protected let MAX_SOURCE_BINARY_DEPTH: Int64 = 64

protected class SourceAuxiliaryBudget {
    private let maxBytes: Int64
    private let maxWork: Int64
    private let bytes = AtomicInt64(0)
    private let work = AtomicInt64(0)
    private let exceeded = AtomicInt64(0)

    protected init(maxBytes: Int64, maxWork: Int64) {
        if (maxBytes < 0 || maxWork < 0) {
            throw IllegalArgumentException("source auxiliary limits must be non-negative")
        }
        this.maxBytes = maxBytes
        this.maxWork = maxWork
    }

    private func consume(counter: AtomicInt64, maximum: Int64, amount: Int64): Bool {
        if (amount < 0 || amount > maximum) {
            let _ = exceeded.fetchAdd(1)
            return false
        }
        let previous = counter.fetchAdd(amount)
        if (previous > maximum - amount) {
            let _ = exceeded.fetchAdd(1)
            return false
        }
        true
    }

    protected func consumeBytes(amount: Int64): Bool { consume(bytes, maxBytes, amount) }
    protected func consumeWork(amount: Int64): Bool { consume(work, maxWork, amount) }
    protected func limitReached(): Bool { exceeded.fetchAdd(0) > 0 }
}

protected func readAuxiliaryTextBounded(path: Path, perFileLimit: Int64,
    budget: SourceAuxiliaryBudget): String {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink() || info.size < 0 ||
        info.size > perFileLimit) {
        throw IllegalArgumentException("auxiliary input is not a bounded regular file")
    }
    if (!budget.consumeBytes(info.size)) {
        throw IllegalArgumentException("source auxiliary byte budget exceeded")
    }
    readTextBounded(path, perFileLimit)
}

protected func readAuxiliaryFileBounded(path: Path, perFileLimit: Int64,
    budget: SourceAuxiliaryBudget): Array<Byte> {
    readAuxiliaryFileBoundedSnapshot(path, perFileLimit, budget).bytes
}

protected func readAuxiliaryFileBoundedSnapshot(path: Path, perFileLimit: Int64,
    budget: SourceAuxiliaryBudget): BoundedFileRead {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink() || info.size < 0 ||
        info.size > perFileLimit) {
        throw IllegalArgumentException("auxiliary input is not a bounded regular file")
    }
    if (!budget.consumeBytes(info.size) || !budget.consumeWork(info.size)) {
        throw IllegalArgumentException("source auxiliary cache budget exceeded")
    }
    readFileBoundedSnapshot(path, perFileLimit)
}

protected class SourceCacheStats {
    protected var hits: Int64 = 0
    protected var misses: Int64 = 0
    protected var writes: Int64 = 0
    protected var corruptEntries: Int64 = 0
    protected var writeFailures: Int64 = 0

    protected func reset(): Unit {
        hits = 0
        misses = 0
        writes = 0
        corruptEntries = 0
        writeFailures = 0
    }
}
