#!/usr/bin/env python3
"""Bound archive parsing before Python archive libraries materialize metadata."""

from __future__ import annotations

from dataclasses import dataclass
import gzip
from pathlib import Path
import struct
from typing import BinaryIO


EOCD_SIGNATURE = b"PK\x05\x06"
ZIP64_EOCD_SIGNATURE = b"PK\x06\x06"
ZIP64_LOCATOR_SIGNATURE = b"PK\x06\x07"
CENTRAL_FILE_SIGNATURE = b"PK\x01\x02"
EOCD = struct.Struct("<4s4H2LH")
ZIP64_LOCATOR = struct.Struct("<4sLQL")
ZIP64_EOCD = struct.Struct("<4sQ2H2L4Q")
CENTRAL_FILE = struct.Struct("<4s6H3L5H2L")
MAX_EOCD_SEARCH = EOCD.size + 65535
MAX_ZIP64_RECORD_SIZE = 1024 * 1024
TAR_BLOCK_SIZE = 512
TAR_ZERO_BLOCK = b"\0" * TAR_BLOCK_SIZE
ZIP_MAGICS = (b"PK\x03\x04", b"PK\x05\x06")
GZIP_MAGIC = b"\x1f\x8b"
TAR_EXTENSION_TYPES = {b"x", b"g", b"L", b"K"}


@dataclass(frozen=True)
class ZipDirectorySummary:
    entries: int
    directory_size: int


@dataclass(frozen=True)
class TarHeaderSummary:
    headers: int
    members: int
    payload_size: int
    expanded_size: int
    extension_headers: int


def archive_magic(path: Path) -> str:
    """Classify an archive from bytes at offset zero, never from its suffix."""
    with path.open("rb") as stream:
        prefix = stream.read(TAR_BLOCK_SIZE)
    if prefix[:4] in ZIP_MAGICS:
        return "zip"
    if prefix.startswith(GZIP_MAGIC):
        return "gzip-tar"
    if len(prefix) == TAR_BLOCK_SIZE and _valid_tar_checksum(prefix):
        return "tar"
    raise ValueError("archive magic is unsupported or malformed")


def _parse_tar_number(field: bytes, label: str) -> int:
    if field and field[0] & 0x80:
        # POSIX permits GNU base-256 values. Only non-negative sizes/modes are useful here.
        if field[0] & 0x40:
            raise ValueError(f"TAR {label} is negative")
        value = int.from_bytes(bytes((field[0] & 0x7F,)) + field[1:], "big")
    else:
        stripped = field.rstrip(b"\0 ").lstrip(b" ")
        if not stripped:
            return 0
        if any(byte < ord("0") or byte > ord("7") for byte in stripped):
            raise ValueError(f"TAR {label} is not an octal number")
        value = int(stripped, 8)
    if value < 0:
        raise ValueError(f"TAR {label} is negative")
    return value


def _valid_tar_checksum(header: bytes) -> bool:
    if len(header) != TAR_BLOCK_SIZE or header == TAR_ZERO_BLOCK:
        return False
    try:
        expected = _parse_tar_number(header[148:156], "checksum")
    except ValueError:
        return False
    actual = sum(header[:148]) + (8 * ord(" ")) + sum(header[156:])
    return actual == expected


class _BoundedTarReader:
    def __init__(self, stream: BinaryIO, maximum: int):
        self.stream = stream
        self.maximum = maximum
        self.consumed = 0

    def read_exact(self, size: int) -> bytes:
        if size < 0 or self.consumed + size > self.maximum:
            raise ValueError("TAR expanded bytes exceed the verification limit")
        blocks: list[bytes] = []
        remaining = size
        while remaining:
            block = self.stream.read(min(1024 * 1024, remaining))
            if not block:
                raise ValueError("TAR archive is truncated")
            blocks.append(block)
            remaining -= len(block)
            self.consumed += len(block)
        return b"".join(blocks)

    def discard_exact(self, size: int) -> None:
        if size < 0 or self.consumed + size > self.maximum:
            raise ValueError("TAR expanded bytes exceed the verification limit")
        remaining = size
        while remaining:
            block = self.stream.read(min(1024 * 1024, remaining))
            if not block:
                raise ValueError("TAR archive is truncated")
            remaining -= len(block)
            self.consumed += len(block)

    def require_zero_tail(self) -> None:
        while True:
            if self.consumed >= self.maximum:
                extra = self.stream.read(1)
                if extra:
                    raise ValueError("TAR expanded bytes exceed the verification limit")
                return
            block = self.stream.read(min(1024 * 1024, self.maximum - self.consumed))
            if not block:
                return
            self.consumed += len(block)
            if any(block):
                raise ValueError("TAR archive contains data after its end marker")


