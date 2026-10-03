"""Executable user journeys over the generated PocketKit showcase."""
from __future__ import annotations

from urllib.parse import unquote, urljoin, urlsplit

from .browser_support import Journey, click_and_return, copy_code, require_text, assert_native_symbol, assert_native_id, directory_navigation


def selected_member(journey: Journey):
    from playwright.sync_api import expect
    page, target = journey.page, journey.target
    anchor = unquote(urlsplit(target["resolved"]["href"]).fragment)
    matches = [item for item in page.locator("details[data-cjdoc-member]").all()
               if item.get_attribute("id") == anchor]
    if len(matches) != 1:
        raise AssertionError("deep link must identify exactly one native inline member")
    current = matches[0]
    expect(current).to_have_attribute("open", "")
    expect(current).to_be_visible()
    require_text(current, target["resolved"]["signature"])
    return current


def members(journey: Journey):
    from playwright.sync_api import expect
    page, current = journey.page, selected_member(journey)
    name = journey.target["resolved"]["memberName"]
    siblings = page.locator("details[data-cjdoc-member]").filter(
        has=page.locator("summary", has_text="add("))
    # The controlled sample promises a real overload group, not just any member.
    candidates = [item for item in siblings.all()
                  if item.get_attribute("data-member-name") == name
                  and item.get_attribute("id") != current.get_attribute("id")]
    if not candidates:
        raise AssertionError("overload demonstration needs two native overloads")
    second = candidates[0]
    if second.get_attribute("open") is None:
        journey.expand(second)
    expect(current).to_have_attribute("open", "")
    expect(second).to_have_attribute("open", "")
    require_text(current, "String", "增加一")
    require_text(second, "Int64", "radix", "IllegalArgumentException")
    field = page.locator("[data-cjdoc-member-filter]")
    field.fill("cjdoc_no_such_member_58b0e6")
    expect(current).not_to_be_visible()
    def filter_match():
        field.fill(name)
        expect(current).to_be_visible()
        expect(second).to_be_visible()
    journey.measured("queryMs", filter_match, field)
    field.fill("")
    copy_code(journey, current.locator(".code-copy").first)
    # Follow an ordinary link and use real Back/Forward, preserving both contracts.
    origin = page.url
    standalone = current.locator("a.member-permalink")
    if standalone.count() != 1:
        standalone = current.get_by_role("link", name="Open standalone page" if journey.target["locale"] == "en" else "打开独立页面")
    journey.click(standalone)
    destination = page.url
    require_text(page.locator("main"), "add", "String")
    journey.back(origin)
    expect(current).to_have_attribute("open", "")
    journey.activations += 1
    page.go_forward(wait_until="load")
    if page.url != destination:
        raise AssertionError("Forward did not restore the standalone overload route")
    journey.back(origin)
    directory_navigation(journey)
    journey.assertions += ["the exact deep-linked overload opened with its complete source contract",
                           "two distinct overloads stay expanded together through filtering; browser history restores the selected route"]


def types(journey: Journey):
    from playwright.sync_api import expect
    page, origin = journey.page, journey.page.url
    link = page.locator(".page-header .symbol-summary a").filter(has_text="pocketkit.io.TextReader").first
    expect(link).to_be_visible()
    journey.click(link)
    reader = page.url
    assert_native_symbol(journey, "pocketkit.io.TextReader")
    require_text(page.locator("main"), "TextReader", "Readable", "调用方")
    link = page.get_by_role("link", name="pocketkit.io.Readable", exact=True)
    journey.click(link)
    assert_native_symbol(journey, "pocketkit.io.Readable")
    require_text(page.locator("main"), "Readable", "read", "close")
    journey.back(reader)
    journey.back(origin)
    journey.assertions.append("the function return-type link leads to TextReader, its Readable relation, and back")


def contracts(journey: Journey):
    from playwright.sync_api import expect
    page, current = journey.page, selected_member(journey)
    require_text(current, "start", "limit", "20", "Array<?String>", "IllegalArgumentException")
    for name, expected in (("chunks", "Array<Array<String>>"), ("at", "index")):
        member = page.locator(f'details[data-cjdoc-member][data-member-name="{name}"]').first
        journey.expand(member)
        expect(member).to_have_attribute("open", "")
        require_text(member, expected, "IllegalArgumentException")
    if journey.target["locale"] == "zh-CN":
        require_text(current, "参数", "返回值")
    journey.assertions.append("named parameters, defaults, optional/nested generic returns and exception boundaries are rendered")


def resources(journey: Journey):
    current = selected_member(journey)
    require_text(current, "IllegalStateException", "关闭", "None", "position")
    require_text(journey.page.locator("main"), "调用方", "没有文件描述符", "同步")
    close = journey.page.locator('details[data-member-name="close"]').first
    journey.expand(close)
    require_text(close, "再次", "closed", "操作系统资源")
    journey.assertions.append("read and close expose the source-authored in-memory ownership and closed-session exception contract")


