"""Check real version hrefs and readable copy links against native symbol indices."""
from __future__ import annotations

import re
from urllib.parse import unquote, urljoin, urlsplit


def _native(index: dict, identity: str) -> dict:
    matches = [entry for entry in index["entries"] if entry["id"] == identity]
    if len(matches) != 1:
        raise AssertionError("native index must contain exactly one identity: " + identity)
    return matches[0]


def _anchor(identity: str) -> str:
    return "symbol-" + identity.encode("utf-8").hex()


def _select_inline_member(page, identity: str):
    from playwright.sync_api import expect
    if page.viewport_size["width"] <= 760:
        menu = page.locator("[data-cjdoc-menu]")
        if menu.get_attribute("aria-expanded") != "true":
            menu.click()
    anchor = _anchor(identity)
    links = [item for item in page.locator("[data-cjdoc-context-item]").all()
             if unquote(item.get_attribute("href") or "") == "#" + anchor]
    if len(links) != 1:
        raise AssertionError("context navigation does not expose one exact native member")
    links[0].click()
    expect(page).to_have_url(re.compile("#" + re.escape(anchor) + "$"))


def _expect_version_href(page, selector: str, expected: str):
    page.wait_for_function("""([selector, expected]) => {
      const link = document.querySelector(selector);
      return link && decodeURI(link.href) === decodeURI(expected);
    }""", arg=[selector, expected])


def check_version_members(page, member_url: str, current_index: dict, old_index: dict, owner_id: str):
    from playwright.sync_api import expect
    page.goto(member_url, wait_until="load")
    old_root = urljoin(member_url, "../../demo-v1/")
    owner = _native(old_index, owner_id)
    selector = '[data-cjdoc-version-link][data-cjdoc-version-label="demo-v1"]'
    common = [entry for entry in current_index["entries"]
              if entry.get("ownerId") == owner_id and entry["name"] == "find"]
    if len(common) != 2:
        raise AssertionError("controlled sample must expose both find overloads")
    for entry in common:
        _select_inline_member(page, entry["id"])
        expected = urljoin(old_root, _native(old_index, entry["id"])["href"])
        _expect_version_href(page, selector, expected)
        origin = page.url
        page.locator(selector).click()
        page.wait_for_url(expected, wait_until="load")
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", "demo-v1")
        expect(page.locator(".api-title-row h1")).to_have_text("find")
        page.go_back(wait_until="load")
        expect(page).to_have_url(origin)
    page.evaluate("location.hash = ''")
    expected_owner = urljoin(old_root, owner["href"])
    _expect_version_href(page, selector, expected_owner)
    expect(page.locator(selector)).to_have_text("demo-v1")
    added = [entry for entry in current_index["entries"]
             if entry.get("ownerId") == owner_id and entry["name"] == "nonEmpty"]
    if len(added) != 1 or any(entry["id"] == added[0]["id"] for entry in old_index["entries"]):
        raise AssertionError("controlled added member must be absent in demo-v1")
    _select_inline_member(page, added[0]["id"])
    _expect_version_href(page, selector, expected_owner)
    missing = page.locator(selector).get_attribute("data-cjdoc-version-missing")
    expect(page.locator(selector)).to_have_text("demo-v1" + missing)
    page.locator(selector).click()
    page.wait_for_url(expected_owner, wait_until="load")
    expect(page.locator(".api-title-row h1")).to_have_text("TextCatalog")


def _copy_url(page, button) -> str:
    from playwright.sync_api import expect
    expected = urljoin(page.url, button.get_attribute("data-cjdoc-copy-link"))
    button.click()
    expect(button).to_have_attribute("data-copy-link-result", re.compile("copied|manual"))
    if button.get_attribute("data-copy-link-result") == "manual":
        field = button.locator("..").locator("[data-cjdoc-copy-link-fallback]")
        expect(field).to_have_value(expected)
        if not field.evaluate("node => node.readOnly && node.selectionStart === 0 && node.selectionEnd === node.value.length"):
            raise AssertionError("manual copy fallback must select the complete readonly URL")
        return expected
    if page.evaluate("Boolean(navigator.clipboard && window.isSecureContext)"):
        actual = page.evaluate("navigator.clipboard.readText()")
    else:
        page.evaluate("""() => {const field=document.createElement('textarea');
          field.id='reading-copy-probe';document.body.append(field);field.focus();}""")
        try:
            page.keyboard.press("Control+v")
            actual = page.locator("#reading-copy-probe").input_value()
        finally:
            page.locator("#reading-copy-probe").evaluate("node => node.remove()")
    if actual != expected:
        raise AssertionError("Copy link clipboard contents differ from the readable URL")
    return actual


def check_readable_links(page, member_url: str, current_index: dict, owner_id: str, member_id: str):
    from playwright.sync_api import expect
    version_root = urljoin(member_url, "../")
    for identity, selector in ((owner_id, ".api-title-row [data-cjdoc-copy-link]"),
                               (member_id, "[data-cjdoc-member][open] [data-cjdoc-copy-link]")):
        page.goto(member_url, wait_until="load")
        button = page.locator(selector).first
        alias = _copy_url(page, button)
        filename = urlsplit(alias).path.rsplit("/", 1)[-1]
        if filename.startswith("symbol-") or "TextCatalog" not in filename or len(filename) > 96:
            raise AssertionError("copy link must use a bounded human-readable symbol alias")
        suffix = "?theme=paper"
        if identity == owner_id:
            suffix += "#" + _anchor(member_id)
        expected = urljoin(version_root, _native(current_index, identity)["href"]) + suffix
        page.goto(alias + suffix, wait_until="load")
        page.wait_for_url(expected, wait_until="load")
        expect(page.locator("html")).to_have_attribute("data-theme", "paper")
        if identity == owner_id:
            target = next(item for item in page.locator("[data-cjdoc-member]").all()
                          if item.get_attribute("id") == _anchor(member_id))
            expect(target).to_have_attribute("open", "")
        else:
            expect(page.locator(".api-title-row h1")).to_have_text("add")


def run_navigation_regressions(page, member_url: str, current_index: dict,
                               old_index: dict, owner_id: str, member_id: str) -> list[str]:
    check_version_members(page, member_url, current_index, old_index, owner_id)
    check_readable_links(page, member_url, current_index, owner_id, member_id)
    return ["both find overload hrefs preserve exact native identity across versions",
            "clearing the member hash restores the type version href",
            "nonEmpty explicitly falls back to its surviving owner in demo-v1",
            "copied readable type/member aliases preserve query and fragment when reaching the native route"]