def _pax_values(content: bytes) -> dict[str, str]:
    result: dict[str, str] = {}
    offset = 0
    while offset < len(content):
        space = content.find(b" ", offset)
        if space <= offset or not content[offset:space].isdigit():
            raise ValueError("PAX extension contains a malformed record length")
        length = int(content[offset:space])
        end = offset + length
        if length < 5 or end > len(content) or content[end - 1:end] != b"\n":
            raise ValueError("PAX extension contains a malformed record")
        record = content[space + 1:end - 1]
        key, separator, raw_value = record.partition(b"=")
        if separator != b"=" or not key:
            raise ValueError("PAX extension contains a malformed key/value")
        try:
            rendered_key = key.decode("utf-8", "strict")
            rendered_value = raw_value.decode("utf-8", "strict")
        except UnicodeDecodeError as error:
            raise ValueError("PAX extension is not UTF-8") from error
        if rendered_key in result:
            raise ValueError(f"PAX extension contains a duplicate key: {rendered_key}")
        if rendered_key.startswith("GNU.sparse") or rendered_key == "SCHILY.realsize":
            raise ValueError("sparse TAR extensions are unsupported")
        result[rendered_key] = rendered_value
        offset = end
    return result


def _pax_size(value: str) -> int:
    if not value or not value.isascii() or not value.isdecimal():
        raise ValueError("PAX size is not a non-negative decimal integer")
    return int(value, 10)


def _inspect_tar_stream(stream: BinaryIO, *, max_headers: int,
                        max_member_size: int, max_total_size: int,
                        max_expanded_size: int, max_extension_headers: int,
                        max_extension_size: int, allow_extensions: bool,
                        allowed_member_types: frozenset[bytes]) -> TarHeaderSummary:
    reader = _BoundedTarReader(stream, max_expanded_size)
    headers = members = total = extensions = extension_total = 0
    zero_blocks = 0
    local_pax: dict[str, str] | None = None
    global_pax: dict[str, str] = {}
    while True:
        header = reader.read_exact(TAR_BLOCK_SIZE)
        if header == TAR_ZERO_BLOCK:
            zero_blocks += 1
            if zero_blocks == 2:
                reader.require_zero_tail()
                break
            continue
        if zero_blocks:
            raise ValueError("TAR archive has only one zero end block")
        headers += 1
        if headers > max_headers:
            raise ValueError("TAR archive contains too many headers")
        if not _valid_tar_checksum(header):
            raise ValueError("TAR header checksum is invalid")
        declared_size = _parse_tar_number(header[124:136], "member size")
        type_flag = header[156:157] or b"\0"
        if type_flag in TAR_EXTENSION_TYPES:
            extensions += 1
            if not allow_extensions:
                raise ValueError("TAR extension headers are unsupported for release archives")
            if extensions > max_extension_headers or declared_size > max_extension_size or \
                    extension_total + declared_size > max_extension_size:
                raise ValueError("TAR extension headers exceed the verification limit")
            extension_total += declared_size
            content = reader.read_exact(declared_size)
            padding = (-declared_size) % TAR_BLOCK_SIZE
            reader.discard_exact(padding)
            if type_flag in (b"x", b"g"):
                values = _pax_values(content)
                if type_flag == b"g":
                    if "size" in values:
                        raise ValueError("global PAX size overrides are unsupported")
                    global_pax.update(values)
                else:
                    if local_pax is not None:
                        raise ValueError("multiple local PAX headers precede one member")
                    local_pax = values
            continue

        if type_flag not in allowed_member_types:
            raise ValueError(f"TAR archive contains an unsupported member type: {type_flag!r}")

        effective_size = declared_size
        if "size" in global_pax:
            raise ValueError("global PAX size overrides are unsupported")
        if local_pax is not None and "size" in local_pax:
            effective_size = _pax_size(local_pax["size"])
        local_pax = None
        if effective_size > max_member_size:
            raise ValueError("TAR archive member is too large")
        total += effective_size
        if total > max_total_size:
            raise ValueError("TAR archive payload exceeds the verification limit")
        members += 1
        reader.discard_exact(effective_size)
        reader.discard_exact((-effective_size) % TAR_BLOCK_SIZE)
    if local_pax is not None:
        raise ValueError("TAR archive ends after an unconsumed PAX header")
    return TarHeaderSummary(headers, members, total, reader.consumed, extensions)


