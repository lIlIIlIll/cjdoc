#!/usr/bin/env python3
"""Verify PNG chunk handling through source capture and offline publication."""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zlib


SIGNATURE = b"\x89PNG\r\n\x1a\n"
PIXEL = b"\x00\xff\x00\x00\xff"
COMPRESSED = zlib.compress(PIXEL)


def chunk(kind, data=b""):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(*chunks, width=1):
    header = struct.pack(">IIBBBBB", width, 1, 8, 6, 0, 0, 0)
    return SIGNATURE + chunk(b"IHDR", header) + b"".join(chunks) + chunk(b"IEND")


def execute(binary, *args):
    result = subprocess.run([binary, *args], capture_output=True, encoding="utf-8", timeout=120)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


def fixture(root, images, *, extra=()):
    (root / "src").mkdir(parents=True)
    (root / "cjpm.toml").write_text(
        '[package]\ncjc-version = "1.2.0"\nname = "png_probe"\n'
        'version = "1.0.0"\noutput-type = "static"\n', encoding="utf-8",
    )
    markdown = " ".join(f"![{name}](../{name})" for name in (*images, *extra))
    (root / "src" / "api.cj").write_text(
        f"package png_probe\n/** Pixels {markdown} */\npublic func value(): Int64 {{ 1 }}\n",
        encoding="utf-8",
    )
    for name, data in images.items():
        (root / name).write_bytes(data)


def capture(binary, project):
    return execute(binary, "generate", "--project", project, "--semantic", "source", "--format", "json",
                   "--stdout", "--no-cache", "--lint-profile", "off")


def assert_omissions(document, names):
    assert not document.get("assets"), document.get("assets")
    messages = [item["message"] for item in document["diagnostics"] if item["code"] == "CJDOC4026"]
    assert len(messages) == len(names), messages
    for name in names:
        assert any(name in text for text in messages), (name, messages)


def verify_pixels(data):
    offset = len(SIGNATURE)
    payload = bytearray()
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        if data[offset + 4:offset + 8] == b"IDAT":
            payload.extend(data[offset + 8:offset + 8 + length])
        offset += 12 + length
    assert zlib.decompress(payload) == PIXEL


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = args.output.resolve()
    plain = chunk(b"IDAT", COMPRESSED)
    empty = chunk(b"IDAT")
    left = chunk(b"IDAT", COMPRESSED[:4])
    right = chunk(b"IDAT", COMPRESSED[4:])
    accepted = {
        "plain.png": png(plain), "leading-empty.png": png(empty, plain),
        "middle-empty.png": png(left, empty, right), "trailing-empty.png": png(plain, empty),
        "split.png": png(left, right),
    }
    positive = root / "positive"
    fixture(positive, accepted)
    captured = capture(binary, positive)
    document = json.loads(captured)
    if os.name == "nt":
        # The Windows SDK intentionally fails closed for local asset capture.
        assert_omissions(document, accepted)
    else:
        assert all(item["code"] != "CJDOC4026" for item in document["diagnostics"]), document["diagnostics"]
        assets = {asset["sourcePath"]: base64.b64decode(asset["base64"], validate=True)
                  for asset in document["assets"]}
        assert assets == accepted
        for data in assets.values():
            verify_pixels(data)
        snapshot = root / "png.docs.json"
        snapshot.write_text(captured, encoding="utf-8")
        shutil.rmtree(positive)
        execute(binary, "render", "--input", snapshot, "--format", "html", "--output", root / "replayed")
        published = {path.read_bytes() for path in (root / "replayed" / "html" / "assets").glob("*.png")}
        assert published == set(accepted.values()), "offline publication lost or changed PNG bytes"

    corrupt_empty = empty[:-1] + bytes([empty[-1] ^ 1])
    rejected = {
        "all-empty.png": png(empty, empty),
        "bad-crc.png": png(corrupt_empty, plain),
        "noncontiguous.png": png(empty, chunk(b"tEXt", b"description\x00pixel"), plain),
        "too-wide.png": png(chunk(b"IDAT", zlib.compress(b"\x00" + PIXEL[1:] * 16385)), width=16385),
        "too-large.png": png(plain),
    }
    negative = root / "negative"
    fixture(negative, rejected, extra=("../outside.png",))
    (root / "outside.png").write_bytes(png(plain))
    with (negative / "too-large.png").open("r+b") as image:
        image.truncate(16 * 1024 * 1024 + 1)
    assert_omissions(json.loads(capture(binary, negative)), (*rejected, "outside.png"))
    print("PNG IDAT capture, offline bytes, and rejection boundaries passed")


if __name__ == "__main__":
    main()
