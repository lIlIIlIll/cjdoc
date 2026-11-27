"""Check real version hrefs and readable copy links against native symbol indices."""
from __future__ import annotations

import re
from urllib.parse import urljoin, urlsplit

from .browser_support import declaration_url, member_action, member_toc_link, wait_for_declaration


def _native(index: dict, identity: str) -> dict:
    matches = [entry for entry in index["entries"] if entry["id"] == identity]
    if len(matches) != 1:
        raise AssertionError("native index must contain exactly one identity: " + identity)
    return matches[0]


def _anchor(identity: str) -> str:
    return "symbol-" + identity.encode("utf-8").hex()


def _select_inline_member(page, identity: str):
    from playwright.sync_api import expect
    anchor = _anchor(identity)
    link = member_toc_link(page, anchor)
    expect(link).to_have_attribute("href", "#" + anchor)
    link.click()
    expect(page).to_have_url(re.compile("#" + re.escape(anchor) + "$"))


def _expect_version_href(page, selector: str, expected: str):
    page.wait_for_function("""([selector, expected]) => {
      const link = document.querySelector(selector);
      if (!link) return false;
      let value = link.href;
      if (/^https?:/.test(value)) {
        value = value.replace(/\\/index[.]html(?=([?#]|$))/, '/');
      }
      return decodeURI(value) === decodeURI(expected);
    }""", arg=[selector, declaration_url(expected)])


def check_version_members(page, member_url: str, current_index: dict, old_index: dict, owner_id: str,
                          old_owner_url: str):
    from playwright.sync_api import expect
    page.goto(member_url, wait_until="load")
    selector = '[data-cjdoc-version-link][data-cjdoc-version-label="demo-v1"]'
    common = [entry for entry in current_index["entries"]
              if entry.get("ownerId") == owner_id and entry["name"] == "find"]
    if len(common) != 2:
        raise AssertionError("controlled sample must expose both find overloads")
    for entry in common:
        _select_inline_member(page, entry["id"])
        _native(old_index, entry["id"])
        expected = old_owner_url + "#" + _anchor(entry["id"])
        _expect_version_href(page, selector, expected)
        origin = page.url
        page.locator(selector).click()
        wait_for_declaration(page, expected)
        if not page.url.endswith("#" + _anchor(entry["id"])):
            raise AssertionError("version switch lost the selected member anchor")
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", "demo-v1")
        expect(page.locator(".cj-page-header__title-row h1")).to_have_text("TextCatalog")
        selected = page.locator('[data-cjdoc-member][id="' + _anchor(entry["id"]) + '"]')
        expect(selected).to_have_attribute("open", "")
        expect(selected).to_be_visible()
        page.go_back(wait_until="load")
        expect(page).to_have_url(origin)
    page.goto(page.url.split("#", 1)[0], wait_until="load")
    expected_owner = old_owner_url
    _expect_version_href(page, selector, expected_owner)
    expect(page.locator(selector)).to_have_text("demo-v1")
    added = [entry for entry in current_index["entries"]
             if entry.get("ownerId") == owner_id and entry["name"] == "nonEmpty"]
    if len(added) != 1 or any(entry["id"] == added[0]["id"] for entry in old_index["entries"]):
        raise AssertionError("controlled added member must be absent in demo-v1")
    _select_inline_member(page, added[0]["id"])
    expect(page.locator(selector)).to_have_attribute("data-cjdoc-version-state", "missing-symbol")
    page.locator(selector).click()
    wait_for_declaration(page, expected_owner)
    expect(page.locator(".cj-page-header__title-row h1")).to_have_text("TextCatalog")


def _copy_url(page, button) -> str:
    from playwright.sync_api import expect
    expected = urljoin(page.url, button.get_attribute("data-cjdoc-copy-link"))
    button.click()
    expect(button).to_have_attribute("data-cjdoc-copy-state", re.compile("copied|failed"))
    if button.get_attribute("data-cjdoc-copy-state") == "failed":
        field = button.locator("..").locator("[data-cjdoc-copy-link-fallback]")
        expect(field).to_have_value(declaration_url(expected))
        if not field.evaluate("node => node.readOnly && node.selectionStart === 0 && node.selectionEnd === node.value.length"):
            raise AssertionError("rejected copy must select the complete canonical address")
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
    if declaration_url(actual) != declaration_url(expected):
        raise AssertionError("Copy link clipboard contents differ from the canonical declaration")
    return actual


def check_readable_links(page, member_url: str, owner_id: str, member_id: str,
                         owner_url: str, standalone_url: str):
    from playwright.sync_api import expect
    for identity, expected in ((owner_id, owner_url), (member_id, standalone_url)):
        page.goto(member_url, wait_until="load")
        if identity == owner_id:
            button = page.locator(".cj-page-header__title-row [data-cjdoc-copy-link]").first
        else:
            member = page.locator(f'[id="{_anchor(member_id)}"]')
            button = member_action(member, "[data-cjdoc-copy-link]")
        copied = _copy_url(page, button)
        if "/symbols/" in urlsplit(copied).path:
            raise AssertionError("copy link must address the canonical declaration page, not an alias")
        if declaration_url(copied) != declaration_url(expected):
            raise AssertionError("copy link must address the selected declaration's own page")
        if identity != owner_id:
            suffix = "?theme=paper"
            page.goto(copied + suffix, wait_until="load")
            wait_for_declaration(page, expected)
            expect(page.locator("html")).to_have_attribute("data-theme", "paper")
            expect(page.locator(".cj-page-header__title-row h1")).to_have_text("add")
        else:
            # The type page copy carries the reader to the type body itself, and
            # the browser keeps the requested query in the address.
            page.goto(copied + "?theme=paper", wait_until="load")
            wait_for_declaration(page, expected)
            expect(page.locator("html")).to_have_attribute("data-theme", "paper")
            expect(page.locator(".cj-page-header__title-row h1")).to_have_text("TextCatalog")


def run_navigation_regressions(page, member_url: str, current_index: dict,
                               old_index: dict, owner_id: str, member_id: str,
                               old_owner_url: str, owner_url: str, standalone_url: str) -> list[str]:
    check_version_members(page, member_url, current_index, old_index, owner_id, old_owner_url)
    check_readable_links(page, member_url, owner_id, member_id, owner_url, standalone_url)
    return ["both find overload hrefs preserve exact native identity across versions",
            "clearing the member hash restores the type version href",
            "nonEmpty explicitly falls back to its surviving owner in demo-v1",
            "copied type and member addresses point at their own canonical declaration pages"]