def inspect_tar_headers(path: Path, *, compressed: bool, max_headers: int,
                        max_member_size: int, max_total_size: int,
                        max_expanded_size: int, max_extension_headers: int,
                        max_extension_size: int,
                        allow_extensions: bool,
                        allowed_member_types: frozenset[bytes]) -> TarHeaderSummary:
    """Scan every TAR header and payload boundary before invoking ``tarfile``."""
    if min(max_headers, max_member_size, max_total_size, max_expanded_size,
           max_extension_headers, max_extension_size) < 0 or max_headers < 1:
        raise ValueError("invalid TAR verification limits")
    with path.open("rb") as raw:
        if compressed:
            if raw.read(2) != GZIP_MAGIC:
                raise ValueError("TAR.GZ archive has invalid gzip magic")
            raw.seek(0)
            with gzip.GzipFile(fileobj=raw, mode="rb") as stream:
                return _inspect_tar_stream(
                    stream, max_headers=max_headers, max_member_size=max_member_size,
                    max_total_size=max_total_size, max_expanded_size=max_expanded_size,
                    max_extension_headers=max_extension_headers,
                    max_extension_size=max_extension_size,
                    allow_extensions=allow_extensions,
                    allowed_member_types=allowed_member_types,
                )
        return _inspect_tar_stream(
            raw, max_headers=max_headers, max_member_size=max_member_size,
            max_total_size=max_total_size, max_expanded_size=max_expanded_size,
            max_extension_headers=max_extension_headers,
            max_extension_size=max_extension_size,
            allow_extensions=allow_extensions,
            allowed_member_types=allowed_member_types,
        )


def _find_eocd(stream, archive_size: int) -> tuple[int, tuple[object, ...]]:
    tail_size = min(archive_size, MAX_EOCD_SEARCH)
    stream.seek(archive_size - tail_size)
    tail = stream.read(tail_size)
    offset = len(tail)
    while True:
        offset = tail.rfind(EOCD_SIGNATURE, 0, offset)
        if offset < 0:
            raise ValueError("ZIP end-of-central-directory record is missing")
        if len(tail) - offset >= EOCD.size:
            fields = EOCD.unpack_from(tail, offset)
            comment_size = fields[7]
            absolute = archive_size - tail_size + offset
            if absolute + EOCD.size + comment_size == archive_size:
                return absolute, fields


def _read_zip64_eocd(stream, locator_offset: int,
                     declared_offset: int) -> tuple[int, tuple[object, ...]]:
    def read_candidate(offset: int) -> tuple[int, tuple[object, ...]] | None:
        if offset < 0 or offset + ZIP64_EOCD.size > locator_offset:
            return None
        stream.seek(offset)
        fixed = stream.read(ZIP64_EOCD.size)
        if len(fixed) != ZIP64_EOCD.size or not fixed.startswith(ZIP64_EOCD_SIGNATURE):
            return None
        fields = ZIP64_EOCD.unpack(fixed)
        record_size = fields[1]
        if record_size < 44 or record_size > MAX_ZIP64_RECORD_SIZE or \
                offset + 12 + record_size != locator_offset:
            return None
        return offset, fields

    direct = read_candidate(declared_offset)
    if direct is not None:
        return direct

    search_size = min(locator_offset, MAX_ZIP64_RECORD_SIZE + ZIP64_EOCD.size)
    stream.seek(locator_offset - search_size)
    window = stream.read(search_size)
    cursor = len(window)
    while True:
        cursor = window.rfind(ZIP64_EOCD_SIGNATURE, 0, cursor)
        if cursor < 0:
            break
        candidate = read_candidate(locator_offset - search_size + cursor)
        if candidate is not None:
            return candidate
    raise ValueError("ZIP64 end-of-central-directory record is missing or oversized")


