"""Acceptance-only process observations; unknown state is never treated as exit.

Cancellation observes live worker/child identities before releasing the cancel
gate. Windows keeps process handles; Linux keeps pidfds; macOS records ps birth
and full command identity and registers an exit notification before cancellation.
"""
from __future__ import annotations

import os
from pathlib import Path
import select
import signal
import subprocess
import sys


def _posix_state(pid):
    if sys.platform.startswith("linux"):
        try:
            fields = (Path("/proc") / str(pid) / "stat").read_text().rpartition(") ")[2].split()
        except FileNotFoundError:
            return None
        if len(fields) < 20:
            raise RuntimeError("invalid process state")
        return fields[0], fields[19]
    if sys.platform == "darwin":
        result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "lstart=", "-o", "stat=",
                                 "-o", "args="], capture_output=True, text=True, timeout=3,
                                env=dict(os.environ, LC_ALL="C"))
        if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
            return None
        if result.returncode or result.stderr.strip():
            raise RuntimeError("unable to query process state")
        fields = result.stdout.strip().split(None, 6)
        if len(fields) >= 6 and "Z" in fields[5]:
            return fields[5], (" ".join(fields[:5]), "<zombie>")
        if len(fields) != 7:
            raise RuntimeError("invalid process state")
        return fields[5], (" ".join(fields[:5]), fields[6])
    raise RuntimeError("unsupported process-observation platform")


def _windows_api():
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetExitCodeProcess.restype = wintypes.BOOL
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.GetProcessTimes.restype = wintypes.BOOL
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
        wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateProcess.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    return ctypes, wintypes, kernel


