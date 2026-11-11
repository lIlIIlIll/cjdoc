#!/usr/bin/env python3
"""Execute the generated sidebar tree, route, filter and drawer contracts in Node."""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script, canonical_theme_bootstrap_script


def extract_between(script: str, start: str, end: str, prelude: bool = True) -> str:
    """Keep tested JavaScript identical to the renderer's emitted script.

    The slice keeps the opening declaration through the closing brace that ends
    the function, so the harness can call it by name.
    """
    assert start in script, start
    body = script.split(start, 1)[1].split(end, 1)[0]
    terminator = end.split("\n\n", 1)[0]
    shared = ("  const isChinese = false;\n  const root = \"\";\n  const currentId = \"\";\n"
              "  const currentPage = \"\";\n")
    return (shared if prelude else "") + start + body + terminator + "\n"


DOM_PRELUDE = r"""
const assert = require("node:assert/strict");
const vm = require("node:vm");
const attrSelector = /^\[([a-z-]+)(?:=['"]?([^'"\]]*)['"]?)?\]$/;
function matchesSelector(node, selector) {
  for (const part of selector.split(",").map(value => value.trim())) {
    if (part === ":scope > ul") continue;
    if (part === ".cj-tree__label") {
      if ((node.className || "").split(" ").includes("cj-tree__label")) return true;
      continue;
    }
    if (part === "a[href]") {
      if (node.tag === "a" && "href" in node.attrs) return true;
      continue;
    }
    const compound = /^\.([A-Za-z0-9_-]+)(\[.+\])$/.exec(part);
    if (compound) {
      if ((node.className || "").split(" ").includes(compound[1]) &&
        matchesSelector(node, compound[2])) return true;
      continue;
    }
    if (part.startsWith(".")) {
      if ((node.className || "").split(" ").includes(part.slice(1))) return true;
      continue;
    }
    const attribute = attrSelector.exec(part);
    if (attribute) {
      const name = attribute[1];
      if (!(name in node.attrs)) continue;
      if (attribute[2] === undefined || node.attrs[name] === attribute[2]) return true;
    }
  }
  return false;
}
class Node {
  constructor(tag = "div", className = "") {
    this.tag = tag;
    this.className = className;
    this.attrs = {};
    this.dataset = {};
    this.children = [];
    this.hidden = false;
    this.tabIndex = 0;
    this.disabled = false;
    this.textContent = "";
    this.focused = false;
    this.parent = null;
  }
  append(...nodes) {
    for (const node of nodes) {
      node.parent = this;
      this.children.push(node);
    }
  }
  prepend(node) {
    node.parent = this;
    this.children.unshift(node);
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value);
    if (name.startsWith("data-")) {
      this.dataset[name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(value);
    }
  }
  removeAttribute(name) { delete this.attrs[name]; }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
  addEventListener(name, handler) { (this.events = this.events || {})[name] = handler; }
  get classList() {
    const own = this;
    return {
      contains: name => (own.className || "").split(" ").includes(name),
      add: name => {
        const names = (own.className || "").split(" ").filter(Boolean);
        if (!names.includes(name)) names.push(name);
        own.className = names.join(" ");
      },
      remove: name => {
        own.className = (own.className || "").split(" ")
          .filter(value => value && value !== name).join(" ");
      },
      toggle: (name, force) => {
        const present = (own.className || "").split(" ").includes(name);
        const next = force === undefined ? !present : Boolean(force);
        if (next && !present) own.classList.add(name);
        if (!next && present) own.classList.remove(name);
        return next;
      },
    };
  }
  focus() { this.focused = true; document.activeElement = this; }
  getBoundingClientRect() { return {top: this.top || 0}; }
  querySelector(selector) {
    if (selector.startsWith(":scope > ")) {
      const tag = selector.slice(":scope > ".length);
      return this.children.find(child => child.tag === tag) || null;
    }
    const found = this.search(selector);
    return found || null;
  }
  querySelectorAll(selector) { return this.searchAll(selector); }
  search(selector) {
    for (const child of this.children) {
      if (matchesSelector(child, selector)) return child;
      const nested = child.search(selector);
      if (nested) return nested;
    }
    return null;
  }
  searchAll(selector, into = []) {
    for (const child of this.children) {
      if (matchesSelector(child, selector)) into.push(child);
      child.searchAll(selector, into);
    }
    return into;
  }
  closest(selector) {
    let node = this;
    while (node) {
      if (matchesSelector(node, selector)) return node;
      node = node.parent;
    }
    return null;
  }
}
const build = (tag, className, attrs = {}) => {
  const node = new Node(tag, className);
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
  return node;
};
"""


