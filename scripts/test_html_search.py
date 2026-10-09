#!/usr/bin/env python3
"""Execute the shipped search script against a small DOM test double."""
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script


@unittest.skipUnless(shutil.which("node"), "Node.js is needed to execute browser JavaScript")
class HtmlSearchTest(unittest.TestCase):
    def test_copy_readable_link_clipboard_and_manual_fallback(self):
        harness = r'''
const assert = require("node:assert/strict");
const vm = require("node:vm");
(async () => {
  const inserted = [];
  const button = {dataset: {cjdocCopyLink: "../members/Client.read.html"}, textContent:"复制链接", events:{},
    classList: {contains: () => false}, // The page-level text button is not an icon-only member action.
    addEventListener(name, handler) { this.events[name] = handler; },
    parentElement: {querySelector: () => inserted[0] || null},
    insertAdjacentElement(_, node) { inserted.push(node); }};
  const document = {querySelector: () => null,
    querySelectorAll: selector => selector === "[data-cjdoc-copy-link]" ? [button] : [],
    documentElement:{lang:"zh-CN"}, body:{dataset:{}, append() {}}, activeElement:null,
    addEventListener() {}, execCommand: () => false,
    createElement: () => ({style:{},dataset:{},setAttribute() {},remove() {},
      focus() {this.focused=true;}, select() {this.selected=true;}})};
  let copied;
  const clipboard = {writeText: async value => {copied=value;}};
  const location = {pathname:"/docs/symbols/long-id.html",href:"https://example.test/docs/symbols/long-id.html",hash:""};
  const window = {location,isSecureContext:true,addEventListener() {},setTimeout() {}};
  const context = {document,window,location,URL,navigator:{clipboard},
    performance:{getEntriesByType:()=>[]},requestAnimationFrame:callback=>callback()};
  vm.runInNewContext(SCRIPT, context);
  await button.events.click();
  assert.equal(copied,"https://example.test/docs/members/Client.read.html");
  assert.equal(button.dataset.copyLinkResult,"copied");
  assert.equal(button.textContent,"链接已复制");
  clipboard.writeText = async () => {throw Error("clipboard denied");};
  await button.events.click();
  assert.equal(button.dataset.copyLinkResult,"manual");
  assert.equal(inserted.length,1);
  assert.equal(inserted[0].value,copied);
  assert.equal(inserted[0].readOnly,true);
  assert(inserted[0].focused && inserted[0].selected);
})().catch(error => {console.error(error);process.exitCode=1;});
'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node"], input=script, text=True, encoding="utf-8", capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

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
const context = {document, window, requestAnimationFrame: callback => callback(),
 location: {pathname: "/fixture/index.html"}, performance: {getEntriesByType: () => []}, __CJDOC_SEARCH_INDEX__: {schemaVersion: "cjdoc.search-index/7",
entries: [entry("HttpClientBuilder"), entry("HTTPConnectionBuffer"), entry("httpclientbuilder"),
 entry("HttpClientBuilder", "other"), entry("send", "net", "function"), entry("BuilderTools"),
 entry("Nova"), entry("a".repeat(128)), entry("a".repeat(129))]}};
context.__CJDOC_SEARCH_INDEX__.entries.push(
 {...entry("overloaded", "net", "function"), id:"module-a", ownerName:"net.Client", moduleName:"sdk-a", moduleId:"cjdoc:module:a"},
 {...entry("overloaded", "net", "function"), id:"module-b", ownerName:"net.Client", moduleName:"sdk-b", moduleId:"cjdoc:module:b"});
context.__CJDOC_SEARCH_SIGNATURES__ = {"module-a":"func overloaded(String)", "module-b":"func overloaded(Int64)"};
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
// Native history may restore a select value without dispatching change.
kind.value = "class";
assert.equal(search("send").length, 0);
assert(search("Http").includes("HttpClientBuilder"));
kind.value = "class"; kind.events.change();
assert.equal(search("send").length, 0);
kind.value = ""; kind.events.change(); search("Http");
input.events.keydown({key: "ArrowDown", preventDefault() {}});
assert.equal(input.attrs["aria-activedescendant"], "cjdoc-search-result-0");
const link = results.children[0].children[0];
input.events.keydown({key: "Enter", preventDefault() {}}); assert(link.clicked);
input.events.keydown({key: "Escape"}); assert.equal(results.children.length, 0);
document.keydown({key: "k", ctrlKey: true, preventDefault() {}}); assert(input.focused);
assert.equal(search("overloaded").length, 2);
const moduleLinks = results.children.map(item => item.children[0]);
assert.deepEqual(moduleLinks.map(link => link.children[1].textContent), ["net.Client · sdk-a", "net.Client · sdk-b"]);
assert.equal(moduleLinks[0].children[1].title, "net.overloaded · sdk-a · cjdoc:module:a");
assert.notEqual(moduleLinks[0].children[2].textContent, moduleLinks[1].children[2].textContent);
'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node"], input=script, text=True, encoding="utf-8", capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
