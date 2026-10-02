"""Measured layout, budgets and real theme screenshots for final-site evidence."""
from __future__ import annotations

import hashlib
from pathlib import Path

from .scenarios import BUDGETS
from .site import ContractError, canonical_json


def screenshot_name(key: tuple[str, ...]) -> str:
    return "scenario-" + hashlib.sha256(canonical_json(list(key))).hexdigest() + ".png"


def layout(page) -> dict:
    return page.evaluate('''() => {
      const rows = [...document.querySelectorAll("details[data-cjdoc-member]")];
      const rect = node => node ? node.getBoundingClientRect() : null;
      const shown = node => { const r = rect(node); return r && r.width > 0 && r.height > 0; };
      const summaries = rows.map(row => row.querySelector("summary")).filter(shown);
      const visible = summaries.filter(node => { const r=rect(node); return r.bottom > 0 && r.top < innerHeight; });
      const list = rect(document.querySelector("[data-cjdoc-member-browser]"));
      const main = rect(document.querySelector(".docs-main"));
      return {memberCount: rows.length, firstScreenMembers: visible.length,
        listHeight: list ? Math.round(list.height) : 0,
        compactRowHeight: Math.max(0, ...rows.filter(row => !row.open).map(row => rect(row).height)),
        contentTop: main ? Math.max(0, Math.round(main.top + scrollY)) : 0,
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
        scrollY: Math.round(scrollY)};
    }''')


def check_layout(metrics: dict, width: int, behavior: str):
    if metrics["horizontalOverflow"]:
        raise AssertionError(f"page has horizontal overflow at {width}px")
    if 761 <= width <= 1180 and metrics["contentTop"] > BUDGETS["splitContentTop"]:
        raise AssertionError("split viewport has excessive blank space before the native main column")
    for key in ("listHeight", "compactRowHeight"):
        if metrics[key] > BUDGETS[key]:
            raise AssertionError(f"controlled member sample exceeded {key} budget: {metrics[key]}")
    if behavior == "members" and (metrics["memberCount"] < 20 or metrics["firstScreenMembers"] < 1):
        raise AssertionError("the direct member demonstration needs 20 members and a readable member in the landing viewport")


def screenshots(journey, key: tuple, output: Path) -> list[dict]:
    from playwright.sync_api import expect
    page = journey.page
    images = []
    for theme in ("light", "dark"):
        native = page.locator("[data-cjdoc-theme-toggle]")
        if native.count():
            journey.click(native)
            journey.click(page.locator(f'[data-cjdoc-theme-value="{theme}"]'))
        else:
            toggle = page.locator("[data-showcase-theme]")
            expect(toggle).to_have_count(1)
            if page.locator("html").get_attribute("data-theme") != theme:
                journey.click(toggle)
                if page.locator("html").get_attribute("data-theme") != theme:
                    journey.click(toggle)
        expect(page.locator("html")).to_have_attribute("data-theme", theme)
        if page.evaluate("document.documentElement.scrollWidth > innerWidth + 1"):
            raise AssertionError("theme switch introduced horizontal overflow")
        filename = screenshot_name((*key, theme))
        path = output / filename
        page.screenshot(path=str(path), full_page=True)
        images.append({"theme": theme, "path": filename,
                       "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    journey.assertions.append("Light and Dark were actively selected through the real page controls and captured")
    return images


def validate_metrics(metrics: dict, scenario: tuple):
    expected = {"viewport", "landing", "scrollEvents", "scrollDistance", "queryMs", "expandMs",
                "homepageActivations", "homepageDocumentNavigations"}
    if not isinstance(metrics, dict) or set(metrics) != expected:
        raise ContractError("browser metrics are missing or have unknown fields")
    if metrics["viewport"] != {"width": scenario[2], "height": scenario[3]}:
        raise ContractError("browser viewport does not match its registered scenario")
    for key in ("homepageActivations", "homepageDocumentNavigations"):
        if metrics[key] != BUDGETS[key]:
            raise ContractError("homepage navigation budget failed: " + key)
    for key in ("scrollEvents", "scrollDistance"):
        if type(metrics[key]) is not int or metrics[key] < 0:
            raise ContractError("invalid measured scroll metric: " + key)
    for key in ("queryMs", "expandMs"):
        if not isinstance(metrics[key], list):
            raise ContractError("missing measured interaction timings")
        for value in metrics[key]:
            if type(value) not in (int, float) or not 0 <= value <= BUDGETS[key]:
                raise ContractError("invalid or over-budget interaction timing: " + key)
    landing = metrics["landing"]
    names = {"memberCount", "firstScreenMembers", "listHeight", "compactRowHeight",
             "contentTop", "horizontalOverflow", "scrollY"}
    if not isinstance(landing, dict) or set(landing) != names:
        raise ContractError("missing measured landing layout")
    for key in names - {"horizontalOverflow"}:
        if type(landing[key]) not in (int, float) or landing[key] < 0:
            raise ContractError("invalid measured landing layout")
    if type(landing["horizontalOverflow"]) is not bool:
        raise ContractError("invalid measured overflow flag")
    try:
        check_layout(landing, scenario[2], scenario[0])
    except AssertionError as error:
        raise ContractError(str(error)) from error
    if scenario[0] in {"members", "search"} and not metrics["queryMs"]:
        raise ContractError("required query timing was not measured")
    if scenario[0] in {"members", "contracts", "resources"} and not metrics["expandMs"]:
        raise ContractError("required member expansion timing was not measured")