def _windows_parent_pid(pid):
    ctypes, types, kernel = _windows_api()
    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", types.DWORD), ("cntUsage", types.DWORD),
            ("th32ProcessID", types.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", types.DWORD), ("cntThreads", types.DWORD),
            ("th32ParentProcessID", types.DWORD), ("pcPriClassBase", types.LONG),
            ("dwFlags", types.DWORD), ("szExeFile", types.WCHAR * 260)]
    kernel.CreateToolhelp32Snapshot.argtypes = [types.DWORD, types.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = types.HANDLE
    kernel.Process32FirstW.argtypes = [types.HANDLE, ctypes.POINTER(Entry)]
    kernel.Process32FirstW.restype = types.BOOL
    kernel.Process32NextW.argtypes = [types.HANDLE, ctypes.POINTER(Entry)]
    kernel.Process32NextW.restype = types.BOOL
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(entry)
        found = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while found:
            if entry.th32ProcessID == pid:
                return int(entry.th32ParentProcessID)
            found = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        if ctypes.get_last_error() != 18:  # ERROR_NO_MORE_FILES
            raise ctypes.WinError(ctypes.get_last_error())
        return None
    finally:
        kernel.CloseHandle(snapshot)


class ObservedProcess:
    def __init__(self, pid, *, require_live=False, expected_executable=None, expected_command=None,
                 expected_parent=None):
        if not isinstance(pid, int) or pid <= 0:
            raise ValueError("invalid observed process id")
        self.pid, self.handle, self.queue = pid, None, None
        self.backend = ("windows-handle" if os.name == "nt" else
                        "linux-pidfd" if sys.platform.startswith("linux") else "darwin-ps-kqueue")
        self.identity, self.exited = None, False
        try:
            if os.name == "nt":
                ctypes, types, kernel = _windows_api()
                self.handle = kernel.OpenProcess(0x100000 | 0x1000 | 0x0001, False, pid)
                if not self.handle:
                    if ctypes.get_last_error() != 87:  # ERROR_INVALID_PARAMETER: no such PID.
                        raise ctypes.WinError(ctypes.get_last_error())
                    self.exited = True
                else:
                    times = [types.FILETIME() for _ in range(4)]
                    if not kernel.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
                        raise ctypes.WinError(ctypes.get_last_error())
                    self.identity = times[0].dwHighDateTime << 32 | times[0].dwLowDateTime
            else:
                state = _posix_state(pid)
                if state is None or "Z" in state[0]:
                    self.exited = True
                else:
                    self.identity = state[1]
                    if sys.platform.startswith("linux"):
                        try:
                            self.handle = os.pidfd_open(pid)
                        except ProcessLookupError:
                            self.exited = True
                    elif sys.platform == "darwin":
                        self.queue = select.kqueue()
                        try:
                            self.queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                fflags=select.KQ_NOTE_EXIT)], 0, 0)
                        except ProcessLookupError:
                            self.exited = True
                    state = _posix_state(pid)
                    if state is None or state[1] != self.identity or "Z" in state[0]:
                        self.exited = True
            if os.name == "nt" and expected_parent is not None and not self.stopped():
                if _windows_parent_pid(pid) != expected_parent:
                    raise AssertionError("unexpected cancellation process parent")
            if expected_executable is not None and not self.stopped():
                if os.name == "nt":
                    ctypes, types, kernel = _windows_api()
                    buffer = ctypes.create_unicode_buffer(32768)
                    length = types.DWORD(len(buffer))
                    if not kernel.QueryFullProcessImageNameW(self.handle, 0, buffer, ctypes.byref(length)):
                        raise ctypes.WinError(ctypes.get_last_error())
                    image = Path(buffer.value)
                elif sys.platform.startswith("linux"):
                    image = Path("/proc") / str(pid) / "exe"
                else:
                    image = None
                if image is not None and not os.path.samefile(image, expected_executable):
                    raise AssertionError("unexpected cancellation process executable")
                if expected_command is not None and os.name != "nt":
                    arguments = ((Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
                        if sys.platform.startswith("linux") else self.identity[1])
                    present = (os.fsencode(expected_command) in arguments if isinstance(arguments, list)
                               else expected_command in arguments)
                    if not present:
                        raise AssertionError("unexpected cancellation process command")
            if require_live and self.stopped():
                raise AssertionError("cancellation target exited before it was observed")
        except BaseException:
            self.close()
            raise

    def stopped(self):
        if self.exited:
            return True
        if os.name == "nt":
            ctypes, types, kernel = _windows_api()
            state = kernel.WaitForSingleObject(self.handle, 0)
            if state == 258:  # WAIT_TIMEOUT: still running.
                return False
            if state != 0:
                raise ctypes.WinError(ctypes.get_last_error())
            code = types.DWORD()
            if not kernel.GetExitCodeProcess(self.handle, ctypes.byref(code)):
                raise ctypes.WinError(ctypes.get_last_error())
            self.exited = True
        elif self.handle is not None:
            self.exited = bool(select.select([self.handle], [], [], 0)[0])
        else:
            events = self.queue.control(None, 1, 0) if self.queue is not None else []
            for event in events:
                if event.flags & select.KQ_EV_ERROR:
                    raise OSError(event.data, "unable to observe process exit")
                if not event.fflags & select.KQ_NOTE_EXIT:
                    raise RuntimeError("unexpected process notification")
            state = _posix_state(self.pid)
            self.exited = bool(events) or state is None or state[1] != self.identity or "Z" in state[0]
        return self.exited

    def cleanup(self):
        if self.stopped():
            return
        if os.name == "nt":
            ctypes, _, kernel = _windows_api()
            if not kernel.TerminateProcess(self.handle, 1):
                raise ctypes.WinError(ctypes.get_last_error())
        elif self.handle is not None:
            try:
                signal.pidfd_send_signal(self.handle, signal.SIGKILL)
            except ProcessLookupError:
                self.exited = True
        else:
            # Never signal a PID adopted from a later log read. Recheck the live
            # birth/command tuple of this pre-cancel observation immediately.
            state = _posix_state(self.pid)
            if state is not None and state[1] == self.identity and "Z" not in state[0]:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def close(self):
        if self.handle is not None:
            if os.name == "nt":
                _windows_api()[2].CloseHandle(self.handle)
            else:
                os.close(self.handle)
            self.handle = None
        if self.queue is not None:
            self.queue.close()
            self.queue = None


def assert_stopped(pid, observed=None):
    process = observed or ObservedProcess(pid)
    try:
        assert process.stopped(), "live orphan " + str(pid)
    finally:
        if observed is None:
            process.close()


def observe_cancel_targets(records, *, node=None, wrapper=None, child_marker=None, parent_pid=None):
    processes = {}
    workers = {event["pid"] for event in records if event["event"] == "start"}
    try:
        for event in records:
            if event["event"] in ["start", "child"]:
                assert event["pid"] not in processes, "duplicate cancellation identity"
                if parent_pid is not None and event["event"] == "child":
                    assert event.get("parent") in workers, "unowned cancellation descendant"
                command = str(wrapper) if event["event"] == "start" and wrapper is not None else child_marker
                processes[event["pid"]] = ObservedProcess(event["pid"], require_live=True,
                    expected_executable=node, expected_command=command,
                    expected_parent=parent_pid if event["event"] == "start" else event.get("parent"))
        assert {event["event"] for event in records} >= {"start", "child"}, "missing real cancellation child"
        return processes
    except BaseException:
        for process in processes.values():
            process.close()
        raise


def cleanup_observed(processes):
    failure = None
    try:
        for process in processes.values():
            try:
                process.cleanup()
            except Exception as error:
                failure = failure or error
    finally:
        for process in processes.values():
            process.close()
    if failure:
        raise failure
