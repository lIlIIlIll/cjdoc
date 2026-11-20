package cjdoc.render

// The browser half of the published search contract. This script is shipped
// with the index and is also a pure ES2020 API usable from Node and file://.
// Admit exact schemas (including enum order), printable titles and well-formed
// identity strings. Return the first validation error. Precise and discovery
// share selector primitives, but resolve their own evidence and overload rules.
internal let HTML_SEARCH_KERNEL_SCRIPT = #"
globalThis.cjdocSearch = (() => {
  const INDEX_CACHE = new WeakMap();
  const SEP = String.fromCharCode(0);
  const RULE_PRIMITIVES = new Set([
    "exact_symbol_id", "exact_symbol_key", "exact_qualified_name", "exact_qualified_name_with_selector",
    "exact_name", "exact_name_with_selector", "query_exact_name", "query_exact_name_with_selector",
    "exact_owner_member", "exact_owner_member_with_selector", "exact_alias", "exact_alias_with_selector",
    "ascii_fold_name", "name_prefix", "qualified_prefix", "all_token_word_prefix", "acronym",
    "structured_text", "structured_text_with_selector", "one_edit", "documentation_text",
    "documentation_text_with_selector", "concept_text", "filter_only"
  ]);
  const OP_PRIMITIVES = new Set(["exact_string_equal", "ascii_fold_contains"]);
  const SET_PREDICATE_PRIMITIVES = new Set(["all_exact"]);
  const TAG_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/u;

  const fail = (status, errorCode, reason = "not_executed", details = {}) => ({
    status, errorCode, reason, items: [], offset: 0, returned: 0, total: null,
    complete: false, next: null, coverage: null, facets: {tags: []}, ...details
  });
  const success = (status, reason, items, offset, total, complete, next, coverage, facets) => ({
    status, errorCode: null, reason, items, offset, returned: items.length,
    total, complete, next, coverage, facets
  });

  const hasUnpairedSurrogate = value => {
    for (let index = 0; index < value.length; index += 1) {
      const code = value.charCodeAt(index);
      if (code >= 0xd800 && code <= 0xdbff) {
        if (index + 1 >= value.length) return true;
        const next = value.charCodeAt(index + 1);
        if (next < 0xdc00 || next > 0xdfff) return true;
        index += 1;
      } else if (code >= 0xdc00 && code <= 0xdfff) return true;
    }
    return false;
  };
  const utf8Bytes = value => {
    if (typeof value !== "string" || hasUnpairedSurrogate(value)) {
      throw new TypeError("invalid Unicode scalar sequence");
    }
    const bytes = [];
    for (const char of value) {
      const code = char.codePointAt(0);
      if (code < 0x80) bytes.push(code);
      else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    return Uint8Array.from(bytes);
  };
  const compareByteArrays = (left, right) => {
    const size = Math.min(left.length, right.length);
    for (let index = 0; index < size; index += 1) {
      if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
    }
    return left.length === right.length ? 0 : (left.length < right.length ? -1 : 1);
  };
  const compareBytes = (left, right) => compareByteArrays(utf8Bytes(left), utf8Bytes(right));
  const ASCII_UPPERCASE = /[A-Z]/g;
  const lowercaseAscii = character => String.fromCharCode(character.charCodeAt(0) + 0x20);
  const fold = value => value.replace(ASCII_UPPERCASE, lowercaseAscii);
  const runeCount = value => [...value].length;
  const isWordCode = code => (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) || code === 0x5f;
  const tokens = value => {
    const result = [];
    let current = "";
    const flush = () => { if (current) { result.push(fold(current)); current = ""; } };
    for (const char of value) {
      const code = char.codePointAt(0);
      if (isWordCode(code) || code >= 0x80) current += char; else flush();
    }
    flush();
    return result;
  };
  const wordParts = value => {
    const chars = [...value];
    const words = [];
    let current = "";
    let started = false;
    for (let index = 0; index < chars.length; index += 1) {
      const char = chars[index];
      const code = char.codePointAt(0);
      const word = isWordCode(code) || code >= 0x80;
      if (!word) {
        if (started) words.push(fold(current));
        current = "";
        started = false;
        continue;
      }
      const upper = code >= 0x41 && code <= 0x5a;
      if (started && upper) {
        const previousCode = chars[index - 1].codePointAt(0);
        const nextCode = chars[index + 1] ? chars[index + 1].codePointAt(0) : 0;
        const previousLower = previousCode >= 0x61 && previousCode <= 0x7a;
        const previousUpper = previousCode >= 0x41 && previousCode <= 0x5a;
        const nextLower = nextCode >= 0x61 && nextCode <= 0x7a;
        if (previousLower || (previousUpper && nextLower)) {
          words.push(fold(current));
          current = "";
        }
      }
      current += char;
      started = true;
    }
    if (started) words.push(fold(current));
    return words;
  };
  const acronym = words => words.map(word => [...word][0] || "").join("");
  const containsAll = (haystack, wanted) => wanted.length > 0 && wanted.every(token => haystack.includes(token));
  const oneEditApart = (query, candidate) => {
    const left = [...query];
    const right = [...candidate];
    if (Math.abs(left.length - right.length) > 1) return false;
    let leftIndex = 0;
    let rightIndex = 0;
    let edits = 0;
    while (leftIndex < left.length && rightIndex < right.length) {
      if (left[leftIndex] === right[rightIndex]) { leftIndex += 1; rightIndex += 1; continue; }
      edits += 1;
      if (edits > 1) return false;
      if (left.length === right.length) { leftIndex += 1; rightIndex += 1; }
      else if (left.length > right.length) leftIndex += 1;
      else rightIndex += 1;
    }
    if (leftIndex < left.length || rightIndex < right.length) edits += 1;
    return edits === 1;
  };

  const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const own = (value, name) => Object.prototype.hasOwnProperty.call(value, name);
  const stringArray = value => Array.isArray(value) && value.every(item => typeof item === "string");
  const propertyArray = property => Array.isArray(property) ? property : [property];
  const validRulePrimitive = primitive => RULE_PRIMITIVES.has(primitive);
  const validOperatorPrimitive = primitive => OP_PRIMITIVES.has(primitive);

  const sameItems = (value, expected) => Array.isArray(value) &&
    value.length === expected.length && expected.every((item, index) => value[index] === item);
  const sameSet = (values, expected) => Array.isArray(values) && values.length === expected.size &&
    new Set(values).size === values.length && values.every(value => expected.has(value));

  const validateContract = contract => {
    if (!exactKeys(contract, ["version", "maxRequestBytes", "textPolicy", "defaultMode", "defaultProfile",
        "defaultLimit", "maxLimit", "maxFilters", "maxTags", "staticBodyTextLimit",
        "summaryDisplayLimit", "signatureDisplayLimit", "requestProperties", "globalFields",
        "searchFields", "filterFields", "filterOps", "setPredicates", "preciseRules", "discoveryRules"]) ||
        contract.version !== "cjdoc.search-contract/2" ||
        !isObject(contract.requestProperties) || !stringArray(contract.globalFields) ||
        !stringArray(contract.searchFields) || !Array.isArray(contract.filterFields) || contract.filterFields.length === 0 ||
        !Array.isArray(contract.filterOps) || contract.filterOps.length === 0 ||
        !Array.isArray(contract.setPredicates) || contract.setPredicates.length !== 1 ||
        !Array.isArray(contract.preciseRules) || contract.preciseRules.length === 0 ||
        !Array.isArray(contract.discoveryRules) || contract.discoveryRules.length === 0) return false;
    if (contract.defaultMode !== "precise" || contract.defaultProfile !== "full-ir" ||
        contract.defaultLimit !== 20 || contract.maxLimit !== 100 || contract.maxFilters !== 64 ||
        contract.maxTags !== 64 || contract.maxRequestBytes !== 1048576 ||
        contract.staticBodyTextLimit !== 2000 || contract.summaryDisplayLimit !== 240 ||
        contract.signatureDisplayLimit !== 512) return false;
    const properties = contract.requestProperties;
    const policy = contract.textPolicy;
    if (!exactKeys(policy, ["caseFold", "normalization", "tokens", "words", "edit", "minEditRunes", "maxEditRunes"]) ||
        policy.caseFold !== "ascii-only" || policy.normalization !== "none" ||
        policy.tokens !== "ascii-alnum-underscore-or-u0080-plus" ||
        policy.words !== "ascii-camel-acronym-boundaries" ||
        policy.edit !== "one-scalar-insert-delete-substitute" ||
        !Number.isSafeInteger(policy.minEditRunes) || !Number.isSafeInteger(policy.maxEditRunes) ||
        policy.minEditRunes < 1 || policy.maxEditRunes < policy.minEditRunes || policy.maxEditRunes > 128) return false;
    const topFields = new Set();
    for (const field of [...contract.globalFields, ...contract.searchFields]) {
      if (typeof field !== "string" || !own(properties, field) || topFields.has(field)) return false;
      topFields.add(field);
    }
    const modeSchema = properties.mode;
    const profileSchema = properties.profile;
    const fields = new Set();
    if (!exactKeys(modeSchema, ["enum"]) || !sameItems(modeSchema.enum, ["precise", "discovery"]) ||
        !exactKeys(profileSchema, ["enum"]) ||
        !sameItems(profileSchema.enum, ["full-ir", "bounded-static"])) return false;
    const filterSchema = properties.filters;
    if (!exactKeys(filterSchema, ["type", "maxItems", "items"]) || filterSchema.type !== "array" ||
        filterSchema.maxItems !== contract.maxFilters ||
        !exactKeys(filterSchema.items, ["type", "additionalProperties", "required", "properties"]) ||
        filterSchema.items.type !== "object" || filterSchema.items.additionalProperties !== false ||
        !Array.isArray(filterSchema.items.required) || filterSchema.items.required.length !== 3 ||
        filterSchema.items.required.some(field => !["field", "op", "value"].includes(field)) ||
        !exactKeys(filterSchema.items.properties, ["field", "op", "value"]) ||
        !exactKeys(filterSchema.items.properties.field, ["enum"]) ||
        !Array.isArray(filterSchema.items.properties.field.enum) ||
        !exactKeys(filterSchema.items.properties.op, ["enum"]) ||
        !Array.isArray(filterSchema.items.properties.op.enum) ||
        !exactKeys(filterSchema.items.properties.value, ["type", "minLength", "maxLength"]) ||
        filterSchema.items.properties.value.type !== "string" ||
        filterSchema.items.properties.value.minLength !== 1 ||
        filterSchema.items.properties.value.maxLength !== 16384) return false;
    for (const row of contract.filterFields) {
      if (!exactKeys(row, ["field", "property", "context"]) ||
          typeof row.field !== "string" || !row.field || fields.has(row.field) ||
          !(typeof row.property === "string" && row.property.length > 0 ||
            stringArray(row.property) && row.property.every(value => value.length > 0)) ||
          (row.context !== "entry" && row.context !== "canonical-or-exposure")) return false;
      fields.add(row.field);
    }
    const fieldEnum = filterSchema.items.properties.field.enum;
    if (!sameSet(fieldEnum, fields)) return false;
    const operators = new Set();
    for (const row of contract.filterOps) {
      if (!exactKeys(row, ["op", "primitive"]) || typeof row.op !== "string" || !row.op ||
          operators.has(row.op) || typeof row.primitive !== "string" ||
          !validOperatorPrimitive(row.primitive)) return false;
      operators.add(row.op);
    }
    const operatorEnum = filterSchema.items.properties.op.enum;
    if (!sameSet(operatorEnum, operators)) return false;
    const predicate = contract.setPredicates[0];
    const tagsSchema = properties.tags;
    if (!exactKeys(predicate, ["field", "property", "primitive"]) ||
        predicate.field !== "tags" || predicate.property !== "tagIds" ||
        !SET_PREDICATE_PRIMITIVES.has(predicate.primitive) ||
        !contract.searchFields.includes(predicate.field) ||
        !exactKeys(tagsSchema, ["type", "minItems", "maxItems", "items"]) ||
        tagsSchema.type !== "array" || tagsSchema.minItems !== 1 ||
        tagsSchema.maxItems !== contract.maxTags ||
        !exactKeys(tagsSchema.items, ["type", "pattern", "minLength", "maxLength"]) ||
        tagsSchema.items.type !== "string" || tagsSchema.items.minLength !== 1 ||
        tagsSchema.items.maxLength !== 64 ||
        tagsSchema.items.pattern !== "^[A-Za-z0-9_-]{1,64}$") return false;
    for (const rules of [contract.preciseRules, contract.discoveryRules]) {
      for (const row of rules) {
        if (!exactKeys(row, ["primitive", "level", "score", "reason"]) ||
            typeof row.primitive !== "string" || !validRulePrimitive(row.primitive) ||
            !Number.isSafeInteger(row.level) || !Number.isSafeInteger(row.score) ||
            typeof row.reason !== "string" || !row.reason) return false;
      }
    }
    return true;
  };

  const exactKeys = (object, expected) => {
    if (!isObject(object)) return false;
    const keys = Object.keys(object);
    return keys.length === expected.length && expected.every(key => own(object, key));
  };
  const validCoverage = (coverage, index, contract) =>
    exactKeys(coverage, ["profile", "projectionId", "bodyTextLimit", "bodyComplete", "truncatedEntries"]) &&
    coverage.profile === "bounded-static" && coverage.projectionId === index.projectionId &&
    coverage.bodyTextLimit === contract.staticBodyTextLimit && typeof coverage.bodyComplete === "boolean" &&
    Number.isSafeInteger(coverage.truncatedEntries) && coverage.truncatedEntries >= 0 &&
    coverage.bodyComplete === (coverage.truncatedEntries === 0);
  const nonemptyString = value => typeof value === "string" && value.length > 0 && !hasUnpairedSurrogate(value);
  const nullableString = value => value === null || (typeof value === "string" && !hasUnpairedSurrogate(value));
  const validSection = section => isObject(section) && typeof section.kind === "string" &&
    typeof section.anchor === "string" && typeof section.text === "string" &&
    !hasUnpairedSurrogate(section.kind) && !hasUnpairedSurrogate(section.anchor) && !hasUnpairedSurrogate(section.text);
  const validTagId = value => typeof value === "string" && TAG_ID_PATTERN.test(value);
  const hasDisplayControl = value => /[\u0000-\u001f\u007f]/u.test(value);
  const boundedTitle = value => nonemptyString(value) && utf8Bytes(value).length <= 256 &&
    !hasDisplayControl(value);
  const validMetadataTitle = value => boundedTitle(value) && value.trim().length > 0;
  const validLegacyGroupTitle = value => boundedTitle(value) &&
    !/^[ \t\n\r\f\v]*$/u.test(value);
  const validSafeText = value => nonemptyString(value) && !hasDisplayControl(value);
  const DOCUMENT_SET_FIELDS = ["id", "moduleId", "library", "identity", "state", "source", "target",
    "cfg", "audience", "language", "revision", "apiVersion", "documentationRevision", "indexIdentity",
    "baseUrl"];
  const DEPENDENCY_FIELDS = ["moduleId", "componentModuleId", "name", "instanceId", "kind",
    "identity", "state", "evidence", "version", "revision", "target", "cfg"];
  const exactStringFields = (value, fields) => exactKeys(value, fields) &&
    fields.every(key => typeof value[key] === "string" && !hasUnpairedSurrogate(value[key]));
  const validDocumentSet = value => value === null ||
    (exactStringFields(value, DOCUMENT_SET_FIELDS) &&
      nonemptyString(value.id) && nonemptyString(value.library) &&
      ["observed", "verified", "declared", "unknown"].includes(value.state));
  const validDependency = value => value === null ||
    (exactStringFields(value, DEPENDENCY_FIELDS) &&
      nonemptyString(value.moduleId) && nonemptyString(value.name) && nonemptyString(value.instanceId) &&
      ["source", "binary", "std", "stdx", "toolchain"].includes(value.kind) &&
      ["unknown", "declared", "observed", "verified", "conflict"].includes(value.state));
  const validIndexModule = value => {
    if (!exactKeys(value,
      ["moduleId", "moduleName", "documentSet", "dependency", "dependencyInstanceState"]) ||
        !nonemptyString(value.moduleId) || !nullableString(value.moduleName) ||
        !validDocumentSet(value.documentSet) || !validDependency(value.dependency) ||
        !["recorded", "not_applicable", "unrecorded", "ambiguous"].includes(value.dependencyInstanceState)) return false;
    if (value.documentSet !== null && value.documentSet.moduleId !== value.moduleId) return false;
    if (value.dependency !== null && value.dependency.componentModuleId !== value.moduleId) return false;
    return true;
  };
  const validIndexScope = value => exactKeys(value, ["snapshotId", "sourceSnapshotId", "publicationRevision",
    "project", "language", "audience", "cfgProfile", "apiCollectionState"]) &&
      nonemptyString(value.snapshotId) && nonemptyString(value.sourceSnapshotId) &&
      typeof value.publicationRevision === "string" && typeof value.project === "string" &&
      nonemptyString(value.language) && ["external", "package", "all"].includes(value.audience) &&
      typeof value.cfgProfile === "string" &&
      ["resolved", "partial", "unavailable"].includes(value.apiCollectionState);
  const frozenCopy = value => {
    if (Array.isArray(value)) return Object.freeze(value.map(frozenCopy));
    if (isObject(value)) {
      const copy = {};
      for (const key of Object.keys(value)) copy[key] = frozenCopy(value[key]);
      return Object.freeze(copy);
    }
    return value;
  };
  const validClassification = (value, concept) => {
    if (!exactKeys(value, ["group", "tags"]) || !Array.isArray(value.tags)) return false;
    if (concept && (value.group !== null || value.tags.length !== 0)) return false;
    if (value.group !== null && (!exactKeys(value.group, ["id", "packageName", "ownerId", "title", "order"]) ||
        !validTagId(value.group.id) || !validSafeText(value.group.packageName) ||
        !(value.group.ownerId === null || nonemptyString(value.group.ownerId)) ||
        !validLegacyGroupTitle(value.group.title) ||
        !(value.group.order === null || (Number.isSafeInteger(value.group.order) &&
          value.group.order >= 0 && value.group.order <= 999999)))) return false;
    let previous = null;
    for (const tag of value.tags) {
      if (!exactKeys(tag, ["id", "title"]) || !validTagId(tag.id) || !validMetadataTitle(tag.title)) return false;
      if (previous !== null && compareBytes(previous, tag.id) >= 0) return false;
      previous = tag.id;
    }
    return true;
  };
  const prepareTagDictionary = (rows, modules, indexScope) => {
    if (!Array.isArray(rows)) return null;
    const all = [];
    const byScope = new Map();
    let previous = null;
    for (const row of rows) {
      if (!exactKeys(row, ["scope", "id", "title"]) || !Number.isSafeInteger(row.scope) ||
          row.scope < 0 || row.scope >= modules.length || !validTagId(row.id) ||
          !validMetadataTitle(row.title)) return null;
      const module = modules[row.scope];
      if (previous) {
        const moduleOrder = compareBytes(previous.moduleId, module.moduleId);
        if (moduleOrder > 0 || (moduleOrder === 0 && compareBytes(previous.id, row.id) >= 0)) return null;
      }
      previous = {moduleId: module.moduleId, id: row.id};
      let scoped = byScope.get(row.scope);
      if (!scoped) { scoped = new Map(); byScope.set(row.scope, scoped); }
      if (scoped.has(row.id)) return null;
      const facet = Object.freeze({
        scope: Object.freeze({
          snapshotId: indexScope.snapshotId,
          sourceSnapshotId: indexScope.sourceSnapshotId,
          moduleId: module.moduleId,
          documentSet: frozenCopy(module.documentSet),
          dependencyInstance: frozenCopy(module.dependency),
          dependencyInstanceState: module.dependencyInstanceState
        }),
        id: row.id,
        title: row.title
      });
      const tag = Object.freeze({
        scope: row.scope,
        moduleId: module.moduleId,
        id: row.id,
        title: row.title,
        key: row.scope + SEP + row.id,
        facet
      });
      scoped.set(row.id, tag);
      all.push(tag);
    }
    return {all: Object.freeze(all), byScope};
  };

  const prepareFilterProperties = (source, contract) => {
    const properties = new Map();
    for (const definition of contract.filterFields) {
      for (const property of propertyArray(definition.property)) {
        if (!own(source, property)) continue;
        const value = source[property];
        const values = Array.isArray(value) ? value : [value];
        properties.set(property, values.map(raw => ({
          raw, folded: typeof raw === "string" && !hasUnpairedSurrogate(raw) ? fold(raw) : ""
        })));
      }
    }
    return properties;
  };
  const prepareEntry = (entry, modules, indexScope, contract, tagDictionary) => {
    if (!isObject(entry) || own(entry, "tagIds") ||
        !nonemptyString(entry.id) || !nonemptyString(entry.snapshotId) || !nonemptyString(entry.canonicalId) ||
        typeof entry.concept !== "boolean" || !Number.isSafeInteger(entry.scope) ||
        typeof entry.kind !== "string" || typeof entry.name !== "string" || hasUnpairedSurrogate(entry.name) ||
        !nullableString(entry.qualifiedName) || !nullableString(entry.packageName) ||
        !nullableString(entry.ownerName) || !nullableString(entry.ownerQualifiedName) ||
        !nullableString(entry.ownerId) || !nullableString(entry.symbolKey) ||
        !Array.isArray(entry.parameterTypes) || !entry.parameterTypes.every(value => typeof value === "string" && !hasUnpairedSurrogate(value)) ||
        !Number.isSafeInteger(entry.genericArity) || entry.genericArity < 0 ||
        !nullableString(entry.returnType) || !nullableString(entry.returnCanonical) ||
        typeof entry.summary !== "string" || typeof entry.summaryDisplay !== "string" ||
        typeof entry.body !== "string" || typeof entry.bodyTruncated !== "boolean" ||
        typeof entry.href !== "string" || !validClassification(entry.classification, entry.concept) ||
        !Array.isArray(entry.exposures) || !Array.isArray(entry.externalDocs) ||
        !Array.isArray(entry.bindings) || !Array.isArray(entry.sections) ||
        !entry.sections.every(validSection) || !entry.exposures.every(exposure =>
          isObject(exposure) && nonemptyString(exposure.id) &&
          Number.isSafeInteger(exposure.scope) && exposure.scope >= 0 &&
          exposure.scope < modules.length && nonemptyString(exposure.name) &&
          nonemptyString(exposure.qualifiedName) && nonemptyString(exposure.packageName))) return null;
    if ([entry.kind, entry.summary, entry.summaryDisplay, entry.body, entry.href,
        ...entry.parameterTypes].some(hasUnpairedSurrogate)) return null;
    if (entry.snapshotId !== indexScope.snapshotId) return null;
    if (entry.concept) {
      if (entry.scope !== -1 || entry.kind !== "concept" || entry.genericArity !== 0 ||
          entry.packageName !== null || entry.qualifiedName !== null || entry.ownerId !== null ||
          entry.ownerName !== null || entry.ownerQualifiedName !== null || entry.symbolKey !== null ||
          entry.parameterTypes.length !== 0 || entry.returnType !== null || entry.returnCanonical !== null ||
          entry.exposures.length !== 0) return null;
    } else if (entry.scope < 0 || entry.scope >= modules.length || entry.packageName === null ||
        entry.qualifiedName === null || !modules[entry.scope]) return null;
    const classification = frozenCopy({
      group: entry.classification.group === null ? null : {
        id: entry.classification.group.id,
        packageName: entry.classification.group.packageName,
        ownerId: entry.classification.group.ownerId,
        title: entry.classification.group.title,
        order: entry.classification.group.order
      },
      tags: entry.classification.tags.map(tag => ({id: tag.id, title: tag.title}))
    });
    if (!entry.concept && classification.group !== null &&
        (classification.group.packageName !== entry.packageName ||
          classification.group.ownerId !== entry.ownerId)) return null;
    const tagFacts = [];
    const scopedTags = entry.concept ? null : tagDictionary.get(entry.scope);
    for (const tag of classification.tags) {
      const descriptor = scopedTags && scopedTags.get(tag.id);
      if (!descriptor || descriptor.title !== tag.title) return null;
      tagFacts.push(descriptor);
    }
    const exposures = entry.exposures.map(exposure => ({
      raw: exposure,
      idBytes: utf8Bytes(exposure.id),
      filterProperties: prepareFilterProperties(exposure, contract)
    }));
    exposures.sort((a, b) => compareByteArrays(a.idBytes, b.idBytes));
    const name = entry.name || "";
    const qualifiedName = entry.qualifiedName || "";
    const ownerName = entry.ownerName || "";
    const ownerQualifiedName = entry.ownerQualifiedName || "";
    const packageName = entry.packageName || "";
    const parameterTypes = entry.parameterTypes.slice();
    const returnType = entry.returnType || "";
    const returnCanonical = entry.returnCanonical || "";
    const structured = [qualifiedName, name, ownerName, ownerQualifiedName, packageName,
      entry.kind, ...parameterTypes, returnType, returnCanonical].join("\n");
    const metadataText = [classification.group && classification.group.id,
      classification.group && classification.group.title,
      ...classification.tags.flatMap(tag => [tag.id, tag.title])].filter(Boolean).join("\n");
    return {
      raw: entry, snapshotId: entry.snapshotId, canonicalId: entry.canonicalId,
      snapshotBytes: utf8Bytes(entry.snapshotId), canonicalBytes: utf8Bytes(entry.canonicalId),
      concept: entry.concept, scope: entry.scope, kind: entry.kind, name, qualifiedName,
      packageName, ownerName, symbolKey: entry.symbolKey || "",
      genericArity: entry.genericArity, parameterTypes, exposures, sections: entry.sections,
      classification, tagIds: Object.freeze(classification.tags.map(tag => tag.id)),
      tagFacets: Object.freeze(tagFacts), metadataText,
      filterProperties: prepareFilterProperties(entry, contract),
      nameFold: fold(name), qualifiedFold: fold(qualifiedName),
      identifierFold: fold([qualifiedName, name, ownerName].join("\n")),
      structuredFold: fold(structured + "\n" + metadataText),
      documentationFold: fold(entry.summary + "\n" + entry.body + "\n" + metadataText),
      nameWords: wordParts(name), ownerWords: wordParts(ownerName), qualifiedWords: wordParts(qualifiedName)
    };
  };

  const prepareIndex = index => {
    if (!isObject(index)) return {error: "search_index_unavailable"};
    if (INDEX_CACHE.has(index)) return INDEX_CACHE.get(index);
    let prepared;
    try {
      prepared = buildPreparedIndex(index);
    } catch (_) { prepared = {error: "search_index_invalid"}; }
    INDEX_CACHE.set(index, prepared);
    return prepared;
  };
  const buildPreparedIndex = index => {
    const invalid = {error: "search_index_invalid"};
    if (index.schemaVersion !== "cjdoc.search-index/11") {
      return {error: "search_index_version_unsupported"};
    }
    if (!validateContract(index.contract)) return {error: "search_contract_unavailable"};
    if (!exactKeys(index, ["schemaVersion", "profile", "contract", "projectionId", "scope",
        "coverage", "modules", "tags", "entries"]) ||
        index.profile !== "bounded-static" || !nonemptyString(index.projectionId) ||
        !validIndexScope(index.scope) || !Array.isArray(index.modules) || index.modules.length > 4096 ||
        !Array.isArray(index.tags) || !Array.isArray(index.entries) ||
        !validCoverage(index.coverage, index, index.contract)) return invalid;
    const modules = [];
    const moduleIds = new Set();
    for (const module of index.modules) {
      if (!validIndexModule(module) || moduleIds.has(module.moduleId)) return invalid;
      moduleIds.add(module.moduleId);
      modules.push(frozenCopy(module));
    }
    const tagDictionary = prepareTagDictionary(index.tags, modules, index.scope);
    if (!tagDictionary) return invalid;
    const entries = [];
    const byIdentity = new Map();
    const byCanonicalId = new Map();
    const usedTagKeys = new Set();
    for (const entry of index.entries) {
      const facts = prepareEntry(entry, modules, index.scope, index.contract, tagDictionary.byScope);
      if (!facts) return invalid;
      for (const tag of facts.tagFacets) usedTagKeys.add(tag.key);
      const snapshotGroup = byIdentity.get(facts.snapshotId) || new Map();
      byIdentity.set(facts.snapshotId, snapshotGroup);
      let group = snapshotGroup.get(facts.canonicalId);
      if (!group) {
        group = {entry: facts, exposures: [], snapshotId: facts.snapshotId,
          canonicalId: facts.canonicalId, snapshotBytes: facts.snapshotBytes,
          canonicalBytes: facts.canonicalBytes};
        snapshotGroup.set(facts.canonicalId, group);
        byCanonicalId.set(facts.canonicalId, group);
        entries.push(group);
      } else if (group.entry.scope !== facts.scope ||
          canonicalJson(group.entry.classification) !== canonicalJson(facts.classification)) {
        return invalid;
      }
      for (const exposure of facts.exposures) {
        if (!group.exposures.some(existing => existing.raw.id === exposure.raw.id)) {
          group.exposures.push(exposure);
        }
      }
    }
    if (tagDictionary.all.some(tag => !usedTagKeys.has(tag.key))) return invalid;
    for (const group of entries) {
      group.exposures.sort((a, b) => compareByteArrays(a.idBytes, b.idBytes));
    }
    return {contract: index.contract, modules, entries, byIdentity, byCanonicalId,
      tagDictionary, scope: frozenCopy(index.scope), coverage: frozenCopy(index.coverage),
      projectionId: index.projectionId,
      contentBinding: index.projectionId + "\n" + canonicalJson(index.scope)};
  };

  const canonicalJson = value => {
    if (value === null || typeof value === "boolean" || typeof value === "number") return JSON.stringify(value);
    if (typeof value === "string") return JSON.stringify(value);
    if (Array.isArray(value)) return "[" + value.map(canonicalJson).join(",") + "]";
    const keys = Object.keys(value).sort(compareBytes);
    return "{" + keys.map(key => JSON.stringify(key) + ":" + canonicalJson(value[key])).join(",") + "}";
  };

  const validateValue = (value, schema, contract) => {
    if (!isObject(schema)) return false;
    if (schema.const !== undefined && value !== schema.const) return false;
    if (Array.isArray(schema.enum) && !schema.enum.some(item => item === value)) return false;
    if (schema.type === "string") {
      if (typeof value !== "string" || hasUnpairedSurrogate(value)) return false;
      const size = runeCount(value);
      if (schema.minLength !== undefined && size < schema.minLength) return false;
      if (schema.maxLength !== undefined && size > schema.maxLength) return false;
      if (schema.pattern !== undefined && !(new RegExp(schema.pattern, "u")).test(value)) return false;
      return true;
    }
    if (schema.type === "integer") {
      if (!Number.isSafeInteger(value)) return false;
      if (schema.minimum !== undefined && value < schema.minimum) return false;
      if (schema.maximum !== undefined && value > schema.maximum) return false;
      return true;
    }
    if (schema.type === "boolean") return typeof value === "boolean";
    if (schema.type === "array") {
      if (!Array.isArray(value)) return false;
      const maximum = schema.maxItems === undefined ? Infinity : schema.maxItems;
      const maxItems = schema === contract.requestProperties.filters
        ? Math.min(maximum, contract.maxFilters) : maximum;
      if (value.length > maxItems) return false;
      if (schema.minItems !== undefined && value.length < schema.minItems) return false;
      if (schema.uniqueItems) {
        const seen = new Set();
        for (const item of value) {
          const key = canonicalJson(item);
          if (seen.has(key)) return false;
          seen.add(key);
        }
      }
      if (schema.items && !value.every(item => validateValue(item, schema.items, contract))) return false;
      return true;
    }
    if (schema.type === "object") {
      if (!isObject(value)) return false;
      const props = schema.properties || {};
      if (schema.additionalProperties === false && Object.keys(value).some(key => !own(props, key))) return false;
      if (Array.isArray(schema.required) && schema.required.some(key => !own(value, key))) return false;
      for (const key of Object.keys(value)) {
        if (own(props, key) && !validateValue(value[key], props[key], contract)) return false;
      }
      return true;
    }
    return schema.type === undefined;
  };

  const normalizeFilters = (filters, prepared) => {
    if (!Array.isArray(filters)) return {error: "request_schema"};
    const contract = prepared.contract;
    const filterSchema = contract.requestProperties.filters;
    if (!validateValue(filters, filterSchema, contract)) return {error: "request_schema"};
    const fieldMap = new Map(contract.filterFields.map(row => [row.field, row]));
    const opMap = new Map(contract.filterOps.map(row => [row.op, row]));
    const seen = new Set();
    const normalized = [];
    for (const filter of filters) {
      const definition = fieldMap.get(filter.field);
      const operator = opMap.get(filter.op);
      if (!definition || !operator) return {error: "request_schema"};
      const key = filter.field + SEP + filter.op + SEP + filter.value;
      if (seen.has(key)) continue;
      seen.add(key);
      normalized.push({field: filter.field, op: filter.op, value: filter.value,
        foldedValue: operator.primitive === "ascii_fold_contains" ? fold(filter.value) : "",
        definition, operator});
    }
    normalized.sort((left, right) => compareBytes(
      left.field + SEP + left.op + SEP + left.value,
      right.field + SEP + right.op + SEP + right.value));
    return {filters: normalized};
  };
  const normalizeSetPredicates = (effective, request, prepared) => {
    const normalized = [];
    for (const definition of prepared.contract.setPredicates) {
      const field = definition.field;
      const schema = prepared.contract.requestProperties[field];
      if (!own(request, field)) {
        effective[field] = [];
        normalized.push({definition, values: []});
        continue;
      }
      const raw = request[field];
      if (!Array.isArray(raw) || !validateValue(raw, schema, prepared.contract)) return {error: "request_schema"};
      if (definition.primitive !== "all_exact") return {error: "search_contract_unsupported"};
      const values = sortedUniqueStrings(raw);
      effective[field] = values;
      normalized.push({definition, values});
    }
    return {predicates: normalized};
  };

  const hasInvalidUnicode = value => {
    if (typeof value === "string") return hasUnpairedSurrogate(value);
    if (Array.isArray(value)) return value.some(hasInvalidUnicode);
    if (isObject(value)) return Object.keys(value).some(key =>
      hasUnpairedSurrogate(key) || hasInvalidUnicode(value[key]));
    return false;
  };
  const requestError = (request, contract) => {
    if (!isObject(request)) return "request_schema";
    let serialized;
    try { serialized = JSON.stringify(request); } catch (_) { return "request_json"; }
    if (typeof serialized !== "string") return "request_json";
    try {
      if (utf8Bytes(serialized).length > contract.maxRequestBytes) return "request_byte_limit";
    } catch (_) { return "request_unicode"; }
    if (hasInvalidUnicode(request)) return "request_unicode";
    if (Object.keys(request).some(key => !own(contract.requestProperties, key))) return "unknown_field";
    const operation = request.operation;
    if (typeof operation !== "string" || !validateValue(operation, contract.requestProperties.operation, contract)) return "request_schema";
    if (operation !== "search") {
      const searchConfigurationFields = ["mode", "profile", "filters",
        ...contract.setPredicates.map(row => row.field)];
      if (Object.keys(request).some(key => searchConfigurationFields.includes(key))) return "field_not_applicable";
      return "operation_unavailable";
    }
    const allowed = new Set([...contract.globalFields, ...contract.searchFields]);
    if (Object.keys(request).some(key => !allowed.has(key))) return "field_not_applicable";
    for (const key of Object.keys(request)) {
      if (!validateValue(request[key], contract.requestProperties[key], contract)) return "request_schema";
    }
    return null;
  };

  const normalizeRequest = (request, prepared) => {
    const contract = prepared.contract;
    const error = requestError(request, contract);
    if (error) return {error};
    const effective = {};
    for (const key of Object.keys(request)) effective[key] = request[key];
    const versionSchema = contract.requestProperties.schemaVersion;
    if (!own(effective, "schemaVersion") && versionSchema && typeof versionSchema.const === "string") {
      effective.schemaVersion = versionSchema.const;
    }
    if (!own(effective, "mode")) effective.mode = contract.defaultMode;
    if (!own(effective, "profile")) effective.profile = contract.defaultProfile;
    if (!own(effective, "limit")) effective.limit = contract.defaultLimit;
    if (!own(effective, "query")) effective.query = "";
    if (!own(effective, "filters")) effective.filters = [];
    for (const definition of contract.setPredicates) {
      if (!own(effective, definition.field)) effective[definition.field] = [];
    }
    for (const key of ["snapshotId", "language", "audience", "cfgProfile"]) {
      if (!own(effective, key)) effective[key] = prepared.scope[key];
    }
    const filtersResult = normalizeFilters(effective.filters, prepared);
    if (filtersResult.error) return {error: filtersResult.error};
    effective.filters = filtersResult.filters.map(({field, op, value}) => ({field, op, value}));
    const setResult = normalizeSetPredicates(effective, request, prepared);
    if (setResult.error) return {error: setResult.error};
    const properties = contract.requestProperties;
    for (const key of Object.keys(effective)) {
      const isAbsentSetDefault = prepared.contract.setPredicates.some(row =>
        row.field === key && !own(request, key));
      if (key !== "cursor" && !isAbsentSetDefault && own(properties, key) &&
          !validateValue(effective[key], properties[key], contract)) return {error: "request_schema"};
    }
    if (effective.limit > contract.maxLimit) return {error: "request_schema"};
    const hasUserNarrowing = userNarrowing(request);
    effective._filterOnlyEligible = /^[ \t\n\r\f\v]*$/u.test(effective.query) &&
      hasUserNarrowing && !selectedIdentity(effective);
    return {effective, filters: filtersResult.filters, setPredicates: setResult.predicates,
      hasUserNarrowing};
  };

  const filterValueMatches = (stored, filter) => {
    if (!stored || typeof stored.raw !== "string") return false;
    if (filter.operator.primitive === "exact_string_equal") return stored.raw === filter.value;
    if (filter.operator.primitive === "ascii_fold_contains") return stored.folded.includes(filter.foldedValue);
    return false;
  };
  const contextAdmits = (context, filters) => filters.every(filter =>
    propertyArray(filter.definition.property).some(property => {
      if (!context || !context.filterProperties.has(property)) return false;
      return context.filterProperties.get(property).some(value => filterValueMatches(value, filter));
    }));
  const filterAdmits = (facts, groupExposures, filters) => {
    if (!filters.length) return {admitted: true, exposureIds: []};
    const contextual = filters.filter(filter => filter.definition.context === "canonical-or-exposure");
    const entryFilters = filters.filter(filter => filter.definition.context === "entry");
    for (const filter of entryFilters) {
      if (!contextAdmits(facts, [filter])) return {admitted: false, exposureIds: []};
    }
    if (!contextual.length) return {admitted: true, exposureIds: []};
    const canonicalAdmits = contextAdmits(facts, contextual);
    const exposureIds = [];
    for (const exposure of groupExposures) {
      if (contextAdmits(exposure, contextual)) exposureIds.push(exposure.raw.id);
    }
    return {admitted: canonicalAdmits || exposureIds.length > 0, exposureIds};
  };
  const setPredicatesAdmit = (facts, predicates) => predicates.every(({definition, values}) => {
    if (!values.length) return true;
    const stored = facts[definition.property];
    return Array.isArray(stored) && values.every(value => stored.includes(value));
  });

  const ruleRows = (prepared, mode) => mode === "discovery" ? prepared.contract.discoveryRules : prepared.contract.preciseRules;
  const ruleFor = (prepared, mode, primitive, options = {}) => {
    const rows = ruleRows(prepared, mode);
    const row = rows.find(value => value.primitive === primitive &&
      (!options.reason || value.reason === options.reason));
    if (!row) return null;
    if (options.overload && mode === "precise") {
      const reason = row.reason + "_with_overload_selector";
      return rows.find(value => value.level === row.level && value.score === row.score &&
        value.reason === reason) || row;
    }
    return row;
  };
  const evidenceFrom = (prepared, mode, primitive, exposureId = "", options = {}) => {
    const row = ruleFor(prepared, mode, primitive, options);
    if (!row) return null;
    return {level: row.level, score: row.score, reason: row.reason, exposureId};
  };
  const exactAliasFacts = (exposures, value) => exposures.filter(exposure =>
    exposure.raw.name === value);
  const selectorEvidence = (facts, exposures, request, prepared, mode, hasOverload = false) => {
    const evidence = (primitive, exposureId = "") => {
      const row = evidenceFrom(prepared, mode, primitive, exposureId, {overload: hasOverload});
      return row ? [row] : [];
    };
    const admit = (admitted, primitive) => admitted ? evidence(primitive) : [];
    if (request.symbolId !== undefined) {
      return admit(!facts.concept && facts.canonicalId === request.symbolId, "exact_symbol_id");
    }
    if (request.symbolKey !== undefined) {
      return admit(!facts.concept && facts.symbolKey === request.symbolKey, "exact_symbol_key");
    }
    if (request.qualifiedName !== undefined) {
      return admit(!facts.concept && facts.qualifiedName === request.qualifiedName, "exact_qualified_name");
    }
    if (request.name === undefined || facts.concept) return [];
    const value = request.name;
    if (facts.name === value) return evidence("exact_name");
    if (facts.qualifiedName === value) return evidence("exact_qualified_name");
    if (facts.ownerName && facts.ownerName + "." + facts.name === value) return evidence("exact_owner_member");
    return exactAliasFacts(exposures, value).flatMap(exposure => evidence("exact_alias", exposure.raw.id));
  };
  // Both modes walk their own published rule table; a rule that matches yields
  // its declared level/score/reason. Precise scanning stops at the first match,
  // discovery accumulates every match, and only precise honours overload
  // selector variants.
  const queryEvidence = (facts, exposures, query, prepared, mode, hasOverload = false) => {
    if (!query) return [];
    const precise = mode === "precise";
    const wanted = tokens(query);
    const foldedQuery = fold(query);
    const matches = [];
    for (const row of ruleRows(prepared, mode)) {
      const variant = row.primitive.endsWith("_with_selector");
      const primitive = variant ? row.primitive.slice(0, -"_with_selector".length) : row.primitive;
      if (precise && primitive !== "exact_symbol_id" && primitive !== "exact_symbol_key" &&
          primitive !== "concept_text" && hasOverload !== variant) continue;
      let exposureIds = [""];
      let matched = false;
      if (primitive === "exact_symbol_id") matched = !facts.concept && query === facts.canonicalId;
      else if (primitive === "exact_symbol_key") {
        matched = !facts.concept && !!facts.symbolKey && query === facts.symbolKey;
      } else if (primitive === "exact_qualified_name") {
        matched = !facts.concept && (precise || !!facts.qualifiedName) && query === facts.qualifiedName;
      } else if (primitive === "query_exact_name" || (!precise && primitive === "exact_name")) {
        matched = !facts.concept && query === facts.name;
      } else if (primitive === "exact_owner_member") {
        matched = !facts.concept && !!facts.ownerName && query === facts.ownerName + "." + facts.name;
      } else if (primitive === "exact_alias") {
        const aliases = facts.concept ? [] : exactAliasFacts(exposures, query);
        if (aliases.length) { matched = true; exposureIds = aliases.map(exposure => exposure.raw.id); }
      } else if (primitive === "ascii_fold_name") matched = !!facts.name && facts.nameFold === foldedQuery;
      else if (primitive === "name_prefix") matched = !!facts.name && facts.nameFold.startsWith(foldedQuery);
      else if (primitive === "qualified_prefix") {
        matched = !!facts.qualifiedName && facts.qualifiedFold.startsWith(foldedQuery);
      } else if (primitive === "all_token_word_prefix") {
        const words = facts.nameWords.concat(facts.ownerWords);
        matched = wanted.length > 0 && wanted.every(token => words.some(word => word.startsWith(token)));
      } else if (primitive === "acronym") {
        matched = !facts.concept && wanted.length === 1 &&
          (acronym(facts.nameWords) === wanted[0] || acronym(facts.qualifiedWords) === wanted[0]);
      } else if (primitive === "structured_text") {
        matched = !facts.concept && containsAll(precise ? facts.identifierFold : facts.structuredFold, wanted);
      } else if (primitive === "one_edit") {
        const length = wanted.length === 1 ? runeCount(wanted[0]) : 0;
        const policy = prepared.contract.textPolicy;
        if (!facts.concept && wanted.length === 1 && length >= policy.minEditRunes &&
            length <= policy.maxEditRunes) {
          const choices = [facts.nameFold, ...facts.nameWords];
          matched = choices.some(candidate => oneEditApart(wanted[0], candidate));
        }
      } else if (primitive === "documentation_text") {
        matched = !facts.concept && containsAll(facts.documentationFold, wanted);
      } else if (primitive === "concept_text") {
        matched = facts.concept && containsAll(facts.documentationFold, wanted);
      }
      if (!matched) continue;
      const evidenceRows = exposureIds.map(exposureId =>
        ({level: row.level, score: row.score, reason: row.reason, exposureId}));
      if (precise) return evidenceRows;
      matches.push(...evidenceRows);
    }
    return matches;
  };
  const selectedIdentity = request => request.symbolId !== undefined || request.symbolKey !== undefined ||
    request.qualifiedName !== undefined || request.name !== undefined;
  const overloadSelected = request => request.parameterTypes !== undefined || request.genericArity !== undefined;
  const selectorAdmits = (facts, request) => {
    if (request.parameterTypes !== undefined) {
      if (facts.concept || request.parameterTypes.length !== facts.parameterTypes.length) return false;
      for (let index = 0; index < request.parameterTypes.length; index += 1) {
        if (request.parameterTypes[index] !== facts.parameterTypes[index]) return false;
      }
    }
    if (request.genericArity !== undefined && (facts.concept || request.genericArity !== facts.genericArity)) return false;
    return true;
  };

  // Match native scope admission: all known values on this module's document set
  // and dependency must admit the request; only the document set uses `*`.
  const scopeValueAdmits = (documentSet, dependency, key, requested, wildcard) => {
    let known = false;
    if (documentSet && documentSet[key] !== "") {
      known = true;
      if (documentSet[key] !== requested && !(wildcard && documentSet[key] === "*")) return false;
    }
    if (dependency && dependency[key] !== "") {
      known = true;
      if (dependency[key] !== requested) return false;
    }
    return known;
  };
  // A module record is the only place these identities live, so both candidate
  // admission and request scope validation ask the same question of it.
  const moduleFieldsAdmit = (module, request) => {
    if (request.moduleId !== undefined && module.moduleId !== request.moduleId &&
        module.moduleName !== request.moduleId) return false;
    const set = module.documentSet;
    const dependency = module.dependency;
    if (request.documentSetId !== undefined && (!set || set.id !== request.documentSetId)) return false;
    if (request.library !== undefined && (!set || set.library !== request.library)) return false;
    if (request.apiVersion !== undefined && (!set || set.apiVersion !== request.apiVersion)) return false;
    if (request.dependencyInstanceId !== undefined &&
        (!dependency || dependency.instanceId !== request.dependencyInstanceId)) return false;
    if (request.target !== undefined && !scopeValueAdmits(set, dependency, "target", request.target, true)) return false;
    return request.cfg === undefined || scopeValueAdmits(set, dependency, "cfg", request.cfg, true);
  };
  const moduleScopeAdmits = (facts, modules, request) => {
    if (facts.concept) {
      const moduleFields = ["moduleId", "packageName", "documentSetId", "apiVersion", "library",
        "dependencyInstanceId", "target", "cfg"];
      if (moduleFields.some(key => request[key] !== undefined)) return false;
      return request.kind === undefined || request.kind === facts.kind;
    }
    const module = modules[facts.scope];
    if (!module || !moduleFieldsAdmit(module, request)) return false;
    if (request.packageName !== undefined && facts.packageName !== request.packageName) return false;
    return request.kind === undefined || facts.kind === request.kind;
  };
  const userNarrowing = request => {
    const executionFields = new Set(["schemaVersion", "operation", "mode", "profile", "limit",
      "cursor", "query", "filters", "latest", "languageFallback"]);
    return request.latest === true || (Array.isArray(request.filters) && request.filters.length > 0) ||
      Object.keys(request).some(name => !executionFields.has(name));
  };
  const compareEvidence = (left, right) => {
    if (left.score !== right.score) return left.score > right.score ? -1 : 1;
    const reason = compareBytes(left.reason, right.reason);
    if (reason !== 0) return reason;
    return compareBytes(left.exposureId || "", right.exposureId || "");
  };
  const compareCandidate = (left, right) => {
    if (left.evidence.score !== right.evidence.score) return left.evidence.score > right.evidence.score ? -1 : 1;
    let result = compareByteArrays(left.group.snapshotBytes, right.group.snapshotBytes);
    if (result !== 0) return result;
    result = compareByteArrays(left.group.canonicalBytes, right.group.canonicalBytes);
    if (result !== 0) return result;
    return compareBytes(left.evidence.reason, right.evidence.reason);
  };
  const sortedUniqueStrings = values => {
    const unique = [...new Set(values)];
    unique.sort(compareBytes);
    return unique;
  };

  const validateScope = (request, prepared) => {
    const scope = prepared.scope;
    if (request.snapshotId !== scope.snapshotId) return "snapshot_unavailable";
    if (request.language !== scope.language || request.audience !== scope.audience || request.cfgProfile !== scope.cfgProfile) {
      return "projection_unavailable";
    }
    if (request.latest === true && scope.latest !== true) return "latest_not_declared";
    const scopedKeys = ["moduleId", "documentSetId", "apiVersion", "library",
      "dependencyInstanceId", "target", "cfg"];
    if (scopedKeys.some(key => request[key] !== undefined) &&
        !prepared.modules.some(module => moduleFieldsAdmit(module, request))) {
      return "scope_not_captured";
    }
    return null;
  };

  const cursorCanonicalRequest = request => {
    const canonical = {};
    for (const key of Object.keys(request)) if (key !== "cursor") canonical[key] = request[key];
    return canonicalJson(canonical);
  };
  const sha256Utf8 = value => {
    const bytes = utf8Bytes(value);
    const bitLength = bytes.length * 8;
    const padded = new Uint8Array(Math.ceil((bytes.length + 9) / 64) * 64);
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, Math.floor(bitLength / 0x100000000));
    view.setUint32(padded.length - 4, bitLength >>> 0);
    const k = new Uint32Array([
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08,
      0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f,
      0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);
    const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    const w = new Uint32Array(64);
    for (let block = 0; block < padded.length; block += 64) {
      for (let index = 0; index < 16; index += 1) w[index] = view.getUint32(block + index * 4);
      for (let index = 16; index < 64; index += 1) {
        const a = w[index - 15], b = w[index - 2];
        const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
        const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
        w[index] = (w[index - 16] + s0 + w[index - 7] + s1) >>> 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let index = 0; index < 64; index += 1) {
        const s1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        const choice = (e & f) ^ (~e & g);
        const temp1 = (hh + s1 + choice + k[index] + w[index]) >>> 0;
        const s0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        const majority = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (s0 + majority) >>> 0;
        hh = g; g = f; f = e; e = (d + temp1) >>> 0;
        d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
      }
      h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0;
      h[3] = (h[3] + d) >>> 0; h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0;
      h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
    }
    return [...h].map(word => word.toString(16).padStart(8, "0")).join("");
  };

  // Every rejected query carries the same empty result shape so callers can
  // read errorCode without probing for missing arrays.
  const parseError = (errorCode, invalidToken) =>
    ({query: "", filters: [], tags: [], errorCode, invalidToken});
  const parseQuery = (raw, contract) => {
    if (typeof raw !== "string" || hasUnpairedSurrogate(raw)) return parseError("invalid_unicode", raw);
    if (!validateContract(contract)) return parseError("search_contract_unavailable", "");
    const fields = new Map(contract.filterFields.map(row => [fold(row.field), row.field]));
    const contains = contract.filterOps.find(row => row.primitive === "ascii_fold_contains");
    const tagPredicate = contract.setPredicates.find(row => row.field === "tags");
    if (!contains || !tagPredicate) return parseError("search_contract_unsupported", "");
    const filters = [];
    const tags = [];
    const terms = [];
    const trimmed = raw.replace(/^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/gu, "");
    for (const token of trimmed.split(/[ \t\n\r\f\v]+/u).filter(Boolean)) {
      const colon = token.indexOf(":");
      if (colon <= 0) { terms.push(token); continue; }
      const field = fold(token.slice(0, colon));
      const value = token.slice(colon + 1);
      if (field === "tag") {
        if (!value) return parseError("empty_filter_value", token);
        if (!validTagId(value)) return parseError("invalid_tag_id", token);
        tags.push(value);
        if (tags.length > 64) return parseError("request_schema", token);
        continue;
      }
      if (!fields.has(field)) return parseError("unknown_filter_field", token);
      if (!value) return parseError("empty_filter_value", token);
      filters.push({field: fields.get(field), op: contains.op, value});
    }
    return {query: terms.join(" "), filters, tags, errorCode: null, invalidToken: ""};
  };

  // A cursor is bound to the projection and the canonical request, so the same
  // digest proves pagination continuity on both issuing and checking.
  const cursorDigest = (normalized, prepared) => sha256Utf8("cjdoc.cursor-binding/2:" +
    prepared.contentBinding + "\n" + normalized.profile + "\n" + cursorCanonicalRequest(normalized));
  const checkCursor = (cursor, normalized, prepared) => {
    if (typeof cursor !== "string" || hasUnpairedSurrogate(cursor)) return {error: "cursor_format"};
    const match = /^cjdoc\.cursor\/2:(0|[1-9][0-9]*):([^:]+):([0-9a-f]{64})$/.exec(cursor);
    if (!match) return {error: "cursor_format"};
    const offset = Number(match[1]);
    if (!Number.isSafeInteger(offset)) return {error: "cursor_format"};
    if (match[2] !== normalized.profile) return {error: "cursor_binding"};
    let digest;
    try { digest = cursorDigest(normalized, prepared); }
    catch (_) { return {error: "cursor_format"}; }
    if (digest !== match[3]) return {error: "cursor_binding"};
    return {offset};
  };
  const makeCursor = (offset, normalized, prepared) => "cjdoc.cursor/2:" + offset + ":" +
    normalized.profile + ":" + cursorDigest(normalized, prepared);

  const collectCandidates = (prepared, normalizedResult, restrictCanonicalIds = null) => {
    const normalized = normalizedResult.effective;
    const query = normalized.query;
    const queryEmpty = !query || /^[ \t\n\r\f\v]*$/u.test(query);
    const hasNarrowing = normalizedResult.hasUserNarrowing;
    const filterOnly = queryEmpty && hasNarrowing && !selectedIdentity(normalized);
    const hasOverload = overloadSelected(normalized);
    const scoped = [];
    for (const group of prepared.entries) {
      const facts = group.entry;
      if (restrictCanonicalIds && !restrictCanonicalIds.has(group.canonicalId)) continue;
      if (!moduleScopeAdmits(facts, prepared.modules, normalized)) continue;
      if (!selectorAdmits(facts, normalized)) continue;
      const filterResult = filterAdmits(facts, group.exposures, normalizedResult.filters);
      if (!filterResult.admitted ||
          !setPredicatesAdmit(facts, normalizedResult.setPredicates)) continue;
      let evidence = [];
      if (filterOnly) evidence = [evidenceFrom(prepared, normalized.mode, "filter_only")].filter(Boolean);
      else if (selectedIdentity(normalized)) {
        evidence = selectorEvidence(facts, group.exposures, normalized, prepared,
          normalized.mode, hasOverload);
      } else if (queryEmpty) evidence = [];
      else evidence = queryEvidence(facts, group.exposures, query, prepared,
        normalized.mode, hasOverload);
      if (!evidence.length) continue;
      let best = evidence[0];
      for (const candidate of evidence) if (compareEvidence(candidate, best) < 0) best = candidate;
      const exposureIds = filterResult.exposureIds.slice();
      for (const candidate of evidence) if (candidate.exposureId) exposureIds.push(candidate.exposureId);
      const anchors = (best.reason === "documentation_text" || best.reason === "guide_text") && !facts.concept
        ? sortedUniqueStrings(facts.sections.filter(value => containsAll(fold(value.text), tokens(query))
          ).map(value => value.anchor)) : [];
      scoped.push({group, evidence: best, exposureIds: sortedUniqueStrings(exposureIds),
        anchor: anchors[0] || ""});
    }
    scoped.sort(compareCandidate);
    const unique = [];
    const seen = new Set();
    for (const item of scoped) {
      const key = item.group.snapshotId + SEP + item.group.canonicalId;
      if (seen.has(key)) continue;
      seen.add(key);
      unique.push(item);
    }
    return {unique, filterOnly, queryEmpty, hasNarrowing};
  };
  const tagFacetRows = unique => {
    const counts = new Map();
    for (const item of unique) {
      for (const tag of item.group.entry.tagFacets) {
        const current = counts.get(tag.key);
        if (current) current.count += 1;
        else counts.set(tag.key, {tag, count: 1});
      }
    }
    const rows = [...counts.values()].map(({tag, count}) => ({
      scope: tag.facet.scope, id: tag.id, title: tag.title, count
    }));
    rows.sort((left, right) => {
      let order = compareBytes(left.scope.snapshotId, right.scope.snapshotId);
      if (!order) order = compareBytes(left.scope.moduleId, right.scope.moduleId);
      if (!order) order = compareBytes(left.id, right.id);
      return order;
    });
    return rows;
  };
  const validateSearchRequest = (normalizedResult, prepared) => {
    const normalized = normalizedResult.effective;
    if (normalized.profile === "full-ir") return {error: "search_profile_unavailable", status: "unavailable"};
    if (normalized.profile !== "bounded-static" ||
        (normalized.mode !== "precise" && normalized.mode !== "discovery")) {
      return {error: "request_schema", status: "invalid_request"};
    }
    const scopeError = validateScope(normalized, prepared);
    return scopeError ? {error: scopeError, status: "scope_mismatch"} : null;
  };
  const execute = (index, request) => {
    const prepared = prepareIndex(index);
    if (prepared.error) return fail("unavailable", prepared.error);
    const normalizedResult = normalizeRequest(request, prepared);
    if (normalizedResult.error) return fail("invalid_request", normalizedResult.error);
    const requestError = validateSearchRequest(normalizedResult, prepared);
    if (requestError) return fail(requestError.status, requestError.error);
    const normalized = normalizedResult.effective;
    const {unique, filterOnly, queryEmpty, hasNarrowing} = collectCandidates(prepared, normalizedResult);
    let offset = 0;
    if (normalized.cursor !== undefined) {
      const parsedCursor = checkCursor(normalized.cursor, normalized, prepared);
      if (parsedCursor.error) return fail("stale_cursor", parsedCursor.error, "not_executed",
        {coverage: prepared.coverage});
      offset = parsedCursor.offset;
      if (offset > unique.length) return fail("stale_cursor", "cursor_out_of_range", "not_executed",
        {offset, total: unique.length, coverage: prepared.coverage});
    }
    const limit = normalized.limit;
    const end = Math.min(unique.length, offset + limit);
    const page = unique.slice(offset, end);
    const items = page.map(item => ({snapshotId: item.group.snapshotId,
      canonicalId: item.group.canonicalId, score: item.evidence.score, reason: item.evidence.reason,
      matchedExposureIds: item.exposureIds, anchor: item.anchor,
      classification: item.group.entry.classification}));
    const complete = end >= unique.length;
    const next = limit > 0 && !complete ? makeCursor(end, normalized, prepared) : null;
    const hasEvidence = unique.length > 0;
    let status = hasEvidence ? "ok" : "not_found";
    let reason = hasEvidence ? (filterOnly ? "filter_only" : "") : "no_match_in_scope";
    if (normalized.mode === "precise" && !filterOnly && unique.length > 1 &&
        unique[0].evidence.level === unique[1].evidence.level) {
      status = "ambiguous";
      reason = "several_captured_identities_tie";
    }
    if (!hasEvidence && (!queryEmpty || hasNarrowing || selectedIdentity(normalized)) &&
        prepared.scope.apiCollectionState !== "resolved") {
      status = "source_incomplete";
      reason = "no_match_with_incomplete_api_collection";
    }
    if (limit === 0 && hasEvidence) reason = "zero_limit_requested";
    return success(status, reason, items, offset, unique.length, complete, next,
      prepared.coverage, {tags: tagFacetRows(unique)});
  };
  const unavailable = (status, errorCode) => ({status, errorCode, canonicalIds: []});
  const createEntryFilter = (index, canonicalIds) => {
    const prepared = prepareIndex(index);
    if (prepared.error) return () => unavailable("unavailable", prepared.error);
    if (!Array.isArray(canonicalIds) ||
        !canonicalIds.every(value => nonemptyString(value))) {
      return () => unavailable("unavailable", "search_index_invalid");
    }
    const ids = sortedUniqueStrings(canonicalIds);
    const groups = [];
    for (const id of ids) {
      const group = prepared.byCanonicalId.get(id);
      if (!group || group.entry.concept) return () => unavailable("unavailable", "search_index_invalid");
      groups.push(group);
    }
    const restriction = new Set(ids);
    return request => {
      const localRequest = {...(isObject(request) ? request : {})};
      localRequest.operation = "search";
      if (!own(localRequest, "mode")) localRequest.mode = "discovery";
      if (!own(localRequest, "profile")) localRequest.profile = "bounded-static";
      localRequest.limit = 0;
      delete localRequest.cursor;
      const normalizedResult = normalizeRequest(localRequest, prepared);
      if (normalizedResult.error) return unavailable("invalid_request", normalizedResult.error);
      const requestError = validateSearchRequest(normalizedResult, prepared);
      if (requestError) return unavailable(requestError.status, requestError.error);
      const normalized = normalizedResult.effective;
      const queryEmpty = !normalized.query || /^[ \t\n\r\f\v]*$/u.test(normalized.query);
      if (!queryEmpty || normalizedResult.hasUserNarrowing ||
          selectedIdentity(normalized) || overloadSelected(normalized)) {
        const {unique} = collectCandidates(prepared, normalizedResult, restriction);
        return {status: "ok", errorCode: null,
          canonicalIds: unique.map(item => item.group.canonicalId)};
      }
      return {status: "ok", errorCode: null, canonicalIds: groups
        .filter(group => moduleScopeAdmits(group.entry, prepared.modules, normalized))
        .map(group => group.canonicalId)};
    };
  };

  const findEntry = (index, snapshotId, canonicalId) => {
    const prepared = prepareIndex(index);
    if (prepared.error) return null;
    const bySnapshot = prepared.byIdentity.get(snapshotId);
    const group = bySnapshot && bySnapshot.get(canonicalId);
    return group ? group.entry.raw : null;
  };

  return {fold, tokens, wordParts, acronym, oneEditApart, compareBytes, sha256Utf8,
    parseQuery, normalizeFilters, execute, createEntryFilter, findEntry};
})();
"#
