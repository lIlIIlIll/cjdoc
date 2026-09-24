"""Real final-tree Playwright runner. No synthetic success or policy bypass.

Only registered behavioral scenarios can produce evidence. Browser startup,
HTTP/file navigation and assertion failures leave results.json absent and write
failures.json instead. This is a foundation for S-06, not all of its scenarios.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.metadata
import json
from pathlib import Path
import tempfile
import threading
from urllib.parse import unquote, urlsplit

from .contract import validate_manifest
from .evidence import _expected_cases, validate_evidence
from .offline import ARCHIVE, extract_archive
from .site import ContractError, Site, canonical_json, load_json

# This table defines test behavior, not a second list of feature targets.
# Targets and required executions always come from the resolved feature manifest.
SCENARIOS = {
    "member-desktop-light-root": ("member", "http", 1280, 900, "light", "/"),
    "member-desktop-dark-subpath": ("member", "http", 1280, 900, "dark", "/cjdoc-preview/"),
    "member-mobile-dark-subpath": ("member", "http", 390, 844, "dark", "/cjdoc-preview/"),
    "member-offline": ("member", "file", 1280, 900, "light", None),
    "search-root": ("search", "http", 1280, 900, "light", "/"),
    "search-subpath": ("search", "http", 1280, 900, "dark", "/cjdoc-preview/"),
    "search-offline": ("search", "file", 1280, 900, "light", None),
}


def registered_cases(manifest: dict) -> dict:
    validate_manifest(manifest)
    cases = _expected_cases(manifest)
    if not cases:
        raise ContractError("no available showcase scenarios; refusing a vacuous browser pass")
    for key, target in cases.items():
        scenario = SCENARIOS.get(key[2])
        if scenario is None or scenario[1] != key[3]:
            raise ContractError(f"unimplemented or mismatched browser scenario: {key[2]} / {key[3]}")
        if scenario[0] == "member" and target.get("placement") != "member":
            raise ContractError("member browser scenarios require a native inline member target")
        if scenario[0] == "search" and target["kind"] != "navigation":
            raise ContractError("search browser scenarios require a navigation target")
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
    expected = urlsplit(base + href)
    got = urlsplit(actual)
    return (got.scheme, got.netloc, unquote(got.path), got.query, unquote(got.fragment)) == (
        expected.scheme, expected.netloc, unquote(expected.path), expected.query, unquote(expected.fragment))


def member_behavior(page, target: dict) -> tuple[int, list[str]]:
    from playwright.sync_api import expect
    resolved = target["resolved"]
    anchor = unquote(urlsplit(resolved["href"]).fragment)
    # IDs are copied from native HTML. No source-to-anchor encoding is reproduced.
    detail = page.locator("[data-cjdoc-member]")
    matches = [item for item in detail.all() if item.get_attribute("id") == anchor]
    if len(matches) != 1:
        raise AssertionError("deep link did not locate exactly one native member detail")
    current = matches[0]
    expect(current).to_have_attribute("open", "")
    expect(current).to_be_visible()
    if " ".join(resolved["signature"].split()) not in " ".join(current.inner_text().split()):
        raise AssertionError("opened contract does not contain the selected source signature")
    assertions = ["homepage click landed on the native owner page and exact member anchor",
                  "the selected member opened automatically with its full source signature"]
    activations = 1
    siblings = [item for item in page.locator("[data-cjdoc-member]").all()
                if item.get_attribute("data-member-name") == resolved["memberName"]]
    if len(siblings) >= 2:
        second = next(item for item in siblings if item.get_attribute("id") != anchor)
        if second.get_attribute("open") is None:
            second.locator("summary").first.click()
            activations += 1
        expect(current).to_have_attribute("open", "")
        expect(second).to_have_attribute("open", "")
        assertions.append("two overload contracts remained open simultaneously on one owner page")
    field = page.locator("[data-cjdoc-member-filter]")
    expect(field).to_have_count(1)
    field.fill("cjdoc_no_such_member_58b0e6")
    expect(current).not_to_be_visible()
    field.fill(resolved["memberName"])
    expect(current).to_be_visible()
    field.fill("")
    assertions.append("member filtering hid unmatched rows and restored the selected overload")
    return activations, assertions


def search_behavior(page, target: dict) -> tuple[int, list[str]]:
    from playwright.sync_api import expect
    query = target["match"]["title"].split(".")[-1]
    field = page.locator("[data-cjdoc-search]")
    expect(field).to_have_count(1)
    page.keyboard.press("Control+k")
    expect(field).to_be_focused()
    field.fill("name:" + query)
    results = page.locator("[data-cjdoc-results] a")
    expect(results.first).to_be_visible()
    if not any(query.lower() in text.lower() for text in results.all_text_contents()):
        raise AssertionError("name: query did not find the selected indexed symbol")
    field.fill("cjdoc_no_such_symbol_58b0e6")
    expect(results).to_have_count(0)
    return 1, ["Ctrl+K focused the generated search input",
               "name: query returned a matching indexed symbol",
               "an unmatched query cleared stale result links"]


def screenshot_name(key: tuple[str, ...]) -> str:
    """Hash the complete tuple so user IDs cannot collide through delimiters."""
    return "scenario-" + hashlib.sha256(canonical_json(list(key))).hexdigest() + ".png"


def exercise(browser, target: dict, key: tuple, base: str, screenshots: Path) -> dict:
    behavior, _, width, height, theme, _ = SCENARIOS[key[2]]
    from playwright.sync_api import expect
    context = browser.new_context(viewport={"width": width, "height": height}, color_scheme=theme)
    errors: list[str] = []
    try:
        # Enforce the static-site boundary; unexpected remote resources fail.
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
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("requestfailed", lambda req: errors.append(f"request failed: {req.url}: {req.failure}"))
        page.on("response", lambda response: errors.append(f"HTTP {response.status}: {response.url}")
                if response.status >= 400 else None)
        page.set_default_timeout(10000)
        page.goto(base + "index.html", wait_until="networkidle")
        link = page.locator(f'[data-feature-id="{key[0]}"] [data-target-id="{key[1]}"]')
        expect(link).to_have_count(1)
        expect(link).to_have_attribute("href", target["resolved"]["href"])
        navigations: list[str] = []
        page.on("request", lambda request: navigations.append(request.url)
                if request.resource_type == "document" and request.frame == page.main_frame else None)
        link.click()
        page.wait_for_load_state("networkidle")
        if not same_route(page.url, base, target["resolved"]["href"]):
            raise AssertionError("homepage feature entry did not reach its exact resolved route")
        if len(navigations) != 1:
            raise AssertionError("feature entry must reach its target in one document navigation")
        expect(page.locator("html")).to_have_attribute("lang", target["locale"])
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", target["version"])
        activations, assertions = (member_behavior if behavior == "member" else search_behavior)(page, target)
        # Check real layout, not viewport constants alone.
        if page.evaluate("document.documentElement.scrollWidth > innerWidth + 1"):
            raise AssertionError(f"horizontal page overflow at {width}px")
        assertions.append(f"no horizontal page overflow at {width}x{height} ({theme} preference)")
        if errors:
            raise AssertionError("; ".join(errors))
        filename = screenshot_name(key)
        screenshot = screenshots / filename
        page.screenshot(path=str(screenshot), full_page=True)
        return {"featureId": key[0], "targetId": key[1], "scenarioId": key[2], "mode": key[3],
                "locale": key[4], "version": key[5], "status": "passed", "entry": "index.html",
                "href": target["resolved"]["href"], "activations": activations,
                "documentNavigations": len(navigations), "assertions": assertions,
                "screenshot": {"path": filename, "sha256": hashlib.sha256(screenshot.read_bytes()).hexdigest()}}
    finally:
        context.close()


def run(site_path: Path, evidence_path: Path, executable: str | None = None) -> None:
    site = Site(site_path)
    if any(parent.is_symlink() for parent in evidence_path.absolute().parents):
        raise ContractError("symlink in browser evidence destination")
    output = evidence_path.resolve()
    if output.is_relative_to(site.root) or site.root.is_relative_to(output):
        raise ContractError("browser evidence and final site must be separate trees")
    if evidence_path.exists() or evidence_path.is_symlink():
        raise ContractError("browser evidence output must be a new directory (no stale results reuse)")
    output.mkdir(parents=True)
    try:
        manifest = load_json(site.file("showcase-features.json"))
        cases = registered_cases(manifest)
        fingerprint = site.digest()
        from playwright.sync_api import sync_playwright
        results = []
        with tempfile.TemporaryDirectory(prefix="cjdoc-offline-test-") as temporary:
            offline = None
            if any(key[3] == "file" for key in cases):
                offline = extract_archive(site.file(ARCHIVE), Path(temporary) / "site", site)
            with sync_playwright() as playwright:
                options = {"headless": True}
                if executable:
                    options["executable_path"] = executable
                browser = playwright.chromium.launch(**options)
                try:
                    for key, target in cases.items():
                        prefix = SCENARIOS[key[2]][-1]
                        if key[3] == "file":
                            base = offline.root.as_uri() + "/"
                            results.append(exercise(browser, target, key, base, output))
                        else:
                            with serve(site.root, prefix) as base:
                                results.append(exercise(browser, target, key, base, output))
                    browser_version = browser.version
                finally:
                    browser.close()
        if Site(site_path).digest() != fingerprint:
            raise ContractError("final published tree changed during browser verification")
        evidence = {"schemaVersion": "cjdoc.showcase-evidence/1", "revision": manifest["revision"],
                    "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
                    "siteSha256": fingerprint,
                    "runner": {"name": "cjdoc-final-showcase-browser", "version": importlib.metadata.version("playwright"),
                               "browser": "chromium", "browserVersion": browser_version}, "results": results}
        validate_evidence(manifest, evidence, site, output)
        (output / "results.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception as error:
        (output / "failures.json").write_text(json.dumps({"status": "failed", "error": str(error)},
                                                          ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        raise


def main(argv=None) -> int:
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
    print("Registered final-tree browser scenarios passed. Run the static/evidence gate before upload.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
