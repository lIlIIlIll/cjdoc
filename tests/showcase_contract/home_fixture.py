"""Synthetic full-shape home-site fixture shared by the sharding contract tests.

Builds a resolved manifest with a complete transport x viewport matrix plus real
structurally valid PNG placeholders. It proves sharding/merge control flow; it is
explicitly not real-browser or native cjdoc evidence.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import zlib

from showcase_contract.contract import PLAN_SCHEMA
from showcase_contract.site import canonical_json

REVISION = "a" * 40
TRANSPORTS = {"root": ("http", "/"), "subpath": ("http", "/cjdoc-preview/"),
              "offline": ("file", None)}
VIEWPORTS = {"desktop": (1440, 1000), "narrow": (960, 900), "mobile": (390, 844)}
# Only navigation-shaped journeys are used: members/contracts/resources would
# additionally require an inline member placement.
JOURNEYS = ("search", "types")
PAGE = "demo/types/generated-route.html"
PROJECT = {"name": "synthetic_home", "audience": "external", "version": "demo-v2"}


def png_bytes(width: int, height: int) -> bytes:
    """A tiny but structurally valid PNG carrying the requested IHDR dimensions."""
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = (b"\x00" + b"\x00" * (width * 3)) * height
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def scenario_ids(journey: str) -> list[tuple[str, str]]:
    return [(f"{journey}-{transport}-{viewport}", TRANSPORTS[transport][0])
            for transport in TRANSPORTS for viewport in VIEWPORTS]


def author_features() -> list[dict]:
    features = []
    for journey in JOURNEYS:
        target = {
            "id": f"{journey}-en-v2", "kind": "navigation", "locale": "en", "version": "demo-v2",
            "instructions": "Synthetic sharding fixture",
            "index": "demo/navigation-index.json", "project": dict(PROJECT),
            "match": {"kind": "symbol", "title": "Bag.add", "packageName": "demo.collections"},
            "scenarios": [{"id": name, "mode": mode} for name, mode in scenario_ids(journey)],
        }
        features.append({
            "id": journey, "title": f"Synthetic {journey}", "implementation": "partial",
            "demonstration": "available", "reason": "Synthetic data proves no cjdoc behavior.",
            "trackingIssues": [50], "inputs": ["examples/home.cj"], "targets": [target],
        })
    return features


def build_home_manifest(revision: str = REVISION) -> dict:
    """A manifest whose planSha256 matches what validate_manifest re-derives."""
    features = []
    normalized = []
    for feature in author_features():
        targets = [{**target, "resolved": {"href": PAGE + "#add", "symbolId": "symbol:x",
                                           "pageId": "page:x", "semanticState": "partial"}}
                   for target in feature["targets"]]
        features.append({**feature, "inputs": [{"path": feature["inputs"][0], "sha256": "b" * 64}],
                         "targets": targets})
        normalized.append({**feature, "inputs": sorted(feature["inputs"])})
    plan_sha256 = hashlib.sha256(canonical_json(
        {**{"schemaVersion": PLAN_SCHEMA}, "features": normalized})).hexdigest()
    return {"schemaVersion": "cjdoc.showcase-features/1", "revision": revision,
            "planSha256": plan_sha256, "features": features}


def build_build_manifest() -> dict:
    return {"tools": {"cjdocSha256": "d" * 64}, "sourceDownload": {"sha256": "e" * 64}}


class HomeFixture:
    """A synthetic resolved site plus the real generated-site side files."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.site = root / "site"
        (self.site / "downloads").mkdir(parents=True)
        (self.site / "demo").mkdir(parents=True)
        (self.site / PAGE).parent.mkdir(parents=True, exist_ok=True)
        (self.site / "index.html").write_text(
            '<html lang="en"><body id="home">Home</body></html>', encoding="utf-8")
        (self.site / PAGE).write_text(
            '<html lang="en"><body><h1 id="add">Synthetic member</h1></body></html>',
            encoding="utf-8")
        (self.site / "downloads/showcase-offline.zip").write_bytes(b"PK\x05\x06" + b"\x00" * 18)
        index = {"schemaVersion": "cjdoc.navigation-index/1", "project": dict(PROJECT),
                 "pages": [{"id": "page:x", "kind": "symbol", "title": "Bag.add",
                            "href": "types/generated-route.html#add", "symbolId": "symbol:x",
                            "semanticState": "partial"}]}
        (self.site / "demo/navigation-index.json").write_text(json.dumps(index), encoding="utf-8")
        self.manifest = build_home_manifest()
        self.write_json("showcase-features.json", self.manifest)
        self.write_json("build.json", build_build_manifest())

    def write_json(self, name: str, value: object) -> None:
        (self.site / name).write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def site_digest(self) -> str:
        from showcase_contract.site import Site

        return Site(self.site).digest()
