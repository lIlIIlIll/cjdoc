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
  closest() { return null; }
  scrollIntoView() {}
  focus() { this.focused = true; }
  blur() { this.blurred = true; }
  click() { this.clicked = true; }
}
const input = new Element(), results = new Element(), kind = new Element(), pkg = new Element();
kind.value = "";
const controls = {"[data-cjdoc-search]": input, "[data-cjdoc-results]": results,
  "[data-cjdoc-kind]": kind, "[data-cjdoc-package]": pkg};
const document = {querySelector: key => controls[key] || null,
  querySelectorAll: () => [],
  createElement: tag => new Element(tag), documentElement: {lang: "en"},
  body: { dataset: {} },
  addEventListener: (key, handler) => { document[key] = handler; }};
const window = {location: {hash: ""}, addEventListener: (key, handler) => { window[key] = handler; }};
const entry = (name, packageName = "net", type = "class") => ({id: packageName + name,
 name, qualifiedName: packageName + "." + name, packageName, kind: type,
 summary: "<script>literal preview</script>", href: "symbols/" + name + ".html"});
const context = {document, window, location: {pathname: "/fixture/index.html"}, performance: {getEntriesByType: () => []}, __CJDOC_SEARCH_INDEX__: {schemaVersion: "cjdoc.search-index/6",
entries: [entry("HttpClientBuilder"), entry("HTTPConnectionBuffer"), entry("httpclientbuilder"),
 entry("HttpClientBuilder", "other"), entry("send", "net", "function"), entry("BuilderTools"),
 entry("Nova"), entry("a".repeat(128)), entry("a".repeat(129))]}};
vm.runInNewContext(SCRIPT, context);
const search = query => { input.value = query; input.events.input(); return results.children.map(x => x.children[0].children[0].children[0].textContent); };
assert(search("HttpClientBuilder").includes("HttpClientBuilder"));
assert(search("httpclientbuilder").includes("httpclientbuilder"));
assert(search("Http").includes("HttpClientBuilder"));
assert(search("Http").includes("HTTPConnectionBuffer"));
assert(search("builder").includes("HttpClientBuilder"));
assert.equal(search("buil")[0], "BuilderTools");
assert(search("HCB").includes("HttpClientBuilder"));
assert(search("HttClientBuilder").includes("HttpClientBuilder"));
assert(search("HtttpClientBuilder").includes("HttpClientBuilder"));
assert(search("HttpClientBuildex").includes("HttpClientBuilder"));
assert.equal(search("HxtClientBuildeq").length, 0);
assert(search("Niva").includes("Nova"));
assert.equal(search("Nva").length, 0);
const maxLengthTypo = "a".repeat(127) + "b";
assert(search(maxLengthTypo).includes("a".repeat(128)));
const tooLongTypo = "a".repeat(128) + "b";
assert.equal(search(tooLongTypo).length, 0);
assert(search("package:other").includes("HttpClientBuilder"));
assert.equal(search("zzzzzz").length, 0);
pkg.value = "other"; pkg.events.change();
assert.deepEqual(search("Http"), ["HttpClientBuilder"]);
assert.equal(results.children[0].children[0].children[2].textContent, "<script>literal preview</script>");
pkg.value = ""; pkg.events.change();
kind.value = "function"; kind.events.change();
assert.deepEqual(search("send"), ["send"]);
assert.deepEqual(search("Http"), []);
kind.value = "class"; kind.events.change();
assert.equal(search("send").length, 0);
kind.value = ""; kind.events.change(); search("Http");
input.events.keydown({key: "ArrowDown", preventDefault() {}});
assert.equal(input.attrs["aria-activedescendant"], "cjdoc-search-result-0");
const link = results.children[0].children[0];
input.events.keydown({key: "Enter", preventDefault() {}}); assert(link.clicked);
input.events.keydown({key: "Escape"}); assert.equal(results.children.length, 0);
document.keydown({key: "k", ctrlKey: true, preventDefault() {}}); assert(input.focused);
'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
