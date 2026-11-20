"""Real-browser capability check for canonical API addresses and historical aliases.

Runs once against the final PocketKit publication rather than per feature
scenario. It addresses files by their published identity (navigation index and
emitted HTML), never by recomputing a SymbolId or an alias filename.
"""
from __future__ import annotations

import re
from pathlib import PurePosixPath
from urllib.parse import quote, unquote, urljoin, urlsplit

from .browser_support import declaration_url, wait_for_declaration
from .routes import public_api_file
from .site import ContractError, Site, load_json

HTTP = "/"


def _member_target(site: Site) -> dict:
    manifest = load_json(site.file("showcase-features.json"))
    for feature in manifest["features"]:
        if feature.get("demonstration") != "available":
            continue
        for target in feature["targets"]:
            resolved = target.get("resolved")
            if (target.get("placement") == "member" and isinstance(resolved, dict)
                    and resolved.get("symbolId") and resolved.get("ownerSymbolId")
                    and resolved.get("memberPageHref")):
                return {"feature": feature["id"], "target": target}
    raise ContractError("canonical API route check needs one resolved inline member target")


def _body(site: Site, name: str, symbol_id: str) -> None:
    document = site.documents.get(name)
    if document is None:
        raise ContractError(f"canonical API check is missing a generated body: {name}")
    if document.route == "symbol-alias" or document.alias_target is not None:
        raise ContractError(f"canonical API check resolved a historical alias: {name}")
    if document.symbol_id != symbol_id:
        raise ContractError(f"canonical API body lost its declaration identity: {name}")


def _alias_files(site: Site, symbol_id: str) -> list[tuple[str, str]]:
    """Both published alias generations, keyed by the declaration they reach."""
    by_generation: dict[str, list[tuple[str, str]]] = {"legacy": [], "readable": []}
    for name, document in sorted(site.documents.items()):
        if document.alias_target is None:
            continue
        resolved = site.local_link(name, document.alias_target)
        if resolved is None:
            raise ContractError(f"historical alias target is not a local page: {name}")
        target = site.documents.get(resolved[0])
        if target is None or target.symbol_id != symbol_id:
            continue
        generation = "legacy" if PurePosixPath(name).name.startswith("symbol-") else "readable"
        by_generation[generation].append((name, resolved[0]))
    if not by_generation["legacy"] or not by_generation["readable"]:
        raise ContractError("canonical API check needs both historical alias generations")
    return by_generation["legacy"] + by_generation["readable"]


def _selection_file(site: Site, member_file: str) -> tuple[str, list[str]]:
    directory = PurePosixPath(member_file).parent.parent
    selection = (directory / "index.html").as_posix()
    document = site.documents.get(selection)
    if document is None or not (document.page_id or "").startswith("api-choice:"):
        raise ContractError("overload family has no generated selection page: " + member_file)
    members = set()
    for href in document.links:
        resolved = site.local_link(selection, href)
        if resolved is None or not resolved[0].endswith("/index.html"):
            continue
        if PurePosixPath(resolved[0]).parent.parent == directory:
            members.add(resolved[0])
    if len(members) < 2:
        raise ContractError("selection page must list every overload of its family")
    return selection, sorted(members)


def _declared_path(value: str) -> str:
    """Path only: the address bar's canonical form, without reader state."""
    return unquote(urlsplit(declaration_url(value)).path)


def _body_identity(page, symbol_id: str) -> None:
    from playwright.sync_api import expect
    body = page.locator("body")
    expect(body).to_have_attribute("data-cjdoc-symbol-id", symbol_id)
    if body.get_attribute("data-cjdoc-route") != "api":
        raise AssertionError("canonical declaration address is not an API body")


def _copy_address(page, button, expected: str) -> str:
    from playwright.sync_api import expect
    declared = urljoin(page.url, button.get_attribute("data-cjdoc-copy-link"))
    if "/symbols/" in urlsplit(declared).path:
        raise AssertionError("copy control points at a historical alias")
    if declaration_url(declared) != declaration_url(expected):
        raise AssertionError("copy control address differs from the declaration body")
    button.click()
    expect(button).to_have_attribute("data-cjdoc-copy-state", "copied")
    actual = page.evaluate("navigator.clipboard.readText()")
    if urlsplit(actual).path.endswith("/index.html") or declaration_url(actual) != declaration_url(expected):
        raise AssertionError("clipboard address differs from the canonical declaration")
    return actual


