"""Fail-closed Playwright acceptance of every promised final-site journey.

The runner activates the final homepage, follows native links, records observed
layout/action timings and produces evidence only after all scenarios pass.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager, ExitStack
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.metadata
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlsplit

from .browser_journeys import JOURNEYS as API_JOURNEYS
from .browser_reports import JOURNEYS as REPORT_JOURNEYS
from .browser_metrics import check_layout, layout, screenshot_name, screenshots, validate_metrics
from .browser_support import Journey
from .contract import validate_manifest
from .evidence import _expected_cases, validate_evidence
from .offline import ARCHIVE, extract_archive
from .scenarios import SCENARIOS, BUDGETS
from .site import ContractError, Site, canonical_json, load_json

BEHAVIORS = {**API_JOURNEYS, **REPORT_JOURNEYS}


def registered_cases(manifest: dict) -> dict:
    validate_manifest(manifest)
    cases = _expected_cases(manifest)
    if not cases:
        raise ContractError("no available showcase scenarios; refusing a vacuous browser pass")
    for key, target in cases.items():
        scenario = SCENARIOS.get(key[2])
        if scenario is None or scenario[1] != key[3] or scenario[0] not in BEHAVIORS:
            raise ContractError(f"unimplemented or mismatched browser scenario: {key[2]} / {key[3]}")
        if scenario[0] in {"members", "contracts", "resources"} and target.get("placement") != "member":
            raise ContractError("member browser scenarios require a native inline member target")
        if scenario[0] in {"search", "types", "guides", "versions", "external", "machine", "extension", "authoring"} and target["kind"] != "navigation":
            raise ContractError("navigation browser scenarios require a navigation target")
    return cases


@contextmanager
def serve(root: Path, prefix: str):
    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            if not path.startswith(prefix):
                self.send_error(404)
                return
            self.path = "/" + path[len(prefix):]
            super().do_GET()

        def guess_type(self, path):
            value = super().guess_type(path)
            return value + "; charset=utf-8" if value.startswith("text/") or value == "application/json" else value

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(root)))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}{prefix}"
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def same_route(actual: str, base: str, href: str) -> bool:
    expected, got = urlsplit(base + href), urlsplit(actual)
    return (got.scheme, got.netloc, unquote(got.path), got.query, unquote(got.fragment)) == (
        expected.scheme, expected.netloc, unquote(expected.path), expected.query, unquote(expected.fragment))


def observe(context, base: str, errors: list, scrolling: dict):
    allowed = urlsplit(base)
    def route_resource(route):
        parsed = urlsplit(route.request.url)
        if ((parsed.scheme, parsed.netloc) == (allowed.scheme, allowed.netloc)
                or parsed.scheme in ("data", "blob")):
            route.continue_()
        else:
            errors.append("unexpected remote resource: " + route.request.url)
            route.abort()
    context.route("**/*", route_resource)
    def scroll_event(_, distance):
        scrolling["scrollEvents"] += 1
        scrolling["scrollDistance"] += int(distance)
    context.expose_binding("__showcaseObserveScroll", scroll_event)
    context.add_init_script('''(() => {
      let previous = 0;
      addEventListener("scroll", () => {
        const distance = Math.round(Math.abs(scrollY - previous)); previous = scrollY;
        globalThis.__showcaseObserveScroll(distance);
      }, {passive:true});
    })();''')


def check_locale_navigation(journey: Journey):
    from playwright.sync_api import expect
    page = journey.page
    link = page.locator("[data-showcase-locale][href]")
    if not link.count():
        raise AssertionError("generated example lacks a mapped other-language entry")
    before = page.url
    fragment = urlsplit(before).fragment
    locale = "en" if journey.target["locale"] == "zh-CN" else "zh-CN"
    journey.click(link.first)
    expect(page.locator("html")).to_have_attribute("lang", locale)
    expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", journey.target["version"])
    if journey.target.get("placement") == "member":
        if urlsplit(page.url).fragment != fragment:
            raise AssertionError("language switching lost the selected native member anchor")
        from .browser_journeys import selected_member
        selected_member(journey)
    if journey.target.get("signature"):
        from .browser_support import require_text
        require_text(page.locator("main"), journey.target["signature"])
    if journey.target.get("resolved", {}).get("symbolId"):
        from urllib.parse import urljoin
        index_link = page.locator('[data-machine-format="navigation"]')
        index_url = urljoin(page.url, index_link.get_attribute("href"))
        native = load_json(journey.local_path(index_url))
        identity = journey.target["resolved"].get("ownerSymbolId", journey.target["resolved"]["symbolId"])
        matches = [record for record in native["pages"] if record.get("symbolId") == identity]
        if len(matches) != 1 or unquote(page.url.split("#")[0]) != unquote(urljoin(index_url, matches[0]["href"]).split("#")[0]):
            raise AssertionError("language switch did not preserve the native symbol/owner identity")
    journey.back(before)
    journey.assertions.append("the language control follows the same native declaration/version and browser Back returns")


def exercise(browser, target: dict, key: tuple, base: str, site: Site, output: Path, homes: dict) -> dict:
    from playwright.sync_api import expect
    behavior, _, width, height, theme, _ = SCENARIOS[key[2]]
    context = browser.new_context(viewport={"width": width, "height": height}, color_scheme=theme,
                                  accept_downloads=True, permissions=["clipboard-read", "clipboard-write"])
    errors, scrolling = [], {"scrollEvents": 0, "scrollDistance": 0}
    page = None
    try:
        observe(context, base, errors, scrolling)
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        # Chromium reports intentional download navigations as net::ERR_ABORTED;
        # actual download failure is checked through the Download object instead.
        page.on("requestfailed", lambda req: errors.append(f"request failed: {req.url}: {req.failure}")
                if not (req.failure == "net::ERR_ABORTED" and urlsplit(req.url).path.endswith((".zip", ".cj"))) else None)
        page.on("response", lambda response: errors.append(f"HTTP {response.status}: {response.url}")
                if response.status >= 400 else None)
        page.set_default_timeout(10000)
        page.goto(base + "index.html", wait_until="load")
        if page.evaluate("document.documentElement.scrollWidth > innerWidth + 1"):
            raise AssertionError("final homepage overflows its viewport")
        initial_actions = 0
        if target["locale"] == "en":
            page.locator('header a[lang="en"]').click()
            page.wait_for_load_state("load")
            expect(page.locator("html")).to_have_attribute("lang", "en")
            initial_actions += 1
        home_key = (target["locale"], width, height, key[3], SCENARIOS[key[2]][-1])
        if home_key not in homes:
            home = Journey(page, site, base, target, key[3])
            images = screenshots(home, tuple(str(part) for part in (*home_key, "homepage")), output)
            homes[home_key] = {"locale": target["locale"], "mode": key[3], "prefix": SCENARIOS[key[2]][-1],
                               "viewport": {"width": width, "height": height}, "screenshots": images}
            initial_actions += home.activations - 1
        link = page.locator(f'[data-feature-id="{key[0]}"] [data-target-id="{key[1]}"]')
        expect(link).to_have_count(1)
        expect(link).to_have_attribute("href", target["resolved"]["href"])
        navigations = []
        # Count committed document loads, not same-document hashes or download
        # requests that Chromium intentionally aborts before committing a page.
        page.on("domcontentloaded", lambda: navigations.append(page.url))
        link.click()
        page.wait_for_load_state("load")
        if not same_route(page.url, base, target["resolved"]["href"]):
            raise AssertionError("homepage entry did not reach its exact native resolved route")
        if len(navigations) != 1:
            raise AssertionError("homepage feature entry must reach its target in one document navigation")
        expect(page.locator("html")).to_have_attribute("lang", target["locale"])
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", target["version"])
        journey = Journey(page, site, base, target, key[3])
        journey.activations += initial_actions
        if target.get("placement") == "member":
            from .browser_journeys import selected_member
            expect(selected_member(journey).locator("summary").first).to_be_in_viewport()
        duplicates = page.evaluate("""() => {
          const seen=new Set(), repeated=[];
          for (const node of document.querySelectorAll('[id]')) {
            if (seen.has(node.id)) repeated.push(node.id); seen.add(node.id);
          }
          return repeated;
        }""")
        if duplicates:
            raise AssertionError("runtime scripts produced duplicate HTML IDs: " + ", ".join(duplicates))
        initial = layout(page)
        check_layout(initial, width, behavior)
        BEHAVIORS[behavior](journey)
        if target["kind"] == "navigation":
            check_locale_navigation(journey)
        pictures = screenshots(journey, key, output)
        metrics = {"viewport": {"width": width, "height": height}, "landing": initial, **scrolling,
                   **journey.timings, "homepageActivations": 1, "homepageDocumentNavigations": 1}
        validate_metrics(metrics, SCENARIOS[key[2]])
        if errors:
            raise AssertionError("; ".join(errors))
        return {"featureId": key[0], "targetId": key[1], "scenarioId": key[2], "mode": key[3],
                "locale": key[4], "version": key[5], "status": "passed", "entry": "index.html",
                "href": target["resolved"]["href"], "activations": journey.activations,
                "documentNavigations": len(navigations), "assertions": journey.assertions,
                "screenshot": {name: pictures[0][name] for name in ("path", "sha256")},
                "screenshots": pictures, "metrics": metrics}
    except Exception:
        if page is not None:
            page.screenshot(path=str(output / screenshot_name((*key, "failed"))), full_page=True)
        raise
    finally:
        context.close()


def run(site_path: Path, evidence_path: Path, executable: str | None = None,
        shard: tuple[dict, int, str, int] | None = None) -> None:
    """Run every (or one shard's) declared journey against the final site.

    `shard` carries (plan, shardIndex, runId, runAttempt). Shard mode records the
    same per-case evidence plus elapsedMs timings and defers full coverage
    checking to `merge`, which calls the unmodified validate_evidence() gate.
    """
    from . import browser_sharding

    site = Site(site_path)
    if any(parent.is_symlink() for parent in evidence_path.absolute().parents):
        raise ContractError("symlink in browser evidence destination")
    output = evidence_path.resolve()
    if output.is_relative_to(site.root) or site.root.is_relative_to(output):
        raise ContractError("browser evidence and final site must be separate trees")
    if evidence_path.exists() or evidence_path.is_symlink():
        raise ContractError("browser evidence output must be a new directory (no stale results reuse)")
    output.mkdir(parents=True)
    active = None
    try:
        manifest = load_json(site.file("showcase-features.json"))
        cases = registered_cases(manifest)
        if shard is not None:
            plan, shard_index, run_id, run_attempt = shard
            if plan.get("runId") != run_id:
                raise ContractError(f"plan is for run {plan.get('runId')}, not {run_id}")
            browser_sharding.verify_plan_against(plan, site_path)
            unknown = [entry["key"] for entry in browser_sharding.shard_cases(plan, shard_index)
                       if tuple(entry["key"]) not in cases]
            if unknown:
                raise ContractError(f"plan refers to unknown browser cases: {unknown[:3]}")
            order = {key: number for number, key in enumerate(cases)}
            planned = [tuple(entry["key"]) for entry in browser_sharding.shard_cases(plan, shard_index)]
            cases = {key: cases[key] for key in sorted(planned, key=lambda item: order[item])}
        site.validate_links()
        fingerprint = site.digest()
        sizes = {"siteBytes": sum(path.stat().st_size for path in site.root.rglob("*") if path.is_file()),
                 "offlineBytes": site.file(ARCHIVE).stat().st_size}
        for name, value in sizes.items():
            if value > BUDGETS[name]:
                raise ContractError("final controlled showcase exceeds size budget: " + name)
        from playwright.sync_api import sync_playwright
        results, homes, timings = [], {}, []
        with tempfile.TemporaryDirectory(prefix="cjdoc-offline-test-") as temporary, ExitStack() as stack:
            offline = extract_archive(site.file(ARCHIVE), Path(temporary) / "site", site)
            bases = {prefix: stack.enter_context(serve(site.root, prefix)) for prefix in ("/", "/cjdoc-preview/")}
            with sync_playwright() as playwright:
                options = {"headless": True}
                if executable:
                    options["executable_path"] = executable
                browser = playwright.chromium.launch(**options)
                try:
                    for number, (key, target) in enumerate(cases.items(), 1):
                        active = key
                        prefix = SCENARIOS[key[2]][-1]
                        current = offline if key[3] == "file" else site
                        base = offline.root.as_uri() + "/" if key[3] == "file" else bases[prefix]
                        print(f"[{number}/{len(cases)}] {' / '.join(key)}", flush=True)
                        started = time.perf_counter()
                        record = exercise(browser, target, key, base, current, output, homes)
                        timings.append({"key": list(key),
                                        "elapsedMs": round((time.perf_counter() - started) * 1000, 3)})
                        results.append(record)
                    browser_version = browser.version
                finally:
                    browser.close()
        if Site(site_path).digest() != fingerprint:
            raise ContractError("final published tree changed during browser verification")
        runner = {"name": "cjdoc-final-showcase-browser",
                  "version": importlib.metadata.version("playwright"),
                  "browser": "chromium", "browserVersion": browser_version}
        if shard is not None:
            plan, shard_index, run_id, run_attempt = shard
            expected = [entry["key"] for entry in browser_sharding.shard_cases(plan, shard_index)]
            completed = [[record[field] for field in
                          ("featureId", "targetId", "scenarioId", "mode", "locale", "version")]
                         for record in results]
            attachments = sorted(
                ({"relativePath": path.relative_to(output).as_posix(),
                  "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                 for path in output.rglob("*.png")),
                key=lambda item: item["relativePath"])
            document = {
                "schemaVersion": browser_sharding.SHARD_SCHEMA,
                "planSha256": plan["planSha256"],
                "shardIndex": shard_index,
                "shardCount": plan["shardCount"],
                "runId": run_id,
                "runAttempt": run_attempt,
                "revision": plan["revision"],
                "siteSha256": fingerprint,
                "manifestSha256": plan["manifestSha256"],
                "binarySha256": plan["binarySha256"],
                "sourceArchiveSha256": plan["sourceArchiveSha256"],
                "runner": runner,
                "budgets": BUDGETS,
                "siteMetrics": sizes,
                "expectedCases": expected,
                "completedCases": completed,
                "homepages": list(homes.values()),
                "results": results,
                "attachments": attachments,
                "status": "passed",
            }
            (output / "shard.json").write_text(
                json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8", newline="\n")
            (output / "timings.json").write_text(
                json.dumps(browser_sharding.timing_document({"results": timings}),
                           ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8", newline="\n")
            print(f"browser shard {shard_index}/{plan['shardCount']} passed; run merge to verify coverage")
            return
        evidence = {"schemaVersion": "cjdoc.showcase-evidence/2", "revision": manifest["revision"],
                    "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
                    "siteSha256": fingerprint, "budgets": BUDGETS, "siteMetrics": sizes,
                    "homepages": list(homes.values()),
                    "runner": runner, "results": results}
        validate_evidence(manifest, evidence, site, output)
        (output / "results.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception as error:
        (output / "failures.json").write_text(json.dumps({"status": "failed", "case": active, "error": str(error)},
                                                          ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        raise


def main(argv=None) -> int:
    from . import browser_sharding

    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] in (["plan"], ["run"], ["merge"]):
        return shard_main(argv)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--chromium", help="optional installed Chromium executable")
    args = parser.parse_args(argv)
    try:
        run(args.site, args.evidence, args.chromium)
    except Exception as error:
        print(f"Showcase browser verification FAILED: {error}")
        return 1
    print("All declared final-tree browser journeys passed. Run the static/evidence gate before upload.")
    return 0


def shard_main(argv: list[str]) -> int:
    """`plan`, `run --shard-index` and `merge` for the sharded acceptance."""
    from . import browser_sharding

    command, rest = argv[0], argv[1:]
    parser = argparse.ArgumentParser(prog=f"showcase_contract.browser {command}")
    if command == "plan":
        parser.add_argument("--site", type=Path, required=True)
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--shards", type=int, default=browser_sharding.SHARD_COUNT)
        parser.add_argument("--run-id", required=True)
        parser.add_argument("--history", type=Path)
    elif command == "run":
        parser.add_argument("--site", type=Path, required=True)
        parser.add_argument("--plan", type=Path, required=True)
        parser.add_argument("--shard-index", type=int, required=True)
        parser.add_argument("--run-id", required=True)
        parser.add_argument("--run-attempt", type=int, default=1)
        parser.add_argument("--evidence", type=Path, required=True)
        parser.add_argument("--chromium", help="optional installed Chromium executable")
    else:
        parser.add_argument("--site", type=Path, required=True)
        parser.add_argument("--plan", type=Path, required=True)
        parser.add_argument("--shard-result", action="append", default=[], metavar="N=FILE")
        parser.add_argument("--evidence", type=Path, required=True)
        parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(rest)
    try:
        if command == "plan":
            document = browser_sharding.build_plan(args.site, args.run_id, args.shards, args.history)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                                   encoding="utf-8", newline="\n")
            print(f"browser shard plan written: {args.output} ({len(document['cases'])} cases, "
                  f"{len(document['homeKeys'])} homepage groups)")
            return 0
        if command == "run":
            plan = browser_sharding.load_plan(args.plan)
            if plan["runId"] != args.run_id:
                raise browser_sharding.ContractError(
                    f"plan is for run {plan['runId']}, not {args.run_id}")
            run(args.site, args.evidence, args.chromium,
                shard=(plan, args.shard_index, args.run_id, args.run_attempt))
            return 0

        def parse_shard_result(value: str) -> tuple[int, Path]:
            index, _, path = value.partition("=")
            if not path:
                raise browser_sharding.ContractError(f"--shard-result needs N=FILE, got {value!r}")
            return int(index), Path(path)

        shard_files = dict(parse_shard_result(value) for value in args.shard_result)
        receipt = browser_sharding.merge(args.plan, shard_files, args.site, args.evidence, args.receipt)
        print(f"merged {len(receipt['shards'])} browser shards; full evidence gate passed")
        return 0
    except Exception as error:
        print(f"Showcase browser sharding FAILED: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