def inspect_zip_directory(path: Path, *, max_entries: int,
                          max_directory_size: int) -> ZipDirectorySummary:
    """Validate and count central headers without allocating ``ZipInfo`` objects."""
    if max_entries < 1 or max_directory_size < CENTRAL_FILE.size:
        raise ValueError("invalid ZIP verification limits")
    archive_size = path.stat().st_size
    with path.open("rb") as stream:
        eocd_offset, eocd = _find_eocd(stream, archive_size)
        disk_number, central_disk = eocd[1], eocd[2]
        entries_on_disk, declared_entries = eocd[3], eocd[4]
        directory_size, directory_offset = eocd[5], eocd[6]
        boundary = eocd_offset

        uses_zip64 = any(value == sentinel for value, sentinel in (
            (entries_on_disk, 0xFFFF), (declared_entries, 0xFFFF),
            (directory_size, 0xFFFFFFFF), (directory_offset, 0xFFFFFFFF),
        ))
        if uses_zip64:
            locator_offset = eocd_offset - ZIP64_LOCATOR.size
            if locator_offset < 0:
                raise ValueError("ZIP64 locator is missing")
            stream.seek(locator_offset)
            locator_data = stream.read(ZIP64_LOCATOR.size)
            if len(locator_data) != ZIP64_LOCATOR.size:
                raise ValueError("ZIP64 locator is truncated")
            signature, zip64_disk, zip64_offset, total_disks = \
                ZIP64_LOCATOR.unpack(locator_data)
            if signature != ZIP64_LOCATOR_SIGNATURE or zip64_disk != 0 or total_disks != 1:
                raise ValueError("multi-disk or malformed ZIP64 archives are unsupported")
            boundary, zip64 = _read_zip64_eocd(stream, locator_offset, zip64_offset)
            disk_number, central_disk = zip64[4], zip64[5]
            entries_on_disk, declared_entries = zip64[6], zip64[7]
            directory_size, directory_offset = zip64[8], zip64[9]

        if disk_number != 0 or central_disk != 0 or entries_on_disk != declared_entries:
            raise ValueError("multi-disk ZIP archives are unsupported")
        if declared_entries > max_entries:
            raise ValueError("release archive contains too many members")
        if directory_size > max_directory_size:
            raise ValueError("ZIP central directory exceeds the verification limit")
        central_start = boundary - directory_size
        if central_start < 0 or directory_offset > central_start:
            raise ValueError("ZIP central directory offset is invalid")

        stream.seek(central_start)
        actual_entries = 0
        position = central_start
        while position < boundary:
            if boundary - position < CENTRAL_FILE.size:
                raise ValueError("ZIP central directory is truncated")
            header = stream.read(CENTRAL_FILE.size)
            if len(header) != CENTRAL_FILE.size:
                raise ValueError("ZIP central directory is truncated")
            fields = CENTRAL_FILE.unpack(header)
            if fields[0] != CENTRAL_FILE_SIGNATURE:
                raise ValueError("ZIP central directory contains an unexpected record")
            variable_size = fields[10] + fields[11] + fields[12]
            entry_size = CENTRAL_FILE.size + variable_size
            if position + entry_size > boundary:
                raise ValueError("ZIP central-directory entry is truncated")
            stream.seek(variable_size, 1)
            position += entry_size
            actual_entries += 1
            if actual_entries > max_entries:
                raise ValueError("release archive contains too many members")
        if position != boundary or actual_entries != declared_entries:
            raise ValueError("ZIP central-directory member count is inconsistent")
    return ZipDirectorySummary(actual_entries, directory_size)