@unittest.skipUnless(shutil.which("node"), "Node.js is required for browser-script regression tests")
class HtmlNavigationTest(unittest.TestCase):
    def run_node(self, implementation: str, harness: str) -> None:
        script = "const SOURCE = " + json.dumps(implementation) + ";\n" + DOM_PRELUDE + harness
        result = subprocess.run(
            ["node"], input=script, text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_route_state_marks_overview_page_and_api_ancestor(self) -> None:
        script = canonical_search_script()
        source = extract_between(script, "  const syncRouteState = () => {",
                                 "\n  };\n\n  const positionSidebar")
        harness = r"""
const sidebar = new Node("aside");
sidebar.dataset.cjdocCurrentPage = "index.html";
const overview = build("a", "cj-sidebar__link", {href: "index.html"});
const api = build("a", "cj-sidebar__link", {href: "index.html#packages"});
sidebar.append(overview, api);
const document = {body: {dataset: {cjdocRoute: "overview"}}};
const window = {location: {hash: ""}};
const context = vm.createContext({document, window, sidebar});
vm.runInContext(SOURCE + "\nsyncRouteState();", context);
const state = link => ({
  page: link.getAttribute("aria-current"),
  ancestor: (link.className || "").split(" ").includes("cj-sidebar__link--ancestor"),
});
assert.deepEqual(state(overview), {page: "page", ancestor: false});
assert.deepEqual(state(api), {page: null, ancestor: false});
// A fragment is client state on the same document: the overview stays current.
window.location.hash = "#packages";
vm.runInContext("syncRouteState();", context);
assert.deepEqual(state(overview), {page: "page", ancestor: false});
assert.deepEqual(state(api), {page: null, ancestor: true});
document.body.dataset.cjdocRoute = "api";
sidebar.dataset.cjdocCurrentPage = "symbols/member.html";
vm.runInContext("syncRouteState();", context);
assert.deepEqual(state(overview), {page: null, ancestor: false});
assert.deepEqual(state(api), {page: null, ancestor: true});
"""
        self.run_node(source, harness)

    def test_position_sidebar_prefers_current_page_then_deepest_ancestor(self) -> None:
        script = canonical_search_script()
        source = extract_between(script, "  const positionSidebar = () => {",
                                 "\n  };\n\n  const typeElements")
        harness = r"""
const run = (nodes) => {
  const sidebar = new Node("aside");
  for (const node of nodes) sidebar.append(node);
  sidebar.scrollTop = 0;
  sidebar.clientHeight = 300;
  sidebar.getBoundingClientRect = () => ({top: 100});
  const window = {location: {hash: ""}};
  const document = {body: {dataset: {}}};
  const context = vm.createContext({document, window, sidebar});
  vm.runInContext(SOURCE + "\npositionSidebar();", context);
  return sidebar.scrollTop;
};
const link = (className, top, current) => {
  const node = new Node("a", className);
  node.top = top;
  if (current) node.setAttribute("aria-current", "page");
  return node;
};
// The package row comes first in document order; the page entry deep in the
// branch is where the reader is.
assert.equal(run([link("cj-tree__link cj-tree__link--ancestor", 150),
  link("cj-tree__link", 900, true)]), 900 - 100 - 100);
// A member page has no current tree link; the type row is the deepest ancestor.
assert.equal(run([link("cj-tree__link cj-tree__link--ancestor", 150),
  link("cj-tree__link cj-tree__link--ancestor", 700)]), 700 - 100 - 100);
assert.equal(run([link("cj-sidebar__link", 40, true)]), 0);
"""
        self.run_node(source, harness)

    def test_filter_expands_matching_branch_and_hides_others(self) -> None:
        script = canonical_search_script()
        source = (extract_between(script, "  const packages = [];",
                                  "\n  };\n\n  const syncRouteState")
                  + extract_between(script, "  const typeElements = record => {",
                                    "\n  };\n\n  const initDrawer", prelude=False))
        harness = r"""
const tree = build("nav", "cj-tree");
const copperModule = build("section", "cj-tree__module",
  {"data-cjdoc-tree-module": ""});
const alphaModule = build("section", "cj-tree__module",
  {"data-cjdoc-tree-module": ""});
const alphaItem = build("li", "cj-tree__item",
  {"data-cjdoc-tree-item": "package", "data-cjdoc-tree-key": "packages/alpha.html"});
const copperItem = build("li", "cj-tree__item",
  {"data-cjdoc-tree-item": "package", "data-cjdoc-tree-key": "packages/copper.html"});
const alphaLink = build("a", "cj-tree__link", {href: "packages/alpha.html"});
alphaLink.append(build("span", "cj-tree__label"));
alphaLink.children[0].textContent = "alpha";
const copperLink = build("a", "cj-tree__link", {href: "packages/copper.html"});
copperLink.append(build("span", "cj-tree__label"));
copperLink.children[0].textContent = "copper";
for (const [item, link] of [[alphaItem, alphaLink], [copperItem, copperLink]]) {
  const row = build("div", "cj-tree__row");
  const toggle = build("button", "cj-tree__toggle", {"data-cjdoc-tree-toggle": "",
    "aria-expanded": "false"});
  toggle.hidden = true;
  row.append(toggle, link);
  item.append(row);
}
alphaModule.append(alphaItem);
copperModule.append(copperItem);
tree.append(alphaModule, copperModule);
const data = {
  version: 2,
  packages: [
    {id: "packages/alpha.html", label: "alpha", href: "packages/alpha.html",
      types: ["type-alpha"]},
    {id: "packages/copper.html", label: "copper", href: "packages/copper.html",
      types: ["type-copper"]},
  ],
  types: {
    "type-alpha": {label: "Alpha", kind: "class", kindLabel: "class",
      href: "symbols/alpha.html", members: ["member-alpha"]},
    "type-copper": {label: "Copper", kind: "class", kindLabel: "class",
      href: "symbols/copper.html", members: ["member-copper"]},
  },
  members: {
    "member-alpha": {label: "tone()", kind: "function", kindLabel: "function",
      anchor: "symbol-1"},
    "member-copper": {label: "wire()", kind: "function", kindLabel: "function",
      anchor: "symbol-2"},
  },
};
const filterInput = build("input", "cj-input");
filterInput.value = "";
const empty = build("p", "", {"data-cjdoc-sidebar-no-results": ""});
empty.hidden = true;
const document = {
  body: {dataset: {}},
  documentElement: new Node("html"),
  querySelector: selector => selector === "[data-cjdoc-sidebar-filter]" ? filterInput
    : selector === "[data-cjdoc-sidebar-no-results]" ? empty : null,
  querySelectorAll: () => [],
  createElement: tag => new Node(tag),
};
const window = {location: {hash: ""}, matchMedia: () => ({matches: false})};
const context = vm.createContext({document, window, tree, data, packages: undefined});
vm.runInContext(SOURCE + "\ninitSidebarTree();\nfilterSidebar();", context);
assert.equal(alphaItem.hidden, false);
assert.equal(copperItem.hidden, false);
filterInput.value = "wire";
vm.runInContext("filterSidebar();", context);
assert.equal(alphaItem.hidden, true, "packages without a match are hidden");
assert.equal(copperItem.hidden, false);
const copperTypes = copperItem.querySelector(":scope > ul");
assert(copperTypes, "a matching package expands its materialized children");
assert.equal(copperTypes.hidden, false);
assert.equal(copperItem.querySelector("[data-cjdoc-tree-toggle]")
  .getAttribute("aria-expanded"), "true");
assert.equal(empty.hidden, true);
filterInput.value = "zzzzzz";
vm.runInContext("filterSidebar();", context);
assert.equal(alphaItem.hidden, true);
assert.equal(copperItem.hidden, true);
assert.equal(empty.hidden, false);
filterInput.value = "";
vm.runInContext("filterSidebar();", context);
assert.equal(alphaItem.hidden, false);
assert.equal(copperItem.hidden, false);
assert.equal(empty.hidden, true);
"""
        self.run_node(source, harness)

    def test_drawer_sets_page_state_and_restores_focus(self) -> None:
        script = canonical_search_script()
        source = extract_between(script, "  const initDrawer = () => {",
                                 "\n  };\n\n  initSidebarTree")
        harness = r"""
const sidebar = new Node("aside", "cj-sidebar");
sidebar.append(build("input", "cj-input", {"data-cjdoc-sidebar-filter": ""}));
const menu = build("button", "", {"data-cjdoc-menu": "", "aria-expanded": "false"});
const backdrop = build("button", "", {"data-cjdoc-menu-backdrop": ""});
backdrop.hidden = true;
const header = build("header", "cj-header");
const main = build("main", "cj-main");
const document = {
  body: {dataset: {}},
  documentElement: new Node("html"),
  activeElement: null,
  querySelector: selector => selector === "[data-cjdoc-menu]" ? menu
    : selector === "[data-cjdoc-menu-backdrop]" ? backdrop
    : selector === "[data-cjdoc-sidebar-close]" ? null : null,
  querySelectorAll: selector => selector === ".cj-header, .cj-main, .cj-toc, .cj-footer"
    ? [header, main] : [],
};
document.addEventListener = () => {};
const window = {matchMedia: () => ({matches: true}), addEventListener() {}};
const context = vm.createContext({document, window, sidebar});
vm.runInContext(SOURCE + "\ninitDrawer();", context);
menu.events.click();
assert.equal(menu.getAttribute("aria-expanded"), "true");
assert.equal(document.documentElement.getAttribute("data-cj-drawer"), "open");
assert.equal(backdrop.hidden, false);
assert.equal(header.getAttribute("inert"), "");
assert.equal(main.getAttribute("inert"), "");
assert.equal(sidebar.getAttribute("role"), "dialog");
assert.equal(sidebar.getAttribute("aria-modal"), "true");
menu.events.click();
assert.equal(menu.getAttribute("aria-expanded"), "false");
assert.equal(document.documentElement.getAttribute("data-cj-drawer"), null);
assert.equal(backdrop.hidden, true);
assert.equal(header.getAttribute("inert"), null);
assert.equal(main.getAttribute("inert"), null);
assert.equal(menu.focused, true, "closing the drawer returns focus to its trigger");
"""
        self.run_node(source, harness)

    def test_theme_bootstrap_url_choice_beats_storage_and_reader_values_are_allow_listed(self) -> None:
        harness = r"""
// DOM_PRELUDE already provides assert and vm.
const boot = (search, stored) => {
  const attrs = {};
  const root = {
    setAttribute(name, value) { attrs[name] = value; },
    removeAttribute(name) { delete attrs[name]; },
  };
  const context = vm.createContext({
    document: {documentElement: root, addEventListener() {}},
    window: {location: {search, href: "https://example.test/a.html" + search},
             history: {replaceState() {}}},
    localStorage: {getItem: key => stored[key] ?? null, setItem() {}},
    URLSearchParams, URL,
  });
  vm.runInContext(SOURCE, context);
  return attrs;
};
// An explicit ?theme=system is a choice, not an absence: it overrides storage.
assert.equal(boot("?theme=system", {"cjdoc-theme": "dark"})["data-theme"], undefined);
assert.equal(boot("", {"cjdoc-theme": "dark"})["data-theme"], "dark");
assert.equal(boot("?theme=ocean", {"cjdoc-theme": "dark"})["data-theme"], "ocean");
assert.equal(boot("?theme=bogus", {"cjdoc-theme": "paper"})["data-theme"], "paper");
const reader = boot("", {"cjdoc-reader": JSON.stringify({font: "serif", size: "l"})});
assert.equal(reader["data-cj-font"], "serif");
assert.equal(reader["data-cj-size"], "l");
assert.equal("data-cj-js" in reader, true);
const hostile = boot("", {"cjdoc-reader": JSON.stringify({font: "x\" onload=\"y", size: "xl"})});
assert.equal("data-cj-font" in hostile, false);
assert.equal("data-cj-size" in hostile, false);
assert.equal("data-cj-font" in boot("", {"cjdoc-reader": "{not json"}), false);
"""
        self.run_node(canonical_theme_bootstrap_script(), harness)


if __name__ == "__main__":
    unittest.main()
