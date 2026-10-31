#!/usr/bin/env python3
"""Real-browser responsive/semantic/accessibility matrix for package indexes.

Generates the original package shapes plus declaration-group and declaration-tag
fixtures, then drives real Chromium over file:// and mounted /docs/ sites.

The matrix checks visible heading chains (and expanded details), unique IDs and
historical anchors, responsive layouts and WCAG AA contrast, independent row/tag
keyboard and pointer interactions, exact scoped tag search/facets, and local
canonical overload membership/counts. Group and tag fixtures run in both
published locales and both transports; the original package checks remain.

Playwright is a hard requirement: a missing browser fails the run rather than
silently shrinking the matrix.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from urllib.parse import parse_qs, urlencode, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_stage

# Every fixture is paired with the anchors and tag identities its own sources
# must publish. These expectations prevent a renderer from shrinking coverage
# when a declaration category, historical alias, or classification disappears.
FIXTURE_ANCHORS = {
    "package_index": ("declarations", "classes"),
    "basic": ("declarations", "classes", "structs", "interfaces", "enums",
              "aliases", "functions", "extensions"),
    "declaration-groups": ("declarations", "api-group-10-application",
                           "api-group-20-generated-spi", "api-group-30-first-party-internal",
                           "api-kind-14-10-application-classes",
                           "api-kind-14-10-application-functions",
                           "api-kind-23-30-first-party-internal-classes"),
    "declaration-tags": ("declarations", "api-group-10-query", "api-group-20-state",
                         "api-kind-8-10-query-classes", "api-kind-8-20-state-classes"),
}
VIEWPORTS = (("desktop", 1440, 900), ("tablet", 1024, 768), ("mobile", 390, 844))
GROUP_TAG_VIEWPORTS = (("compact-tablet", 960, 900),)
THEMES = ("light", "dark")
LOCALES = ("en", "zh-CN")
MULTILINGUAL_FIXTURES = {"declaration-groups": "groups", "declaration-tags": "tags"}
FIXTURES = (("package_index", "single-category"), ("basic", "multi-category"),
            ("declaration-groups", "author-groups"),
            ("declaration-tags", "author-groups-and-tags"))

CONTRAST_PROBE = r"""() => {
  const parse = value => {
    const match = /rgba?\(([^)]+)\)/.exec(value || '');
    if (!match) return null;
    const parts = match[1].split(',').map(part => parseFloat(part.trim()));
    return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
  };
  const lum = colour => {
    const channel = value => { value /= 255;
      return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4); };
    return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b);
  };
  const background = node => {
    let current = node;
    while (current) {
      const colour = parse(getComputedStyle(current).backgroundColor);
      if (colour && colour.a === 1) return colour;
      current = current.parentElement;
    }
    return { r: 255, g: 255, b: 255, a: 1 };
  };
  const ratio = (node) => {
    const style = getComputedStyle(node);
    const foreground = parse(style.color);
    if (!foreground) return null;
    const behind = background(node);
    const light = Math.max(lum(foreground), lum(behind));
    const dark = Math.min(lum(foreground), lum(behind));
    return { ratio: (light + 0.05) / (dark + 0.05), size: parseFloat(style.fontSize) };
  };
  // Audit the elements that actually paint glyphs. A signature container holds
  // `.code-*` syntax spans and `.type-link` anchors whose colours differ from the
  // container's own `--muted`, so measuring only the container would miss a
  // low-contrast keyword or link colour.
  const candidates = [
    ...document.querySelectorAll('.declaration-group h2, .declaration-group h3'),
    ...document.querySelectorAll('.declaration-row-link code'),
    ...document.querySelectorAll('.declaration-signature, .declaration-signature .code-keyword,' +
      ' .declaration-signature .code-type, .declaration-signature .code-string,' +
      ' .declaration-signature .code-number, .declaration-signature .code-comment,' +
      ' .declaration-signature .type-link, .declaration-row-link .type-link'),
    ...document.querySelectorAll('.declaration-description'),
    ...document.querySelectorAll('.declaration-tag-badge, .declaration-group-badge'),
    ...document.querySelectorAll('.page-header h1 code, .badge'),
  ];
  return candidates.map(node => {
    const value = ratio(node);
    return value === null ? null : {
      text: (node.textContent || '').trim().slice(0, 24),
      cls: String(node.className || node.tagName).slice(0, 32),
      ratio: Math.round(value.ratio * 1000) / 1000,
      size: value.size,
    };
  }).filter(Boolean);
}"""

LAYOUT_PROBE = r"""() => {
  const rows = [...document.querySelectorAll('.declaration-row')];
  const firstScreen = rows.filter(row => {
    const r = row.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight;
  }).length;
  const list = document.querySelector('.declaration-list');
  return {
    overflow: document.documentElement.scrollWidth > innerWidth + 1,
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth, rows: rows.length, firstScreen,
    listHeight: list ? Math.round(list.getBoundingClientRect().height) : 0,
  };
}"""

STRUCTURE_PROBE = r"""() => {
  const allHeadings = [...document.querySelectorAll('main h1, main h2, main h3, main h4, main h5, main h6')];
  // Closed details bodies are not part of the rendered heading sequence. Keep
  // their headings for per-detail assertions, but do not treat hidden markup as
  // a visible skipped-level transition.
  const headings = allHeadings.filter(node =>
    !node.closest('details:not([open])') && !node.closest('[hidden]') &&
    node.getClientRects().length > 0).map(node => Number(node.tagName.slice(1)));
  const anchors = [...document.querySelectorAll('[id]')].map(node => node.id);
  const groups = [...document.querySelectorAll('[data-cjdoc-toc-role="group"]')]
    .map(node => ({ id: node.id, level: Number(node.tagName.slice(1)),
                    text: node.textContent.trim() }));
  return { h1: document.querySelectorAll('main h1').length, headings, anchors, groups,
           declarations: !!document.getElementById('declarations') };
}"""

TAG_SEARCH_PROBE = r"""() => {
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  const pathOf = href => new URL(href, document.baseURI).pathname;
  const resultRows = [...document.querySelectorAll('[data-cjdoc-results] > li')].map(item => {
    const link = item.querySelector('a');
    const href = link && pathOf(link.href);
    const entry = href && index.entries.find(candidate => pathOf(candidate.href) === href);
    return entry ? {
      canonicalId: entry.canonicalId, name: entry.name, ownerName: entry.ownerName || '',
      kind: entry.kind, qualifiedName: entry.qualifiedName, parameterTypes: entry.parameterTypes,
      returnType: entry.returnType || '',
      tagIds: (entry.classification?.tags || []).map(tag => tag.id),
      renderedName: item.querySelector('.search-result-name')?.textContent.trim() || '',
      renderedSignature: item.querySelector('.search-result-signature')?.textContent.trim() || ''
    } : null;
  });
  const facets = [...document.querySelectorAll('[data-cjdoc-search-facets] [data-cjdoc-search-facet]')]
    .map(link => {
      const match = link.textContent.match(/\((\d+)\)$/);
      return {
        id: link.dataset.cjdocTagId, count: match ? Number(match[1]) : null,
        selected: link.getAttribute('aria-current') === 'true',
        moduleId: link.dataset.cjdocFacetModuleId,
        snapshotId: link.dataset.cjdocFacetSnapshotId
      };
    });
  return {
    index: {
      scope: index.scope,
      modules: index.modules.map(module => ({moduleId: module.moduleId, moduleName: module.moduleName}))
    },
    resultRows,
    facetsHidden: document.querySelector('[data-cjdoc-search-facets]')?.hidden ?? true,
    facets
  };
}"""

TAG_MEMBER_PROBE = r"""() => {
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  const signatures = globalThis.__CJDOC_SEARCH_SIGNATURES__ || {};
  const symbolAnchor = symbolId => "symbol-" +
    [...new TextEncoder().encode(symbolId)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  const rows = [...document.querySelectorAll('[data-cjdoc-member-browser] [data-cjdoc-member]')];
  const visible = row => !row.hidden && !row.closest('.member-row')?.hidden;
  const identity = row => {
    const id = row.dataset.memberSymbolId;
    const entry = index.entries.find(candidate => candidate.canonicalId === id);
    return {
      id, visible: visible(row), name: row.dataset.memberName,
      ownerName: entry?.ownerName || '', qualifiedName: entry?.qualifiedName || null,
      parameterTypes: entry?.parameterTypes || null, returnType: entry?.returnType || '',
      tagIds: (entry?.classification?.tags || []).map(tag => tag.id),
      signature: signatures[id] || ''
    };
  };
  const readRows = rows.filter(row => row.dataset.memberName === 'read');
  const groupState = id => {
    const section = document.querySelector(
      'section[data-cjdoc-declaration-group="' + id + '"]');
    const heading = section?.querySelector(':scope > h2');
    const links = heading ? [...document.querySelectorAll('[data-cjdoc-toc] [data-toc-target]')]
      .filter(link => link.dataset.tocTarget === heading.id) : [];
    return {
      exists: !!section, hidden: section?.hidden ?? true,
      count: section?.querySelector('[data-cjdoc-group-count]')?.textContent.trim() || '',
      heading: heading?.textContent.trim() || '',
      tocTexts: links.map(link => link.textContent.trim()),
      tocHidden: links.length === 0 || links.every(link => link.closest('li').hidden)
    };
  };
  const overload = [...document.querySelectorAll('[data-cjdoc-overload-group]')]
    .find(group => group.dataset.overloadTotal === '3' &&
      group.querySelector('[data-cjdoc-toc-role="overload"] code')?.textContent.trim() === 'read');
  const kindAliases = ['api-kind-8-10-query-functions', 'api-kind-8-20-state-properties']
    .map(id => {
      const node = document.getElementById(id);
      return !!node && node.tagName === 'SPAN' &&
        node.classList.contains('section-anchor-alias') &&
        !node.hasAttribute('data-cjdoc-toc-role');
    });
  return {
    memberCount: rows.length,
    readRows: readRows.map(identity),
    visibleRead: readRows.filter(visible).map(identity),
    visibleMembers: rows.filter(visible).map(row => row.dataset.memberName),
    untaggedVisible: rows.some(row => row.dataset.memberName === 'untagged' && visible(row)),
    groupQuery: groupState('10-query'),
    groupState: groupState('20-state'),
    overload: overload ? {
      hidden: overload.hidden,
      total: Number(overload.dataset.overloadTotal),
      count: overload.querySelector('[data-cjdoc-overload-count]')?.textContent.trim() || '',
      headingLevel: Number(overload.querySelector('[data-cjdoc-toc-role="overload"]').tagName.slice(1))
    } : null,
    memberAnchors: rows.every(row => !!row.dataset.memberSymbolId &&
      row.id === symbolAnchor(row.dataset.memberSymbolId) &&
      document.getElementById(row.id) === row),
    legacyGroupAnchors: ['api-group-10-query', 'api-group-20-state']
      .every(id => !!document.getElementById(id)),
    kindAliases
  };
}"""


def missing_anchors(text: str, expected) -> list[str]:  # noqa: ANN001 - sequence of str
    present = set(re.findall(r'id="([^"]+)"', text))
    return [anchor for anchor in expected if anchor not in present]


def page_url(entry: dict, fragment: str = "") -> str:
    # `Path.as_uri()` is the only portable way to build a file URL: on Windows it
    # yields `file:///C:/...`, whereas quoting a path string would encode the
    # drive as `file://C%3A%5C...` and Playwright would treat it as a host.
    url = (Path(entry["root"]) / entry["route"]).resolve().as_uri()
    return url + (f"#{fragment}" if fragment else "")


def transport_url(entry: dict, transport: str, server_base: str | None = None,
                  *, route: str | None = None, query=None, fragment: str = "") -> str:  # noqa: ANN001
    relative_route = route or entry["route"]
    if transport == "file":
        url = (Path(entry["root"]) / relative_route).resolve().as_uri()
    else:
        if server_base is None or entry["fixture"] not in MULTILINGUAL_FIXTURES:
            raise ValueError("served group/tag URLs require a mounted locale root")
        mount = MULTILINGUAL_FIXTURES[entry["fixture"]]
        locale = entry["locale"]
        url = f"{server_base}/docs/{mount}/{locale}/{relative_route.lstrip('/')}"
    if query:
        url += "?" + urlencode(query, doseq=True)
    if fragment:
        url += "#" + fragment
    return url


def symbol_page_routes(root: Path, symbol_name: str) -> list[str]:
    escaped_name = symbol_name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    heading = re.compile(
        r'<h1\b[^>]*>\s*<code>' + re.escape(escaped_name) + r'</code>\s*</h1>'
    )
    routes = []
    for path in sorted((root / "symbols").glob("*.html")):
        text = path.read_text(encoding="utf-8")
        if 'data-cjdoc-member-browser' in text and heading.search(text):
            routes.append(f"symbols/{path.name}")
    return routes


def generate_site(binary: Path, repo: Path, fixture: str, work: Path) -> list[dict]:
    # Copy the fixture out of the checkout FIRST. Generating a project writes a
    # `target/` build tree beside its sources, and leaving that inside the
    # repository breaks the stages that run after this one: the real-repository
    # smoke refuses any untracked fixture `target/`. The copy also keeps the
    # matrix from mutating tracked fixture sources.
    project = work / "projects" / fixture
    if project.exists():
        shutil.rmtree(project)
    project.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(repo / "tests/fixtures/projects" / fixture, project,
                    ignore=shutil.ignore_patterns("target"))
    site = work / fixture
    # The CLI creates the output root and writes its ownership marker into it; a
    # pre-created directory is refused as pre-existing user output, so the path
    # must not exist before the run.
    if site.exists():
        shutil.rmtree(site)
    environment = {**os.environ, "TMPDIR": str(work), "TMP": str(work), "TEMP": str(work)}
    command = [str(binary), "generate", "--project", str(project),
               "--format", "html", "--output", str(site)]
    if fixture in MULTILINGUAL_FIXTURES:
        command.append("--all-languages")
    result = subprocess.run(command, text=True, capture_output=True, cwd=str(repo), env=environment)
    html_root = site / "html"
    if result.returncode != 0 or not html_root.is_dir():
        details = result.stderr[-600:].replace(str(project), "<fixture>")
        details = details.replace(str(site), "<output>").replace(str(repo), "<repo>")
        details = details.replace(str(binary), "<binary>").replace(str(Path.home()), "$HOME")
        raise ValueError(f"generating {fixture} failed: {details}")
    roots = [(locale, html_root / locale) for locale in LOCALES] \
        if fixture in MULTILINGUAL_FIXTURES else [("default", html_root)]
    pages = []
    for locale, root in roots:
        if not root.is_dir():
            raise ValueError(f"{fixture}: expected generated locale root {locale}")
        package_pages = sorted((root / "packages").glob("*.html"))
        for page in package_pages:
            text = page.read_text(encoding="utf-8")
            absent = missing_anchors(text, FIXTURE_ANCHORS[fixture])
            if absent:
                raise ValueError(
                    f"{fixture}/{locale}/{page.name}: required anchors are missing: {absent}"
                )
            pages.append({
                "fixture": fixture,
                "locale": locale,
                "root": str(root),
                "route": f"packages/{page.name}",
                "historicalAnchors": list(FIXTURE_ANCHORS[fixture]),
            })
    if not pages:
        raise ValueError(f"{fixture} generated no package pages")
    return pages


@contextmanager
def mounted_http_server(work: Path, pages: list[dict]):
    """Mount the generated bilingual sites at the real /docs/ subpath."""
    served_root = work / "served"
    docs_root = served_root / "docs"
    docs_root.mkdir(parents=True, exist_ok=True)
    mounted = set()
    for entry in pages:
        fixture = entry["fixture"]
        if fixture not in MULTILINGUAL_FIXTURES:
            continue
        key = (fixture, entry["locale"])
        if key in mounted:
            continue
        mounted.add(key)
        mount = MULTILINGUAL_FIXTURES[fixture]
        destination = docs_root / mount / entry["locale"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"served mount already exists: {fixture}/{entry['locale']}")
        destination.symlink_to(Path(entry["root"]).resolve(), target_is_directory=True)

    class QuietHandler(SimpleHTTPRequestHandler):
        def log_message(self, format, *args):  # noqa: A002
            pass

    server = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        partial(QuietHandler, directory=str(served_root)),
    )
    thread = Thread(target=server.serve_forever, name="package-index-matrix-http", daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def check_structure(page, fixture, *, require_declarations: bool = True) -> list[str]:  # noqa: ANN001
    failures = []
    structure = page.evaluate(STRUCTURE_PROBE)
    if structure["h1"] != 1:
        failures.append(f"{fixture}: expected exactly one main H1, found {structure['h1']}")
    if require_declarations and not structure["declarations"]:
        failures.append(f"{fixture}: #declarations anchor is missing")
    for previous, current in zip(structure["headings"], structure["headings"][1:]):
        if current - previous > 1:
            failures.append(f"{fixture}: heading level jumps {previous} -> {current}")
    if len(set(structure["anchors"])) != len(structure["anchors"]):
        failures.append(f"{fixture}: duplicate element ids")
    for group in structure["groups"]:
        if not group["id"]:
            failures.append(f"{fixture}: a group heading has no anchor")
        if not group["text"]:
            failures.append(f"{fixture}: a group heading is empty")
    return failures


def check_anchors(page, pages, transport: str = "file",
                  server_base: str | None = None) -> list[str]:  # noqa: ANN001
    failures = []
    for entry in pages:
        for anchor in entry["historicalAnchors"]:
            page.goto(transport_url(entry, transport, server_base, fragment=anchor))
            state = page.evaluate(
                """anchor => {
                  const target = document.getElementById(anchor);
                  const list = target && target.parentElement
                    ? target.parentElement.querySelector('.declaration-list') : null;
                  return { found: !!target, rows: list ? list.querySelectorAll('.declaration-row').length : 0 };
                }""",
                anchor,
            )
            where = f"{entry['fixture']}/{entry['locale']} {transport}#{anchor}"
            if not state["found"]:
                failures.append(f"{where}: anchor does not resolve")
            elif state["rows"] < 1:
                failures.append(f"{where}: owns no declaration list")
    return failures


def settle_browser_paint(page) -> None:  # noqa: ANN001 - Playwright Page
    """Measure the final theme, not a transitioning foreground on its new background."""
    page.evaluate("""async () => {
      await document.fonts.ready;
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      await Promise.all(document.getAnimations()
        .filter(animation => animation instanceof CSSTransition)
        .map(animation => animation.finished.catch(() => {})));
    }""")


def check_viewport(page, pages, name: str, width: int, height: int,
                   emulated: str | None, transport: str = "file",
                   server_base: str | None = None) -> list[str]:
    failures = []
    page.set_viewport_size({"width": width, "height": height})
    for entry in pages:
        page.goto(transport_url(entry, transport, server_base))
        if emulated:
            page.emulate_media(color_scheme=emulated)
            page.evaluate("theme => { document.documentElement.dataset.theme = theme; }", emulated)
        else:
            page.emulate_media(color_scheme="light")
            page.evaluate("() => { delete document.documentElement.dataset.theme; }")
        settle_browser_paint(page)
        where = f"{entry['fixture']}/{entry['locale']} {transport} {name}"
        layout = page.evaluate(LAYOUT_PROBE)
        if layout["overflow"]:
            failures.append(
                f"{where}: horizontal overflow (scrollWidth {layout['scrollWidth']} > {layout['innerWidth']})"
            )
        if layout["rows"] < 1:
            failures.append(f"{where}: no declaration rows rendered")
        if layout["firstScreen"] < 1:
            failures.append(f"{where}: no declaration row in the first screen")
        for sample in page.evaluate(CONTRAST_PROBE):
            floor = 3.0 if sample["size"] >= 24 else 4.5
            if sample["ratio"] < floor:
                failures.append(
                    f"{where}: contrast {sample['ratio']} < {floor} for "
                    f"{sample['cls']} {sample['text']!r} ({sample['size']}px)"
                )
    return failures


def check_native_zoom(browser, pages) -> list[str]:  # noqa: ANN001 - Playwright Browser
    """Real 200% browser zoom: half the CSS viewport at 2x device pixel ratio.

    Page zoom is not a CSS transform. At 200% a 1024x768 window reports ~512 CSS
    pixels of width with `devicePixelRatio` 2, which is what makes
    `@media(max-width:760px)` and DPR-dependent rules apply -- neither happens
    with `documentElement.style.zoom`. Playwright's Python API has no zoom
    command, so the same state is created directly: a 512x384 viewport with
    `device_scale_factor=2`.
    """
    failures = []
    context = browser.new_context(viewport={"width": 512, "height": 384}, device_scale_factor=2)
    page = context.new_page()
    try:
        for entry in pages:
            page.goto(page_url(entry))
            page.emulate_media(color_scheme="light")
            settle_browser_paint(page)
            state = page.evaluate(
                """() => ({
                  innerWidth, dpr: devicePixelRatio,
                  overflow: document.documentElement.scrollWidth > innerWidth + 1,
                  rows: document.querySelectorAll('.declaration-row').length,
                  visibleRows: [...document.querySelectorAll('.declaration-row')]
                    .filter(row => { const r = row.getBoundingClientRect();
                                     return r.width > 0 && r.height > 0; }).length,
                  anchor: !!document.getElementById('declarations'),
                  narrowRuleApplied: matchMedia('(max-width: 760px)').matches,
                })"""
            )
            where = f"{entry['fixture']} zoom200"
            if state["dpr"] != 2:
                failures.append(f"{where}: expected devicePixelRatio 2, saw {state['dpr']}")
            if round(state["innerWidth"]) > 520:
                failures.append(
                    f"{where}: zoom did not halve the CSS viewport (innerWidth {state['innerWidth']})"
                )
            if not state["narrowRuleApplied"]:
                failures.append(f"{where}: the narrow-viewport media query did not apply under zoom")
            if state["overflow"]:
                failures.append(f"{where}: page-level horizontal overflow under zoom")
            if state["rows"] < 1 or state["visibleRows"] < 1:
                failures.append(f"{where}: declaration rows are not rendered under zoom")
            if not state["anchor"]:
                failures.append(f"{where}: #declarations anchor missing under zoom")
            for sample in page.evaluate(CONTRAST_PROBE):
                floor = 3.0 if sample["size"] >= 24 else 4.5
                if sample["ratio"] < floor:
                    failures.append(
                        f"{where}: contrast {sample['ratio']} < {floor} for "
                        f"{sample['cls']} {sample['text']!r}"
                    )
    finally:
        context.close()
    return failures


def check_keyboard(page, entry) -> list[str]:  # noqa: ANN001 - Playwright Page
    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(page_url(entry))
    page.locator(".declaration-row-link").first.focus()
    state = page.evaluate(
        """() => {
          const active = document.activeElement;
          if (!active) return { link: false, outline: false };
          const after = getComputedStyle(active, '::after');
          const own = getComputedStyle(active);
          return {
            link: active.classList.contains('declaration-row-link'),
            outline: own.outlineStyle !== 'none' || after.outlineStyle !== 'none',
          };
        }"""
    )
    failures = []
    if not state["link"]:
        failures.append(f"{entry['fixture']}: focus does not land on a declaration row link")
    if not state["outline"]:
        failures.append(f"{entry['fixture']}: the focused row link has no visible indicator")
    return failures


def check_accessible_names(page, pages) -> list[str]:  # noqa: ANN001 - Playwright Page
    failures = []
    for entry in pages:
        page.goto(page_url(entry))
        audit = page.evaluate(
            """() => {
              const rows = [...document.querySelectorAll('.declaration-row')];
              return {
                rows: rows.length,
                nested: rows.filter(row => row.querySelector('a a, a button, button a')).length,
                missing: rows.filter(row => {
                  const link = row.querySelector('.declaration-row-link');
                  return !link || !(link.getAttribute('aria-label') || link.textContent || '').trim();
                }).length,
                leaked: rows.filter(row => {
                  const link = row.querySelector('.declaration-row-link');
                  const signature = row.querySelector('.declaration-signature');
                  return !!link && !!signature && link.contains(signature);
                }).length,
              };
            }"""
        )
        where = entry["fixture"]
        if audit["rows"] < 1:
            failures.append(f"{where}: no rows to audit")
        if audit["nested"]:
            failures.append(f"{where}: {audit['nested']} rows nest interactive elements")
        if audit["missing"]:
            failures.append(f"{where}: {audit['missing']} row links have no accessible name")
        if audit["leaked"]:
            failures.append(f"{where}: {audit['leaked']} row links swallow the signature")
    return failures


def check_expanded_detail_structure(page, fixture: str) -> list[str]:  # noqa: ANN001
    page.evaluate(
        "() => document.querySelectorAll('details[data-cjdoc-member]')" +
        ".forEach(detail => { detail.open = true; })"
    )
    failures = check_structure(page, fixture + "/expanded-details", require_declarations=False)
    page.evaluate(
        "() => document.querySelectorAll('details[data-cjdoc-member]')" +
        ".forEach(detail => { detail.open = false; })"
    )
    return failures


def check_grouped_members(page, entry: dict, transport: str,
                          server_base: str | None) -> list[str]:  # noqa: ANN001
    failures = []
    root = Path(entry["root"])
    routes = symbol_page_routes(root, "Application")
    where = f"declaration-groups/{entry['locale']} {transport}"
    if len(routes) != 1:
        return [f"{where}: expected exactly one Application member page, found {len(routes)}"]
    route = routes[0]
    page.goto(transport_url(entry, transport, server_base, route=route))
    failures += check_structure(page, where + "/Application", require_declarations=False)
    failures += check_expanded_detail_structure(page, where + "/Application")
    state = page.evaluate(r"""() => {
      const group = id => document.getElementById('api-group-' + id).parentElement;
      const rows = [...document.querySelectorAll('[data-cjdoc-member]')];
      const symbolAnchor = symbolId => "symbol-" +
        [...new TextEncoder().encode(symbolId)].map(byte => byte.toString(16).padStart(2, "0")).join("");
      const single = group('10-application');
      const mixed = group('20-generated-spi');
      const levels = section => [...section.querySelectorAll('[data-cjdoc-toc-role="overload"]')]
        .map(node => Number(node.tagName.slice(1)));
      const member = name => document.querySelector('[data-member-name="' + name + '"]');
      const plain = member('zLast');
      const target = plain && plain.querySelector('summary');
      const toc = [...document.querySelectorAll('[data-cjdoc-toc] a')]
        .find(node => plain && node.dataset.tocTarget === plain.id);
      const singleKind = document.getElementById('api-kind-14-10-application-functions');
      const mixedKind = document.getElementById('api-kind-16-20-generated-spi-functions');
      return {
        members: rows.length,
        memberAnchors: rows.every(row => !!row.dataset.memberSymbolId &&
          row.id === symbolAnchor(row.dataset.memberSymbolId) &&
          document.getElementById(row.id) === row),
        singleKindHeadings: single.querySelectorAll('.member-group-heading').length,
        mixedKindHeadings: mixed.querySelectorAll('.member-group-heading').length,
        singleOverloads: levels(single), mixedOverloads: levels(mixed),
        plainDepth: target ? Number(target.dataset.cjdocTocDepth) : null,
        plainTocDepth: toc ? Number(toc.closest('li').dataset.depth) : null,
        singleDetails: [...single.querySelectorAll('.member-detail-body h4')].length,
        mixedDetails: [...mixed.querySelectorAll('.member-detail-body h5')].length,
        legacyGroupAnchors: ['api-group-10-application','api-group-20-generated-spi']
          .every(id => !!document.getElementById(id)),
        legacyKindAnchors: ['functions','properties','api-kind-14-10-application-functions',
          'api-kind-16-20-generated-spi-functions'].every(id => !!document.getElementById(id)),
        singleKindAlias: !!singleKind && singleKind.tagName === 'SPAN' &&
          singleKind.classList.contains('section-anchor-alias') &&
          !singleKind.hasAttribute('data-cjdoc-toc-role'),
        mixedKindHeading: !!mixedKind && mixedKind.tagName === 'H3',
        memberAnchor: !!plain && !!plain.id && document.getElementById(plain.id) === plain,
        internalToc: [...document.querySelectorAll('[data-cjdoc-toc] a')].some(link =>
          document.getElementById(link.dataset.tocTarget)?.closest('.member-detail-body')),
      };
    }""")
    expected = {
        "members": 6, "singleKindHeadings": 0, "mixedKindHeadings": 2,
        "singleOverloads": [3], "mixedOverloads": [4],
        "plainDepth": 3, "plainTocDepth": 3,
        "legacyGroupAnchors": True, "legacyKindAnchors": True,
        "singleKindAlias": True, "mixedKindHeading": True, "memberAnchor": True,
        "memberAnchors": True,
        "internalToc": False,
    }
    for key, value in expected.items():
        if state[key] != value:
            failures.append(f"{where}: {key}: {state[key]!r} != {value!r}")
    if state["singleDetails"] < 2 or state["mixedDetails"] < 2:
        failures.append(f"{where}: inline detail headings did not follow their overload parents")
    page.locator("[data-cjdoc-member-filter]").fill("zLast")
    filtered = page.evaluate("""() => {
      const groups = [...document.querySelectorAll('section[data-cjdoc-declaration-group]')];
      return groups.map(group => {
        const heading = group.querySelector('h2');
        const toc = [...document.querySelectorAll('[data-cjdoc-toc] [data-toc-target]')]
          .find(link => link.dataset.tocTarget === heading.id);
        return {id:group.dataset.cjdocDeclarationGroup,hidden:group.hidden,
          count:group.querySelector('[data-cjdoc-group-count]').textContent.trim(),
          heading:heading.textContent.trim(),toc:toc?.textContent.trim(),
          tocHidden:toc ? toc.closest('li').hidden : true};
      });
    }""")
    first = next((item for item in filtered if item["id"] == "10-application"), None)
    second = next((item for item in filtered if item["id"] == "20-generated-spi"), None)
    if not first or not second:
        failures.append(f"{where}: expected both visible source groups")
    else:
        if first["hidden"] or "1 / 3" not in first["count"] or second["hidden"] is False:
            failures.append(f"{where}: filtering did not update outer counts and empty groups")
        if first["toc"] != first["heading"]:
            failures.append(f"{where}: filtered TOC count disagrees with its heading")
        if not second["tocHidden"]:
            failures.append(f"{where}: an empty group's TOC entry remained visible")
    return failures

TAG_STREAM_IDENTITIES = {
    ("StreamReader", "", (), ""),
    ("read", "StreamReader", ("Int64",), "Int64"),
    ("read", "StreamReader", ("String",), "String"),
    ("read", "OtherReader", ("Int64",), "Int64"),
}
TAG_STREAM_STABLE_IDENTITIES = {
    ("StreamReader", "", (), ""),
    ("read", "StreamReader", ("Int64",), "Int64"),
}
TAG_UPPER_IDENTITIES = {
    ("read", "StreamReader", ("Array<UInt8>",), "Int64"),
    ("upperCaseOnly", "", (), "Unit"),
}
TAG_STREAMING_IDENTITIES = {("streamingOnly", "", (), "Unit")}
TAG_STREAM_READ_IDENTITIES = {
    ("read", "StreamReader", ("Int64",), "Int64"),
    ("read", "StreamReader", ("String",), "String"),
}
TAG_ALL_READ_IDENTITIES = TAG_STREAM_READ_IDENTITIES | {
    ("read", "StreamReader", ("Array<UInt8>",), "Int64"),
}


def parameter_type_identity(row: dict) -> tuple[str, ...]:
    return tuple(re.sub(r"[ \t\r\n]+", "", value) for value in row["parameterTypes"] or ())


def search_identity_set(rows: list[dict | None]) -> set[tuple]:
    return {
        (row["name"], row["ownerName"], parameter_type_identity(row), row["returnType"])
        for row in rows if row is not None
    }


def count_pair_matches(text: str, matched: int, total: int) -> bool:
    return [int(value) for value in re.findall(r"\d+", text)[:2]] == [matched, total]


def check_search_rows(state: dict, expected: set[tuple], where: str) -> list[str]:
    rows = state["resultRows"]
    failures = []
    if any(row is None for row in rows):
        failures.append(f"{where}: a rendered result did not map to its published canonical entry")
        return failures
    actual = search_identity_set(rows)
    if actual != expected or len(rows) != len(expected):
        failures.append(f"{where}: canonical results {sorted(actual)!r} != {sorted(expected)!r}")
    canonical_ids = [row["canonicalId"] for row in rows]
    if len(canonical_ids) != len(set(canonical_ids)):
        failures.append(f"{where}: duplicate canonical results were rendered")
    return failures


def check_tagged_global(page, entry: dict, transport: str,
                        server_base: str | None) -> list[str]:  # noqa: ANN001
    failures = []
    where = f"declaration-tags/{entry['locale']} {transport}"
    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(transport_url(entry, transport, server_base))
    badge_selector = (
        '.declaration-row[data-member-name="StreamReader"] '
        '.declaration-tag-badge[data-cjdoc-tag-link][data-cjdoc-tag-id="stream"]'
    )
    badge = page.locator(badge_selector)
    if badge.count() != 1:
        return [f"{where}: expected the source StreamReader stream badge, found {badge.count()}"]
    badge_state = page.evaluate(
        """selector => {
          const badge = document.querySelector(selector);
          const row = badge?.closest('.declaration-row');
          const primary = row?.querySelector('.declaration-row-link');
          return {
            id: badge?.dataset.cjdocTagId || '',
            isLink: badge?.tagName === 'A',
            inPrimary: !!primary?.contains(badge),
            primaryHref: primary?.getAttribute('href') || '',
            badgeHref: badge?.getAttribute('href') || ''
          };
        }""",
        badge_selector,
    )
    if badge_state["id"] != "stream" or not badge_state["isLink"] or badge_state["inPrimary"]:
        failures.append(f"{where}: tag badge is not an independent anchor beside the declaration link")
    if not badge_state["primaryHref"] or "index.html?tag=" in badge_state["primaryHref"]:
        failures.append(f"{where}: the declaration's primary link lost its own destination")

    primary = page.locator(
        '.declaration-row[data-member-name="StreamReader"] .declaration-row-link'
    )
    if primary.count() != 1:
        failures.append(f"{where}: the source declaration row link is missing")
    else:
        primary.focus()
        focused_tag = ""
        for _ in range(8):
            focused_tag = page.evaluate(
                """() => document.activeElement?.dataset.cjdocTagId || ''"""
            )
            if focused_tag == "stream":
                break
            page.keyboard.press("Tab")
        focus_state = page.evaluate(
            """() => {
              const active = document.activeElement;
              const style = active ? getComputedStyle(active) : null;
              return {
                id: active?.dataset.cjdocTagId || '',
                focusVisible: !!active?.matches(':focus-visible'),
                outline: !!style && style.outlineStyle !== 'none' &&
                  parseFloat(style.outlineWidth) > 0
              };
            }"""
        )
        if focus_state["id"] != "stream" or not focus_state["focusVisible"] or not focus_state["outline"]:
            failures.append(f"{where}: tag badge is not independently keyboard-focusable with a visible indicator")

    # Playwright's actual pointer click proves the overlaid row link does not
    # cover the independently focusable badge.
    badge.click()
    page.wait_for_function(
        "() => window.location.pathname.endsWith('/index.html') && " +
        "document.querySelectorAll('[data-cjdoc-results] > li').length === 4"
    )
    params = parse_qs(urlparse(page.url).query, keep_blank_values=True)
    if set(params) != {"tag", "moduleId", "snapshotId"} or params.get("tag") != ["stream"]:
        failures.append(f"{where}: badge navigation did not preserve the exact scoped tag request")
    state = page.evaluate(TAG_SEARCH_PROBE)
    scope = state["index"]["scope"]
    module_ids = [module["moduleId"] for module in state["index"]["modules"]]
    module_id = params.get("moduleId", [""])[0]
    snapshot_id = params.get("snapshotId", [""])[0]
    if (scope.get("language") != entry["locale"] or not snapshot_id or
            snapshot_id != scope.get("snapshotId") or module_id not in module_ids):
        failures.append(f"{where}: tag navigation scope does not identify this locale's captured module")
    failures += check_search_rows(state, TAG_STREAM_IDENTITIES, where + " scoped stream")
    if state["facetsHidden"]:
        failures.append(f"{where}: tag facets stayed hidden after a scoped tag request")
    facets = {facet["id"]: facet for facet in state["facets"]}
    if "secret" in facets:
        failures.append(f"{where}: a private declaration's secret tag leaked into the facet dictionary")
    stream_facet = facets.get("stream")
    stable_facet = facets.get("stable")
    if (not stream_facet or not stream_facet["selected"] or stream_facet["count"] != 4 or
            stream_facet["moduleId"] != module_id or stream_facet["snapshotId"] != snapshot_id):
        failures.append(f"{where}: selected stream facet lacks the source-derived scoped count of four")
    if (not stable_facet or stable_facet["selected"] or stable_facet["count"] != 2 or
            stable_facet["moduleId"] != module_id or stable_facet["snapshotId"] != snapshot_id):
        failures.append(f"{where}: stable facet is not scoped to the two stream+stable declarations")

    stable_selector = (
        '[data-cjdoc-search-facets] [data-cjdoc-search-facet][data-cjdoc-tag-id="stable"]'
    )
    if page.locator(stable_selector).count() != 1:
        failures.append(f"{where}: the source stable facet is missing")
    else:
        page.locator(stable_selector).click()
        page.wait_for_function(
            "count => document.querySelectorAll('[data-cjdoc-results] > li').length === count", arg=2
        )
        stable_state = page.evaluate(TAG_SEARCH_PROBE)
        failures += check_search_rows(
            stable_state, TAG_STREAM_STABLE_IDENTITIES, where + " stream AND stable facet"
        )
        selected = {facet["id"]: facet for facet in stable_state["facets"]}
        if any(not selected.get(tag, {}).get("selected") or selected[tag]["count"] != 2
               for tag in ("stream", "stable")):
            failures.append(f"{where}: both facets must count the fully filtered two-declaration set")
        if transport == "http":
            updated = parse_qs(urlparse(page.url).query, keep_blank_values=True)
            if (set(updated.get("tag", [])) != {"stream", "stable"} or
                    updated.get("moduleId") != [module_id] or
                    updated.get("snapshotId") != [snapshot_id]):
                failures.append(f"{where}: facet navigation lost repeated tags or scope on /docs/")

    index_url = transport_url(entry, transport, server_base, route="index.html")
    for query, expected, expected_count in (
        ("tag:Stream", TAG_UPPER_IDENTITIES, 2),
        ("tag:streaming", TAG_STREAMING_IDENTITIES, 1),
    ):
        page.goto(index_url)
        page.locator("[data-cjdoc-search]").fill(query)
        page.wait_for_function(
            "count => document.querySelectorAll('[data-cjdoc-results] > li').length === count",
            arg=expected_count,
        )
        exact_state = page.evaluate(TAG_SEARCH_PROBE)
        failures += check_search_rows(exact_state, expected, where + " " + query)
    page.goto(transport_url(entry, transport, server_base))
    page.locator(
        '.declaration-row[data-member-name="StreamReader"] .declaration-row-link'
    ).click()
    page.wait_for_function(
        "() => document.querySelector('[data-cjdoc-member-browser]') && " +
        "document.querySelector('main h1 code')?.textContent.trim() === 'StreamReader'"
    )
    if transport == "http" and "/docs/tags/" not in urlparse(page.url).path:
        failures.append(f"{where}: primary declaration link did not remain independent under /docs/")
    return failures


def check_tagged_members(page, entry: dict, transport: str,
                         server_base: str | None) -> list[str]:  # noqa: ANN001
    failures = []
    where = f"declaration-tags/{entry['locale']} {transport} local"
    routes = symbol_page_routes(Path(entry["root"]), "StreamReader")
    if len(routes) != 1:
        return [f"{where}: expected exactly one StreamReader member page, found {len(routes)}"]
    page.set_viewport_size({"width": 1440, "height": 900})
    page.goto(transport_url(entry, transport, server_base, route=routes[0]))
    failures += check_structure(page, where + "/StreamReader", require_declarations=False)
    failures += check_expanded_detail_structure(page, where + "/StreamReader")
    initial = page.evaluate(TAG_MEMBER_PROBE)
    actual_all_reads = search_identity_set(initial["readRows"])
    if len(initial["readRows"]) != 3 or actual_all_reads != TAG_ALL_READ_IDENTITIES:
        failures.append(f"{where}: the three source read signatures are not distinct canonical entries")
    tags_by_parameters = {
        parameter_type_identity(row): set(row["tagIds"])
        for row in initial["readRows"] if row is not None
    }
    if tags_by_parameters != {
        ("Int64",): {"stream", "stable"},
        ("String",): {"stream"},
        ("Array<UInt8>",): {"Stream"},
    }:
        failures.append(f"{where}: read signature tag IDs differ from the source declarations")
    if (not initial["memberAnchors"] or not initial["legacyGroupAnchors"] or
            not initial["groupQuery"]["exists"] or not initial["groupState"]["exists"] or
            initial["kindAliases"] != [True, True]):
        failures.append(f"{where}: historical group, omitted-kind, or member anchors are missing")

    page.locator("[data-cjdoc-member-filter]").fill("tag:stream")
    page.wait_for_function(
        "count => document.querySelectorAll('[data-cjdoc-member]:not([hidden])').length === count", arg=2
    )
    stream_state = page.evaluate(TAG_MEMBER_PROBE)
    if search_identity_set(stream_state["visibleRead"]) != TAG_STREAM_READ_IDENTITIES:
        failures.append(f"{where}: tag:stream did not retain the exact two canonical read signatures")
    if (len(stream_state["visibleRead"]) != 2 or
            set(stream_state["visibleMembers"]) != {"read"} or
            stream_state["untaggedVisible"]):
        failures.append(f"{where}: stream filter count or no-inheritance behavior is incorrect")
    if (stream_state["groupQuery"]["hidden"] or
            not count_pair_matches(stream_state["groupQuery"]["count"], 2, 3) or
            stream_state["groupQuery"]["tocHidden"] or
            not stream_state["groupQuery"]["tocTexts"] or
            any(text != stream_state["groupQuery"]["heading"]
                for text in stream_state["groupQuery"]["tocTexts"])):
        failures.append(f"{where}: the visible group, its 2/3 count, and TOC label did not stay synchronized")
    if not stream_state["groupState"]["hidden"] or not stream_state["groupState"]["tocHidden"]:
        failures.append(f"{where}: zero-match state group or its TOC entry remained visible")
    overload = stream_state["overload"]
    if (not overload or overload["hidden"] or overload["total"] != 3 or
            overload["headingLevel"] != 3 or not count_pair_matches(overload["count"], 2, 3)):
        failures.append(f"{where}: stream filter did not report 2 of the original 3 read overloads")

    page.locator("[data-cjdoc-member-filter]").fill("tag:stream tag:stable")
    page.wait_for_function(
        "count => document.querySelectorAll('[data-cjdoc-member]:not([hidden])').length === count", arg=1
    )
    intersection = page.evaluate(TAG_MEMBER_PROBE)
    expected_intersection = {("read", "StreamReader", ("Int64",), "Int64")}
    if search_identity_set(intersection["visibleRead"]) != expected_intersection:
        failures.append(f"{where}: stream AND stable did not retain only read(count: Int64)")
    if (intersection["groupQuery"]["hidden"] or
            not count_pair_matches(intersection["groupQuery"]["count"], 1, 3) or
            not intersection["groupQuery"]["tocTexts"] or
            any(text != intersection["groupQuery"]["heading"]
                for text in intersection["groupQuery"]["tocTexts"])):
        failures.append(f"{where}: stream+stable group count and TOC label disagree")
    overload = intersection["overload"]
    if (not overload or overload["hidden"] or not count_pair_matches(overload["count"], 1, 3)):
        failures.append(f"{where}: stream+stable did not report 1 of the original 3 read overloads")
    if not intersection["groupState"]["hidden"] or not intersection["groupState"]["tocHidden"]:
        failures.append(f"{where}: filtering did not keep the zero-match state group hidden")
    page.locator("[data-cjdoc-member-filter]").fill("tag:Stream")
    page.wait_for_function(
        "count => document.querySelectorAll('[data-cjdoc-member]:not([hidden])').length === count", arg=1
    )
    case_sensitive = page.evaluate(TAG_MEMBER_PROBE)
    if search_identity_set(case_sensitive["visibleRead"]) != {
        ("read", "StreamReader", ("Array<UInt8>",), "Int64")
    }:
        failures.append(f"{where}: uppercase Stream must remain a distinct local tag identity")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    repo = Path(__file__).resolve().parents[1]
    # The stage deletes its own scratch tree, so it must never be pointed at a
    # directory it does not own. Mirrors the other acceptance stages: a
    # non-empty root without this stage's marker is refused, and a symlinked root
    # is refused outright rather than followed.
    if output.is_symlink():
        raise ValueError(f"output root must not be a symlink: {output}")
    marker = output / "package-index-matrix.owner"
    if output.exists():
        if not output.is_dir():
            raise ValueError(f"output root must be a directory: {output}")
        entries = [child for child in output.iterdir() if child.name != marker.name]
        if entries and not marker.is_file():
            raise ValueError(
                f"output root is not owned by this stage (refusing to delete): {output}"
            )
    work = output / "work"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    marker.write_text("cjdoc package index matrix\n", encoding="utf-8")

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise ValueError(
            "Playwright is required for the package index matrix "
            "(pip install -r scripts/requirements-showcase.txt)"
        ) from error

    shapes = {}
    pages: list[dict] = []
    for fixture, shape in FIXTURES:
        shapes[fixture] = shape
        pages.extend(generate_site(binary, repo, fixture, work))
    # Each labelled shape must really be that shape, otherwise the matrix would
    # claim browser coverage of a layout it never rendered.
    for entry in pages:
        text = (Path(entry["root"]) / entry["route"]).read_text(encoding="utf-8")
        groups = re.findall(r'<(h2|h3) id="[^"]*" data-cjdoc-toc-role="group">', text)
        level = groups[0] if groups else ""
        if shapes[entry["fixture"]] == "single-category" and level != "h2":
            raise ValueError(f"{entry['fixture']} is labelled single-category but renders {level!r}")
        if shapes[entry["fixture"]] == "multi-category" and level != "h3":
            raise ValueError(f"{entry['fixture']} is labelled multi-category but renders {level!r}")
    (output / "package-index-pages.json").write_text(
        json.dumps([{k: v for k, v in entry.items() if k != "root"} for entry in pages],
                   ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )

    group_tag_pages = [
        entry for entry in pages if entry["fixture"] in MULTILINGUAL_FIXTURES
    ]
    grouped_pages = [entry for entry in group_tag_pages
                     if entry["fixture"] == "declaration-groups"]
    tagged_pages = [entry for entry in group_tag_pages
                    if entry["fixture"] == "declaration-tags"]
    failures: list[str] = []
    browser_coverage = []
    with mounted_http_server(work, pages) as server_base:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page()
            try:
                for entry in pages:
                    page.goto(transport_url(entry, "file"))
                    failures += check_structure(
                        page, f"{entry['fixture']}/{entry['locale']} file"
                    )
                failures += check_anchors(page, pages)

                for entry in group_tag_pages:
                    page.goto(transport_url(entry, "http", server_base))
                    failures += check_structure(
                        page, f"{entry['fixture']}/{entry['locale']} http-/docs/"
                    )
                failures += check_anchors(page, group_tag_pages, "http", server_base)

                for entry in grouped_pages:
                    for transport in ("file", "http"):
                        failures += check_grouped_members(page, entry, transport, server_base)
                        browser_coverage.append({
                            "fixture": entry["fixture"],
                            "locale": entry["locale"],
                            "transport": transport,
                            "mount": (f"/docs/{MULTILINGUAL_FIXTURES[entry['fixture']]}/"
                                      f"{entry['locale']}/" if transport == "http" else None),
                            "packageRoute": entry["route"],
                            "memberRoute": (symbol_page_routes(
                                Path(entry["root"]), "Application"
                            ) or [None])[0],
                        })
                for entry in tagged_pages:
                    for transport in ("file", "http"):
                        failures += check_tagged_global(page, entry, transport, server_base)
                        failures += check_tagged_members(page, entry, transport, server_base)
                        browser_coverage.append({
                            "fixture": entry["fixture"],
                            "locale": entry["locale"],
                            "transport": transport,
                            "mount": (f"/docs/{MULTILINGUAL_FIXTURES[entry['fixture']]}/"
                                      f"{entry['locale']}/" if transport == "http" else None),
                            "packageRoute": entry["route"],
                            "memberRoute": (symbol_page_routes(
                                Path(entry["root"]), "StreamReader"
                            ) or [None])[0],
                        })

                for name, width, height in VIEWPORTS:
                    for theme in THEMES:
                        failures += check_viewport(page, pages, name, width, height, theme)
                        failures += check_viewport(
                            page, group_tag_pages, name, width, height, theme,
                            "http", server_base,
                        )
                for name, width, height in GROUP_TAG_VIEWPORTS:
                    for theme in THEMES:
                        failures += check_viewport(
                            page, group_tag_pages, name, width, height, theme
                        )
                        failures += check_viewport(
                            page, group_tag_pages, name, width, height, theme,
                            "http", server_base,
                        )
                failures += check_native_zoom(browser, pages)
                failures += check_keyboard(page, pages[0])
                failures += check_accessible_names(page, pages)
            finally:
                browser_version = browser.version
                browser.close()
    (output / "declaration-group-tag-browser-matrix.json").write_text(
        json.dumps({
            "coverage": browser_coverage,
            "sourceDerivedAssertions": {
                "globalStream": 4,
                "globalStreamAndStable": 2,
                "caseSensitiveStreamTag": 2,
                "prefixDistinctStreamingTag": 1,
                "localStreamRead": {"matched": 2, "total": 3},
                "localStreamAndStableRead": {"matched": 1, "total": 3},
            },
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )
    # DONE-03 pairs samples under matched browser/font conditions, so the identity this
    # stage actually rendered with is published rather than assumed. Reported only
    # after the matrix ran: a version string is evidence of what executed, and reading
    # it up front would attribute a browser to a run that never started.
    ci_stage.report_identity({
        "browserVersion": browser_version,
        "browserIdentity": "chromium",
        "fontSetDigest": ci_stage.font_set_digest(),
    })

    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        print(f"package index matrix failed with {len(failures)} finding(s)", file=sys.stderr)
        return 1
    print(f"package index matrix passed for {len(pages)} page(s): {sorted(shapes.items())}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"package index matrix failed: {error}", file=sys.stderr)
        raise SystemExit(1)
