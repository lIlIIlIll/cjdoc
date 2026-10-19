#!/usr/bin/env python3
"""Real-browser responsive/semantic/accessibility matrix for the package index (issue #115).

Generates two fixture projects so both heading shapes are exercised -- a
single-category package whose category heading *is* the section, and a
multi-category package with an umbrella heading -- then drives real Chromium
over the shipped HTML and asserts:

* semantics: one main H1, no skipped heading levels, non-empty group headings;
* anchors: the historical ``#declarations`` and category deep links resolve and
  each owns a declaration list, including after the single-category merge;
* layout: no page-level horizontal overflow at 1440x900, 1024x768 and 390x844,
  in the light and dark themes and at 200% zoom, with a first-screen row;
* contrast: every sampled text node meets WCAG AA for its size, per theme;
* interaction: a declaration row link receives keyboard focus with a visible
  indicator and never nests interactive content.

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
from pathlib import Path

# Every fixture is paired with the anchors its own declarations must publish.
# These are expectations, not discoveries: they were read from each project's
# sources (and its Doc IR), so a renderer that drops a category alias fails here
# instead of quietly shrinking the assertion set.
#   package_index: one public class -> Classes (the single-category merge keeps
#   the category alias alongside #declarations)
#   basic: class, struct, interface, enum, typeAlias, function, extend
FIXTURE_ANCHORS = {
    "package_index": ("declarations", "classes"),
    "basic": ("declarations", "classes", "structs", "interfaces", "enums",
              "aliases", "functions", "extensions"),
}
VIEWPORTS = (("desktop", 1440, 900), ("tablet", 1024, 768), ("mobile", 390, 844))
THEMES = ("light", "dark")
FIXTURES = (("package_index", "single-category"), ("basic", "multi-category"))

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
    ...document.querySelectorAll('.page-header h1 code, .badge'),
  ];
  const nodes = candidates.filter(node => (node.textContent || '').trim().length > 0);
  return nodes.map(node => {
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
  const headings = [...document.querySelectorAll('main h1, main h2, main h3')]
    .map(node => Number(node.tagName.slice(1)));
  const anchors = [...document.querySelectorAll('[id]')].map(node => node.id);
  const groups = [...document.querySelectorAll('[data-cjdoc-toc-role="group"]')]
    .map(node => ({ id: node.id, level: Number(node.tagName.slice(1)),
                    text: node.textContent.trim() }));
  return { h1: document.querySelectorAll('main h1').length, headings, anchors, groups,
           declarations: !!document.getElementById('declarations') };
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


def generate_site(binary: Path, repo: Path, fixture: str, work: Path) -> list[dict]:
    site = work / fixture
    # The CLI creates the output root and writes its ownership marker into it; a
    # pre-created directory is refused as pre-existing user output, so the path
    # must not exist before the run.
    if site.exists():
        shutil.rmtree(site)
    environment = {**os.environ, "TMPDIR": str(work), "TMP": str(work), "TEMP": str(work)}
    result = subprocess.run(
        [str(binary), "generate", "--project", str(repo / "tests/fixtures/projects" / fixture),
         "--format", "html", "--output", str(site)],
        text=True, capture_output=True, cwd=str(repo), env=environment,
    )
    if result.returncode != 0 or not (site / "html").is_dir():
        raise ValueError(f"generating {fixture} failed: {result.stderr[-600:]}")
    pages = []
    for page in sorted((site / "html/packages").glob("*.html")):
        text = page.read_text(encoding="utf-8")
        absent = missing_anchors(text, FIXTURE_ANCHORS[fixture])
        if absent:
            raise ValueError(
                f"{fixture}/{page.name}: required anchors are missing: {absent}"
            )
        pages.append({
            "fixture": fixture,
            "root": str(site / "html"),
            "route": f"packages/{page.name}",
            "historicalAnchors": list(FIXTURE_ANCHORS[fixture]),
        })
    if not pages:
        raise ValueError(f"{fixture} generated no package pages")
    return pages


def check_structure(page, fixture) -> list[str]:  # noqa: ANN001 - Playwright Page
    failures = []
    structure = page.evaluate(STRUCTURE_PROBE)
    if structure["h1"] != 1:
        failures.append(f"{fixture}: expected exactly one main H1, found {structure['h1']}")
    if not structure["declarations"]:
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


def check_anchors(page, pages) -> list[str]:  # noqa: ANN001 - Playwright Page
    failures = []
    for entry in pages:
        for anchor in entry["historicalAnchors"]:
            page.goto(page_url(entry, anchor))
            state = page.evaluate(
                """anchor => {
                  const target = document.getElementById(anchor);
                  const list = target && target.parentElement
                    ? target.parentElement.querySelector('.declaration-list') : null;
                  return { found: !!target, rows: list ? list.querySelectorAll('.declaration-row').length : 0 };
                }""",
                anchor,
            )
            if not state["found"]:
                failures.append(f"{entry['route']}#{anchor}: anchor does not resolve")
            elif state["rows"] < 1:
                failures.append(f"{entry['route']}#{anchor}: owns no declaration list")
    return failures


def check_viewport(page, pages, name: str, width: int, height: int,
                   emulated: str | None) -> list[str]:
    failures = []
    page.set_viewport_size({"width": width, "height": height})
    for entry in pages:
        page.goto(page_url(entry))
        if emulated:
            page.emulate_media(color_scheme=emulated)
            page.evaluate("theme => { document.documentElement.dataset.theme = theme; }", emulated)
        else:
            page.emulate_media(color_scheme="light")
            page.evaluate("() => { delete document.documentElement.dataset.theme; }")
        where = f"{entry['fixture']} {name}"
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

    failures: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page()
        try:
            for entry in pages:
                page.goto(page_url(entry))
                failures += check_structure(page, entry["fixture"])
            failures += check_anchors(page, pages)
            for name, width, height in VIEWPORTS:
                for theme in THEMES:
                    failures += check_viewport(page, pages, name, width, height, theme)
            failures += check_native_zoom(browser, pages)
            failures += check_keyboard(page, pages[0])
            failures += check_accessible_names(page, pages)
        finally:
            browser.close()

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
