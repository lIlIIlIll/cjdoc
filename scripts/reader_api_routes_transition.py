"""Qualify the readable API address change without rewriting old evidence.

Reader Scale compares a pinned baseline site with a candidate site whose
published declaration bodies moved from opaque ``symbols/symbol-<slug>.html``
files to readable ``<package>/<owners>/<name>/index.html`` directories. This
module is the one explicit, opt-in exception for that address change:

* both sides must be genuine publisher products -- verified search receipts, a
  schema-bound ``machine-manifest``/reading-projection pair and a machine symbol
  inventory whose digest matches its manifest row;
* the two inventories must be a bijection by the stable local ``SymbolId``:
  identical visible identity sets, one address per identity, no duplicate and
  no unproven address;
* Normalize only reader hrefs. Frozen navigation evidence, query strings,
  fragments and external URLs must remain exact. The expected after ARIA
  snapshot is the approved pre-route tree at its historical file address.

Nothing here rewrites stored evidence. Registration happens before the after
capture and returns a digest-bound registration of the baseline product
identity, the baseline address table and the complete ARIA pair.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import posixpath
import re
import sys
from urllib.parse import unquote, urlsplit

sys.dont_write_bytecode = True
try:
    from .reader_search_identity import MANIFEST_PAIRS, verify_search_identity
    from .strict_json import strict_dumps, strict_load, strict_loads
    from .test_agent_artifacts import check_schema, document
except ImportError:
    from reader_search_identity import MANIFEST_PAIRS, verify_search_identity
    from strict_json import strict_dumps, strict_load, strict_loads
    from test_agent_artifacts import check_schema, document

SCHEMA = "cjdoc.reader-api-routes-transition/1"
REPO = Path(__file__).resolve().parent.parent
PROFILE_FIELDS = {"schemaVersion", "recipe", "sourceSha256", "taskManifestSha256",
                  "routeObserver", "page", "locales"}
PAGE_FIELDS = {"qualifiedName", "kind"}
SNAPSHOT_FIELDS = {"snapshot", "sha256"}
REGISTRATION_FIELDS = {"schemaVersion", "profile", "sha256", "fileSha256", "snapshots", "baseline"}
BASELINE_FIELDS = {"pair", "snapshotId", "projectionId", "docIrSha256", "symbolIndexSha256",
                   "routeFingerprint", "symbols", "pageSymbolId", "pageHref", "linkTargets"}
URL_LINE = re.compile(r"^(?P<lead>\s*- /url: )(?P<value>.*)$")
SYMBOL_TOKEN = "<cjdoc-api-symbol:{}>"
SHA = re.compile(r"^[0-9a-f]{64}$")
ROUTE_OBSERVER = "reader-scale-tasks.mjs"

def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError("registered API route transition: " + message)


def _digest(value: str | bytes) -> str:
    encoded = value.encode("utf-8") if isinstance(value, str) else value
    return hashlib.sha256(encoded).hexdigest()


def _profile_digest(profile: dict) -> str:
    return _digest(json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def _check_corpus(profile: dict, observation: dict) -> None:
    for name in ("recipe", "sourceSha256", "taskManifestSha256"):
        _require(profile[name] == observation[name], "different corpus or task selection: " + name)


def _validate_profile(profile: dict) -> None:
    _require(set(profile) == PROFILE_FIELDS and profile["schemaVersion"] == SCHEMA,
             "unsupported or incomplete profile")
    _require(isinstance(profile["recipe"], str) and bool(profile["recipe"]), "missing corpus recipe")
    for name in ("sourceSha256", "taskManifestSha256"):
        _require(isinstance(profile[name], str) and SHA.fullmatch(profile[name]) is not None,
                 "invalid corpus digest: " + name)
    observer = profile["routeObserver"]
    _require(isinstance(observer, dict) and set(observer) == {"baseline", "after"} and
             all(isinstance(value, str) and SHA.fullmatch(value) for value in observer.values()),
             "expected current and historical route observer fingerprints")
    page = profile["page"]
    _require(isinstance(page, dict) and set(page) == PAGE_FIELDS, "unexpected captured-page record")
    _require(isinstance(page["qualifiedName"], str) and bool(page["qualifiedName"]),
             "the captured-page declaration is missing")
    _require(page["kind"] is None or (isinstance(page["kind"], str) and bool(page["kind"])),
             "the captured-page declaration kind is not text or null")
    _require(set(profile["locales"]) == {"en", "zh-CN"}, "complete bilingual snapshots are required")
    for observations in profile["locales"].values():
        _require(set(observations) == {"baseline", "after"}, "both full snapshots are required")
        for record in observations.values():
            _require(isinstance(record, dict) and set(record) == SNAPSHOT_FIELDS,
                     "unexpected snapshot record")
            _require(isinstance(record["snapshot"], str) and bool(record["snapshot"]),
                     "snapshot path is missing")
            _require(isinstance(record["sha256"], str) and SHA.fullmatch(record["sha256"]) is not None,
                     "invalid snapshot digest")


def check_route_observer(profile: dict, before: dict, after: dict) -> None:
    """Permit only the predeclared address check change, never different metrics."""
    fingerprints = profile["routeObserver"]
    _require(before.get(ROUTE_OBSERVER) in fingerprints.values() and
             after.get(ROUTE_OBSERVER) == fingerprints["after"],
             "unexpected route observer fingerprint")
    _require({name: value for name, value in before.items() if name != ROUTE_OBSERVER} ==
             {name: value for name, value in after.items() if name != ROUTE_OBSERVER},
             "other browser instrumentation changed")


def _check_address(href: object, label: str) -> str:
    """Accept only a portable published relative file path."""
    _require(isinstance(href, str) and bool(href), label + " address is empty")
    _require(not href.startswith("/") and "\\" not in href and re.match(r"^[A-Za-z]:", href) is None,
             label + " address is absolute: " + href)
    _require(all(part not in ("", ".", "..") for part in href.split("/")),
             label + " address is not a portable relative file: " + href)
    return href


def route_table(inventory: dict, schema: dict | None = None) -> dict:
    """Index one verified machine inventory as a stable-id <-> address bijection."""
    if schema is not None:
        check_schema(inventory, schema, "symbol-index.json")
    _require(isinstance(inventory, dict) and inventory.get("schemaVersion") == "cjdoc.symbol-index/2",
             "unsupported machine symbol inventory")
    entries = inventory.get("entries")
    _require(isinstance(entries, list) and bool(entries),
             "the machine symbol inventory publishes no declaration")
    by_id: dict[str, str] = {}
    by_href: dict[str, str] = {}
    qualified: dict[str, str] = {}
    kinds: dict[str, str] = {}
    for entry in entries:
        symbol = entry.get("id")
        _require(isinstance(symbol, str) and bool(symbol), "an inventory symbol identity is missing")
        _require(symbol not in by_id, "duplicate inventory symbol identity: " + symbol)
        href = _check_address(entry.get("href"), "inventory")
        _require(href not in by_href, "two declarations share one published address: " + href)
        _require(isinstance(entry.get("qualifiedName"), str) and bool(entry["qualifiedName"]),
                 "an inventory declaration has no qualified name: " + symbol)
        _require(isinstance(entry.get("kind"), str) and bool(entry["kind"]),
                 "an inventory declaration has no kind: " + symbol)
        by_id[symbol] = href
        by_href[href] = symbol
        qualified[symbol] = entry["qualifiedName"]
        kinds[symbol] = entry["kind"]
    return {"ids": sorted(by_id), "hrefById": by_id, "idByHref": by_href,
            "qualifiedNames": qualified, "kinds": kinds}


def route_table_from_index(index: dict) -> dict:
    """Derive the same bijection from a receipt-verified search projection.

    The search index is the published declaration surface; when a package does
    not also ship the machine inventory, its own verified rows are the evidence.
    """
    entries = index.get("entries")
    _require(isinstance(entries, list) and bool(entries),
             "the search projection publishes no declaration")
    by_id: dict[str, str] = {}
    by_href: dict[str, str] = {}
    qualified: dict[str, str] = {}
    kinds: dict[str, str] = {}
    for entry in entries:
        if entry.get("concept") is True:
            continue
        symbol = entry.get("id")
        _require(isinstance(symbol, str) and bool(symbol), "an indexed symbol identity is missing")
        _require(symbol not in by_id, "duplicate indexed symbol identity: " + symbol)
        href = _check_address(entry.get("href"), "indexed")
        _require(href not in by_href, "two indexed declarations share one published address: " + href)
        qualified[symbol] = entry["qualifiedName"]
        kinds[symbol] = entry["kind"]
        by_id[symbol] = href
        by_href[href] = symbol
    _require(bool(by_id), "the search projection publishes no declaration address")
    return {"ids": sorted(by_id), "hrefById": by_id, "idByHref": by_href,
            "qualifiedNames": qualified, "kinds": kinds}


def published_route_table(proof: dict, schema: dict | None = None) -> dict:
    """Cross-check the receipt-verified inventory with the search projection."""
    _require(proof.get("inventory") is not None, "a machine symbol inventory is required")
    indexed = route_table_from_index(proof["index"])
    from_inventory = route_table(proof["inventory"], schema)
    _require(from_inventory["ids"] == indexed["ids"],
             "the machine inventory and search projection publish different declarations")
    for symbol in from_inventory["ids"]:
        _require(from_inventory["hrefById"][symbol] == indexed["hrefById"][symbol],
                 "the machine inventory and search projection disagree on an address: " + symbol)
    return from_inventory


def _table_from_symbols(rows: list[dict]) -> dict:
    by_id: dict[str, str] = {}
    by_href: dict[str, str] = {}
    for row in rows:
        symbol = row.get("id") if isinstance(row, dict) else None
        _require(isinstance(symbol, str) and bool(symbol), "a registered symbol identity is invalid")
        _require(symbol not in by_id, "duplicate registered symbol identity: " + symbol)
        href = _check_address(row.get("href"), "registered")
        _require(href not in by_href, "two registered declarations share one address: " + href)
        by_id[symbol] = href
        by_href[href] = symbol
    return {"ids": sorted(by_id), "hrefById": by_id, "idByHref": by_href}


def address_fingerprint(table: dict) -> str:
    """Digest the ordered identity/address pairs without depending on storage order."""
    rows = [{"id": symbol, "href": table["hrefById"][symbol]} for symbol in table["ids"]]
    return _digest(strict_dumps(rows, ensure_ascii=False, separators=(",", ":"), sort_keys=True))


def _page_symbol(table: dict, page: dict) -> str:
    matches = [symbol for symbol in table["ids"]
               if table["qualifiedNames"].get(symbol) == page["qualifiedName"]
               and (page["kind"] is None or table["kinds"].get(symbol) == page["kind"])]
    _require(len(matches) == 1,
             "the registered page declaration is not unique in the machine inventory: " +
             page["qualifiedName"])
    return matches[0]


def _decode_path(path: str) -> str:
    segments = []
    for segment in path.split("/"):
        decoded = unquote(segment)
        _require("/" not in decoded and "\\" not in decoded,
                 "a published address encodes a path separator: " + path)
        segments.append(decoded)
    return "/".join(segments)


def _resolve(page_dir: str, path: str) -> str:
    resolved = posixpath.normpath(posixpath.join(page_dir, path) if page_dir else path)
    _require(resolved != ".." and not resolved.startswith("../"),
             "a published address escapes the publication root: " + path)
    return "" if resolved == "." else resolved


def _lookup_address(table: dict, page_dir: str, path: str) -> str | None:
    """Resolve a published link to a machine inventory row, or None when unrelated."""
    resolved = _resolve(page_dir, path)
    candidates = [resolved]
    if path.endswith("/"):
        candidates.append(resolved.rstrip("/") + "/index.html")
    for candidate in candidates:
        symbol = table["idByHref"].get(candidate.lstrip("/"))
        if symbol is not None:
            return symbol
    return None


def _url_token(value: str, table: dict, page_dir: str, page_symbol: str | None = None) -> str:
    """Map one address to a stable token; unrelated addresses keep their exact spelling."""
    _require(isinstance(value, str), "a published link is not text")
    if value == "":
        return "literal:"
    if value.startswith("#"):
        # A fragment and a full current-page address name the same section,
        # but cite its independently bound page identity, never just its anchor.
        destination = SYMBOL_TOKEN.format(page_symbol) if page_symbol is not None else "self:"
        return destination + value
    parts = urlsplit(value)
    if parts.scheme or parts.netloc or parts.path.startswith("/"):
        return "literal:" + value
    encoded_path = re.split("[?#]", value, maxsplit=1)[0]
    suffix = value[len(encoded_path):]
    if not parts.path:
        return "self:" + suffix
    decoded = _decode_path(parts.path)
    symbol = _lookup_address(table, page_dir, decoded)
    if symbol is not None:
        return SYMBOL_TOKEN.format(symbol) + suffix
    return "site:" + _resolve(page_dir, decoded) + suffix


def _address_token(href: str, table: dict) -> str:
    """Map a stored inventory/search address to its symbol identity, or keep it literal."""
    symbol = table["idByHref"].get(href)
    if symbol is None:
        symbol = table["idByHref"].get(_decode_path(href))
    return SYMBOL_TOKEN.format(symbol) if symbol is not None else "literal:" + href


def link_targets(tree: str, table: dict, page_href: str) -> list[str]:
    """Extract the ordered ARIA link targets, proving only known declaration addresses."""
    page_dir = posixpath.dirname(page_href)
    page_symbol = table["idByHref"].get(page_href)
    targets = []
    for line in tree.split("\n"):
        match = URL_LINE.fullmatch(line)
        if match is not None:
            targets.append(_url_token(match.group("value"), table, page_dir, page_symbol))
    return targets


def _snapshot_bytes(snapshot_root: Path, record: dict, locale: str, label: str) -> bytes:
    encoded = document(snapshot_root, record["snapshot"]).read_bytes()
    _require(hashlib.sha256(encoded).hexdigest() == record["sha256"],
             "full snapshot file digest differs: " + locale + "/" + label)
    return encoded


def _check_search_addresses(index: dict, table: dict, locale: str) -> None:
    """Every indexed declaration must address its own machine inventory row."""
    for entry in index["entries"]:
        if entry.get("concept") is True:
            continue
        symbol = entry.get("id")
        _require(symbol in table["hrefById"],
                 "an indexed declaration has no machine inventory identity: " + str(symbol))
        _require(entry["href"] == table["hrefById"][symbol],
                 "an indexed declaration address differs from its inventory row: " + symbol)
        for binding in entry.get("bindings", []):
            target = binding.get("targetSymbolId")
            href = binding.get("href")
            if isinstance(target, str) and target in table["hrefById"] and isinstance(href, str) and href:
                _require(href == table["hrefById"][target],
                         "a resolved local binding address differs from its inventory row: " + target)


def register_api_route_transition(profile_file: Path, baseline: Path, native: dict,
                                  sites: dict[str, Path], schema_dir: Path | None = None,
                                  snapshot_root: Path | None = None) -> dict:
    """Freeze baseline publisher identity, addresses and the expected ARIA pair."""
    schema_dir = schema_dir or REPO / "docs/schema"
    snapshot_root = snapshot_root or REPO
    profile_bytes = profile_file.read_bytes()
    profile = strict_loads(profile_bytes, description="API route transition profile")
    _validate_profile(profile)
    _check_corpus(profile, native)
    _require({row["locale"] for row in native["locales"]} == set(profile["locales"]),
             "baseline locale set differs from the profile")
    _require(set(sites) == set(profile["locales"]),
             "actual baseline publisher sites are missing for a registered locale")
    schema = strict_load(schema_dir / "symbol-index.schema.json")
    snapshots: dict[str, dict[str, str]] = {}
    frozen: dict[str, dict] = {}
    for locale, observations in profile["locales"].items():
        snapshots[locale] = {}
        for label, record in observations.items():
            snapshots[locale][label] = _snapshot_bytes(snapshot_root, record, locale, label).decode("utf-8")
        record = next(row for row in native["locales"] if row["locale"] == locale)
        browser = strict_load(document(baseline, record["browserReport"]),
                              description="baseline browser observation")
        _check_corpus(profile, browser)
        _require(browser["harness"].get(ROUTE_OBSERVER) in profile["routeObserver"].values(),
                 "unregistered baseline route observer")
        _require(browser["environment"]["requestedUiLocale"] == locale, "baseline browser locale differs")
        _require(browser["accessibility"].get("status") != "not-applicable",
                 "an actual no-JS accessible-tree observation is required")
        _require(browser["accessibility"]["noScript"]["accessibleTree"] == snapshots[locale]["baseline"],
                 "baseline accessible tree is not the registered complete snapshot")
        proof = verify_search_identity(sites[locale], browser["resources"], schema_dir)
        _require(proof["manifestPair"][1] == "cjdoc.read/1", "expected legacy reading projection")
        table = published_route_table(proof, schema)
        _check_search_addresses(proof["index"], table, locale)
        page_symbol = _page_symbol(table, profile["page"])
        page_href = table["hrefById"][page_symbol]
        frozen[locale] = {
            "pair": list(proof["manifestPair"]),
            "snapshotId": proof["snapshotId"],
            "projectionId": proof["projectionId"],
            "docIrSha256": proof["docIrSha256"],
            # The independently verified inventory is required for this transition.
            "symbolIndexSha256": proof["symbolIndexSha256"],
            "routeFingerprint": address_fingerprint(table),
            "symbols": [{"id": symbol, "href": table["hrefById"][symbol]} for symbol in table["ids"]],
            "pageSymbolId": page_symbol,
            "pageHref": page_href,
            "linkTargets": link_targets(snapshots[locale]["baseline"], table, page_href),
        }
    return {"schemaVersion": SCHEMA, "profile": profile, "sha256": _profile_digest(profile),
            "fileSha256": hashlib.sha256(profile_bytes).hexdigest(),
            "snapshots": snapshots, "baseline": frozen}


def validate_api_route_registration(registration: dict) -> dict:
    _require(isinstance(registration, dict) and set(registration) == REGISTRATION_FIELDS,
             "unexpected registration fields")
    _require(registration.get("schemaVersion") == SCHEMA, "unsupported transition registration")
    profile = registration["profile"]
    _validate_profile(profile)
    _require(_profile_digest(profile) == registration["sha256"], "profile changed after registration")
    _require(set(registration["snapshots"]) == set(profile["locales"]),
             "registered locale set changed")
    _require(set(registration["baseline"]) == set(profile["locales"]),
             "registered baseline locale set changed")
    for locale, observations in profile["locales"].items():
        _require(set(registration["snapshots"][locale]) == {"baseline", "after"},
                 "registered snapshot pair changed")
        for label, record in observations.items():
            text = registration["snapshots"][locale][label]
            _require(isinstance(text, str) and _digest(text) == record["sha256"],
                     "registered full snapshot changed: " + locale + "/" + label)
        frozen = registration["baseline"][locale]
        _require(isinstance(frozen, dict) and set(frozen) == BASELINE_FIELDS,
                 "unexpected registered baseline record")
        _require(isinstance(frozen["pair"], list) and tuple(frozen["pair"]) in MANIFEST_PAIRS,
                 "unsupported registered manifest pair")
        for name in ("snapshotId", "projectionId", "docIrSha256", "routeFingerprint"):
            _require(isinstance(frozen[name], str) and bool(frozen[name]),
                     "registered baseline identity is missing: " + name)
        # Recompute the frozen ordered evidence from the registered rows so a
        # post-registration edit cannot smuggle a different address or ranking.
        table = _table_from_symbols(frozen["symbols"])
        _require(address_fingerprint(table) == frozen["routeFingerprint"],
                 "registered baseline addresses changed: " + locale)
        _require(frozen["pageSymbolId"] in table["hrefById"],
                 "registered page declaration is absent from the baseline inventory")
        _require(table["hrefById"][frozen["pageSymbolId"]] == frozen["pageHref"],
                 "registered page address changed")
        _require(link_targets(registration["snapshots"][locale]["baseline"], table, frozen["pageHref"]) ==
                 frozen["linkTargets"], "registered baseline ARIA link targets changed: " + locale)
    return profile


class ApiRouteQualification:
    """Prove the address-only difference for one locale between verified products."""

    def __init__(self, registration: dict, locale: str, before_proof: dict, after_proof: dict,
                 before_table: dict, after_table: dict):
        self.registration = registration
        self.profile = registration["profile"]
        self.locale = locale
        self.before_proof = before_proof
        self.after_proof = after_proof
        self.before_table = before_table
        self.after_table = after_table
        self.frozen = registration["baseline"][locale]
        self.snapshots = registration["snapshots"][locale]

    # -- addresses -------------------------------------------------------
    def _table(self, side: str) -> dict:
        _require(side in ("baseline", "after"), "unknown evidence side: " + side)
        return self.before_table if side == "baseline" else self.after_table

    def page_href(self, side: str) -> str:
        return self._table(side)["hrefById"][self.frozen["pageSymbolId"]]

    def normalize_hrefs(self, side: str, hrefs: list[str]) -> list[str]:
        """Rewrite a captured first-20 result list without changing its order."""
        _require(isinstance(hrefs, list) and all(isinstance(value, str) for value in hrefs),
                 "a captured search result list is not text")
        table = self._table(side)
        # Result addresses are rendered relative to the site-root search page.
        return [_url_token(value, table, "") for value in hrefs]

    def normalize_search(self, side: str, index: dict) -> None:
        """Rewrite only the proven declaration addresses inside a search index copy."""
        table = self._table(side)
        for entry in index["entries"]:
            if entry.get("concept") is not True:
                entry["href"] = _address_token(entry["href"], table)
            for binding in entry.get("bindings", []):
                if isinstance(binding.get("href"), str):
                    binding["href"] = _address_token(binding["href"], table)

    def normalize_tree(self, side: str, tree: str) -> str:
        """Rewrite only address lines of a complete accessible tree."""
        table = self._table(side)
        page_href = self.page_href(side)
        page_dir = posixpath.dirname(page_href)
        page_symbol = table["idByHref"][page_href]
        lines = []
        for line in tree.split("\n"):
            match = URL_LINE.fullmatch(line)
            lines.append(line if match is None else
                         match.group("lead") + _url_token(match.group("value"), table, page_dir, page_symbol))
        return "\n".join(lines)

    # -- accessible tree -------------------------------------------------
    def _observed_tree(self, observation: dict) -> str:
        _check_corpus(self.profile, observation)
        _require(observation["environment"]["requestedUiLocale"] == self.locale,
                 "unregistered browser locale")
        _require(observation["accessibility"].get("status") != "not-applicable",
                 "actual no-JS accessible-tree observation is required")
        return observation["accessibility"]["noScript"]["accessibleTree"]

    def check_trees(self, before: dict, after: dict) -> None:
        old = self._observed_tree(before)
        new = self._observed_tree(after)
        _require(old == self.snapshots["baseline"],
                 "baseline accessible tree differs from the complete registered snapshot: " + self.locale)
        _require(link_targets(old, self.before_table, self.page_href("baseline")) ==
                 self.frozen["linkTargets"], "baseline ARIA link targets differ from registration")
        # Earlier, separately qualified navigation/wording stays intact. Only
        # the addresses in that approved complete tree may differ here.
        expected = self.normalize_tree("baseline", self.snapshots["after"])
        _require(self.normalize_tree("after", new) == expected,
                 "ARIA content changed beyond the proven address mapping: " + self.locale)

    # -- machine inventory ----------------------------------------------
    def _normalized_inventory(self, table: dict, inventory: dict) -> list[dict]:
        entries = deepcopy(inventory["entries"])
        for entry in entries:
            entry["href"] = _address_token(entry["href"], table)
        return sorted(entries, key=lambda entry: entry["id"])

    def check_inventories(self) -> None:
        """Require one inventory modulo the proven identity/address rewriting."""
        old, new = self.before_proof.get("inventory"), self.after_proof.get("inventory")
        _require(old is not None and new is not None, "a machine symbol inventory is required")
        _require(self._normalized_inventory(self.before_table, old) ==
                 self._normalized_inventory(self.after_table, new),
                 "machine symbol inventory changed beyond the proven address mapping")

    # -- search payload --------------------------------------------------
    def check_search_payload(self, paired_snapshot: bool = True) -> None:
        """Require one search projection modulo the proven address rewriting.

        ``paired_snapshot`` mirrors the Doc IR transition: when that transition
        is registered the derived snapshot/projection identities are paired,
        because they are recomputed from the changed Doc IR version. Otherwise
        every identity is compared exactly.
        """
        old_proof, new_proof = self.before_proof, self.after_proof
        _require(old_proof["contractText"] == new_proof["contractText"],
                 "raw embedded search contract changed")
        _require(old_proof["signatures"] == new_proof["signatures"],
                 "native script signatures changed")
        compared = []
        for side, proof in (("baseline", old_proof), ("after", new_proof)):
            index = deepcopy(proof["index"])
            self.normalize_search(side, index)
            if paired_snapshot or old_proof["manifestPair"] != new_proof["manifestPair"]:
                for name in ("snapshotId", "sourceSnapshotId"):
                    index["scope"][name] = "<registered-paired-snapshot>"
                for entry in index["entries"]:
                    entry["snapshotId"] = "<registered-paired-snapshot>"
                index["projectionId"] = "<registered-paired-projection>"
                index["coverage"]["projectionId"] = "<registered-paired-projection>"
            compared.append(index)
        _require(compared[0] == compared[1],
                 "search payload changed beyond the proven address mapping")


def qualify_api_routes(registration: dict, locale: str, before_site: Path, after_site: Path,
                       before_resources: dict, after_resources: dict,
                       schema_dir: Path | None = None, doc_ir_transition: bool = False) -> ApiRouteQualification:
    """Verify both products and prove the candidate address bijection for one locale."""
    schema_dir = schema_dir or REPO / "docs/schema"
    profile = validate_api_route_registration(registration)
    _require(locale in profile["locales"], "unregistered browser locale: " + locale)
    schema = strict_load(schema_dir / "symbol-index.schema.json")
    frozen = registration["baseline"][locale]
    before_proof = verify_search_identity(before_site, before_resources, schema_dir)
    after_proof = verify_search_identity(after_site, after_resources, schema_dir)
    _require(list(before_proof["manifestPair"]) == frozen["pair"],
             "baseline publisher projection domain changed: " + locale)
    for name in ("snapshotId", "projectionId", "docIrSha256"):
        _require(before_proof[name] == frozen[name], "baseline publisher identity changed: " + name)
    _require(before_proof["symbolIndexSha256"] == frozen["symbolIndexSha256"],
             "baseline publisher identity changed: symbolIndexSha256")
    _require(after_proof["manifestPair"][1] == "cjdoc.read/2",
             "expected readable API projection: " + locale)
    if not doc_ir_transition:
        # A routes-only exception stays narrow: the captured documentation model
        # may not change. A different Doc IR requires its own registered transition.
        _require(before_proof["docIr"] == after_proof["docIr"],
                 "the Doc IR changed; register the Doc IR transition as well")
    before_table = published_route_table(before_proof, schema)
    _require(address_fingerprint(before_table) == frozen["routeFingerprint"],
             "baseline published addresses changed: " + locale)
    _require([row["id"] for row in frozen["symbols"]] == before_table["ids"],
             "baseline published declaration identities changed: " + locale)
    after_table = published_route_table(after_proof, schema)
    _check_search_addresses(after_proof["index"], after_table, locale)
    _require(after_table["ids"] == before_table["ids"],
             "the candidate inventory is not the same visible declaration set: " + locale)
    qualification = ApiRouteQualification(registration, locale, before_proof, after_proof,
                                          before_table, after_table)
    _require(_page_symbol(after_table, profile["page"]) == frozen["pageSymbolId"],
             "the captured page is not the registered declaration: " + locale)
    qualification.check_inventories()
    return qualification
