protected package cjdoc.process

import std.process.*
@When[os != "Windows"]
import std.posix.{killpg, SIGKILL}

// Keep these standalone: std.ast rejects foreign blocks in cjdoc's self-documentation pass.
@When[os == "Windows"]
@CallingConv[CDECL]
foreign func CreateJobObjectW(attributes: CPointer<Unit>,
    name: CPointer<UInt16>): CPointer<Unit>

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func SetInformationJobObject(job: CPointer<Unit>, infoClass: Int32,
    limits: VArray<Int64, $18>, length: UInt32): Int32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func OpenProcess(access: UInt32, inheritHandle: Int32,
    processId: UInt32): CPointer<Unit>

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func AssignProcessToJobObject(job: CPointer<Unit>,
    process: CPointer<Unit>): Int32

@When[os == "Windows"]
@CallingConv[CDECL]
foreign func CloseHandle(handle: CPointer<Unit>): Int32

// Windows job ownership is a process-supervision detail, not an example-runner
// detail: every bounded child needs the same handle, so it lives with the
// supervisor and its kill path.
@When[os == "Windows"]
protected func createExampleProcessJob(process: SubProcess,
    memoryBytes!: Int64 = 0): CPointer<Unit> {
    unsafe {
        let job = CreateJobObjectW(CPointer<Unit>(), CPointer<UInt16>())
        if (job.isNull()) {
            throw IllegalStateException("could not create run-example process job")
        }
        // JobObjectExtendedLimitInformation is 18 64-bit words on Windows x64;
        // LimitFlags is word 2 and JobMemoryLimit is word 15.
        if (memoryBytes < 0) {
            throw IllegalArgumentException("memory limit must not be negative")
        }
        let limitFlags: Int64 = if (memoryBytes > 0) { 0x2200 } else { 0x2000 }
        var extendedLimits: VArray<Int64, $18> =
            [0, 0, limitFlags, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        if (memoryBytes > 0) { extendedLimits[15] = memoryBytes }
        if (SetInformationJobObject(job, 9, inout extendedLimits, 144) == 0) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not configure run-example process job")
        }
        let processHandle = OpenProcess(0x0101, 0, UInt32(process.pid))
        if (processHandle.isNull()) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not open run-example supervisor process")
        }
        let assigned = AssignProcessToJobObject(job, processHandle) != 0
        let _ = CloseHandle(processHandle)
        if (!assigned) {
            let _ = CloseHandle(job)
            throw IllegalStateException("could not assign run-example supervisor to process job")
        }
        job
    }
}

@When[os != "Windows"]
protected func createExampleProcessJob(process: SubProcess,
    memoryBytes!: Int64 = 0): CPointer<Unit> {
    let _ = process
    let _ = memoryBytes
    CPointer<Unit>()
}

@When[os == "Windows"]
protected func closeExampleProcessJob(job: CPointer<Unit>): Bool {
    if (job.isNull()) { return false }
    unsafe { CloseHandle(job) != 0 }
}

@When[os != "Windows"]
protected func closeExampleProcessJob(job: CPointer<Unit>): Bool {
    let _ = job
    false
}
