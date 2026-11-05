#!/usr/bin/env python3
"""Exercise caller-pinned source provenance through capture and offline readers."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from test_admonitions import query_cli


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/projects/source_provenance"
EXPECTED_REVISION = "1111111111111111111111111111111111111111"
EXPECTED_SOURCE_DIGEST = "83d4a986bde0be31775c0510a602ec849ea129338bf581f0000a3ee7388251f3"
EXPECTED_URL = (
    "https://github.com/example/source-provenance-fixture/blob/"
    f"{EXPECTED_REVISION}/src/api.cj"
)


def run(binary: Path, *arguments: object) -> str:
    result = subprocess.run(
        [str(binary), *map(str, arguments)], text=True,
        capture_output=True, check=False, timeout=180,
    )
    assert result.returncode == 0, (
        f"{arguments[0]} failed ({result.returncode}): {result.stderr}"
    )
    return result.stdout


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def find_declaration(document: dict, name: str) -> dict:
    found = [symbol for symbol in document["declarations"] if symbol.get("name") == name]
    assert len(found) == 1, f"expected exactly one declaration named {name}"
    return found[0]


def find_agent_declaration(site: Path, name: str) -> dict:
    found = []
    for path in (site / "html/agent/symbols").glob("*.json"):
        value = read_json(path)
        if value.get("schemaVersion") == "cjdoc.declaration/3" and \
                value.get("symbol", {}).get("name") == name:
            found.append(value)
    assert len(found) == 1, "Agent declaration/3 source view is missing"
    return found[0]


def write_record_limit_receipt(project: Path, name: str, count: int) -> str:
    source = (project / f"src/{name}/api.cj").read_bytes()
    records = [{
        "path": f"{name}/api.cj",
        "sha256": hashlib.sha256(source).hexdigest(),
    }]
    records.extend({"path": f"unused/{index}.cj", "sha256": "0" * 64}
                   for index in range(count - 1))
    receipt = json.dumps({
        "schemaVersion": "cjdoc.source-provenance/1",
        "repository": {"url": "https://github.com/example/receipt-record-limits",
                       "revision": EXPECTED_REVISION},
        "files": records,
    }, separators=(",", ":")).encode()
    (project / f"evidence/{name}.json").write_bytes(receipt)
    return hashlib.sha256(receipt).hexdigest()


def exercise_receipt_record_limits(binary: Path, output: Path) -> None:
    project = output / "record-limits-project"
    (project / "evidence").mkdir(parents=True)
    (project / "cjpm.toml").write_text('[package]\nname = "receipt_record_limits"\n')
    for name in ("first", "second", "unrelated"):
        source = project / f"src/{name}/api.cj"
        source.parent.mkdir(parents=True)
        source.write_text(f"package receipt_record_limits\npublic func {name}Api(): Unit {{}}\n")
    first_pin = write_record_limit_receipt(project, "first", 60000)
    for second_count in (40000, 40001):
        second_pin = write_record_limit_receipt(project, "second", second_count)
        configuration = ""
        # A canonical-root alias must not consume the pinned receipt twice.
        for root, name, pin in (("src/first", "first", first_pin),
                                ("./src/first", "first", first_pin),
                                ("src/second", "second", second_pin)):
            configuration += (
                f'[[source.repositories]]\nroot = "{root}"\n'
                f'url = "https://github.com/example/receipt-record-limits"\n'
                f'revision = "{EXPECTED_REVISION}"\nrepository-path = "{name}"\n'
                f'receipt = "evidence/{name}.json"\nreceipt-sha256 = "{pin}"\n'
            )
        (project / "cjdoc.toml").write_text(configuration)
        result = subprocess.run(
            [str(binary), "generate", "--project", str(project), "--format", "json",
             "--stdout", "--no-cache", "--lint-profile", "off"],
            capture_output=True, check=False, timeout=180,
        )
        limited = second_count == 40001
        assert result.returncode == int(limited), result.stderr.decode(errors="replace")
        snapshot = output / f"record-limits-{second_count}.json"
        snapshot.write_bytes(result.stdout)
        document = json.loads(result.stdout)
        assert sorted(row["name"] for row in document["declarations"]) == [
            "firstApi", "secondApi", "unrelatedApi",
        ], "receipt rejection must not truncate source API collection"
        errors = [row["code"] for row in document["diagnostics"] if row["severity"] == "error"]
        assert errors == (["CJDOC1028"] if limited else [])
        origins = {row["path"]: row["provenance"] for row in document["files"]}
        assert origins["src/first/api.cj"]["state"] == "verified"
        assert origins["src/unrelated/api.cj"]["reason"] == "no_registration"
        origin = origins["src/second/api.cj"]
        assert origin["state"] == ("unavailable" if limited else "verified")
        assert origin["reason"] == ("resource_limit" if limited else "receipt_matched")
        symbol = find_declaration(document, "secondApi")
        queried = query_cli(binary, snapshot, {
            "operation": "get_symbol", "symbolId": symbol["id"], "sections": ["source"],
        })
        source = queried["result"]["items"][0]["source"]
        assert source["state"] == origin["state"] and source["reason"] == origin["reason"]
        expected_url = None if limited else (
            "https://github.com/example/receipt-record-limits/blob/"
            f"{EXPECTED_REVISION}/second/api.cj#L2"
        )
        assert source["url"] == expected_url


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("captured", "replay", "mismatch", "mismatch-project", "source-free-project",
                 "record-limits-project"):
        assert not (output / name).exists(), f"output child already exists: {name}"

    captured = output / "captured"
    run(binary, "generate", "--project", FIXTURE, "--format", "json", "--format", "html",
        "--format", "markdown", "--agent-full", "--output", captured, "--no-cache")
    document = read_json(captured / "docs.json")
    assert document.get("schemaVersion") == "cjdoc.doc-ir/18"
    assert all("repositoryPath" not in module for module in document["modules"])
    declaration = find_declaration(document, "inspectSnapshot")
    file_doc = next(file for file in document["files"] if file["path"] == "src/api.cj")
    provenance = file_doc["provenance"]
    assert provenance["state"] == "verified" and provenance["reason"] == "receipt_matched"
    assert provenance["repositoryPath"] == "src/api.cj"
    assert provenance["sourceDigest"] == f"sha256:{EXPECTED_SOURCE_DIGEST}"
    assert provenance["normalizedDigest"] == provenance["sourceDigest"]
    assert provenance["evidenceKind"] == "caller_pinned_receipt"
    assert provenance["evidenceIdentity"].startswith("sha256:")

    symbol_id = declaration["id"]
    agent = find_agent_declaration(captured, "inspectSnapshot")
    source = agent["source"]
    assert source["state"] == "verified" and source["reason"] == "receipt_matched"
    assert source["url"] == EXPECTED_URL + "#L4"
    assert source["range"] == declaration["source"]
    assert source["repository"] == provenance["repository"]
    assert source["recordedRevision"] == EXPECTED_REVISION
    assert source["revisionKind"] == "exact"
    assert source["sourceDigest"] == provenance["sourceDigest"]
    assert source["normalizedDigest"] == provenance["normalizedDigest"]
    assert source["evidenceIdentity"] == provenance["evidenceIdentity"]
    assert source["evidenceKind"] == "caller_pinned_receipt"

    symbol_html = (captured / "html" / agent["representations"]["html"]).read_text(encoding="utf-8")
    assert f'href="{EXPECTED_URL}#L4"' in symbol_html
    package_markdown = list((captured / "markdown/packages").glob("*.md"))
    assert len(package_markdown) == 1, "expected the fixture's one published package"
    markdown_route = package_markdown[0].relative_to(captured / "markdown")
    symbol_markdown = (captured / "markdown" / markdown_route).read_text(encoding="utf-8")
    assert f"{EXPECTED_URL}#L4" in symbol_markdown
    assert "verified/receipt_matched" in symbol_markdown

    query = query_cli(binary, captured / "docs.json", {
        "operation": "get_symbol", "symbolId": symbol_id, "sections": ["source"],
        "maxBytes": 65536,
    })
    assert query.get("schemaVersion") == "cjdoc.query-result/4"
    query_source = query["result"]["items"][0]["source"]
    assert query_source == source, "Agent and query source evidence disagree"
    report = next(item for item in query["sources"] if item["kind"] == "source")
    assert report["state"] == "verified" and report["url"] == source["url"]

    # A frozen snapshot is sufficient: replay after deleting its original inputs.
    source_free_project = output / "source-free-project"
    shutil.copytree(FIXTURE, source_free_project)
    source_free_capture = output / "source-free-capture"
    assert not source_free_capture.exists()
    run(binary, "generate", "--project", source_free_project, "--format", "json",
        "--format", "html", "--format", "markdown", "--agent-full",
        "--output", source_free_capture, "--no-cache")
    shutil.rmtree(source_free_project / "src")
    (source_free_project / "evidence/source.json").unlink()
    replay = output / "replay"
    run(binary, "render", "--input", source_free_capture / "docs.json", "--format", "json",
        "--format", "html", "--format", "markdown", "--agent-full", "--output", replay)
    replay_agent = find_agent_declaration(replay, "inspectSnapshot")
    assert replay_agent["source"] == source
    replay_markdown = (replay / "markdown" / markdown_route).read_text(encoding="utf-8")
    assert f"{EXPECTED_URL}#L4" in replay_markdown
    replay_query = query_cli(binary, replay / "docs.json", {
        "operation": "get_symbol", "symbolId": symbol_id, "sections": ["source"],
        "maxBytes": 65536,
    })
    assert replay_query["result"]["items"][0]["source"] == source

    # A same-capture byte mismatch invalidates only that file's evidence and link.
    mismatch_project = output / "mismatch-project"
    shutil.copytree(FIXTURE, mismatch_project)
    source_path = mismatch_project / "src/api.cj"
    source_path.write_bytes(source_path.read_bytes() + b"\n// changed after receipt pin\n")
    mismatch = output / "mismatch"
    run(binary, "generate", "--project", mismatch_project, "--format", "json",
        "--format", "html", "--format", "markdown", "--agent-full",
        "--output", mismatch, "--no-cache")
    mismatch_doc = read_json(mismatch / "docs.json")
    mismatch_file = next(file for file in mismatch_doc["files"] if file["path"] == "src/api.cj")
    assert mismatch_file["provenance"]["state"] == "unavailable"
    assert mismatch_file["provenance"]["reason"] == "digest_mismatch"
    mismatch_agent = find_agent_declaration(mismatch, "inspectSnapshot")
    assert mismatch_agent["source"]["url"] is None
    assert mismatch_agent["source"]["state"] == "unavailable"
    assert mismatch_agent["source"]["reason"] == "digest_mismatch"
    mismatch_html = (mismatch / "html" / mismatch_agent["representations"]["html"]).read_text(encoding="utf-8")
    assert EXPECTED_URL not in mismatch_html
    mismatch_markdown = (mismatch / "markdown" / markdown_route).read_text(encoding="utf-8")
    assert EXPECTED_URL not in mismatch_markdown
    assert "unavailable/digest_mismatch" in mismatch_markdown
    exercise_receipt_record_limits(binary, output)
    print("PASS: pinned source capture, source-free replay, and digest-mismatch link denial")


if __name__ == "__main__":
    main()
