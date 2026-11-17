package cjdoc

import cjdoc_chir_protocol.CHIR_WORKER_BASENAME
import std.fs.*

@When[os == "macOS"]
foreign func _NSGetExecutablePath(buffer: CPointer<UInt8>, size: CPointer<UInt32>): Int32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func GetModuleFileNameW(moduleHandle: CPointer<Unit>, buffer: CPointer<UInt16>, size: UInt32): UInt32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func WideCharToMultiByte(codePage: UInt32, flags: UInt32,
    source: CPointer<UInt16>, sourceSize: Int32, output: CPointer<UInt8>, outputSize: Int32,
    defaultCharacter: CPointer<UInt8>, usedDefaultCharacter: CPointer<Int32>): Int32

@When[os == "Linux"]
private func nativeCjdocExecutablePath(): Path {
    canonicalize(Path("/proc/self/exe"))
}

@When[os == "macOS"]
private func nativeCjdocExecutablePath(): Path {
    unsafe {
        var size: UInt32 = 0
        let _ = _NSGetExecutablePath(CPointer<UInt8>(), inout size)
        if (size == 0 || size > 32768) {
            throw IllegalStateException("current executable path is unavailable")
        }
        let buffer = Array<Byte>(Int64(size), repeat: 0)
        let handle = acquireArrayRawData(buffer)
        try {
            if (_NSGetExecutablePath(handle.pointer, inout size) != 0) {
                throw IllegalStateException("current executable path is unavailable")
            }
        } finally { releaseArrayRawData(handle) }
        var length: Int64 = 0
        while (length < buffer.size && buffer[length] != 0) { length++ }
        if (length == 0 || length == buffer.size) {
            throw IllegalStateException("current executable path is invalid")
        }
        canonicalize(Path(String.fromUtf8(buffer[..length])))
    }
}

@When[os == "Windows"]
private func windowsExecutablePath(source: CPointer<UInt16>, length: UInt32): Path {
    unsafe {
        // Preserve non-ASCII installation paths and reject invalid UTF-16.
        let size = WideCharToMultiByte(65001, 128, source, Int32(length),
            CPointer<UInt8>(), 0, CPointer<UInt8>(), CPointer<Int32>())
        if (size <= 0 || size > 131072) {
            throw IllegalStateException("current executable path encoding is invalid")
        }
        let buffer = Array<Byte>(Int64(size), repeat: 0)
        let output = acquireArrayRawData(buffer)
        try {
            if (WideCharToMultiByte(65001, 128, source, Int32(length),
                output.pointer, size, CPointer<UInt8>(), CPointer<Int32>()) != size) {
                throw IllegalStateException("current executable path encoding is invalid")
            }
        } finally { releaseArrayRawData(output) }
        canonicalize(Path(String.fromUtf8(buffer)))
    }
}

@When[os == "Windows"]
private func nativeCjdocExecutablePath(): Path {
    var capacity: Int64 = 512
    while (capacity <= 32768) {
        let wide = Array<UInt16>(capacity, repeat: 0)
        unsafe {
            let source = acquireArrayRawData(wide)
            try {
                let length = GetModuleFileNameW(CPointer<Unit>(), source.pointer, UInt32(capacity))
                if (length == 0) {
                    throw IllegalStateException("current executable path is unavailable")
                }
                if (length < UInt32(capacity)) { return windowsExecutablePath(source.pointer, length) }
            } finally { releaseArrayRawData(source) }
        }
        capacity *= 2
    }
    throw IllegalStateException("current executable path exceeds the platform limit")
}

@When[os != "Linux" && os != "macOS" && os != "Windows"]
private func nativeCjdocExecutablePath(): Path {
    throw IllegalStateException("current executable discovery is unsupported on this platform")
}

internal func currentCjdocExecutablePath(): ?String {
    try { Some(nativeCjdocExecutablePath().toString()) } catch (_: Exception) { None }
}

@When[os == "Windows"]
private func installedChirWorkerName(): String { CHIR_WORKER_BASENAME + ".exe" }

@When[os != "Windows"]
private func installedChirWorkerName(): String { CHIR_WORKER_BASENAME }

internal func selectedCliChirWorker(options: NewCliOptions, executable: ?String): ?String {
    if (options.semanticMode != "chir") { return None }
    if (options.chirWorkerExecutable.isSome()) { return options.chirWorkerExecutable }
    match (executable) {
        case Some(path) => Some(Path(path).parent.join(installedChirWorkerName()).toString())
        case None => None
    }
}
