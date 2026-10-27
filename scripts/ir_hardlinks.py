"""Retain regular compiler IR with same-volume links; no held source handles."""
from __future__ import annotations
import hashlib
import os
from pathlib import Path
import stat
import threading


class CaptureMissed(ValueError):
    pass


def ordinary(path: Path) -> bool:
    info = path.lstat()
    return stat.S_ISREG(info.st_mode) and not path.is_symlink() and not (
        hasattr(path, "is_junction") and path.is_junction())


class IrLinks:
    def __init__(self, temporary: Path, retained: Path):
        self.temporary = temporary.resolve(strict=True)
        self.retained = retained.resolve(strict=True)
        if self.retained.is_relative_to(self.temporary):
            raise CaptureMissed("retention directory must be outside compiler temporary tree")
        if self.temporary.stat().st_dev != self.retained.stat().st_dev:
            raise CaptureMissed("compiler temporary and retention roots are not on one volume")
        self.entries = []
        self.issues = []
        self.lock = threading.Lock()

    def accept(self, path: Path):
        if not path.name.endswith(".opt.bc"):
            return
        with self.lock:
            if self.issues:
                return
            try:
                relative = path.relative_to(self.temporary)
                for parent in [self.temporary, *list(path.parents)[:len(relative.parts) - 1]]:
                    if parent.is_symlink() or (hasattr(parent, "is_junction") and parent.is_junction()):
                        raise CaptureMissed("IR parent is a symlink or junction")
                if not ordinary(path) or not path.resolve(strict=True).is_relative_to(self.temporary):
                    raise CaptureMissed("IR input is not an owned regular file")
                source = path.lstat()
                identity = (source.st_dev, source.st_ino)
                if any((row["device"], row["inode"]) == identity for row in self.entries):
                    return
                if len(self.entries) >= 128:
                    raise CaptureMissed("IR file count limit exceeded")
                if source.st_dev != self.retained.stat().st_dev:
                    raise CaptureMissed("IR and retention roots are not on one volume")
                destination = self.retained / (str(len(self.entries)) + "-" + path.name)
                os.link(path, destination, follow_symlinks=False)
                linked = destination.lstat()
                if not ordinary(destination) or (linked.st_dev, linked.st_ino) != identity:
                    destination.unlink()
                    raise CaptureMissed("IR identity changed while creating its hard link")
                if linked.st_nlink < 2:
                    destination.unlink()
                    raise CaptureMissed("hard link did not increase source link count")
                self.entries.append({"sourceRelative": relative.as_posix(), "name": path.name,
                                     "retained": destination.name, "device": linked.st_dev,
                                     "inode": linked.st_ino, "linkCountAfterLink": linked.st_nlink})
            except FileNotFoundError as error:
                # Notifications can outlive an already captured pathname.
                if not any(row["sourceRelative"] == path.relative_to(self.temporary).as_posix()
                           for row in self.entries):
                    self.issues.append("missed IR before hard link: " + str(error))
            except (OSError, ValueError) as error:
                self.issues.append(type(error).__name__ + ": " + str(error))

    def walk(self):
        return os.walk(self.temporary, followlinks=False)

    def scan(self):
        # Called only on filesystem notifications, once at startup and once at
        # shutdown. There is no timer or unchanged-state polling.
        for directory, names, files in self.walk():
            names[:] = [name for name in names
                        if not (Path(directory) / name).is_symlink()
                        and not (hasattr(Path(directory) / name, "is_junction")
                                 and (Path(directory) / name).is_junction())]
            for name in files:
                if name.endswith(".opt.bc"):
                    self.accept(Path(directory) / name)

    def finish(self):
        if self.issues:
            raise CaptureMissed("; ".join(self.issues))
        self.scan()
        results = []
        total = 0
        for row in self.entries:
            path = self.retained / row["retained"]
            before = path.lstat()
            if not ordinary(path) or (before.st_dev, before.st_ino) != (row["device"], row["inode"]):
                raise CaptureMissed("retained IR identity changed")
            if before.st_size > 64 * 1024 * 1024:
                raise CaptureMissed("retained IR exceeds per-file budget")
            total += before.st_size
            if total > 256 * 1024 * 1024:
                raise CaptureMissed("retained IR exceeds total budget")
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(65536), b""):
                    digest.update(block)
            after = path.lstat()
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                    after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise CaptureMissed("retained IR changed after compiler exit")
            results.append({**row, "size": after.st_size, "sha256": digest.hexdigest(),
                            "linkCountAfterCompiler": after.st_nlink,
                            "originalPresent": (self.temporary / row["sourceRelative"]).exists()})
        if self.issues:
            raise CaptureMissed("; ".join(self.issues))
        if not results:
            raise CaptureMissed("no optimized bitcode captured")
        return results