def _reject_address(page, button, expected: str) -> None:
    from playwright.sync_api import expect
    before = page.url
    page.evaluate("""() => {
      Object.defineProperty(navigator, 'clipboard', {configurable: true,
        value: {writeText: () => Promise.reject(new Error('denied'))}});
      document.execCommand = () => false;
    }""")
    button.click()
    expect(button).to_have_attribute("data-cjdoc-copy-state", "failed")
    field = button.locator("xpath=..").locator("[data-cjdoc-copy-link-fallback]")
    expect(field).to_have_value(declaration_url(expected))
    if not field.evaluate("node => node.readOnly && node.selectionStart === 0 "
                          "&& node.selectionEnd === node.value.length"):
        raise AssertionError("rejected clipboard must expose the complete canonical address")
    if page.url != before:
        raise AssertionError("copying a rejected link changed the reader route")


def _short_directory(page, base: str, file: str, symbol_id: str) -> None:
    directory = base + file[: -len("index.html")]
    page.goto(directory.rstrip("/"), wait_until="load")
    if not urlsplit(page.url).path.endswith("/"):
        raise AssertionError("static hosting must serve the published directory")
    _body_identity(page, symbol_id)
    page.goto(directory, wait_until="load")
    _body_identity(page, symbol_id)


def check_canonical_api_routes(browser, site: Site, offline: Site, bases: dict[str, str]) -> None:
    """Exercise HTTP short addresses, offline files, aliases and copy controls."""
    from playwright.sync_api import expect

    found = _member_target(site)
    resolved = found["target"]["resolved"]
    resolved_href = resolved["href"]
    if "#" not in resolved_href:
        raise ContractError("inline member target lost its owner anchor")
    owner_file, anchor = resolved_href.split("#", 1)
    member_file = resolved["memberPageHref"]
    owner_id, member_id = resolved["ownerSymbolId"], resolved["symbolId"]
    owner_file = public_api_file(site, found["target"], {"href": owner_file, "symbolId": owner_id})
    _body(site, owner_file, owner_id)
    _body(site, member_file, member_id)
    _body(offline, owner_file, owner_id)
    _body(offline, member_file, member_id)
    if "/symbols/" in owner_file or "/symbols/" in member_file:
        raise ContractError("resolved declaration bodies must not be aliases")
    selection, members = _selection_file(site, member_file)
    if member_file not in members:
        raise ContractError("selection page omits the resolved overload")
    aliases = _alias_files(site, owner_id)
    offline_aliases = _alias_files(offline, owner_id)

    base = bases[HTTP]
    context = browser.new_context(viewport={"width": 1280, "height": 900},
                                  permissions=["clipboard-read", "clipboard-write"])
    try:
        page = context.new_page()
        page.set_default_timeout(10000)
        _short_directory(page, base, owner_file, owner_id)
        page.goto(base + owner_file + "?theme=paper#" + quote(anchor), wait_until="load")
        wait_for_declaration(page, base + owner_file)
        expect(page.locator("html")).to_have_attribute("data-theme", "paper")
        details = page.locator('details[data-cjdoc-member][id="' + anchor + '"]')
        expect(details).to_have_attribute("open", "")
        expect(details).to_be_visible()

        page.goto(base + member_file, wait_until="load")
        _body_identity(page, member_id)
        wait_for_declaration(page, base + member_file)
        copied = _copy_address(page, page.locator("[data-cjdoc-copy-link]").first,
                               base + member_file)
        if _declared_path(copied) == _declared_path(base + owner_file):
            raise AssertionError("member copy collapsed into its owner page")

        page.goto(base + owner_file, wait_until="load")
        _copy_address(page, page.locator("[data-cjdoc-copy-link]").first, base + owner_file)

        # A real type page copies an inline member to that member's own page.
        member_button = page.locator(
            'details[data-cjdoc-member][id="' + anchor + '"]'
            ' ~ .cj-member-actions [data-cjdoc-copy-link]').first
        if not member_button.count():
            row = page.locator("div.cj-member-row").filter(
                has=page.locator('details[data-cjdoc-member][id="' + anchor + '"]'))
            member_button = row.locator("[data-cjdoc-copy-link]").first
        member_button.locator("xpath=ancestor::div[contains(@class, 'cj-member-row')]").hover()
        _copy_address(page, member_button, base + member_file)

        page.goto(base + selection, wait_until="load")
        expect(page.locator("body")).to_have_attribute("data-cjdoc-route", "api-choice")
        if page.locator("body").get_attribute("data-cjdoc-symbol-id"):
            raise AssertionError("selection page must not fabricate a SymbolId")
        options = page.locator('main section[aria-labelledby="api-options"] a[href]')
        listed = options.evaluate_all("nodes => nodes.map(node => node.getAttribute('href'))")
        expected_links = {_declared_path(urljoin(base, member)) for member in members}
        actual_links = {_declared_path(urljoin(page.url, href)) for href in listed}
        if expected_links != actual_links:
            raise AssertionError("selection page did not expose the exact overload routes")
        for option in options.all():
            expect(option).to_be_visible()

        for alias, target in aliases:
            page.goto(urljoin(base, alias) + "?theme=paper#" + quote(anchor), wait_until="load")
            wait_for_declaration(page, urljoin(base, target))
            parts = urlsplit(page.url)
            if parts.query != "theme=paper" or unquote(parts.fragment) != anchor:
                raise AssertionError("historical alias did not preserve query and fragment")
            expect(page.locator("html")).to_have_attribute("data-theme", "paper")
            _body_identity(page, owner_id)

        page.goto(base + owner_file, wait_until="load")
        # Where the publication ships both languages, its own switch must reach
        # the same declaration in the other scope instead of dropping to a home.
        switches = page.locator('.cj-lang-toggle a[hreflang][href]').evaluate_all(
            "nodes => nodes.map(node => ({lang: node.getAttribute('hreflang'),"
            " href: node.getAttribute('href')}))")
        for switch in switches:
            if switch["lang"] == site.documents[owner_file].language:
                continue
            destination = urljoin(page.url, switch["href"])
            mount, address = urlsplit(base), urlsplit(destination)
            if ((address.scheme, address.netloc) != (mount.scheme, mount.netloc)
                    or not address.path.startswith(mount.path)):
                raise AssertionError("language switch leaves the deployment mount")
            relative = unquote(address.path[len(mount.path):])
            if relative.endswith("/"):
                relative += "index.html"
            target = site.documents.get(relative)
            if target is None:
                raise AssertionError("language switch points outside the publication: " + destination)
            if target.alias_target is not None or target.symbol_id != owner_id:
                raise AssertionError("language switch lost the declaration identity")
            if target.language == site.documents[owner_file].language:
                raise AssertionError("language switch did not leave the current language")
            page.goto(destination, wait_until="load")
            _body_identity(page, owner_id)
            wait_for_declaration(page, destination)
            page.go_back(wait_until="load")
            page.wait_for_load_state("load")

        reject = browser.new_context(viewport={"width": 1280, "height": 900})
        try:
            rejected = reject.new_page()
            rejected.set_default_timeout(10000)
            rejected.goto(base + owner_file, wait_until="load")
            _reject_address(rejected, rejected.locator("[data-cjdoc-copy-link]").first,
                            base + owner_file)
        finally:
            reject.close()

        # Without scripts the alias's own static link still reaches the body.
        static = browser.new_context(viewport={"width": 390, "height": 844},
                                     java_script_enabled=False)
        try:
            no_script = static.new_page()
            no_script.set_default_timeout(10000)
            no_script.goto(base + aliases[0][0], wait_until="load")
            expect(no_script.locator("body")).to_have_attribute("data-cjdoc-route", "symbol-alias")
            no_script.locator("a[data-cjdoc-alias-target]").click()
            no_script.wait_for_load_state("load")
            _body_identity(no_script, owner_id)
        finally:
            static.close()
    finally:
        context.close()

    file_base = offline.root.as_uri() + "/"
    context = browser.new_context(viewport={"width": 1280, "height": 900})
    try:
        page = context.new_page()
        page.set_default_timeout(10000)
        page.goto(file_base + owner_file, wait_until="load")
        if not urlsplit(page.url).path.endswith("/index.html"):
            raise AssertionError("offline navigation must keep the explicit index.html file")
        _body_identity(page, owner_id)
        page.goto(file_base + member_file, wait_until="load")
        if not urlsplit(page.url).path.endswith("/index.html"):
            raise AssertionError("offline member navigation must keep its explicit file")
        _body_identity(page, member_id)
        for alias, target in offline_aliases:
            page.goto(file_base + alias + "?theme=paper#" + quote(anchor), wait_until="load")
            wait_for_declaration(page, file_base + target)
            parts = urlsplit(page.url)
            if not parts.path.endswith("/index.html"):
                raise AssertionError("offline alias must land on the explicit generated file")
            if parts.query != "theme=paper" or unquote(parts.fragment) != anchor:
                raise AssertionError("offline alias did not preserve query and fragment")
            _body_identity(page, owner_id)
    finally:
        context.close()