def guides(journey: Journey):
    page, guide = journey.page, journey.page.url
    links = page.locator("main a").filter(has_text="TextCatalog.add")
    if not links.count():
        raise AssertionError("guide has no bound overload link")
    journey.click(links.first)
    require_text(page.locator("main"), "public func add(value: String): Unit")
    assert_native_symbol(journey, "pocketkit.TextCatalog.add", "public func add(value: String): Unit")
    back = page.locator("main a").filter(has_text="Catalogue and lifetime").first
    if not back.count():
        raise AssertionError("selected member has no related-guide backlink")
    journey.click(back)
    if unquote(page.url.split("#")[0]) != unquote(guide.split("#")[0]):
        raise AssertionError("related guide did not return to the exact bound concept page")
    copy_code(journey)
    journey.assertions.append("the guide selects the String overload, whose own related-guide link returns to this guide")


def search(journey: Journey):
    from playwright.sync_api import expect
    page = journey.page
    field, results = page.locator("[data-cjdoc-search]"), page.locator("[data-cjdoc-results] a")
    page.keyboard.press("Control+k")
    expect(field).to_be_focused()
    for query, expected in (("name:TextCatalog", "TextCatalog"), ("param:String", "String"),
                            ("return:TextReader", "TextReader"), ("package:pocketkit.io name:Token", "pocketkit.io"),
                            ("package:pocketkit.parsing name:Token", "pocketkit.parsing")):
        def query_result():
            field.fill(query)
            expect(results.first).to_be_visible()
            require_text(results.first, expected)
        journey.measured("queryMs", query_result, field)
    field.fill("unrecognized:TextCatalog")
    expect(results).to_have_count(0)
    expect(page.locator("[data-cjdoc-search-status]")).to_be_visible()
    require_text(page.locator("[data-cjdoc-search-status]"), "name:", "return:")
    field.fill("cjdoc_no_such_symbol_58b0e6")
    expect(results).to_have_count(0)
    expect(page.locator("[data-cjdoc-search-status]")).to_be_visible()
    field.fill("name:openText")
    origin = page.url
    page.keyboard.press("ArrowDown")
    expect(field).to_have_attribute("aria-activedescendant", "cjdoc-search-result-0")
    destination = urljoin(page.url, results.first.get_attribute("href"))
    journey.activations += 1
    page.keyboard.press("Enter")
    expect(page).to_have_url(destination)
    page.wait_for_load_state("load")
    assert_native_symbol(journey, "pocketkit.io.openText")
    journey.back(origin)
    journey.assertions.append("keyboard search exercises native name, parameter, return and package scopes plus explicit invalid/no-match states")


def versions(journey: Journey):
    from playwright.sync_api import expect
    page, origin = journey.page, journey.page.url
    version = journey.target["version"]
    other = "demo-v1" if version == "demo-v2" else "demo-v2"
    link = page.locator(".cjdoc-version-selector a").filter(has_text=other).first
    label = link.inner_text()
    expected = urljoin(origin, link.get_attribute("href"))
    journey.click(link)
    if page.url != expected:
        raise AssertionError("version switch did not follow its native identity-mapped route")
    expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", other)
    from .site import load_json
    index_url = urljoin(page.url, page.locator('[data-machine-format="symbols"]').get_attribute("href"))
    index = load_json(journey.local_path(index_url))
    matches = [entry for entry in index["entries"] if entry["id"] == journey.target["resolved"]["symbolId"]]
    if not matches:
        if "symbol unavailable" not in label or page.url != urljoin(index_url, "index.html"):
            raise AssertionError("removed native identity must be explicitly unavailable and reach the declared version overview")
    elif len(matches) == 1:
        if "symbol unavailable" in label or unquote(page.url) != unquote(urljoin(index_url, matches[0]["href"])):
            raise AssertionError("version switch must preserve the exact common native identity")
        require_text(page.locator("main"), journey.target["signature"])
    else:
        raise AssertionError("version index has an ambiguous native symbol identity")
    journey.back(origin)
    expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", version)
    journey.assertions.append("native version identity mapping preserves the common member or explicitly labels its absence")


def external(journey: Journey):
    page = journey.page
    local = page.locator("main a").filter(has_text="Stamp")
    local = next((item for item in local.all() if item.inner_text().strip() == "Stamp"), None)
    if local is None:
        raise AssertionError("local-first Stamp reference is missing")
    original = page.url
    journey.click(local)
    assert_native_symbol(journey, "pocketkit.Stamp")
    journey.back(original)
    for name in ("pocket_support.SourceLabel", "pocket_support.SourceLabel.text"):
        link = page.locator("main a").filter(has_text=name)
        exact = next((item for item in link.all() if item.inner_text().strip() == name), None)
        if exact is None:
            raise AssertionError("independent dependency reference is missing: " + name)
        journey.click(exact)
        assert_native_symbol(journey, name)
        from playwright.sync_api import expect
        expect(page.locator("body")).to_have_attribute("data-cjdoc-doc-version", "support-v1")
        journey.back(original)
    journey.assertions.append("local Stamp and independent support-v1 SourceLabel/type-member links retain their scopes and versions")


