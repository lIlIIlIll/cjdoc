"""Source-bound search cases for the real CLI, MCP session and published JS.

Expected identities bind only to exact qualifiedName/headerSpelling pairs in the
captured public Doc IR, never to either executor or the tested search index.
The caller supplies real CLI/MCP transports; Node evaluates the shipped kernel.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from typing import Callable


JS_RUNNER = r"""
const fs = require('node:fs');
const vm = require('node:vm');
const [scriptPath,indexPath] = process.argv.slice(1);
const source = fs.readFileSync(scriptPath,'utf8');
const marker = 'globalThis.cjdocSearch = (() => {';
const start = source.indexOf(marker);
const close = source.indexOf('})();',start);
if(start < 0 || close < 0) throw new Error('published search kernel is absent');
const sandbox = {};
sandbox.globalThis = sandbox;
vm.runInNewContext(source.slice(start,close+5),sandbox);
const index = JSON.parse(fs.readFileSync(indexPath,'utf8'));
const input = JSON.parse(fs.readFileSync(0,'utf8'));
if(input.shaVectors) {
  process.stdout.write(JSON.stringify(input.shaVectors.map(value =>
    sandbox.cjdocSearch.sha256Utf8(value))));
} else {
  process.stdout.write(JSON.stringify(input.requests.map(request =>
    sandbox.cjdocSearch.execute(index,request))));
}
"""


class SearchCaseFailure(AssertionError):
    pass


def _json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _captured_ir(snapshot: Path) -> dict:
    value = _json(snapshot)
    if value.get("schemaVersion") == "cjdoc.machine-manifest/1":
        root = snapshot.parent.parent
        target = (root / value["docIr"]["path"]).resolve()
        if not target.is_relative_to(root.resolve()):
            raise SearchCaseFailure("manifest Doc IR escapes its document root")
        payload = target.read_bytes()
        if hashlib.sha256(payload).hexdigest() != value["docIr"]["sha256"]:
            raise SearchCaseFailure("manifest Doc IR hash mismatch")
        return json.loads(payload)
    return value


def _bind_refs(document: dict, selectors: dict) -> dict[str, dict]:
    result = {}
    for name, selector in selectors.items():
        matches = [symbol for symbol in document["declarations"]
                   if symbol["qualifiedName"] == selector["qualifiedName"]
                   and symbol["headerSpelling"] == selector["signature"]]
        if len(matches) != 1:
            raise SearchCaseFailure(f"symbolRef {name} binds {len(matches)} source declarations")
        result[name] = matches[0]
    return result


def _expand(value: object, refs: dict[str, dict], scope: dict) -> object:
    if isinstance(value, dict):
        if set(value) == {"$symbolId"}:
            return refs[value["$symbolId"]]["id"]
        if set(value) == {"$scope"}:
            return scope[value["$scope"]]
        if set(value) == {"$parameterTypes"}:
            return [parameter["type"]["spelling"]
                    for parameter in refs[value["$parameterTypes"]]["parameters"]]
        return {key: _expand(item, refs, scope) for key, item in value.items()}
    if isinstance(value, list):
        return [_expand(item, refs, scope) for item in value]
    return value


def _native(response: dict) -> dict:
    state = response["completeness"]["query"]
    return {
        "status": response["status"],
        "errorCode": (response.get("error") or {}).get("code"),
        "reason": state["reason"],
        "total": state["total"], "returned": state["returned"],
        "offset": state["offset"], "complete": state["complete"],
        "hasNext": state["next"] is not None, "coverage": state["coverage"],
        "facets": response["result"]["facets"],
        "items": [{"snapshotId": item["identity"]["snapshotId"],
                   "canonicalId": item["identity"]["symbolId"] or item["identity"]["pageId"],
                   "score": item["match"]["score"], "reason": item["match"]["reason"],
                   "classification": item["classification"],
                   "exposures": sorted({entry["exposedName"] for entry in item["exposures"]},
                                       key=lambda value: value.encode("utf-8"))}
                  for item in response["result"]["items"]],
    }


def _static(response: dict, exposure_names: dict[str, str]) -> dict:
    return {key: response[key] for key in (
        "status", "errorCode", "reason", "total", "returned", "offset", "complete", "coverage"
    )} | {
        "hasNext": response["next"] is not None,
        "facets": response["facets"],
        "items": [{key: item[key] for key in ("snapshotId", "canonicalId", "score", "reason", "classification")}
                  | {"exposures": sorted({exposure_names[identity] for identity in item["matchedExposureIds"]},
                                         key=lambda value: value.encode("utf-8"))}
                  for item in response["items"]],
    }


def _expected_rows(case: dict, refs: dict[str, dict], scope: dict,
                   classifications: dict) -> list[dict]:
    rows = [{"snapshotId": scope["snapshotId"],
             "canonicalId": row["pageId"] if "pageId" in row else refs[row["ref"]]["id"],
             "score": row["score"], "reason": row["reason"], "exposures": row.get("exposures", []),
             "classification": classifications.get(row.get("ref", ""), {"group": None, "tags": []})}
            for row in case["expect"].get("items", [])]
    if case.get("order") == "canonical":
        rows.sort(key=lambda row: (-row["score"], row["snapshotId"].encode("utf-8"),
                                   row["canonicalId"].encode("utf-8"), row["reason"].encode("utf-8")))
    return rows


def _check_expected(label: str, actual: dict, expected: dict, rows: list[dict],
                    request: dict, offset: int) -> None:
    for key in ("status", "errorCode", "reason", "total", "returned", "complete", "hasNext"):
        if key in expected and actual[key] != expected[key]:
            raise SearchCaseFailure(f"{label}: {key}: {actual[key]!r} != {expected[key]!r}")
    if "facets" in expected and actual["facets"] != expected["facets"]:
        raise SearchCaseFailure(f"{label}: facets: {actual['facets']!r} != {expected['facets']!r}")
    if "items" in expected:
        wanted = rows[offset:offset + request.get("limit", 20)]
        if actual["items"] != wanted:
            raise SearchCaseFailure(f"{label}: hits: {actual['items']!r} != {wanted!r}")
        if actual["total"] != len(rows):
            raise SearchCaseFailure(f"{label}: total {actual['total']} != {len(rows)}")
    if "coverage" in expected:
        coverage = actual["coverage"]
        if coverage is None:
            raise SearchCaseFailure(f"{label}: missing retrieval coverage")
        for key, value in expected["coverage"].items():
            if coverage[key] != value:
                raise SearchCaseFailure(f"{label}: coverage.{key}: {coverage[key]!r} != {value!r}")
        limit = coverage["bodyTextLimit"]
        if limit is not None and type(limit) is not int:
            raise SearchCaseFailure(f"{label}: bodyTextLimit must be an integer or null")


class PublishedSearch:
    def __init__(self, root: Path, timeout: float):
        self.node = shutil.which("node")
        if self.node is None:
            raise SearchCaseFailure("Node.js is required for the published search contract gate")
        self.script = root / "search.js"
        self.index = root / "search-index.json"
        for path in (self.script, self.index):
            if not path.is_file():
                raise SearchCaseFailure(f"published site is missing {path.name}")
        self.timeout = timeout

    def run(self, payload: dict) -> list:
        completed = subprocess.run(
            [self.node, "-e", JS_RUNNER, str(self.script), str(self.index)],
            input=json.dumps(payload, ensure_ascii=True), text=True, capture_output=True,
            timeout=self.timeout, check=False,
        )
        if completed.returncode:
            raise SearchCaseFailure(f"published kernel failed: {completed.stderr[:1200]}")
        return json.loads(completed.stdout)

    def execute(self, request: dict) -> dict:
        return self.run({"requests": [request]})[0]

    def check_sha(self) -> None:
        vectors = ["", "abc", "a" * 55, "a" * 56, "a" * 63, "a" * 64,
                   "a" * 119, "a" * 120, "a" * 127, "a" * 128,
                   "中文😀", "a" * 54 + "😀", "\0", "x\0y\n\t"]
        actual = self.run({"shaVectors": vectors})
        expected = [hashlib.sha256(value.encode("utf-8")).hexdigest() for value in vectors]
        if actual != expected:
            raise SearchCaseFailure("published UTF-8 SHA-256 disagrees with reference vectors")


def run_search_cases(cases: Path, static_site: Path, snapshots: tuple[Path, ...],
                     cli: Callable, mcp: Callable, timeout: float) -> None:
    """Exercise independently expected cases through all three production surfaces."""
    if len(snapshots) != 1:
        raise SearchCaseFailure("one static site must be paired with exactly one captured snapshot")
    document = _captured_ir(snapshots[0])
    fixture = _json(cases)
    suite = fixture["suites"].get(document["project"]["name"])
    if suite is None:
        raise SearchCaseFailure("no source-bound search suite for the captured project")
    refs = _bind_refs(document, suite["symbolRefs"])
    published = PublishedSearch(static_site, timeout)
    index = _json(published.index)
    scope = index["scope"]
    classifications = _expand(suite.get("classifications", {}), refs, scope)
    exposure_names = {exposure["id"]: exposure["name"] for entry in index["entries"]
                      for exposure in entry["exposures"]}
    if snapshots[0].name == "manifest.json" and scope["snapshotId"] != _json(snapshots[0])["snapshotId"]:
        raise SearchCaseFailure("search and Agent producers did not share their captured snapshot")
    published.check_sha()
    executed = {"cli": 0, "mcp": 0, "static": 0}
    for case in suite["cases"]:
        case = copy.deepcopy(case)
        if case.get("incompleteStatus") and document["apiCollectionState"] != "resolved":
            case["expect"]["status"] = case["incompleteStatus"]
        request = _expand(case["request"], refs, scope)
        request.setdefault("operation", "search")
        if request["operation"] == "search":
            request.setdefault("profile", "bounded-static")
        rows = _expected_rows(case, refs, scope, classifications)
        hosts = case.get("hosts", ["cli", "mcp", "static"])
        answers = {}
        raw_answers = {}
        for host in hosts:
            if host == "cli":
                code, raw = cli(request)
                expected_code = {"invalid_request": 2, "scope_mismatch": 2,
                                 "stale_cursor": 2, "unavailable": 3,
                                 "resource_limit": 3, "budget_exceeded": 3}.get(raw["status"], 0)
                if code != expected_code:
                    raise SearchCaseFailure(f"{case['id']}: CLI exit {code} != {expected_code}")
                answer = _native(raw)
            elif host == "mcp":
                raw = mcp(request)
                answer = _native(raw)
            else:
                raw = published.execute(request)
                answer = _static(raw, exposure_names)
            _check_expected(f"{case['id']}/{host}", answer,
                            _expand(case["expect"], refs, scope), rows, request, 0)
            answers[host] = answer
            raw_answers[host] = raw
            executed[host] += 1
        if len(answers) > 1 and any(answer != next(iter(answers.values())) for answer in answers.values()):
            raise SearchCaseFailure(f"{case['id']}: production surfaces disagree: {answers!r}")
        if case.get("followAll"):
            collected = {host: answer["items"][:] for host, answer in answers.items()}
            for host in hosts:
                raw = raw_answers[host]
                offset = len(collected[host])
                while (raw["next"] if host == "static" else raw["completeness"]["query"]["next"]) is not None:
                    token = raw["next"] if host == "static" else raw["completeness"]["query"]["next"]
                    continuation = copy.deepcopy(request)
                    continuation.update(_expand(case.get("continueWith", {}), refs, scope))
                    continuation["cursor"] = token
                    if host == "static":
                        raw = published.execute(continuation)
                        answer = _static(raw, exposure_names)
                    elif host == "cli":
                        _, raw = cli(continuation)
                        answer = _native(raw)
                    else:
                        raw = mcp(continuation)
                        answer = _native(raw)
                    expected = {key: value for key, value in case["expect"].items()
                                if key not in {"returned", "hasNext", "complete"}}
                    _check_expected(f"{case['id']}/{host}/page@{offset}", answer,
                                    expected, rows, request, offset)
                    if not answer["items"] or answer["offset"] != offset:
                        raise SearchCaseFailure(f"{case['id']}/{host}: cursor failed to advance")
                    collected[host].extend(answer["items"])
                    offset += len(answer["items"])
                    executed[host] += 1
                if collected[host] != rows:
                    raise SearchCaseFailure(f"{case['id']}/{host}: paged results duplicated or omitted identities")
            if collected and any(value != rows for value in collected.values()):
                raise SearchCaseFailure(f"{case['id']}: complete page walks differ")
        if case.get("cursorErrors"):
            def next_of(host: str) -> str:
                raw = raw_answers[host]
                return raw["next"] if host == "static" else raw["completeness"]["query"]["next"]

            for host in hosts:
                token = next_of(host)
                pieces = token.split(":")
                if (len(pieces) != 4 or pieces[0] != "cjdoc.cursor/2"
                        or pieces[2] != request["profile"] or not pieces[1].isdigit()
                        or len(pieces[3]) != 64 or any(char not in "0123456789abcdef" for char in pieces[3])):
                    raise SearchCaseFailure(f"{case['id']}/{host}: incorrect cursor/2 syntax")
                tampered_digest = ("0" if pieces[3][0] != "0" else "1") + pieces[3][1:]
                variants = [
                    ("malformed", {"cursor": "not-a-cursor"}, "cursor_format", []),
                    ("malformed-offset", {"cursor": ":".join([pieces[0], "x", *pieces[2:]])}, "cursor_format", []),
                    ("malformed-digest", {"cursor": ":".join([*pieces[:3], "x"])}, "cursor_format", []),
                    ("wrong-binding", {"cursor": ":".join([*pieces[:3], tampered_digest])}, "cursor_binding", []),
                    ("past-end", {"cursor": ":".join([pieces[0], str(answers[host]["total"] + 1), *pieces[2:]])},
                     "cursor_out_of_range", []),
                    ("changed-query", {"cursor": token, "query": "a-different-query"}, "cursor_binding", []),
                    ("changed-limit", {"cursor": token, "limit": 2 if request.get("limit") != 2 else 3},
                     "cursor_binding", []),
                ]
                for field in case.get("cursorRemovedFields", []):
                    variants.append(("removed-" + field, {"cursor": token}, "cursor_binding", [field]))
                other = "cli" if host == "static" else "static"
                if other in raw_answers:
                    variants.append(("cross-host", {"cursor": next_of(other)}, "cursor_binding", []))
                for variant, changes, error_code, removed in variants:
                    changed = {**request, **changes}
                    for field in removed:
                        changed.pop(field)
                    if host == "static":
                        answer = _static(published.execute(changed), exposure_names)
                    elif host == "cli":
                        code, raw = cli(changed)
                        if code != 2:
                            raise SearchCaseFailure(f"{case['id']}/{variant}: CLI must reject stale cursor")
                        answer = _native(raw)
                    else:
                        answer = _native(mcp(changed))
                    expected = {"status": "stale_cursor", "errorCode": error_code,
                                "coverage": case["expect"]["coverage"]}
                    _check_expected(f"{case['id']}/{host}/{variant}", answer, expected, rows, changed, 0)
                    executed[host] += 1
    print("source-bound search semantics passed: " + ", ".join(
        f"{count} {host} responses" for host, count in executed.items()))
