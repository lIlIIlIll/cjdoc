#!/usr/bin/env python3
"""Execute the shipped search script against a small DOM test double."""
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script


@unittest.skipUnless(shutil.which("node"), "Node.js is needed to execute browser JavaScript")
class HtmlSearchTest(unittest.TestCase):
    def test_search_ranking_filters_preview_and_keyboard(self):
        harness = r'''
const assert = require("node:assert/strict");
const vm = require("node:vm");
class Element {
  constructor(tag = "") { this.tag = tag; this.children = []; this.dataset = {}; this.value = ""; this.attrs = {}; this.events = {}; }
  append(...children) { this.children.push(...children); }
  replaceChildren() { this.children = []; }
  setAttribute(name, value) { this.attrs[name] = value; }
  removeAttribute(name) { delete this.attrs[name]; }
  addEventListener(name, handler) { this.events[name] = handler; }
  querySelector(tag) { return this.children.find(child => child.tag === tag) || null; }
  scrollIntoView() {}
  focus() { this.focused = true; }
  click() { this.clicked = true; }
}
const input = new Element(), results = new Element(), kind = new Element(), pkg = new Element();
const controls = {"[data-cjdoc-search]": input, "[data-cjdoc-results]": results,
  "[data-cjdoc-kind]": kind, "[data-cjdoc-package]": pkg};
const document = {querySelector: key => controls[key] || null, querySelectorAll: () => [],
  createElement: tag => new Element(tag), documentElement: {lang: "en"},
  addEventListener: (key, handler) => { document[key] = handler; }};
const entry = (name, packageName = "net", type = "class") => ({id: packageName + name,
 name, qualifiedName: packageName + "." + name, packageName, kind: type,
 summary: "<script>literal preview</script>", href: "symbols/" + name + ".html"});
const context = {document, window: {}, __CJDOC_SEARCH_INDEX__: {schemaVersion: "cjdoc.search-index/4",
 entries: [entry("HttpClientBuilder"), entry("HTTPConnectionBuffer"), entry("httpclientbuilder"),
 entry("HttpClientBuilder", "other"), entry("send", "net", "function")]}};
vm.runInNewContext(SCRIPT, context);
const search = query => { input.value = query; input.events.input(); return results.children.map(x => x.children[0].children[0].textContent); };
assert.equal(search("HttpClientBuilder")[0], "net.HttpClientBuilder");
assert.equal(search("httpclientbuilder")[0], "net.httpclientbuilder");
assert(search("hcb").includes("net.HttpClientBuilder"));
assert(search("hcb").includes("net.HTTPConnectionBuffer"));
assert(search("builder").includes("net.HttpClientBuilder"));
assert(search("HttpClentBuilder").includes("net.HttpClientBuilder"));
assert.equal(search("zzzzzz").length, 0);
pkg.value = "other"; pkg.events.change();
assert.deepEqual(search("hcb"), ["other.HttpClientBuilder"]);
assert.equal(results.children[0].children[0].children[2].textContent, "<script>literal preview</script>");
kind.value = "function"; kind.events.change(); assert.equal(results.children.length, 0);
kind.value = ""; pkg.value = ""; search("hcb");
input.events.keydown({key: "ArrowDown", preventDefault() {}});
assert.equal(input.attrs["aria-activedescendant"], "cjdoc-search-result-0");
const link = results.children[0].children[0];
input.events.keydown({key: "Enter", preventDefault() {}}); assert(link.clicked);
input.events.keydown({key: "Escape"}); assert.equal(results.children.length, 0);
document.keydown({key: "k", ctrlKey: true, preventDefault() {}}); assert(input.focused);
'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node", "-e", script], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
