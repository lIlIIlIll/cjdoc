#!/usr/bin/env python3
"""Prepare the immutable, unmodified yjson reader cross-sample and author-derived tasks."""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile
import urllib.request

sys.dont_write_bytecode = True
try:
    from .reader_corpus import digest, matcher
except ImportError:
    from reader_corpus import digest, matcher

REVISION = "54b4965dee0f0b96710cbc678ec5ec9a126b055c"
ARCHIVE_URL = f"https://codeload.github.com/lIlIIlIll/yjson/tar.gz/{REVISION}"
ARCHIVE_SHA256 = "083861dab05c1465af607998652ec5e5817d108519c36df936809862bf0b5837"
ARCHIVE_BYTES = 58926668


def queries() -> list[dict]:
    stream = matcher("yjson.YJson.fromJson", ["InputStream", "JsonReadOptions"])
    document = matcher("yjson.YJson.parseDocument", ["String", "JsonReadOptions"])
    cases = [
        ("exact", "JsonReadOptions", matcher("yjson.JsonReadOptions")),
        ("qualified", "yjson.JsonNode", matcher("yjson.JsonNode")),
        ("parameter", "owner:YJson param:InputStream", stream),
        ("return", "return:JsonDocument", document),
        ("contract", "stream is not closed", stream),
        ("typo", "JsonReadOptons", matcher("yjson.JsonReadOptions")),
        ("package", "package:yjson JsonReadOptions", matcher("yjson.JsonReadOptions")),
        ("overload", "owner:YJson param:InputStream param:JsonReadOptions", stream),
        ("many", "kind:function", document),
    ]
    result = [{"id": f"E{index:03d}", "kind": kind, "query": query,
               "expected": [target], "expectedOutcome": "hit"}
              for index, (kind, query, target) in enumerate(cases, 1)]
    result.append({"id": "E010", "kind": "missing", "query": "rdr_external_absent_token",
                   "expected": [], "expectedOutcome": "absent"})
    return result


def prepare(destination: Path, archive: Path | None = None) -> dict:
    destination.mkdir(parents=True, exist_ok=False)
    if archive:
        if archive.stat().st_size != ARCHIVE_BYTES:
            raise ValueError("cross-sample archive does not match its pinned byte size")
        content = archive.read_bytes()
    else:
        request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "cjdoc-reader-benchmark"})
        with urllib.request.urlopen(request, timeout=120) as response:
            content = response.read(ARCHIVE_BYTES + 1)
        if len(content) != ARCHIVE_BYTES:
            raise ValueError("cross-sample archive does not match its pinned byte size")
    if digest(content) != ARCHIVE_SHA256:
        raise ValueError("immutable cross-sample archive checksum mismatch")
    (destination / "source.tar.gz").write_bytes(content)
    prefix = "yjson-" + REVISION
    with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as bundle:
        if any(PurePosixPath(member.name).parts[0] != prefix for member in bundle.getmembers()):
            raise ValueError("unexpected cross-sample archive root")
        bundle.extractall(destination / "source", filter="data")
    project = destination / "source" / prefix
    sources = [{"path": file.relative_to(project).as_posix(), "sha256": digest(file.read_bytes())}
               for file in sorted(project.rglob("*"))
               if file.is_file() and (file.suffix in {".cj", ".toml"} or file.name == "README.md")]
    manifest = {
        "schemaVersion": "cjdoc.reader-corpus/1", "recipe": "external-yjson-" + REVISION,
        "targetDeclarations": 2319, "sourceDeclarations": None,
        "countSemantics": "2319 native source/AST declarations at the pinned revision; public projection measured separately",
        "sourceSha256": digest(json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()),
        "sources": sources, "queries": queries(), "members": [], "overloads": [],
        "visuals": [{"qualifiedName": "yjson.YJson"}],
        "features": ["real-production-library", "unmodified-source", "source-AST-fallback", "public-projection"],
        "provenance": {
            "kind": "external-library", "repository": "https://github.com/lIlIIlIll/yjson",
            "revision": REVISION, "archiveUrl": ARCHIVE_URL, "archiveSha256": ARCHIVE_SHA256,
            "taskSource": ["README.md", "src/lib_json_direct_codec.cj"],
            "selection": "production cjdoc dependency; 2319 declarations and 1218 public/protected declarations in the STS 1.2.0 source/AST probe",
            "limitations": "Derive macros are not expanded (CJDOC1009); native partial status is retained. No std/stdx-wide or macro-generated API claim.",
            "language": "author source is unchanged; UI locale selection does not fabricate missing author translations",
        },
    }
    (destination / "reader-corpus.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return {"project": project.relative_to(destination).as_posix(), "manifest": "reader-corpus.json",
            "sourceSha256": manifest["sourceSha256"], "archiveSha256": ARCHIVE_SHA256}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--archive", type=Path, help="optional previously downloaded archive; checksum is still verified")
    args = parser.parse_args()
    print(json.dumps(prepare(args.output, args.archive), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
