"""Native event-driven directory observers. No compiler/SDK interception."""
from __future__ import annotations
import os
from pathlib import Path
import select
import socket
import threading
from ir_hardlinks import CaptureMissed


def windows_notifications(data):
    import struct
    if not data:raise ValueError("directory notification overflow; capture incomplete")
    offset=0
    while True:
        if offset+12>len(data):raise ValueError("truncated directory notification")
        next_offset,action,length=struct.unpack_from("<III",data,offset)
        if length%2 or offset+12+length>len(data):
            raise ValueError("invalid directory notification")
        name=data[offset+12:offset+12+length].decode("utf-16-le")
        yield action,name
        if not next_offset:break
        if next_offset<12+length or offset+next_offset>=len(data):
            raise ValueError("invalid next directory notification")
        offset+=next_offset


class EventWatch:
    def __init__(self, links, platform: str):
        self.links = links
        self.ready = threading.Event()
        self.errors = []
        self.backend = WindowsEvents(links) if platform == "windows-x64" else MacEvents(links)
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        try:
            self.backend.run(self.ready)
        except Exception as error:
            self.errors.append(type(error).__name__ + ": " + str(error))
            self.ready.set()

    def start(self):
        self.thread.start()
        if not self.ready.wait(10) or self.errors:
            raise CaptureMissed("event observer did not start: " + "; ".join(self.errors))

    def stop(self):
        self.backend.stop()
        self.thread.join(10)
        if self.thread.is_alive() or self.errors:
            raise CaptureMissed("event observer did not stop: " + "; ".join(self.errors))


class MacEvents:
    def __init__(self, links):
        if not hasattr(select, "kqueue"):
            raise ValueError("native kqueue is unavailable")
        self.links = links
        self.reader, self.writer = socket.socketpair()

    def stop(self):
        self.writer.send(b"x")

    def run(self, ready):
        queue = select.kqueue()
        directories = {}
        def register():
            paths = [self.links.temporary]
            for root, names, _ in os.walk(self.links.temporary, followlinks=False):
                names[:] = [n for n in names if not (Path(root) / n).is_symlink()]
                paths.extend(Path(root) / n for n in names)
            for path in paths:
                if path in directories.values():
                    continue
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                except FileNotFoundError:
                    continue
                directories[fd] = path
                queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                    flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                    fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME)], 0)
        try:
            queue.control([select.kevent(self.reader.fileno(), filter=select.KQ_FILTER_READ,
                                         flags=select.KQ_EV_ADD)], 0)
            register(); self.links.scan(); ready.set()
            while True:
                events = queue.control(None, 64, None)
                if any(event.ident == self.reader.fileno() for event in events):
                    break
                for event in events:
                    if event.flags & select.KQ_EV_ERROR:
                        raise OSError("kqueue reported an event error")
                    if event.fflags & (select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME):
                        if event.ident in directories:
                            os.close(event.ident); del directories[event.ident]
                register(); self.links.scan()
        finally:
            for fd in directories:
                os.close(fd)
            queue.close(); self.reader.close(); self.writer.close()


class WindowsEvents:
    def __init__(self, links):
        import ctypes
        from ctypes import wintypes as w
        if os.name != "nt":
            raise ValueError("ReadDirectoryChangesW requires Windows")
        self.c, self.w, self.links = ctypes, w, links
        self.dll = ctypes.WinDLL("kernel32", use_last_error=True)
        class Overlapped(ctypes.Structure):
            _fields_ = [("Internal", ctypes.c_size_t), ("InternalHigh", ctypes.c_size_t),
                        ("Offset", w.DWORD), ("OffsetHigh", w.DWORD), ("hEvent", w.HANDLE)]
        self.Overlapped = Overlapped
        prototypes = {
            "CreateFileW": ([w.LPCWSTR,w.DWORD,w.DWORD,w.LPVOID,w.DWORD,w.DWORD,w.HANDLE],w.HANDLE),
            "CreateEventW": ([w.LPVOID,w.BOOL,w.BOOL,w.LPCWSTR],w.HANDLE),
            "SetEvent": ([w.HANDLE],w.BOOL), "ResetEvent": ([w.HANDLE],w.BOOL),
            "CloseHandle": ([w.HANDLE],w.BOOL),
            "ReadDirectoryChangesW": ([w.HANDLE,w.LPVOID,w.DWORD,w.BOOL,w.DWORD,
                ctypes.POINTER(w.DWORD),ctypes.POINTER(Overlapped),w.LPVOID],w.BOOL),
            "WaitForMultipleObjects": ([w.DWORD,ctypes.POINTER(w.HANDLE),w.BOOL,w.DWORD],w.DWORD),
            "GetOverlappedResult": ([w.HANDLE,ctypes.POINTER(Overlapped),ctypes.POINTER(w.DWORD),w.BOOL],w.BOOL),
            "CancelIoEx": ([w.HANDLE,ctypes.POINTER(Overlapped)],w.BOOL),
        }
        for name,(args,result) in prototypes.items():
            function=getattr(self.dll,name); function.argtypes=args; function.restype=result
        self.stop_event = self.dll.CreateEventW(None,True,False,None)
        if not self.stop_event:
            raise ctypes.WinError(ctypes.get_last_error())

    def stop(self):
        if not self.dll.SetEvent(self.stop_event):
            raise self.c.WinError(self.c.get_last_error())

    def run(self, ready):
        c,w,d = self.c,self.w,self.dll
        handle=d.CreateFileW(str(self.links.temporary),1,1|2|4,None,3,0x02000000|0x40000000,None)
        if handle == c.c_void_p(-1).value:
            error=c.get_last_error();d.CloseHandle(self.stop_event)
            raise c.WinError(error)
        event=d.CreateEventW(None,True,False,None)
        if not event:
            error=c.get_last_error();d.CloseHandle(handle);d.CloseHandle(self.stop_event)
            raise c.WinError(error)
        buffer=c.create_string_buffer(65536)
        overlap=self.Overlapped(); overlap.hEvent=event
        waiting=(w.HANDLE*2)(self.stop_event,event)
        try:
            while True:
                d.ResetEvent(event)
                pending=d.ReadDirectoryChangesW(handle,buffer,len(buffer),True,
                    0x1|0x2|0x8|0x10,None,c.byref(overlap),None)
                if not pending and c.get_last_error()!=997:
                    raise c.WinError(c.get_last_error())
                ready.set()
                result=d.WaitForMultipleObjects(2,waiting,False,0xFFFFFFFF)
                if result==0:
                    d.CancelIoEx(handle,c.byref(overlap))
                    count=w.DWORD(); d.GetOverlappedResult(handle,c.byref(overlap),c.byref(count),True)
                    break
                if result!=1:
                    raise c.WinError(c.get_last_error())
                count=w.DWORD()
                if not d.GetOverlappedResult(handle,c.byref(overlap),c.byref(count),False):
                    raise c.WinError(c.get_last_error())
                if count.value==0:
                    raise ValueError("directory notification overflow; capture incomplete")
                for action,name in windows_notifications(buffer.raw[:count.value]):
                    if action in (1,3,5):
                        self.links.accept(self.links.temporary/name)

        finally:
            d.CloseHandle(event);d.CloseHandle(handle);d.CloseHandle(self.stop_event)