def downloads(journey: Journey):
    from playwright.sync_api import expect
    journey.download("[data-source-download]")
    if journey.mode == "http":
        journey.download("[data-offline-download]")
    else:
        expect(journey.page.locator("[data-offline-download]")).to_have_attribute("aria-disabled", "true")
    copy_code(journey, journey.page.locator("[data-showcase-copy]"))
    journey.assertions.append("source archive download bytes match the published ZIP; HTTP also downloads the exact offline ZIP")


def extension(journey: Journey):
    page = journey.page
    require_text(page.locator("main"), "byteLength")
    links = page.locator("main a").filter(has_text="Entry")
    if not links.count():
        raise AssertionError("extension member has no native owner/provenance link")
    from .site import load_json
    ir = load_json(journey.site.file(journey.target["docIr"]))
    source = next(item for item in ir["declarations"] if item["id"] == journey.target["resolved"]["symbolId"])
    if not source.get("ownerId"):
        raise AssertionError("extension member lacks native owner provenance")
    old = page.url
    journey.click(links.first)
    assert_native_id(journey, source["ownerId"])
    require_text(page.locator("main"), "String", "extend")
    journey.back(old)
    journey.assertions.append("extension provenance leads to the explicit source String constraint without inferred applicability")


def authoring(journey: Journey):
    page = journey.page
    require_text(page.locator("main"), "cjdoc serve --project . --port 8080", "/__cjdoc/status.json", "Static GitHub Pages")
    code = page.locator("pre").filter(has_text="cjdoc serve").locator(".code-copy")
    copy_code(journey, code)
    evidence = journey.raw('[data-authoring-evidence]', "cjdoc.showcase-authoring/1")
    if evidence.get("status") != "passed":
        raise AssertionError("local authoring report does not record a successful native serve/rebuild")
    from .site import load_json
    manifest = load_json(journey.site.file("showcase-features.json"))
    feature = next(item for item in manifest["features"] if item["id"] == "local-authoring")
    if evidence.get("input") not in feature["inputs"]:
        raise AssertionError("authoring report input does not match the revision-bound managed source")
    before, after = evidence.get("before", {}), evidence.get("after", {})
    for status in (before, after):
        if status.get("schemaVersion") != "cjdoc.serve-status/1" or status.get("status") != "ok":
            raise AssertionError("authoring report is missing a successful native serve status")
    if after.get("successfulBuilds", 0) <= before.get("successfulBuilds", 0):
        raise AssertionError("native serve evidence does not show a successful rebuild after modification")
    journey.assertions.append("the local authoring guide exposes and copies its exact command and explains the static/runtime boundary")


def machine(journey: Journey):
    target = journey.target
    ir = journey.raw('[data-machine-format="json"]', "cjdoc.doc-ir/11")
    selected = [item for item in ir["declarations"] if item["id"] == target["resolved"]["symbolId"]]
    if len(selected) != 1 or selected[0]["headerSpelling"] != target["signature"]:
        raise AssertionError("HTML and machine Doc IR disagree on the selected native declaration")
    navigation = journey.raw('[data-machine-format="navigation"]', "cjdoc.navigation-index/1")
    if navigation["project"]["version"] != target["version"]:
        raise AssertionError("navigation index is for a different documentation version")
    rows = [item for item in navigation["pages"] if item.get("symbolId") == selected[0]["id"]]
    if len(rows) != 1 or not target["resolved"]["href"].endswith(rows[0]["href"]):
        raise AssertionError("HTML route and native navigation identity disagree")
    markdown = journey.raw('[data-machine-format="markdown"]')
    llms = journey.raw('[data-machine-format="llms-full"]')
    if selected[0]["headerSpelling"] not in markdown:
        raise AssertionError("machine Markdown does not contain the exact selected source header")
    if ("# `" + selected[0]["qualifiedName"] + "`") not in markdown:
        raise AssertionError("machine Markdown's declaration heading disagrees with the exact native selection")
    metadata = journey.page.locator(".page-header .declaration-metadata")
    if metadata.get_attribute("open") is None:
        journey.click(metadata.locator("summary"))
    require_text(metadata, "Symbol ID: " + selected[0]["id"])
    for required in ("Version: " + target["version"], "Stable id: " + selected[0]["id"],
                     "Page: " + rows[0]["href"], selected[0]["headerSpelling"]):
        if required not in llms:
            raise AssertionError("llms output lacks the exact declaration identity/version/route: " + required)
    journey.assertions.append("visible artifact links agree with the HTML native identity, signature, route and documentation version")


JOURNEYS = {"members": members, "types": types, "contracts": contracts, "resources": resources,
            "guides": guides, "search": search, "versions": versions, "external": external,
            "downloads": downloads, "extension": extension, "authoring": authoring, "machine": machine}
