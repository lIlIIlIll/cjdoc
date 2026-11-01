#!/usr/bin/env python3
"""Execute the shipped search script against a small DOM test double."""
import shutil
import subprocess
import unittest

from test_validate_html_site import canonical_search_script


@unittest.skipUnless(shutil.which("node"), "Node.js is needed to execute browser JavaScript")
class HtmlSearchTest(unittest.TestCase):

    def test_search_tags_facets_local_filter_and_keyboard(self):
        harness = r'''
const assert = require("node:assert/strict");
const vm = require("node:vm");
function addListener(target, key, handler) {
  const previous = target[key];
  target[key] = event => { if (previous) previous(event); handler(event); };
}
class Element {
  constructor(tag = "") {
    this.tag = tag; this.children = []; this.dataset = {}; this.value = "";
    this.attrs = {}; this.events = {}; this.hidden = false; this.textContent = "";
  }
  append(...children) { this.children.push(...children); }
  replaceChildren() { this.children = []; }
  setAttribute(name, value) {
    this.attrs[name] = value;
    if (name.startsWith("data-")) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
  }
  removeAttribute(name) { delete this.attrs[name]; }
  getAttribute(name) { return this.attrs[name] || null; }
  addEventListener(name, handler) { addListener(this.events, name, handler); }
  querySelector(selector) { return this.children.find(child => child.tag === selector) || null; }
  closest(selector) {
    return selector === "a[data-cjdoc-search-facet]" && this.tag === "a" &&
      Object.prototype.hasOwnProperty.call(this.attrs, "data-cjdoc-search-facet") ? this : null;
  }
  scrollIntoView() {}
  focus() { this.focused = true; }
  blur() { this.blurred = true; }
  click() { this.clicked = true; }
}
const input = new Element("input"), results = new Element("ul"), kind = new Element("select"), pkg = new Element("select");
const searchFacets = new Element("div"), searchPopover = new Element("div"), searchPages = new Element("div");
const previousPage = new Element("button"), nextPage = new Element("button"), searchStatus = new Element("div");
const memberFilter = new Element("input"), originFilter = new Element("select"), memberStatus = new Element("div");
const memberBuilder = new Element("details"), memberSend = new Element("details");
memberBuilder.dataset.memberSymbolId = "cjdoc:v2:net%3AHttpClientBuilder";
memberBuilder.dataset.memberOrigin = "declared";
memberSend.dataset.memberSymbolId = "cjdoc:v2:net%3Asend";
memberSend.dataset.memberOrigin = "reexport";
memberSend.textContent = "Streaming tag shown only in member text";
const memberRows = [memberBuilder, memberSend];
const languageLink = new Element("a");
languageLink.setAttribute("href", "zh-CN/index.html");
languageLink.dataset.languageRoutes = "{}";
input.dataset.root = "/fixture/";
kind.value = "";
const controls = {"[data-cjdoc-search]": input, "[data-cjdoc-results]": results,
  "[data-cjdoc-kind]": kind, "[data-cjdoc-package]": pkg,
  "[data-cjdoc-search-facets]": searchFacets, "[data-cjdoc-search-popover]": searchPopover,
  "[data-cjdoc-search-pages]": searchPages, "[data-cjdoc-search-previous]": previousPage,
  "[data-cjdoc-search-next]": nextPage,
  "[data-cjdoc-search-status]": searchStatus,
  "[data-cjdoc-member-filter]": memberFilter, "[data-cjdoc-member-origin]": originFilter,
  "[data-cjdoc-member-filter-status]": memberStatus};
const document = {querySelector: key => controls[key] || null,
  querySelectorAll: key => key === "[data-cjdoc-member]" ? memberRows :
    key === "[data-language-routes]" ? [languageLink] : [],
  createElement: tag => new Element(tag), createTextNode: text => Object.assign(new Element("#text"), {textContent:text}),
  documentElement: {lang: "en", dataset: {}},
  body: {dataset: {}},
  addEventListener: (key, handler) => addListener(document, key, handler)};
const window = {location: {hash: "", search: "", href: "file:///fixture/index.html",
  pathname: "/fixture/index.html"},
  history: {pushState(_state, _title, href) {
    const url = new URL(href, window.location.href);
    window.location.href = url.href; window.location.search = url.search; window.location.hash = url.hash;
  }},
  addEventListener: (key, handler) => addListener(window, key, handler)};
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
const context = {document, window, URL, URLSearchParams, location:window.location,
 requestAnimationFrame: callback => callback(), performance: {getEntriesByType: () => []},
 __CJDOC_SEARCH_INDEX__: domIndex};
context.__CJDOC_SEARCH_SIGNATURES__ = {"module-a":"func overloaded(String)", "module-b":"func overloaded(Int64)"};
vm.runInNewContext(SCRIPT, context);
const api = context.cjdocSearch;
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
const qualifiedToken = api.parseQuery("QUALIFIEDNAME:net.HttpClientBuilder", contract);
assert.equal(qualifiedToken.filters[0].field, "qualifiedName");
assert.deepEqual(Array.from(api.filterEntries(index, localRequest(qualifiedToken),
  [index.entries[0].canonicalId]).canonicalIds), ["cjdoc:v2:net%3AHttpClientBuilder"]);
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
assert.equal(api.filterEntries(largeIndex, localRequest(localMassQuery),
  massEntries.map(row => row.canonicalId)).canonicalIds.length, 105);
const localTag = api.parseQuery("tag:stream", contract);
const localCanonicalIds = [index.entries[0].canonicalId,
  index.entries.find(row => row.name === "send").canonicalId];
assert.deepEqual(Array.from(api.filterEntries(index, localRequest(localTag),
  localCanonicalIds).canonicalIds), ["cjdoc:v2:net%3AHttpClientBuilder"]);
const localQuery = api.parseQuery("Http", contract);
assert.deepEqual(Array.from(api.filterEntries(index, localRequest(localQuery),
  localCanonicalIds).canonicalIds), ["cjdoc:v2:net%3AHttpClientBuilder"]);
assert.equal(api.filterEntries(index, {query:""}, ["missing-canonical-id"]).errorCode,
  "search_index_invalid");
// A DOM-dispatched keyboard event always carries its originating element.
const keydown = event => input.events.keydown({target: input, ...event});
const search = query => { input.value = query; input.events.input(); return results.children.map(x => x.children[0].children[0].children[0].textContent); };
assert(search("package:other").includes("HttpClientBuilder"));
assert.equal(search("zzzzzz").length, 0);
pkg.value = "other"; pkg.events.change();
assert.deepEqual(search("Http"), ["HttpClientBuilder"]);
assert.equal(results.children[0].children[0].children[2].textContent, "<script>literal preview</script>");
pkg.value = ""; pkg.events.change();
const firstMassPage = search("mass")[0];
assert.equal(results.children.length, 20);
assert.equal(searchPages.hidden, false);
nextPage.events.click();
assert.equal(results.children.length, 20);
const secondMassPage = results.children[0].children[0].children[0].children[0].textContent;
assert.notEqual(secondMassPage, firstMassPage);
previousPage.events.click();
assert.equal(results.children[0].children[0].children[0].children[0].textContent, firstMassPage);
search("Http");
assert.equal(searchFacets.hidden, false);
const streamFacet = searchFacets.children.find(link =>
  link.dataset.cjdocTagId === "stream" && link.dataset.cjdocFacetModuleId === "cjdoc:module:net");
assert(streamFacet);
assert(streamFacet.href.includes("tag=stream"));
assert(streamFacet.href.includes("moduleId=cjdoc%3Amodule%3Anet"));
assert(streamFacet.href.includes("snapshotId=snap"));
const clickFacet = link => searchFacets.events.click({
  target:link, button:0, defaultPrevented:false, metaKey:false, ctrlKey:false, shiftKey:false, altKey:false,
  preventDefault() { this.defaultPrevented = true; }
});
clickFacet(streamFacet);
assert.equal(input.value, "Http");
assert.equal(results.children.length, 2);
assert(searchFacets.children.find(link => link.dataset.cjdocTagId === "stream" &&
  link.dataset.cjdocFacetModuleId === "cjdoc:module:net").attrs["aria-current"] === "true");
assert(new URLSearchParams(window.location.search).getAll("tag").includes("stream"));
clickFacet(searchFacets.children.find(link => link.dataset.cjdocTagId === "stream" &&
  link.dataset.cjdocFacetModuleId === "cjdoc:module:net"));
assert.equal(results.children.length, 3);
assert.equal(new URLSearchParams(window.location.search).getAll("tag").length, 0);
const setSearchUrl = query => {
  const url = new URL(query, "file:///fixture/index.html");
  window.location.href = url.href; window.location.search = url.search; window.location.hash = url.hash;
};
input.value = "";
setSearchUrl("?tag=stream&tag=public&moduleId=cjdoc%3Amodule%3Anet&snapshotId=snap");
window.popstate();
assert.deepEqual(search(""), ["HttpClientBuilder"]);
setSearchUrl("?tag=stream&moduleId=cjdoc%3Amodule%3Amissing&snapshotId=snap");
window.popstate();
assert.equal(results.children.length, 0);
assert(searchStatus.textContent.includes("scope_not_captured"));
setSearchUrl("?tag=stream&snapshotId=stale");
window.popstate();
assert.equal(results.children.length, 0);
assert(searchStatus.textContent.includes("snapshot_unavailable"));
setSearchUrl("?" + Array(65).fill("tag=stream").join("&"));
window.popstate();
assert(searchStatus.textContent.includes("request_schema"));
setSearchUrl("");
window.popstate();
assert.equal(results.children.length, 0);
setSearchUrl("?tag=stream&tag=public&moduleId=cjdoc%3Amodule%3Anet&snapshotId=snap");
window.hashchange();
const languageTarget = new URL(languageLink.href);
assert.deepEqual(languageTarget.searchParams.getAll("tag"), ["stream", "public"]);
assert.equal(languageTarget.searchParams.get("moduleId"), "cjdoc:module:net");
assert.equal(languageTarget.searchParams.get("snapshotId"), null);
setSearchUrl("");
window.popstate();
window.hashchange();
pkg.value = "other"; input.value = ""; pkg.events.change();
assert.deepEqual(results.children.map(x => x.children[0].children[0].children[0].textContent), ["HttpClientBuilder"]);
keydown({key:"Escape", preventDefault() {}});
assert.equal(pkg.value, "other");
assert.equal(searchPopover.hidden, true);
assert.equal(results.children.length, 0);
input.events.focus();
assert.deepEqual(results.children.map(x => x.children[0].children[0].children[0].textContent), ["HttpClientBuilder"]);
pkg.value = ""; pkg.events.change();
originFilter.value = "reexport"; originFilter.events.change();
assert.equal(memberBuilder.hidden, true);
assert.equal(memberSend.hidden, false);
memberFilter.value = "tag:stream"; memberFilter.events.input();
assert.equal(memberBuilder.hidden, true);
assert.equal(memberSend.hidden, true);
originFilter.value = ""; originFilter.events.change();
assert.equal(memberBuilder.hidden, false);
assert.equal(memberSend.hidden, true);
memberFilter.value = "tag:stream tag:public"; memberFilter.events.input();
assert.equal(memberBuilder.hidden, false);
assert.equal(memberSend.hidden, true);
memberFilter.value = "tag:Stream"; memberFilter.events.input();
assert.equal(memberBuilder.hidden, true);
assert.equal(memberSend.hidden, true);
memberFilter.value = "unknown:value"; memberFilter.events.input();
assert.equal(memberStatus.hidden, false);
assert(memberStatus.textContent.includes("unknown_filter_field"));
assert.equal(memberBuilder.hidden, true);
memberFilter.value = ""; memberFilter.events.input();
assert.equal(memberBuilder.hidden, false);
assert.equal(memberSend.hidden, false);
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
keydown({key: "ArrowDown", preventDefault() {}});
assert.equal(input.attrs["aria-activedescendant"], "cjdoc-search-result-0");
const link = results.children[0].children[0];
keydown({key: "Enter", preventDefault() {}}); assert(link.clicked);
keydown({key: "Escape", preventDefault() {}}); assert.equal(results.children.length, 0);
document.keydown({key: "k", ctrlKey: true, preventDefault() {}}); assert(input.focused);
assert.equal(search("overloaded").length, 2);
const moduleLinks = results.children.map(item => item.children[0]);
assert.deepEqual(moduleLinks.map(link => link.children[1].textContent), ["net.Client · sdk-a", "net.Client · sdk-b"]);
assert.equal(moduleLinks[0].children[1].title, "net.overloaded · sdk-a · cjdoc:module:a");
assert.notEqual(moduleLinks[0].children[2].textContent, moduleLinks[1].children[2].textContent);
// An input method editor must not drive results with intermediate text, and
// Enter during composition commits instead of opening a result.
input.value = ""; input.events.input();
input.events.compositionstart();
input.value = "Ht"; input.events.input({isComposing: true});
assert.equal(results.children.length, 0);
input.events.compositionend();
input.value = "Http"; input.events.input();
assert(search("Http").includes("HttpClientBuilder"));
keydown({key: "ArrowDown", preventDefault() {}});
input.events.compositionstart();
// Enter during composition must not activate the highlighted result.
results.children[0].children[0].clicked = undefined;
keydown({key: "Enter", preventDefault() {}, isComposing: true});
assert.equal(results.children[0].children[0].clicked, undefined);
input.events.compositionend();
// Committing the composition re-renders for the committed text, so the
// selection restarts; the reader picks again before opening.
keydown({key: "ArrowDown", preventDefault() {}});
keydown({key: "Enter", preventDefault() {}});
assert(results.children[0].children[0].clicked);
'''
        script = "const SCRIPT = " + __import__("json").dumps(canonical_search_script()) + ";\n" + harness
        result = subprocess.run(["node"], input=script, text=True, encoding="utf-8", capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
