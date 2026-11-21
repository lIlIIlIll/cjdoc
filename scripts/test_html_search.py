#!/usr/bin/env python3
"""Execute the shipped search script against a small DOM test double."""
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script


@unittest.skipUnless(shutil.which("node"), "Node.js is needed to execute browser JavaScript")
class HtmlSearchTest(unittest.TestCase):

    def test_search_dialog_is_created_on_first_request_and_reused(self):
        harness = r'''
const assert = require("node:assert/strict");
const vm = require("node:vm");

// ---- minimal but real DOM ------------------------------------------------
// The page starts with the server-rendered markup (header trigger only) and
// anything a controller builds is discovered by descending from the tree.
let activeDocument = null;

const datasetName = name => name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());

class ClassList {
  constructor(node) { this.node = node; }
  values() { return (this.node.attrs.class || "").split(/\s+/).filter(Boolean); }
  write(values) {
    if (values.length) this.node.attrs.class = values.join(" ");
    else delete this.node.attrs.class;
  }
  contains(name) { return this.values().includes(name); }
  add(...names) {
    const values = this.values();
    for (const name of names) if (!values.includes(name)) values.push(name);
    this.write(values);
  }
  remove(...names) { this.write(this.values().filter(value => !names.includes(value))); }
  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : Boolean(force);
    if (on) this.add(name); else this.remove(name);
    return on;
  }
}

const parseCompound = text => {
  const compound = {tag: null, id: null, classes: [], attrs: []};
  let rest = text.replace(/^:scope/, "");
  const token = /^(\[([^\]]+)\]|#([^.#\[]+)|\.([^.#\[]+)|([A-Za-z][A-Za-z0-9-]*))/;
  while (rest.length) {
    const match = token.exec(rest);
    if (!match) { rest = rest.slice(1); continue; }
    if (match[2] !== undefined) {
      const body = match[2];
      const equals = body.indexOf("=");
      if (equals < 0) compound.attrs.push({name: body.trim()});
      else compound.attrs.push({
        name: body.slice(0, equals).trim(),
        value: body.slice(equals + 1).trim().replace(/^["']|["']$/g, "")
      });
    } else if (match[3] !== undefined) compound.id = match[3];
    else if (match[4] !== undefined) compound.classes.push(match[4]);
    else if (match[5] !== undefined) compound.tag = match[5].toLowerCase();
    rest = rest.slice(match[0].length);
  }
  return compound;
};

const parseSelector = selector => selector.split(",").map(part => {
  const tokens = part.trim().replace(/\s*>\s*/g, " > ").split(/\s+/).filter(Boolean);
  const steps = [];
  let combinator = " ";
  for (const token of tokens) {
    if (token === ">") { combinator = ">"; continue; }
    steps.push({combinator, compound: parseCompound(token)});
    combinator = " ";
  }
  return steps;
}).filter(steps => steps.length);

const matchesCompound = (node, compound) => {
  if (!(node instanceof DomElement)) return false;
  if (compound.tag && node.tag !== compound.tag) return false;
  if (compound.id && node.id !== compound.id) return false;
  for (const name of compound.classes) if (!node.classList.contains(name)) return false;
  for (const attr of compound.attrs) {
    if (!Object.prototype.hasOwnProperty.call(node.attrs, attr.name)) return false;
    if (attr.value !== undefined && node.attrs[attr.name] !== attr.value) return false;
  }
  return true;
};

const matchesAt = (node, steps, index) => {
  if (!matchesCompound(node, steps[index].compound)) return false;
  if (index === 0) return true;
  if (steps[index].combinator === ">") {
    const parent = node.parentElement;
    return Boolean(parent) && matchesAt(parent, steps, index - 1);
  }
  for (let parent = node.parentElement; parent; parent = parent.parentElement) {
    if (matchesAt(parent, steps, index - 1)) return true;
  }
  return false;
};

const matchesSelector = (node, selector) =>
  parseSelector(selector).some(steps => matchesAt(node, steps, steps.length - 1));

const descendants = node => {
  const found = [];
  const walk = parent => {
    for (const child of parent.children) {
      if (child instanceof DomElement) { found.push(child); walk(child); }
    }
  };
  walk(node);
  return found;
};

class DomText {
  constructor(text) { this.text = String(text); this.parent = null; this.children = []; }
  get parentElement() { return this.parent instanceof DomElement ? this.parent : null; }
  get textContent() { return this.text; }
  set textContent(value) { this.text = String(value); }
  contains(node) { return node === this; }
}

class DomElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.attrs = {};
    this.dataset = {};
    this.text = "";
    this.value = "";
    this.listeners = {};
    this.classList = new ClassList(this);
  }
  addEventListener(name, handler) { (this.listeners[name] = this.listeners[name] || []).push(handler); }
  removeEventListener(name, handler) {
    this.listeners[name] = (this.listeners[name] || []).filter(entry => entry !== handler);
  }
  dispatch(name, event = {}) {
    const payload = {...event};
    if (!payload.target) payload.target = this;
    if (!payload.preventDefault) payload.preventDefault = () => { payload.defaultPrevented = true; };
    for (const handler of [...(this.listeners[name] || [])]) handler(payload);
    if (payload.bubbles === false) return payload;
    const next = this.parent instanceof DomElement ? this.parent
      : this.parent && typeof this.parent.dispatch === "function" ? this.parent : null;
    if (next) next.dispatch(name, payload);
    return payload;
  }
  get parentElement() { return this.parent instanceof DomElement ? this.parent : null; }
  get textContent() {
    return this.children.length ? this.children.map(child => child.textContent).join("") : this.text;
  }
  set textContent(value) { this.children = []; this.text = String(value); }
  get id() { return this.attrs.id || ""; }
  set id(value) { this.setAttribute("id", value); }
  get tagName() { return this.tag.toUpperCase(); }
  get lang() { return this.attrs.lang || ""; }
  set lang(value) { this.setAttribute("lang", value); }
  get className() { return this.attrs.class || ""; }
  set className(value) { this.setAttribute("class", value); }
  get hidden() { return Object.prototype.hasOwnProperty.call(this.attrs, "hidden"); }
  set hidden(value) {
    if (value) this.attrs.hidden = ""; else delete this.attrs.hidden;
  }
  get open() { return Object.prototype.hasOwnProperty.call(this.attrs, "open"); }
  set open(value) {
    if (value) this.attrs.open = ""; else delete this.attrs.open;
  }
  get childElementCount() { return this.children.filter(child => child instanceof DomElement).length; }
  append(...nodes) {
    for (const node of nodes) {
      if (node.parent) node.parent.children = node.parent.children.filter(child => child !== node);
      node.parent = this;
      this.children.push(node);
    }
  }
  prepend(...nodes) {
    for (const node of [...nodes].reverse()) {
      if (node.parent) node.parent.children = node.parent.children.filter(child => child !== node);
      node.parent = this;
      this.children.unshift(node);
    }
  }
  replaceChildren(...nodes) { this.children = []; this.text = ""; this.append(...nodes); }
  remove() {
    if (!this.parent) return;
    this.parent.children = this.parent.children.filter(child => child !== this);
    this.parent = null;
  }
  contains(node) {
    if (!node) return false;
    if (node === this) return true;
    return this.children.some(child => child.contains && child.contains(node));
  }
  setAttribute(name, value) {
    const text = String(value);
    this.attrs[name] = text;
    if (name.startsWith("data-")) this.dataset[datasetName(name.slice(5))] = text;
  }
  removeAttribute(name) {
    delete this.attrs[name];
    if (name.startsWith("data-")) delete this.dataset[datasetName(name.slice(5))];
  }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
  }
  hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name); }
  toggleAttribute(name, force = !this.hasAttribute(name)) {
    if (!force) this.removeAttribute(name);
    else if (!this.hasAttribute(name)) this.setAttribute(name, "");
    return Boolean(force);
  }
  matches(selector) { return matchesSelector(this, selector); }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) {
      if (matchesSelector(node, selector)) return node;
    }
    return null;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  querySelectorAll(selector) {
    return descendants(this).filter(node => matchesSelector(node, selector));
  }
  focus() { this.focused = true; if (activeDocument) activeDocument.activeElement = this; }
  blur() { this.blurred = true; }
  select() { this.selected = true; }
  click() { this.clicked = true; this.dispatch("click", {button: 0}); }
  scrollIntoView() {}
  showModal() { this.open = true; }
  close() { this.open = false; this.dispatch("close", {}); }
  insertAdjacentElement(_position, node) { this.parent.append(node); return node; }
}

class DomDocument {
  constructor(options = {}) {
    this.activeElement = null;
    this.listeners = {};
    this.failTags = new Set(options.failTags || []);
    this.documentElement = this.createElement("html");
    this.documentElement.setAttribute("lang", options.lang || "en");
    this.head = this.createElement("head");
    this.body = this.createElement("body");
    this.documentElement.append(this.head, this.body);
    this.documentElement.parent = this;
  }
  addEventListener(name, handler) { (this.listeners[name] = this.listeners[name] || []).push(handler); }
  removeEventListener(name, handler) {
    this.listeners[name] = (this.listeners[name] || []).filter(entry => entry !== handler);
  }
  dispatch(name, event = {}) {
    const payload = {...event};
    if (!payload.target) payload.target = this;
    if (!payload.preventDefault) payload.preventDefault = () => { payload.defaultPrevented = true; };
    for (const handler of [...(this.listeners[name] || [])]) handler(payload);
    return payload;
  }
  createElement(tag) {
    const name = String(tag).toLowerCase();
    if (this.failTags.has(name)) throw new Error("createElement failed: " + name);
    return new DomElement(name);
  }
  createElementNS(_namespace, tag) { return this.createElement(tag); }
  createTextNode(text) { return new DomText(text); }
  querySelector(selector) { return this.documentElement.querySelector(selector); }
  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  getElementById(id) { return this.querySelectorAll("[id]").find(node => node.id === id) || null; }
}

const contract = {
 version: "cjdoc.search-contract/2", maxRequestBytes: 1048576,
 defaultMode: "precise", defaultProfile: "full-ir", defaultLimit: 20, maxLimit: 100,
 maxFilters: 64, maxTags: 64, staticBodyTextLimit: 2000, summaryDisplayLimit: 240, signatureDisplayLimit: 512,
 textPolicy: {caseFold:"ascii-only", normalization:"none",
   tokens:"ascii-alnum-underscore-or-u0080-plus", words:"ascii-camel-acronym-boundaries",
   edit:"one-scalar-insert-delete-substitute", minEditRunes:4, maxEditRunes:128},
 globalFields: ["schemaVersion", "operation", "snapshotId", "language", "languageFallback", "audience", "cfgProfile"],
 searchFields: ["query", "symbolId", "symbolKey", "name", "qualifiedName", "parameterTypes", "genericArity",
   "kind", "moduleId", "packageName", "documentSetId", "apiVersion", "library", "dependencyInstanceId",
   "target", "cfg", "latest", "limit", "cursor", "mode", "profile", "filters", "tags"],
 requestProperties: {
   schemaVersion: {const: "cjdoc.query-request/3"},
   operation: {enum: ["resolve_docs", "search", "get_symbol"]},
   query: {type: "string", maxLength: 4096},
   snapshotId: {type: "string", minLength: 1, maxLength: 256},
   language: {type: "string", minLength: 1, maxLength: 64},
   languageFallback: {type: "boolean"},
   audience: {enum: ["external", "package", "all"]},
   cfgProfile: {type: "string", minLength: 1, maxLength: 16384},
   symbolId: {type: "string", minLength: 1, maxLength: 16384},
   symbolKey: {type: "string", minLength: 1, maxLength: 16384},
   name: {type: "string", minLength: 1, maxLength: 16384},
   qualifiedName: {type: "string", minLength: 1, maxLength: 16384},
   parameterTypes: {type: "array", maxItems: 1024, items: {type: "string", maxLength: 16384}},
   genericArity: {type: "integer", minimum: 0, maximum: 1024},
   kind: {type: "string", minLength: 1, maxLength: 128},
   moduleId: {type: "string", minLength: 1, maxLength: 16384},
   packageName: {type: "string", minLength: 1, maxLength: 16384},
   documentSetId: {type: "string", minLength: 1, maxLength: 16384},
   apiVersion: {type: "string", minLength: 1, maxLength: 1024},
   library: {type: "string", minLength: 1, maxLength: 16384},
   dependencyInstanceId: {type: "string", minLength: 1, maxLength: 16384},
   target: {type: "string", minLength: 1, maxLength: 1024},
   cfg: {type: "string", minLength: 1, maxLength: 16384},
   latest: {type: "boolean"},
   limit: {type: "integer", minimum: 0, maximum: 100},
   cursor: {type: "string", minLength: 1, maxLength: 1024},
   mode: {enum: ["precise", "discovery"]},
   profile: {enum: ["full-ir", "bounded-static"]},
   filters: {type: "array", maxItems: 64, items: {type: "object", additionalProperties: false,
     required: ["field", "op", "value"], properties: {
       field: {enum: ["name", "qualifiedName", "owner", "param", "return", "package", "kind"]},
       op: {enum: ["eq", "contains"]},
       value: {type: "string", minLength: 1, maxLength: 16384}
     }}},
   tags: {type: "array", minItems: 1, maxItems: 64, items: {
     type: "string", minLength: 1, maxLength: 64, pattern: "^[A-Za-z0-9_-]{1,64}$"
   }}
 },
 filterFields: [
   {field: "name", property: "name", context: "canonical-or-exposure"},
   {field: "qualifiedName", property: "qualifiedName", context: "canonical-or-exposure"},
   {field: "owner", property: ["ownerName", "ownerQualifiedName"], context: "entry"},
   {field: "param", property: "parameterTypes", context: "entry"},
   {field: "return", property: ["returnType", "returnCanonical"], context: "entry"},
   {field: "package", property: "packageName", context: "canonical-or-exposure"},
   {field: "kind", property: "kind", context: "entry"}
 ],
 filterOps: [
   {op: "eq", primitive: "exact_string_equal"},
   {op: "contains", primitive: "ascii_fold_contains"}
 ],
 setPredicates: [{field: "tags", property: "tagIds", primitive: "all_exact"}],
 preciseRules: [
   ["exact_symbol_id", 4, 4000, "symbol_id"], ["exact_symbol_key", 4, 4000, "symbol_key"],
   ["exact_qualified_name", 3, 3000, "qualified_name"],
   ["exact_qualified_name_with_selector", 3, 3000, "qualified_name_with_overload_selector"],
   ["exact_name", 2, 2040, "declaration_name"],
   ["exact_name_with_selector", 2, 2040, "declaration_name_with_overload_selector"],
   ["query_exact_name", 2, 2000, "declaration_name"],
   ["query_exact_name_with_selector", 2, 2000, "declaration_name_with_overload_selector"],
   ["exact_owner_member", 2, 2020, "owner_member_name"],
   ["exact_owner_member_with_selector", 2, 2020, "owner_member_name_with_overload_selector"],
   ["exact_alias", 2, 2030, "exposed_reexport_alias"],
   ["exact_alias_with_selector", 2, 2030, "exposed_reexport_alias_with_overload_selector"],
   ["structured_text", 1, 1010, "declaration_text"],
   ["structured_text_with_selector", 1, 1010, "declaration_text_with_overload_selector"],
   ["documentation_text", 1, 1010, "documentation_text"],
   ["documentation_text_with_selector", 1, 1010, "documentation_text_with_overload_selector"],
   ["concept_text", 1, 1010, "guide_text"], ["filter_only", 0, 0, "filter_only"]
 ].map(([primitive, level, score, reason]) => ({primitive, level, score, reason})),
 discoveryRules: [
   ["exact_symbol_id", 12, 12000, "symbol_id"], ["exact_symbol_key", 12, 12000, "symbol_key"],
   ["exact_qualified_name", 11, 11000, "qualified_name"], ["exact_name", 10, 10000, "declaration_name"],
   ["exact_owner_member", 10, 10000, "owner_member_name"], ["exact_alias", 10, 10000, "exposed_reexport_alias"],
   ["ascii_fold_name", 9, 9000, "name_casefold"], ["name_prefix", 8, 8000, "name_prefix"],
   ["qualified_prefix", 7, 7000, "qualified_prefix"], ["all_token_word_prefix", 6, 6000, "word_prefix"],
   ["acronym", 5, 5000, "acronym"], ["structured_text", 4, 4000, "declaration_text"],
   ["one_edit", 3, 3000, "edit_distance_one"], ["documentation_text", 2, 2000, "documentation_text"],
   ["concept_text", 2, 2000, "guide_text"], ["filter_only", 0, 0, "filter_only"]
 ].map(([primitive, level, score, reason]) => ({primitive, level, score, reason}))
};
const makeDocumentSet = (moduleId, id, library, target, cfg) => ({
  id, moduleId, library, identity: library, state:"declared", source:"captured",
  target, cfg, audience:"external", language:"en", revision:"rev",
  apiVersion:"1.0", documentationRevision:"docs", indexIdentity:"index", baseUrl:""
});
const makeDependency = (moduleId, name, instanceId, target, cfg) => ({
  moduleId:"cjdoc:module:consumer", componentModuleId:moduleId, name, instanceId, kind:"source",
  identity:name, state:"declared", evidence:"captured", version:"1.0",
  revision:"rev", target, cfg
});
const documentSetA = makeDocumentSet("cjdoc:module:a", "document-a", "library-a", "target-a", "cfg-a");
const documentSetB = makeDocumentSet("cjdoc:module:b", "document-b", "library-b", "target-b", "cfg-b");
const dependencyA = makeDependency("cjdoc:module:a", "library-a", "dependency-a", "target-a", "cfg-a");
const dependencyB = makeDependency("cjdoc:module:b", "library-b", "dependency-b", "target-b", "cfg-b");
const modules = [
 {moduleId: "cjdoc:module:net", moduleName: "net", documentSet: null, dependency: null, dependencyInstanceState: "not_applicable"},
 {moduleId: "cjdoc:module:other", moduleName: "other", documentSet: null, dependency: null, dependencyInstanceState: "not_applicable"},
 {moduleId: "cjdoc:module:a", moduleName: "sdk-a", documentSet:documentSetA, dependency:dependencyA, dependencyInstanceState: "recorded"},
 {moduleId: "cjdoc:module:b", moduleName: "sdk-b", documentSet:documentSetB, dependency:dependencyB, dependencyInstanceState: "recorded"},
 {moduleId: "cjdoc:module:private", moduleName: "private", documentSet: null, dependency: null, dependencyInstanceState: "not_applicable"},
 {moduleId: "cjdoc:module:empty", moduleName: "empty", documentSet: null, dependency: null, dependencyInstanceState: "not_applicable"}
];
const modulePositions = Object.fromEntries(modules.map((module, index) => [module.moduleId, index]));
const moduleTags = {
 "cjdoc:module:a": [{id:"review", title:"Review"}, {id:"stream", title:"Streaming classification"}],
 "cjdoc:module:b": [{id:"experimental", title:"Experimental"}, {id:"stream", title:"Streaming classification"}],
 "cjdoc:module:net": [{id:"public", title:"Public"}, {id:"stream", title:"Streaming classification"}],
 "cjdoc:module:other": [{id:"Stream", title:"Stream"}, {id:"public", title:"Public"}]
};
const declarationTags = (name, moduleId) => {
  if (moduleId === "cjdoc:module:a" || moduleId === "cjdoc:module:b") return moduleTags[moduleId];
  if (name === "HttpClientBuilder") return moduleTags[moduleId];
  if (moduleId === "cjdoc:module:net" && name === "HTTPConnectionBuffer") {
    return moduleTags[moduleId].filter(tag => tag.id === "stream");
  }
  return [];
};
const entry = (name, packageName = "net", type = "class", moduleId = "cjdoc:module:" + packageName) => ({
 id: packageName + name, canonicalId: "cjdoc:v2:" + encodeURIComponent(packageName + ":" + name),
 snapshotId: "snap", scope: modulePositions[moduleId], concept: false, genericArity: 0, ownerId: null,
 name, qualifiedName: packageName + "." + name, kind: type, packageName,
 ownerName: null, ownerQualifiedName: null, symbolKey: null, parameterTypes: [],
 returnType: null, returnCanonical: null, exposures: [], externalDocs: [], bindings: [],
 sections: [], bodyTruncated: false, body: name === "send" ? "streaming" : "",
 summary: name === "send" ? "Streaming" : "<script>literal preview</script>",
 summaryDisplay: name === "send" ? "Streaming" : "<script>literal preview</script>",
 href: "symbols/" + name + ".html",
 classification: {
   group: name === "HttpClientBuilder" && packageName === "net"
     ? {id:"clients", packageName:"net", ownerId:null,
        title:String.fromCharCode(0x85) + "Legacy", order:2} : null,
   tags: declarationTags(name, moduleId).map(tag => ({id:tag.id, title:tag.title}))
 }
});
const index = {
 schemaVersion: "cjdoc.search-index/11", profile: "bounded-static", contract, projectionId: "projection",
 scope: {snapshotId: "snap", sourceSnapshotId: "source", publicationRevision: "rev",
   project: "fixture", language: "en", audience: "external", cfgProfile: "default",
   apiCollectionState: "resolved"},
 coverage: {profile: "bounded-static", projectionId: "projection", bodyTextLimit: 2000,
   bodyComplete: true, truncatedEntries: 0},
 modules, tags: [
   {scope:2, id:"review", title:"Review"},
   {scope:2, id:"stream", title:"Streaming classification"},
   {scope:3, id:"experimental", title:"Experimental"},
   {scope:3, id:"stream", title:"Streaming classification"},
   {scope:0, id:"public", title:"Public"},
   {scope:0, id:"stream", title:"Streaming classification"},
   {scope:1, id:"Stream", title:"Stream"},
   {scope:1, id:"public", title:"Public"}
 ], entries: [entry("HttpClientBuilder"), entry("HTTPConnectionBuffer"), entry("httpclientbuilder"),
   entry("HttpClientBuilder", "other"), entry("send", "net", "function"), entry("BuilderTools"),
   entry("Nova"), entry("a".repeat(128)), entry("a".repeat(129))]
};
index.entries.push(
 {...entry("overloaded", "net", "function", "cjdoc:module:a"), id:"module-a", canonicalId:"cjdoc:v2:module-a",
  scope: 2, ownerName:"net.Client", ownerQualifiedName:"net.Client",
  classification:{group:null, tags:moduleTags["cjdoc:module:a"]}},
 {...entry("overloaded", "net", "function", "cjdoc:module:b"), id:"module-b", canonicalId:"cjdoc:v2:module-b",
  scope: 3, ownerName:"net.Client", ownerQualifiedName:"net.Client",
  classification:{group:null, tags:moduleTags["cjdoc:module:b"]}});
const massEntries = Array.from({length: 105}, (_, item) => {
  const name = "mass" + String(item).padStart(3, "0");
  return {...entry(name), id:"mass-" + item, canonicalId:"cjdoc:v2:mass:" + item};
});
const domIndex = {...index, projectionId:"projection-dom",
  coverage:{...index.coverage, projectionId:"projection-dom"},
  entries:[...index.entries, ...massEntries]};

// ---- page, window and world ---------------------------------------------
const createWorld = (options = {}) => {
  const document = new DomDocument({lang: options.lang || "en",
    failTags: options.failTags || []});
  activeDocument = document;
  const trigger = document.createElement("button");
  trigger.setAttribute("class", "cj-search-trigger");
  trigger.setAttribute("type", "button");
  trigger.setAttribute("data-cjdoc-search-trigger", "");
  trigger.setAttribute("data-cjdoc-root-prefix", "/fixture/");
  trigger.setAttribute("aria-haspopup", "dialog");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("hidden", "");
  trigger.append(document.createElement("span"));
  document.body.append(trigger);
  const pageInput = document.createElement("input");
  pageInput.id = "page-filter";
  document.body.append(pageInput);
  const languageLink = document.createElement("a");
  languageLink.setAttribute("href", "zh-CN/index.html");
  languageLink.setAttribute("data-language-routes", "{}");
  document.body.append(languageLink);
  const browser = document.createElement("section");
  browser.setAttribute("data-cjdoc-member-browser", "");
  const memberFilter = document.createElement("input");
  memberFilter.setAttribute("data-cjdoc-member-filter", "");
  const originFilter = document.createElement("select");
  originFilter.setAttribute("data-cjdoc-member-origin", "");
  const memberStatus = document.createElement("div");
  memberStatus.setAttribute("data-cjdoc-member-filter-status", "");
  const memberGroup = document.createElement("section");
  memberGroup.setAttribute("data-cjdoc-member-group", "");
  const memberBuilder = document.createElement("details");
  memberBuilder.id = "member-builder";
  memberBuilder.setAttribute("data-cjdoc-member", "");
  memberBuilder.setAttribute("data-member-symbol-id",
    "cjdoc:v2:net%3AHttpClientBuilder");
  memberBuilder.setAttribute("data-member-origin", "declared");
  const memberSend = document.createElement("details");
  memberSend.id = "member-send";
  memberSend.setAttribute("data-cjdoc-member", "");
  memberSend.setAttribute("data-member-symbol-id", "cjdoc:v2:net%3Asend");
  memberSend.setAttribute("data-member-origin", "reexport");
  memberSend.textContent = "Streaming tag shown only in member text";
  memberGroup.append(memberBuilder, memberSend);
  browser.append(memberFilter, originFilter, memberStatus, memberGroup);
  document.body.append(browser);
  const location = {hash: "", search: options.search || "",
    href: "file:///fixture/index.html" + (options.search || ""),
    pathname: "/fixture/index.html"};
  const history = {pushState(_state, _title, href) {
    const url = new URL(href, location.href);
    location.href = url.href;
    location.search = url.search;
    location.hash = url.hash;
  }};
  const window = {
    location, history,
    isSecureContext: false,
    listeners: {},
    addEventListener(name, handler) {
      (this.listeners[name] = this.listeners[name] || []).push(handler);
    },
    removeEventListener(name, handler) {
      this.listeners[name] = (this.listeners[name] || []).filter(entry => entry !== handler);
    },
    dispatch(name, event = {}) {
      const payload = {...event};
      if (!payload.target) payload.target = this;
      if (!payload.preventDefault) payload.preventDefault = () => { payload.defaultPrevented = true; };
      for (const handler of [...(this.listeners[name] || [])]) handler(payload);
      return payload;
    },
    setTimeout: () => 0,
    matchMedia: () => ({matches: false, addEventListener() {}})
  };
  const context = {document, window, history, location, URL, URLSearchParams,
    Element: DomElement, setTimeout: () => 0, clearTimeout: () => {},
    requestAnimationFrame: callback => callback(),
    performance: {getEntriesByType: () => []},
    __CJDOC_SEARCH_INDEX__: domIndex};
  if (options.deprecated) context.__CJDOC_SIDEBAR_INDEX__ =
    {version: 3, deprecated: options.deprecated};
  context.__CJDOC_SEARCH_SIGNATURES__ = {"module-a":"func overloaded(String)",
    "module-b":"func overloaded(Int64)"};
  return {document, window, location, trigger, pageInput, languageLink,
    memberFilter, originFilter, memberStatus, memberBuilder, memberSend,
    context};
};

const loadWorld = (options = {}) => {
  const world = createWorld(options);
  vm.runInNewContext(SCRIPT, world.context);
  return world;
};

const searchDialogIn = world => world.document.querySelector("[data-cjdoc-search-dialog]");
const searchDialogsIn = world => world.document.querySelectorAll("[data-cjdoc-search-dialog]");


const kernelWorld = loadWorld();
const api = kernelWorld.context.cjdocSearch;
for (let repeat = 0; repeat < 2; repeat++) {
  assert.equal(api.fold("AZ_az-\u0130\u212a-\u00c9-e\u0301-\ud83d\ude00"),
    "az_az-\u0130\u212a-\u00c9-e\u0301-\ud83d\ude00",
    "case folding changes ASCII uppercase only, without Unicode normalization or regex state leakage");
}
const baseRequest = {operation: "search", mode: "discovery", profile: "bounded-static"};
const execute = (request, source = index) => api.execute(source, {...baseRequest, ...request});
const guide = {...entry("++"), id:"punctuation", canonicalId:"punctuation", scope:-1,
  concept:true, kind:"concept", packageName:null, qualifiedName:null,
  summary:"", summaryDisplay:"", body:"++", href:"concepts/guides/punctuation.html",
  classification:{group:null, tags:[]}};
const guideIndex = {...index, projectionId:"guide-regressions",
  coverage:{...index.coverage, projectionId:"guide-regressions"},
  entries:[...index.entries, guide]};
for (const mode of ["precise", "discovery"]) {
  assert.equal(execute({mode, name:"++"}, guideIndex).total, 0);
}
const punctuationResult = execute({query:"++"}, guideIndex);
assert.deepEqual(Array.from(punctuationResult.items, row =>
  [row.canonicalId, row.score, row.reason]), [["punctuation", 9000, "name_casefold"]]);
assert.deepEqual(Array.from(execute({query:"+"}, guideIndex).items, row =>
  [row.canonicalId, row.reason]), [["punctuation", "name_prefix"]]);
assert.equal(execute({query:"---"}, guideIndex).total, 0);
const localRequest = parsed => {
  const request = {query:parsed.query, filters:parsed.filters};
  if (parsed.tags.length) request.tags = parsed.tags;
  return request;
};
assert.equal(api.parseQuery("unknown:value", contract).errorCode, "unknown_filter_field");
assert.equal(api.parseQuery("name:", contract).errorCode, "empty_filter_value");
assert.equal(api.parseQuery("tag:", contract).errorCode, "empty_filter_value");
assert.equal(api.parseQuery("tag:bad.id", contract).errorCode, "invalid_tag_id");
assert.equal(api.parseQuery(Array(65).fill("tag:stream").join(" "), contract).errorCode, "request_schema");
assert.equal(api.parseQuery(Array(64).fill("tag:stream").join(" "), contract).errorCode, null);
assert.equal(execute({query: "\ud800"}).errorCode, "request_unicode");
assert.equal(api.parseQuery("\ud800", contract).errorCode, "invalid_unicode");
for (const invalid of ["\udc00", "\ud83d\ude00\ud800", "\ud800x\udc00"]) {
  assert.equal(execute({query: invalid}).errorCode, "request_unicode");
  const brokenIndex = {...index, entries: [{...index.entries[0], summary: invalid}, ...index.entries.slice(1)]};
  assert.equal(execute({query: ""}, brokenIndex).errorCode, "search_index_invalid");
}
const astralGuide = {...guide, name:"指南😀", body:"指南😀"};
const astralIndex = {...guideIndex, entries: [...index.entries, astralGuide]};
assert.equal(execute({query: "指南😀"}, astralIndex).items[0].canonicalId, "punctuation");
for (const [left, right, match] of [
  ["A😀B", "A界B", true], ["A😀界B", "A界B", true], ["A界B", "A😀界B", true],
  ["😀😀界", "😀界", true], ["A😀", "A", true], ["", "😀", true],
  ["A😀B", "A😀B", false], ["A😀界B", "A界😀B", false], ["A😀界B", "A朱B", false]
]) {
  assert.equal(api.oneEditApart(left, right), match, `${left} ↔ ${right}`);
}
for (const raw of [undefined, null, 42, {}]) {
  const rejected = api.parseQuery(raw, contract);
  assert.equal(rejected.errorCode, "invalid_unicode");
  assert.equal(rejected.invalidToken, raw);
}
const qualifiedToken = api.parseQuery("QUALIFIEDNAME:net.HttpClientBuilder", contract);
assert.equal(qualifiedToken.filters[0].field, "qualifiedName");
assert.deepEqual(Array.from(api.createEntryFilter(index,
  [index.entries[0].canonicalId])(localRequest(qualifiedToken)).canonicalIds), ["cjdoc:v2:net%3AHttpClientBuilder"]);
assert.equal(api.execute({...index, schemaVersion:"cjdoc.search-index/10"}, baseRequest).errorCode,
  "search_index_version_unsupported");
const scopedCopy = (projectionId, fields = {}) => ({
  ...index, ...fields, projectionId,
  coverage:{...index.coverage, ...(fields.coverage || {}), projectionId}
});
const assertNoMatch = (request, source = index) => {
  const result = execute(request, source);
  assert.equal(result.status, "not_found");
  assert.equal(result.errorCode, null);
  assert.equal(result.total, 0);
  assert.equal(result.items.length, 0);
  assert.equal(result.reason, "no_match_in_scope");
};
for (const mode of ["precise", "discovery"]) {
  for (const request of [
    {moduleId:"cjdoc:module:empty"},
    {moduleId:"cjdoc:module:private", packageName:"privateOnly"},
    {moduleId:"cjdoc:module:net", packageName:"review_preview.hidden"},
    {moduleId:"cjdoc:module:net", packageName:"review_preview.missing"},
    {packageName:"review_preview.missing"},
    {moduleId:"cjdoc:module:a", packageName:"other"}
  ]) assertNoMatch({...request, mode});
  const sameModuleConjunction = execute({query:"overloaded", mode,
    moduleId:"cjdoc:module:a", packageName:"net", documentSetId:"document-a",
    library:"library-a", apiVersion:"1.0", dependencyInstanceId:"dependency-a",
    target:"target-a", cfg:"cfg-a"});
  assert.equal(sameModuleConjunction.status, "ok");
  assert.deepEqual(Array.from(sameModuleConjunction.items, item => item.canonicalId), ["cjdoc:v2:module-a"]);
}
const unknownModule = execute({moduleId:"cjdoc:module:missing"});
assert.equal(unknownModule.status, "scope_mismatch");
assert.equal(unknownModule.errorCode, "scope_not_captured");
for (const request of [
  {moduleId:"cjdoc:module:a", documentSetId:"document-b", dependencyInstanceId:"dependency-a"},
  {moduleId:"cjdoc:module:a", documentSetId:"document-a", dependencyInstanceId:"dependency-b"},
  {moduleId:"cjdoc:module:a", documentSetId:"document-a", target:"target-b", cfg:"cfg-a"}
]) {
  const rejected = execute(request);
  assert.equal(rejected.status, "scope_mismatch");
  assert.equal(rejected.errorCode, "scope_not_captured");
}
for (const apiCollectionState of ["partial", "unavailable"]) {
  const incomplete = scopedCopy("incomplete-" + apiCollectionState, {
    scope:{...index.scope, apiCollectionState}
  });
  const absence = execute({moduleId:"cjdoc:module:empty"}, incomplete);
  assert.equal(absence.status, "source_incomplete");
  assert.equal(absence.errorCode, null);
  assert.equal(absence.total, 0);
}
const invalidModuleIndex = (projectionId, updateModule) => scopedCopy(projectionId, {
  modules:index.modules.map((module, position) => updateModule(module, position))
});
const contradictoryScope = invalidModuleIndex("contradictory-set-dependency-scope", (module, position) =>
  position === 2 ? {...module, dependency:{...module.dependency, target:"target-b", cfg:"cfg-b"}} : module);
const contradictoryResult = execute({query:"overloaded", moduleId:"cjdoc:module:a",
  documentSetId:"document-a", target:"target-a", cfg:"cfg-a"}, contradictoryScope);
assert.equal(contradictoryResult.status, "scope_mismatch");
assert.equal(contradictoryResult.errorCode, "scope_not_captured");
assert.equal(api.execute(invalidModuleIndex("wrong-document-set-module", (module, position) =>
  position === 2 ? {...module, documentSet:documentSetB} : module), baseRequest).errorCode,
  "search_index_invalid");
assert.equal(api.execute(invalidModuleIndex("wrong-dependency-module", (module, position) =>
  position === 2 ? {...module, dependency:dependencyB} : module), baseRequest).errorCode,
  "search_index_invalid");
assert.equal(api.execute(invalidModuleIndex("duplicate-module-id", (module, position) =>
  position === 1 ? {...module, moduleId:"cjdoc:module:net"} : module), baseRequest).errorCode,
  "search_index_invalid");
const badEntryScope = scopedCopy("entry-scope-outside-inventory", {
  entries:index.entries.map((row, position) => position === 4
    ? {...row, scope:index.modules.length} : row)
});
assert.equal(api.execute(badEntryScope, baseRequest).errorCode, "search_index_invalid");
const capturedExposure = scopedCopy("captured-cross-module-exposure", {
  entries:index.entries.map((row, position) => position === 0 ? {...row, exposures:[{
    id:"alias", scope:1, name:"Alias", qualifiedName:"other.Alias", packageName:"other"
  }]} : row)
});
assert.equal(api.execute(capturedExposure, baseRequest).errorCode, null);
const badExposureScope = scopedCopy("exposure-scope-outside-inventory", {
  entries:index.entries.map((row, position) => position === 0 ? {...row, exposures:[{
    id:"alias", scope:index.modules.length, name:"Alias", qualifiedName:"other.Alias", packageName:"other"
  }]} : row)
});
assert.equal(api.execute(badExposureScope, baseRequest).errorCode, "search_index_invalid");
const badClassification = {...index, projectionId:"bad-classification",
  coverage:{...index.coverage, projectionId:"bad-classification"},
  entries:index.entries.map((row, i) => i === 0
    ? {...row, classification:{group:null, tags:[{id:"stream", title:"Wrong"}]}} : row)};
assert.equal(api.execute(badClassification, baseRequest).errorCode, "search_index_invalid");
const missingClassification = {...index, projectionId:"missing-classification",
  coverage:{...index.coverage, projectionId:"missing-classification"},
  entries:index.entries.map((row, i) => {
    if (i !== 0) return row;
    const copy = {...row}; delete copy.classification; return copy;
  })};
assert.equal(api.execute(missingClassification, baseRequest).errorCode, "search_index_invalid");
const badDictionary = {...index, projectionId:"bad-dictionary",
  coverage:{...index.coverage, projectionId:"bad-dictionary"},
  tags:[...index.tags].reverse()};
assert.equal(api.execute(badDictionary, baseRequest).errorCode, "search_index_invalid");
const badContract = {...index, contract:{...contract, version:"cjdoc.search-contract/1"}};
assert.equal(api.execute(badContract, baseRequest).errorCode, "search_contract_unavailable");
const largeIndex = {...index, projectionId: "projection-large",
  coverage: {...index.coverage, projectionId: "projection-large"},
  entries: [...index.entries, ...massEntries]};
const localMassQuery = api.parseQuery("mass", contract);
assert.equal(api.createEntryFilter(largeIndex,
  massEntries.map(row => row.canonicalId))(localRequest(localMassQuery)).canonicalIds.length, 105);
const localTag = api.parseQuery("tag:stream", contract);
const localCanonicalIds = [index.entries[0].canonicalId,
  index.entries.find(row => row.name === "send").canonicalId];
const localMemberFilter = api.createEntryFilter(index, localCanonicalIds);
const localTagResult = localMemberFilter(localRequest(localTag));
assert.deepEqual(Array.from(localTagResult.canonicalIds), ["cjdoc:v2:net%3AHttpClientBuilder"]);
localCanonicalIds.splice(0, localCanonicalIds.length, "missing-canonical-id");
localTagResult.canonicalIds.push("missing-canonical-id");
assert.deepEqual(Array.from(localMemberFilter(localRequest(localTag)).canonicalIds),
  ["cjdoc:v2:net%3AHttpClientBuilder"]);
const localQuery = api.parseQuery("Http", contract);
assert.deepEqual(Array.from(localMemberFilter(localRequest(localQuery)).canonicalIds),
  ["cjdoc:v2:net%3AHttpClientBuilder"]);
assert.equal(api.createEntryFilter(index, ["missing-canonical-id"])({query:""}).errorCode,
  "search_index_invalid");
// ---- initial load: nothing is built --------------------------------------
const world = loadWorld();
assert.equal(searchDialogIn(world), null, "normal load builds no search dialog");
assert.equal(world.document.querySelectorAll("dialog").length, 0);
assert.equal(world.document.querySelector("[data-cjdoc-theme-popover]"), null,
  "display settings are not precreated either");
assert.equal(world.trigger.hidden, false, "the trigger becomes visible");
assert.equal(world.trigger.getAttribute("aria-controls"), null,
  "no aria-controls before a dialog exists");
assert.equal(world.trigger.getAttribute("aria-expanded"), "false");
// Back/forward with no search state must not build the palette.
world.window.dispatch("popstate", {});
assert.equal(searchDialogIn(world), null);

// ---- first request builds one dialog -------------------------------------
world.document.dispatch("keydown", {key: "k", ctrlKey: true});
assert.equal(searchDialogsIn(world).length, 1, "first request builds exactly one dialog");
const dialog = searchDialogIn(world);
assert.equal(dialog.parentElement, world.document.body, "the dialog is appended to the page");
assert.equal(dialog.open, true);
assert.equal(world.trigger.getAttribute("aria-controls"), "cjdoc-search-dialog");
assert.equal(world.trigger.getAttribute("aria-expanded"), "true");
const input = dialog.querySelector("[data-cjdoc-search]");
const results = dialog.querySelector("[data-cjdoc-results]");
const kind = dialog.querySelector("[data-cjdoc-kind]");
const pkg = dialog.querySelector("[data-cjdoc-package]");
const searchFacets = dialog.querySelector("[data-cjdoc-search-facets]");
const searchPages = dialog.querySelector("[data-cjdoc-search-pages]");
const previousPage = dialog.querySelector("[data-cjdoc-search-previous]");
const nextPage = dialog.querySelector("[data-cjdoc-search-next]");
const searchStatus = dialog.querySelector("[data-cjdoc-search-status]");
assert(input && results && kind && pkg && searchFacets && searchPages &&
  previousPage && nextPage && searchStatus);
assert.equal(input.dataset.root, "/fixture/", "the trigger prefix reaches the input");
assert.equal(input.getAttribute("role"), "combobox");
assert.equal(input.getAttribute("aria-controls"), "cjdoc-search-results");
assert.equal(results.id, "cjdoc-search-results");
assert.equal(results.getAttribute("role"), "listbox");
assert.equal(dialog.querySelector("#cjdoc-search-filters") !== null, true);
assert.equal(dialog.querySelector("[data-cjdoc-search-close]") !== null, true);
assert.equal(dialog.querySelector("[data-cjdoc-search-facet]"), null);
assert.equal(input.focused, true, "opening focuses the query field");
assert.equal(world.document.querySelector("[data-cjdoc-theme-popover]"), null,
  "opening search does not build display settings");

// ---- reopening reuses the existing dialog -------------------------------
input.dispatch("keydown", {key: "Escape"});
assert.equal(dialog.open, false);
assert.equal(world.trigger.focused, true, "Escape returns focus to the trigger");
assert.equal(world.trigger.getAttribute("aria-expanded"), "false");
assert.equal(results.children.length, 0);
world.trigger.dispatch("click", {button: 0});
assert.equal(searchDialogIn(world), dialog, "reopening reuses the same node");
assert.equal(searchDialogsIn(world).length, 1);

// ---- query, filters, paging and facets ----------------------------------
// A DOM-dispatched keyboard event always carries its originating element.
const keydown = event => input.dispatch("keydown", {target: input, ...event});
const search = query => {
  input.value = query;
  input.dispatch("input", {target: input});
  return results.children.map(x =>
    x.children[0].children[0].children[0].textContent);
};
assert(search("package:other").includes("HttpClientBuilder"));
assert.equal(search("zzzzzz").length, 0);
pkg.value = "other";
pkg.dispatch("change", {target: pkg});
assert.deepEqual(search("Http"), ["HttpClientBuilder"]);
assert.equal(results.children[0].children[0].children[2].textContent,
  "<script>literal preview</script>");
pkg.value = "";
pkg.dispatch("change", {target: pkg});
const firstMassPage = search("mass")[0];
assert.equal(results.children.length, 20);
assert.equal(searchPages.hidden, false);
nextPage.dispatch("click", {target: nextPage});
assert.equal(results.children.length, 20);
const secondMassPage = results.children[0].children[0].children[0].children[0].textContent;
assert.notEqual(secondMassPage, firstMassPage);
previousPage.dispatch("click", {target: previousPage});
assert.equal(results.children[0].children[0].children[0].children[0].textContent,
  firstMassPage);
search("Http");
assert.equal(searchFacets.hidden, false);
const streamFacet = searchFacets.children.find(button =>
  button.dataset.cjdocTagId === "stream" &&
  button.dataset.cjdocFacetModuleId === "cjdoc:module:net");
assert(streamFacet);
assert.equal(streamFacet.className, "cj-search__facet");
assert.equal(streamFacet.dataset.cjdocFacetSnapshotId, "snap");
assert.equal(streamFacet.getAttribute("aria-pressed"), "false");
const clickFacet = button => button.dispatch("click", {target: button});
clickFacet(streamFacet);
assert.equal(input.value, "Http");
assert.equal(results.children.length, 2);
assert(searchFacets.children.find(button => button.dataset.cjdocTagId === "stream" &&
  button.dataset.cjdocFacetModuleId === "cjdoc:module:net")
  .getAttribute("aria-pressed") === "true");
assert(new URLSearchParams(world.location.search).getAll("tag").includes("stream"));
clickFacet(searchFacets.children.find(button => button.dataset.cjdocTagId === "stream" &&
  button.dataset.cjdocFacetModuleId === "cjdoc:module:net"));
assert.equal(results.children.length, 3);
assert.equal(new URLSearchParams(world.location.search).getAll("tag").length, 0);
assert.equal(results.children[0].children[0].getAttribute("href").startsWith("/fixture/"),
  true, "result links use the trigger's publication prefix");

const setSearchUrl = query => {
  const url = new URL(query, "file:///fixture/index.html");
  world.location.href = url.href;
  world.location.search = url.search;
  world.location.hash = url.hash;
};
input.value = "";
setSearchUrl("?tag=stream&tag=public&moduleId=cjdoc%3Amodule%3Anet&snapshotId=snap");
world.window.dispatch("popstate", {});
assert.deepEqual(search(""), ["HttpClientBuilder"]);
setSearchUrl("?tag=stream&moduleId=cjdoc%3Amodule%3Amissing&snapshotId=snap");
world.window.dispatch("popstate", {});
assert.equal(results.children.length, 0);
assert(searchStatus.textContent.includes("scope_not_captured"));
setSearchUrl("?tag=stream&snapshotId=stale");
world.window.dispatch("popstate", {});
assert.equal(results.children.length, 0);
assert(searchStatus.textContent.includes("snapshot_unavailable"));
setSearchUrl("?" + Array(65).fill("tag=stream").join("&"));
world.window.dispatch("popstate", {});
assert(searchStatus.textContent.includes("request_schema"));
setSearchUrl("");
world.window.dispatch("popstate", {});
assert.equal(results.children.length, 0);
setSearchUrl("?tag=stream&tag=public&moduleId=cjdoc%3Amodule%3Anet&snapshotId=snap");
world.window.dispatch("hashchange", {});
const languageTarget = new URL(world.languageLink.href);
assert.deepEqual(languageTarget.searchParams.getAll("tag"), ["stream", "public"]);
assert.equal(languageTarget.searchParams.get("moduleId"), "cjdoc:module:net");
assert.equal(languageTarget.searchParams.get("snapshotId"), null);
setSearchUrl("");
world.window.dispatch("popstate", {});
world.window.dispatch("hashchange", {});
pkg.value = "other";
input.value = "";
pkg.dispatch("change", {target: pkg});
assert.deepEqual(results.children.map(x =>
  x.children[0].children[0].children[0].textContent), ["HttpClientBuilder"]);

// Migration belongs to the selected canonical hit, not to the listbox or its
// search order. An inherited key cannot decorate or navigate another hit.
const deprecationWorld = loadWorld({deprecated:Object.assign(Object.create({
  "cjdoc:v2:module-b": {label:"Not owned", kind:"api", href:"net/wrong/index.html"}
}), {
  "cjdoc:v2:module-a": {label:"Client.modern(String)", kind:"api", href:"net/modern/index.html"},
  "cjdoc:v2:net%3Asend": null
})});
deprecationWorld.trigger.dispatch("click", {button:0});
const deprecationDialog = searchDialogIn(deprecationWorld);
const deprecationInput = deprecationDialog.querySelector("[data-cjdoc-search]");
const deprecationResults = deprecationDialog.querySelector("[data-cjdoc-results]");
const migration = () => deprecationDialog.querySelector(".cj-replacement");
const deprecatedKeys = key => deprecationInput.dispatch("keydown", {key,target:deprecationInput});
const deprecatedQuery = value => {
  deprecationInput.value = value;
  deprecationInput.dispatch("input", {target:deprecationInput});
};
deprecatedQuery("overloaded");
assert.equal(deprecationResults.querySelectorAll(".cj-deprecation").length,1);
assert.equal(deprecationResults.querySelector(".cj-replacement"),null);
assert.equal(migration(),null);
deprecatedKeys("ArrowDown");
if (!migration()) deprecatedKeys("ArrowDown");
assert.equal(migration().getAttribute("href"),"/fixture/net/modern/index.html");
assert.equal(migration().querySelector("code").textContent,"Client.modern(String)");
deprecatedKeys("ArrowDown");
assert.equal(migration(),null);
deprecatedQuery("send");
assert.equal(deprecationResults.querySelectorAll(".cj-deprecation").length,1);
deprecatedKeys("ArrowDown");
assert.equal(migration(),null);
deprecatedQuery("overloaded");
deprecatedKeys("ArrowDown");
if (!migration()) deprecatedKeys("ArrowDown");
assert(migration());
deprecatedKeys("Escape");
assert.equal(migration(),null);
assert.equal(deprecationWorld.trigger.focused,true);

// ---- keyboard selection, IME and dismissal ------------------------------
keydown({key: "ArrowDown"});
assert.equal(input.getAttribute("aria-activedescendant"), "cjdoc-search-result-0");
const link = results.children[0].children[0];
keydown({key: "Enter"});
assert(link.clicked);
keydown({key: "Escape"});
assert.equal(results.children.length, 0);
assert.equal(pkg.value, "other");
world.document.dispatch("keydown", {key: "k", ctrlKey: true});
assert.equal(input.focused, true, "the shortcut focuses an open palette");
pkg.value = "";
pkg.dispatch("change", {target: pkg});
assert.equal(search("overloaded").length, 2);
const moduleLinks = results.children.map(item => item.children[0]);
assert.deepEqual(moduleLinks.map(item => item.children[1].textContent),
  ["net.Client · sdk-a", "net.Client · sdk-b"]);
assert.equal(moduleLinks[0].children[1].getAttribute("title"),
  "net.overloaded · sdk-a · cjdoc:module:a");
assert.notEqual(moduleLinks[0].children[2].textContent,
  moduleLinks[1].children[2].textContent);
// An input method editor must not drive results with intermediate text, and
// Enter during composition commits instead of opening a result.
input.value = "";
input.dispatch("input", {target: input});
input.dispatch("compositionstart", {target: input});
input.value = "Ht";
input.dispatch("input", {target: input, isComposing: true});
assert.equal(results.children.length, 0);
input.dispatch("compositionend", {target: input});
input.value = "Http";
input.dispatch("input", {target: input});
assert(search("Http").includes("HttpClientBuilder"));
keydown({key: "ArrowDown"});
input.dispatch("compositionstart", {target: input});
results.children[0].children[0].clicked = undefined;
keydown({key: "Enter", isComposing: true});
assert.equal(results.children[0].children[0].clicked, undefined,
  "Enter during composition never activates a result");
input.dispatch("compositionend", {target: input});
keydown({key: "ArrowDown"});
const activated = results.children[0].children[0];
world.trigger.focused = false;
keydown({key: "Enter"});
// Activating a result follows a same-document link: the palette closes without
// stealing focus back from the destination.
assert.equal(activated.clicked, true);
assert.equal(dialog.open, false);
assert.equal(world.trigger.focused, false,
  "following a result keeps focus on the destination");
world.trigger.dispatch("click", {button: 0});
assert.equal(dialog.open, true);
// A click on the dialog element itself is the backdrop area.
dialog.dispatch("click", {target: dialog});
assert.equal(dialog.open, false);
assert.equal(world.trigger.focused, true, "the backdrop returns focus to the trigger");
// Escape inside the field closes too.
world.trigger.dispatch("click", {button: 0});
keydown({key: "Escape"});
assert.equal(dialog.open, false);

// ---- member filtering stays independent of the palette ------------------
world.originFilter.value = "reexport";
world.originFilter.dispatch("change", {target: world.originFilter});
assert.equal(world.memberBuilder.hidden, true);
assert.equal(world.memberSend.hidden, false);
world.memberFilter.value = "tag:stream";
world.memberFilter.dispatch("input", {target: world.memberFilter});
assert.equal(world.memberBuilder.hidden, true);
assert.equal(world.memberSend.hidden, true);
world.originFilter.value = "";
world.originFilter.dispatch("change", {target: world.originFilter});
assert.equal(world.memberBuilder.hidden, false);
assert.equal(world.memberSend.hidden, true);
world.memberFilter.value = "tag:stream tag:public";
world.memberFilter.dispatch("input", {target: world.memberFilter});
assert.equal(world.memberBuilder.hidden, false);
assert.equal(world.memberSend.hidden, true);
world.memberFilter.value = "tag:Stream";
world.memberFilter.dispatch("input", {target: world.memberFilter});
assert.equal(world.memberBuilder.hidden, true);
assert.equal(world.memberSend.hidden, true);
world.memberFilter.value = "unknown:value";
world.memberFilter.dispatch("input", {target: world.memberFilter});
assert.equal(world.memberStatus.hidden, false);
assert(world.memberStatus.textContent.includes("unknown_filter_field"));
assert.equal(world.memberBuilder.hidden, true);
world.memberFilter.value = "";
world.memberFilter.dispatch("input", {target: world.memberFilter});
assert.equal(world.memberBuilder.hidden, false);
assert.equal(world.memberSend.hidden, false);
// Selecting a filter before the palette exists must not build it.
assert.equal(searchDialogIn(world), dialog);
kind.value = "function";
kind.dispatch("change", {target: kind});
input.value = "send";
input.dispatch("input", {target: input});
assert.deepEqual(results.children.map(x =>
  x.children[0].children[0].children[0].textContent), ["send"]);
// Native history may restore a select value without dispatching change.
kind.value = "class";
assert.equal(search("send").length, 0);
assert(search("Http").includes("HttpClientBuilder"));
kind.value = "class";
kind.dispatch("change", {target: kind});
assert.equal(search("send").length, 0);
kind.value = "";
kind.dispatch("change", {target: kind});

// ---- a shared URL opens the palette on load -----------------------------
const urlWorld = loadWorld({
  search: "?tag=stream&tag=public&moduleId=cjdoc%3Amodule%3Anet&snapshotId=snap"});
assert.equal(searchDialogsIn(urlWorld).length, 1);
const urlDialog = searchDialogIn(urlWorld);
assert.equal(urlDialog.open, true, "a tag URL shows its results");
assert.equal(urlWorld.trigger.getAttribute("aria-controls"), "cjdoc-search-dialog");
const urlResults = urlDialog.querySelector("[data-cjdoc-results]");
assert.deepEqual(urlResults.children.map(node =>
  node.children[0].children[0].children[0].textContent), ["HttpClientBuilder"]);
assert.equal(urlDialog.querySelector("[data-cjdoc-search]").focused, true);

const errorWorld = loadWorld({search: "?tag=stream&snapshotId=stale"});
const errorDialog = searchDialogIn(errorWorld);
assert.equal(errorDialog.open, true);
assert(errorDialog.querySelector("[data-cjdoc-search-status]").textContent
  .includes("snapshot_unavailable"));
assert.equal(errorWorld.document.querySelector("[data-cjdoc-theme-popover]"), null);

// ---- "/" opens unless the reader is typing ------------------------------
const slashWorld = loadWorld();
slashWorld.document.dispatch("keydown", {key: "/", target: slashWorld.pageInput});
assert.equal(searchDialogIn(slashWorld), null, "typing elsewhere never builds the palette");
slashWorld.document.dispatch("keydown", {key: "/", target: slashWorld.document.body});
assert.equal(searchDialogsIn(slashWorld).length, 1);

// ---- a failing constructor surfaces instead of faking success -----------
const brokenWorld = loadWorld({failTags: ["dialog"]});
assert.throws(() => brokenWorld.document.dispatch("keydown", {key: "k", ctrlKey: true}),
  /createElement failed/);
assert.equal(searchDialogIn(brokenWorld), null);
assert.equal(brokenWorld.trigger.getAttribute("aria-controls"), null);
assert.throws(() => brokenWorld.trigger.dispatch("click", {button: 0}),
  /createElement failed/);
assert.equal(brokenWorld.document.body.children.includes(null), false);

// ---- created markup keeps the bilingual copy ---------------------------
const zhWorld = loadWorld({lang: "zh-CN"});
zhWorld.trigger.dispatch("click", {button: 0});
const zhDialog = searchDialogIn(zhWorld);
assert.equal(zhDialog.getAttribute("aria-label"), "搜索文档");
assert.equal(zhDialog.querySelector("[data-cjdoc-search]").getAttribute("placeholder"),
  "搜索文档");
assert.equal(zhDialog.querySelector("[data-cjdoc-search-close]").getAttribute("aria-label"),
  "关闭搜索");
assert.equal(zhDialog.querySelector("[data-cjdoc-search-previous]").textContent, "上一页");
assert(zhDialog.querySelector(".cj-search__note").textContent
  .includes("没有命中不代表完整文档中不存在"));

'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node"], input=script, text=True, encoding="utf-8",
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
