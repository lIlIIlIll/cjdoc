"""Real-browser regressions for filtering, reading position and history restoration."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit

from .browser import serve
from .browser_reading_navigation import run_navigation_regressions
from .site import Site, load_json


def _drawer(page, open: bool):
    if page.viewport_size["width"] > 760:
        return
    menu = page.locator("[data-cjdoc-menu]")
    if (menu.get_attribute("aria-expanded") == "true") != open:
        if open:
            menu.click()
        else:
            page.locator("[data-cjdoc-sidebar-close]").click()


def _filters(page):
    panel = page.locator("#cjdoc-search-filters")
    if not panel.is_visible():
        page.locator("[data-cjdoc-filter-toggle]").click()


def _visible_members(page):
    return page.locator("[data-cjdoc-member]:not([hidden])")


def _toc_matches_content(page):
    problems = page.evaluate("""() => {
      const problems = [];
      for (const link of document.querySelectorAll('[data-cjdoc-toc] [data-toc-target], [data-cjdoc-mobile-toc] [data-toc-target]')) {
        const target = document.getElementById(link.dataset.tocTarget);
        const hidden = Boolean(target && target.closest('[hidden]'));
        if (!target || link.closest('li').hidden !== hidden) problems.push(link.textContent);
      }
      return problems;
    }""")
    if problems:
        raise AssertionError("TOC exposes hidden or missing sections: " + ", ".join(problems))


def check_sidebar_filters(page):
    from playwright.sync_api import expect
    _drawer(page, True)
    field = page.locator("[data-cjdoc-context-filter]")
    bounds = field.evaluate("""node => {
      const parent = node.closest('.docs-sidebar').getBoundingClientRect();
      const child = node.getBoundingClientRect();
      return {visible: child.top >= parent.top && child.bottom <= parent.bottom};
    }""")
    if not bounds["visible"]:
        raise AssertionError("initial sidebar scroll hides the current declaration section")
    field.fill("find")
    expect(page.locator("[data-cjdoc-context-item]:visible")).to_have_count(2)
    field.fill("cjdoc_no_match_72fb")
    expect(page.locator("[data-cjdoc-context-item]:visible")).to_have_count(0)
    expect(page.locator("[data-cjdoc-context-empty]")).to_be_visible()
    field.fill("")
    expect(page.locator("[data-cjdoc-context-empty]")).to_be_hidden()
    package = page.locator("[data-cjdoc-sidebar-filter]")
    package.fill("parsing")
    expect(page.locator(".sidebar-package:visible")).to_have_count(1)
    package.fill("cjdoc_no_match_72fb")
    expect(page.locator(".sidebar-package:visible")).to_have_count(0)
    expect(page.locator("[data-cjdoc-sidebar-no-results]")).to_be_visible()
    package.fill("")
    expect(page.locator(".sidebar-package:visible")).to_have_count(3)
    _drawer(page, False)


def check_member_filters_and_actions(page):
    from playwright.sync_api import expect
    field = page.locator("[data-cjdoc-member-filter]")
    field.fill("find")
    expect(_visible_members(page)).to_have_count(2)
    _toc_matches_content(page)
    hidden_open = page.locator("[data-cjdoc-member][hidden][open]").count()
    page.locator("[data-cjdoc-members-expand]").click()
    expect(page.locator("[data-cjdoc-member]:not([hidden])[open]")).to_have_count(2)
    expect(page.locator("[data-cjdoc-members-expand]")).to_be_disabled()
    page.locator("[data-cjdoc-members-collapse]").click()
    expect(page.locator("[data-cjdoc-member]:not([hidden])[open]")).to_have_count(0)
    if page.locator("[data-cjdoc-member][hidden][open]").count() != hidden_open:
        raise AssertionError("bulk action changed filtered-out members")
    field.fill("cjdoc_no_match_72fb")
    expect(_visible_members(page)).to_have_count(0)
    expect(page.locator("[data-cjdoc-members-expand]")).to_be_disabled()
    expect(page.locator("[data-cjdoc-members-collapse]")).to_be_disabled()
    _toc_matches_content(page)
    field.fill("")
    origins = page.locator("[data-cjdoc-member-origin]")
    for value in origins.locator("option").evaluate_all("nodes => nodes.map(node => node.value)"):
        origins.select_option(value)
        _toc_matches_content(page)
    origins.select_option("")
    _toc_matches_content(page)


def _member_round_trip(page, member):
    origin = page.url
    summary = member.locator("summary").first
    if member.get_attribute("open") is None:
        summary.click()
    member.locator("a.member-permalink").click()
    page.wait_for_load_state("load")
    if unquote(page.url) == unquote(origin):
        raise AssertionError("standalone member navigation did not occur")
    page.go_back(wait_until="load")
    if unquote(page.url) != unquote(origin):
        raise AssertionError("Back changed the originating member route")


def check_member_history(page, member_url):
    from playwright.sync_api import expect
    field = page.locator("[data-cjdoc-member-filter]")
    for url in (member_url, member_url.split("#", 1)[0]):
        page.goto(url, wait_until="load")
        field.fill("find")
        member = page.locator('[data-cjdoc-member][data-member-name="find"]').first
        _member_round_trip(page, member)
        expect(field).to_have_value("find")
        expect(_visible_members(page)).to_have_count(2)
        expect(member).to_have_attribute("open", "")
        _toc_matches_content(page)


def check_search_and_sidebar_history(page, member_url):
    from playwright.sync_api import expect
    page.goto(member_url, wait_until="load")
    search = page.locator("[data-cjdoc-search]")
    search.fill("name:find")
    _filters(page)
    kind = page.locator("[data-cjdoc-kind]")
    kind.select_option("class")
    expect(page.locator("[data-cjdoc-results] li")).to_have_count(0)
    _member_round_trip(page, page.locator("[data-cjdoc-member][open]").first)
    expect(kind).to_have_value("class")
    search.fill("name:find")
    expect(page.locator("[data-cjdoc-results] li")).to_have_count(0)
    _filters(page)
    kind.select_option("function")
    expect(page.locator("[data-cjdoc-results] li")).to_have_count(2)
    contexts = page.locator(".search-context").all_text_contents()
    if any("cjdoc:module:" in value or "owner:" in value for value in contexts):
        raise AssertionError("search results expose redundant internal identities")
    signatures = page.locator(".search-result-signature").all_text_contents()
    if len(set(signatures)) != 2:
        raise AssertionError("search no longer distinguishes the two find overloads")
    search.press("Escape")
    _drawer(page, True)
    for selector in ("[data-cjdoc-context-filter]", "[data-cjdoc-sidebar-filter]"):
        page.locator(selector).fill("cjdoc_no_match_72fb")
    _drawer(page, False)
    _member_round_trip(page, page.locator("[data-cjdoc-member][open]").first)
    _drawer(page, True)
    expect(page.locator("[data-cjdoc-context-filter]")).to_have_value("cjdoc_no_match_72fb")
    expect(page.locator("[data-cjdoc-sidebar-filter]")).to_have_value("cjdoc_no_match_72fb")
    expect(page.locator("[data-cjdoc-context-item]:visible")).to_have_count(0)
    expect(page.locator(".sidebar-package:visible")).to_have_count(0)
    expect(page.locator("[data-cjdoc-context-empty]")).to_be_visible()
    expect(page.locator("[data-cjdoc-sidebar-no-results]")).to_be_visible()
    page.locator("[data-cjdoc-context-filter]").fill("")
    page.locator("[data-cjdoc-sidebar-filter]").fill("")
    _drawer(page, False)


def check_filtered_hash_and_header(page, member_url):
    from playwright.sync_api import expect
    page.goto(member_url, wait_until="load")
    anchor = unquote(urlsplit(member_url).fragment)
    target = page.locator('[data-cjdoc-member]').filter(has=page.locator("a.member-permalink"))
    target = next(item for item in target.all() if item.get_attribute("id") == anchor)
    page.locator("[data-cjdoc-member-filter]").fill("find")
    expect(target).to_be_hidden()
    _drawer(page, True)
    link = next(item for item in page.locator("[data-cjdoc-context-item]").all()
                if unquote(item.get_attribute("href") or "") == "#" + anchor)
    link.click()
    expect(page.locator("[data-cjdoc-member-filter]")).to_have_value("")
    expect(target).to_have_attribute("open", "")
    expect(target).to_be_visible()
    _toc_matches_content(page)
    page.wait_for_function("""id => {
      const top = document.getElementById(id).querySelector('summary').getBoundingClientRect().top;
      const header = document.querySelector('.site-nav').getBoundingClientRect().bottom;
      return top >= header - 1 && top < innerHeight;
    }""", arg=anchor)
    measured = page.evaluate("""() => ({actual: Math.ceil(document.querySelector('.site-nav').getBoundingClientRect().height),
      variable: parseFloat(document.documentElement.style.getPropertyValue('--cjdoc-header-height'))})""")
    if measured["actual"] != measured["variable"]:
        raise AssertionError("anchor offset did not track the real header height")


def run_reading_regressions(page, member_url: str) -> list[str]:
    page.goto(member_url, wait_until="load")
    check_sidebar_filters(page)
    check_member_filters_and_actions(page)
    check_member_history(page, member_url)
    check_search_and_sidebar_history(page, member_url)
    check_filtered_hash_and_header(page, member_url)
    return ["sidebar filters hide nonmatches and retain their state through Back",
            "both TOCs track text and origin filters, including zero matches and reset",
            "bulk expand/collapse acts only on visible members",
            "Back preserves member filters and disclosure state with and without a URL hash",
            "history-restored category filters agree with their visible select value",
            "search results retain distinct signatures without duplicate internal context",
            "same-hash links reveal excluded members below the measured sticky header"]


def run(site_path: Path, evidence_path: Path, executable=None, channel=None):
    from playwright.sync_api import sync_playwright
    site = Site(site_path)
    output = evidence_path.resolve()
    if output.is_relative_to(site.root) or site.root.is_relative_to(output):
        raise ValueError("reading evidence must be outside the generated site")
    output.mkdir(parents=True, exist_ok=False)
    manifest = load_json(site.file("showcase-features.json"))
    feature = next(item for item in manifest["features"] if item["id"] == "compact-members")
    results = []
    with ExitStack() as stack, sync_playwright() as playwright:
        bases = {prefix: stack.enter_context(serve(site.root, prefix)) for prefix in ("/", "/cjdoc-reading/")}
        bases["file"] = site.root.as_uri() + "/"
        options = {"headless": True, "args": ["--disable-features=BackForwardCache"]}
        if executable:
            options["executable_path"] = executable
        if channel:
            options["channel"] = channel
        browser = playwright.chromium.launch(**options)
        try:
            for target in feature["targets"]:
                current_index = load_json(site.file(f"examples/{target['locale']}/{target['version']}/symbol-index.json"))
                old_index = load_json(site.file(f"examples/{target['locale']}/demo-v1/symbol-index.json"))
                for mode, base in bases.items():
                    for width, height in ((1440, 960), (390, 844)):
                        key = f"{target['locale']}-{target['version']}-{mode.strip('/') or 'root'}-{width}"
                        print("reading regression: " + key, flush=True)
                        context = browser.new_context(viewport={"width": width, "height": height},
                                                      permissions=["clipboard-read", "clipboard-write"])
                        page = context.new_page()
                        page.set_default_timeout(10000)
                        errors = []
                        page.on("pageerror", lambda error: errors.append(str(error)))
                        try:
                            assertions = run_reading_regressions(page, base + target["resolved"]["href"])
                            assertions += run_navigation_regressions(page, base + target["resolved"]["href"],
                                                                    current_index, old_index,
                                                                    target["resolved"]["ownerSymbolId"],
                                                                    target["resolved"]["symbolId"])
                            if errors:
                                raise AssertionError("; ".join(errors))
                            results.append({"case": key, "status": "passed", "assertions": assertions})
                        except Exception as error:
                            page.screenshot(path=str(output / (key + "-failed.png")), full_page=True)
                            (output / "failure.json").write_text(json.dumps({"case": key, "error": str(error)}, ensure_ascii=False, indent=2), encoding="utf-8")
                            raise
                        finally:
                            context.close()
        finally:
            browser.close()
    (output / "results.json").write_text(json.dumps({"revision": manifest["revision"], "results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--chromium")
    parser.add_argument("--channel", help="optional installed browser channel, e.g. msedge")
    args = parser.parse_args(argv)
    run(args.site, args.evidence, args.chromium, args.channel)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
