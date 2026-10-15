#!/usr/bin/env python3
"""Execute the generated sidebar route and package-filter contracts in Node."""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script


def extract_callback(script: str, declaration: str, terminator: str) -> str:
    """Keep tested JavaScript identical to the renderer's emitted script."""
    return declaration + script.split(declaration, 1)[1].split(terminator, 1)[0] + "\n  };\n"


@unittest.skipUnless(shutil.which("node"), "Node.js is required for browser-script regression tests")
class HtmlNavigationTest(unittest.TestCase):
    def run_node(self, implementation: str, harness: str) -> None:
        script = "const SOURCE = " + json.dumps(implementation) + ";\n" + harness
        result = subprocess.run(
            ["node"], input=script, text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_quick_start_route_updates_visual_and_aria_current(self) -> None:
        script = canonical_search_script()
        source = extract_callback(
            script, "  const syncRouteState = () => {",
            "\n  };\n  syncRouteState();",
        )
        harness = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');
class Link {
  constructor() {
    this.attributes = {};
    this.values = new Set();
    this.classList = {
      toggle: (name, on) => on ? this.values.add(name) : this.values.delete(name),
      contains: name => this.values.has(name),
    };
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  removeAttribute(name) { delete this.attributes[name]; }
  getAttribute(name) { return this.attributes[name]; }
}
const overview = new Link(), quick = new Link(), api = new Link();
const document = {
  body: {dataset: {cjdocRoute: 'overview'}},
  querySelector(selector) {
    if (selector.includes('#quick-start-title')) return quick;
    if (selector.includes('#packages')) return api;
    if (selector.includes('index.html')) return overview;
    return null;
  },
};
const window = {location: {hash: ''}};
const context = vm.createContext({document, window});
vm.runInContext(SOURCE + '\nsyncRouteState();', context);
function assertOnly(expected) {
  for (const [key, link] of [['overview', overview], ['quick', quick], ['api', api]]) {
    assert.equal(link.classList.contains('is-current'), key === expected, key);
    assert.equal(link.getAttribute('aria-current'), key === expected ? 'page' : undefined, key);
  }
}
assertOnly('overview');
window.location.hash = '#quick-start-title';
vm.runInContext('syncRouteState();', context);
assertOnly('quick');
window.location.hash = '#packages';
vm.runInContext('syncRouteState();', context);
assertOnly('api');
window.location.hash = '';
vm.runInContext('syncRouteState();', context);
assertOnly('overview');
document.body.dataset.cjdocRoute = 'api';
vm.runInContext('syncRouteState();', context);
assertOnly('api');
"""
        self.run_node(source, harness)

    def test_sidebar_prioritizes_active_symbol_and_retains_member_context(self) -> None:
        script = canonical_search_script()
        source = extract_callback(
            script, "  const positionSidebar = () => {",
            "\n  };\n  const syncRouteState",
        )
        harness = r"""
const assert = require("node:assert/strict");
const vm = require("node:vm");
const link = (position) => ({
  getBoundingClientRect: () => ({top: position}),
  classList: {contains: key => key === "is-current"},
  getAttribute: () => "",
});
const selected = link(900), packageLink = link(170);
const contextLink = link(380);
const context = {
  getBoundingClientRect: () => ({top: 240}),
  querySelectorAll: () => [],
};
const sidebar = {
  scrollTop: 0, clientHeight: 300,
  getBoundingClientRect: () => ({top: 100}),
  querySelector(selector) {
    if(selector === ".sidebar-context") return context;
    if(selector === ".sidebar-symbol.is-current") return selected;
    if(selector === ".sidebar-package.is-current") return packageLink;
    throw Error("Unknown selector " + selector);
  },
};
const window = {location: {hash: ""}};
const vmContext = vm.createContext({sidebar, window});
vm.runInContext(SOURCE + "\npositionSidebar();", vmContext);
assert.equal(sidebar.scrollTop, 900 - 100 - (300 / 3));
context.querySelectorAll = () => [contextLink];
sidebar.scrollTop = 0;
vm.runInContext("positionSidebar();", vmContext);
assert.equal(sidebar.scrollTop, 380 - 100 - (300 / 3));
"""
        self.run_node(source, harness)

    def test_mobile_theme_sheet_traps_focus_and_restores_background(self) -> None:
        script = canonical_search_script()
        start = "  const isMobileTheme = () =>"
        end = "  const closeTheme = (restoreFocus = false) => {"
        self.assertIn(start, script)
        self.assertIn(end, script)
        source = start + script.split(start, 1)[1].split(end, 1)[0]
        harness = r"""
const assert = require("node:assert/strict");
const vm = require("node:vm");
let document;
class Node {
  constructor(children = [], tabIndex = -1) {
    this.children = children;
    this.hidden = false;
    this.inert = false;
    this.tabIndex = tabIndex;
    this.attrs = {};
  }
  contains(target) { return this === target || this.children.some(child => child.contains(target)); }
  setAttribute(key, value) { this.attrs[key] = value; }
  removeAttribute(key) { delete this.attrs[key]; }
  getAttribute(key) { return this.attrs[key] || null; }
  querySelectorAll() { return this.children; }
  getClientRects() { return [{}]; }
  focus() { document.activeElement = this; }
}
const close = new Node([], 0), firstOption = new Node([], 0), lastOption = new Node([], 0);
const themePopover = new Node([close, firstOption, lastOption]);
const themeBackdrop = new Node();
const trigger = new Node([], 0);
const header = new Node([trigger, themeBackdrop, themePopover]);
const main = new Node();
const themeMenuContent = new Node();
const body = new Node([header, main, themeMenuContent]);
document = {body, activeElement: lastOption};
const window = {matchMedia: () => ({matches: true})};
const context = vm.createContext({document, window, themePopover, themeBackdrop});
vm.runInContext(SOURCE + "\nsetThemeModal(true);", context);
assert.equal(themePopover.getAttribute("role"), "dialog");
assert.equal(themePopover.getAttribute("aria-modal"), "true");
assert.equal(trigger.inert, true);
assert.equal(main.inert, true);
let prevented = false;
const trap = vm.runInContext("trapThemeFocus", context);
trap({key: "Tab", shiftKey: false, preventDefault() { prevented = true; }});
assert.equal(prevented, true);
assert.equal(document.activeElement, close);
close.focus();
prevented = false;
trap({key: "Tab", shiftKey: true, preventDefault() { prevented = true; }});
assert.equal(prevented, true);
assert.equal(document.activeElement, lastOption);
vm.runInContext("setThemeModal(false);", context);
assert.equal(themePopover.getAttribute("role"), "group");
assert.equal(themePopover.getAttribute("aria-modal"), null);
assert.equal(trigger.inert, false);
assert.equal(main.inert, false);
"""
        self.run_node(source, harness)

    def test_package_filter_hides_nested_symbols_but_not_matching_package(self) -> None:
        script = canonical_search_script()
        source = extract_callback(
            script, "  const filterSidebar = () => {",
            "\n  };\n  if (sidebarFilter)",
        )
        harness = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');
const alphaEntry = {hidden: false, symbols: {hidden: false}};
const betaEntry = {hidden: false, symbols: null};
const createLink = (name, entry) => ({
  hidden: false,
  querySelector: () => ({textContent: name}),
  closest: selector => selector === '.sidebar-package-entry' ? entry : null,
});
const alpha = createLink('alpha', alphaEntry);
const beta = createLink('beta', betaEntry);
const group = {
  open: true,
  hidden: false,
  querySelectorAll: selector => selector === '.sidebar-package' ? [alpha, beta] : [],
};
const sidebarFilter = {value: 'beta'};
const sidebarNoResults = {hidden: true};
const document = {querySelectorAll: selector => selector === '.sidebar-group' ? [group] : []};
const context = vm.createContext({document, sidebarFilter, sidebarNoResults});
vm.runInContext('let savedSidebarState = null;\n' + SOURCE + '\nfilterSidebar();', context);
assert.equal(group.hidden, false);
assert.equal(alpha.hidden, true);
assert.equal(alphaEntry.hidden, true, 'hidden symbols remain visible in their package group');
assert.equal(beta.hidden, false);
assert.equal(betaEntry.hidden, false);
assert.equal(sidebarNoResults.hidden, true);
sidebarFilter.value = '';
vm.runInContext('filterSidebar();', context);
assert.equal(alpha.hidden, false);
assert.equal(alphaEntry.hidden, false);
assert.equal(beta.hidden, false);
assert.equal(betaEntry.hidden, false);
assert.equal(group.open, true);
"""
        self.run_node(source, harness)


if __name__ == "__main__":
    unittest.main()
