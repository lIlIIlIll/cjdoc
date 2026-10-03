"""Browser action accounting and observations; no application behavior is mocked."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

from .site import ContractError, Site


class Journey:
    def __init__(self, page, site: Site, base: str, target: dict, mode: str):
        self.page, self.site, self.base, self.target, self.mode = page, site, base, target, mode
        self.activations = 1
        self.assertions = []
        self.timings = {"queryMs": [], "expandMs": []}

    def click(self, locator):
        self.activations += 1
        locator.click()
        self.page.wait_for_load_state("load")

    def back(self, expected: str):
        self.activations += 1
        self.page.go_back(wait_until="load")
        if unquote(self.page.url) != unquote(expected):
            raise AssertionError("browser Back did not restore the actual originating route")

    def measured(self, name: str, action, locator=None, event: str = "input"):
        if locator is None:
            raise AssertionError("interaction timing requires an observed real input event")
        locator.evaluate("""(node, event) => {
          delete globalThis.__showcaseInteractionStart;
          node.addEventListener(event, () => {
            globalThis.__showcaseInteractionStart = performance.now();
          }, {capture:true, once:true});
        }""", event)
        result = action()
        elapsed = self.page.evaluate("performance.now() - globalThis.__showcaseInteractionStart")
        if elapsed is None:
            raise AssertionError("the browser did not emit the timed interaction event")
        self.timings[name].append(round(elapsed, 3))
        return result

    def expand(self, member):
        from playwright.sync_api import expect
        member.locator("summary").first.scroll_into_view_if_needed()
        def complete():
            self.click(member.locator("summary").first)
            expect(member).to_have_attribute("open", "")
            expect(member.locator(".member-detail-body")).to_be_visible()
        self.measured("expandMs", complete, member.locator("summary").first, "click")

    def local_path(self, url: str) -> Path:
        root, parsed = urlsplit(self.base), urlsplit(url)
        if (parsed.scheme, parsed.netloc) != (root.scheme, root.netloc):
            raise ContractError("journey attempted a resource outside its tested origin")
        path, base = unquote(parsed.path), unquote(root.path)
        if not path.startswith(base):
            raise ContractError("journey escaped its project subpath")
        return self.site.file(path[len(base):])

    def raw(self, selector: str, schema: str | None = None):
        """Follow the rendered raw-evidence link, inspect it, then use browser Back."""
        from playwright.sync_api import expect
        link = self.page.locator(selector).first
        expect(link).to_be_visible()
        old = self.page.url
        url = urljoin(old, link.get_attribute("href"))
        expected = self.local_path(url).read_text(encoding="utf-8")
        self.click(link)
        actual = self.page.locator("pre").first.inner_text()
        if schema:
            value = json.loads(actual)
            if value != json.loads(expected) or value.get("schemaVersion") != schema:
                raise AssertionError("raw browser evidence differs from its versioned generated payload")
        else:
            value = actual
            if actual.strip() != expected.strip():
                raise AssertionError("raw browser payload differs from the generated artifact: " + url + " (actual=" + repr(actual[:80]) + ", expected=" + repr(expected[:80]) + ")")
        self.back(old)
        return value

    def download(self, selector: str):
        link = self.page.locator(selector)
        expected = self.local_path(urljoin(self.page.url, link.get_attribute("href")))
        with self.page.expect_download() as pending:
            self.click(link)
        download = pending.value
        if download.failure():
            raise AssertionError("download failed: " + download.failure())
        actual = Path(download.path())
        if hashlib.sha256(actual.read_bytes()).digest() != hashlib.sha256(expected.read_bytes()).digest():
            raise AssertionError("downloaded bytes differ from the published artifact")
        return actual.read_bytes()


def require_text(locator, *parts: str):
    text = " ".join(locator.inner_text().split())
    for part in parts:
        if " ".join(part.split()) not in text:
            raise AssertionError("generated contract is missing expected source-backed content: " + part)


def click_and_return(journey: Journey, link, expected_name: str, version: str | None = None):
    from playwright.sync_api import expect
    page, old = journey.page, journey.page.url
    expected = urljoin(old, link.get_attribute("href"))
    identity = link.get_attribute("data-report-symbol")
    journey.click(link)
    if unquote(page.url) != unquote(expected):
        raise AssertionError("link activation changed its native resolved route")
    require_text(page.locator("main"), expected_name)
    if identity:
        assert_native_id(journey, identity)
    if version:
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", version)
    journey.back(old)


def clipboard_code_matches(copied: str, source: str) -> bool:
    """Allow platform CRLF conversion while retaining outer-whitespace tolerance."""
    return copied.replace("\r\n", "\n").strip() == source.replace("\r\n", "\n").strip()


def copy_code(journey: Journey, button=None):
    from playwright.sync_api import expect
    page = journey.page
    button = button if button is not None else page.locator(".code-copy").first
    expect(button).to_be_visible()
    if button.get_attribute("data-showcase-copy"):
        code = page.locator("#" + button.get_attribute("data-showcase-copy")).inner_text()
        attribute, expected = "data-copy-result", "copied"
    else:
        code = button.locator("..").locator("code").first.inner_text()
        attribute, expected = "data-copied", "true"
    journey.click(button)
    expect(button).to_have_attribute(attribute, expected)
    if page.evaluate("Boolean(navigator.clipboard && window.isSecureContext)"):
        copied = page.evaluate("navigator.clipboard.readText()")
        if not clipboard_code_matches(copied, code):
            raise AssertionError("clipboard contents do not match the displayed source code")
    else:
        # Verify the real clipboard fallback by pasting into a temporary probe;
        # the copy handler, permissions and clipboard API are never replaced.
        page.evaluate("""() => { const probe=document.createElement('textarea');
          probe.id='showcase-paste-probe'; document.body.append(probe); probe.focus(); }""")
        try:
            page.keyboard.press("Control+v")
            if not clipboard_code_matches(page.locator("#showcase-paste-probe").input_value(), code):
                raise AssertionError("real clipboard paste did not reproduce the displayed code")
        finally:
            page.locator("#showcase-paste-probe").evaluate("node => node.remove()")
    journey.assertions.append("the displayed code copied successfully using the page's real clipboard handler")


def assert_native_symbol(journey: Journey, qualified: str, signature: str | None = None):
    """Independently join semantic selection to native indices, never trust a link alone."""
    from .site import load_json
    page = journey.page
    link = page.locator('[data-machine-format="symbols"]')
    if link.count() != 1:
        raise AssertionError("landed document has no native symbol-index entry point")
    url = urljoin(page.url, link.get_attribute("href"))
    index = load_json(journey.local_path(url))
    candidates = [entry for entry in index["entries"] if entry["qualifiedName"] == qualified]
    if signature:
        ir_url = urljoin(page.url, page.locator('[data-machine-format="json"]').get_attribute("href"))
        ir = load_json(journey.local_path(ir_url))
        identities = {item["id"] for item in ir["declarations"]
                      if item["qualifiedName"] == qualified and item["headerSpelling"] == signature}
        candidates = [entry for entry in candidates if entry["id"] in identities]
    if len(candidates) != 1 or unquote(page.url) != unquote(urljoin(url, candidates[0]["href"])):
        raise AssertionError("landed route is not the exact native identity for " + qualified)


def directory_navigation(journey: Journey):
    from playwright.sync_api import expect
    page, original = journey.page, journey.page.url
    mobile = page.viewport_size["width"] <= 760
    if mobile:
        menu = page.locator("[data-cjdoc-menu]")
        journey.click(menu)
        expect(menu).to_have_attribute("aria-expanded", "true")
        expect(page.locator("#cjdoc-sidebar")).to_have_attribute("aria-modal", "true")
        if not page.evaluate("document.querySelector('#cjdoc-sidebar').contains(document.activeElement)"):
            raise AssertionError("mobile drawer did not receive keyboard focus")
        page.keyboard.press("Escape")
        expect(menu).to_be_focused()
        expect(menu).to_have_attribute("aria-expanded", "false")
        journey.click(menu)
    overview = page.locator("#cjdoc-sidebar [data-cjdoc-nav-link]").first
    href = urljoin(page.url, overview.get_attribute("href"))
    journey.click(overview)
    if page.url != href:
        raise AssertionError("directory navigation did not activate its rendered target")
    expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", journey.target["version"])
    journey.back(original)
    compact_toc = not page.locator("[data-cjdoc-toc]").is_visible()
    toc = page.locator("[data-cjdoc-mobile-toc]" if compact_toc else "[data-cjdoc-toc]")
    if compact_toc:
        journey.click(toc.locator("summary"))
    link = toc.locator("a").first
    anchor = unquote(urlsplit(link.get_attribute("href")).fragment)
    journey.click(link)
    if unquote(urlsplit(page.url).fragment) != anchor:
        raise AssertionError("table of contents did not update the native anchor")
    exists = page.evaluate("id => Boolean(document.getElementById(id))", anchor)
    if not exists:
        raise AssertionError("table of contents target is absent")
    journey.back(original)
    journey.assertions.append("native directory and table-of-contents links work; mobile drawer also restores keyboard focus")


def assert_native_id(journey: Journey, identity: str):
    from .site import load_json
    page = journey.page
    link = page.locator('[data-machine-format="symbols"]')
    if link.count() != 1:
        raise AssertionError("landed page has no native symbol-index entry point")
    url = urljoin(page.url, link.get_attribute("href"))
    native = load_json(journey.local_path(url))
    matches = [entry for entry in native["entries"] if entry["id"] == identity]
    if len(matches) != 1 or unquote(page.url) != unquote(urljoin(url, matches[0]["href"])):
        raise AssertionError("landed route does not match the claimed exact native symbol identity")
