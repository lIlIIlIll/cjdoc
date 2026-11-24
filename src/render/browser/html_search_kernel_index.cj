protected package cjdoc.render.browser

internal let HTML_SEARCH_KERNEL_INDEX_SCRIPT = #"  const validateContract = contract => {
    if (!exactKeys(contract, ["version", "maxRequestBytes", "textPolicy", "defaultMode", "defaultProfile",
        "defaultLimit", "maxLimit", "maxFilters", "maxTags", "staticBodyTextLimit",
        "summaryDisplayLimit", "signatureDisplayLimit", "requestProperties", "globalFields",
        "searchFields", "filterFields", "filterOps", "setPredicates", "preciseRules", "discoveryRules"]) ||
        contract.version !== "cjdoc.search-contract/3" ||
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

  const prepareFilterProperties = (source, fields) => {
    const properties = new Map();
    for (const property of fields) {
      if (!own(source, property)) continue;
      const value = source[property];
      const values = Array.isArray(value) ? value : [value];
      properties.set(property, values.map(raw => ({
        raw, folded: typeof raw === "string" && !hasUnpairedSurrogate(raw) ? fold(raw) : ""
      })));
    }
    return properties;
  };
  const COMMENT_FIELD_ID = /^[a-z][a-z0-9-]{0,63}$/u;
  const validCommentFieldId = value => typeof value === "string" && COMMENT_FIELD_ID.test(value);
  const validCommentFieldValue = value => nonemptyString(value) && runeCount(value) <= 16384 &&
    /[^ \t]/u.test(value) && !/[\u0000-\u0008\u000a-\u001f\u007f-\u009f\u2028\u2029]/u.test(value);
  const prepareCommentFieldDictionary = (rows, modules) => {
    if (!Array.isArray(rows)) return null;
    const all = [];
    const byScope = new Map();
    let previous = null;
    for (const row of rows) {
      if (!exactKeys(row, ["scope", "id", "title", "repeatable"]) ||
          !Number.isSafeInteger(row.scope) || row.scope < 0 || row.scope >= modules.length ||
          !validCommentFieldId(row.id) || !validMetadataTitle(row.title) ||
          typeof row.repeatable !== "boolean") return null;
      const module = modules[row.scope];
      if (previous && (previous.scope > row.scope ||
          (previous.scope === row.scope && compareBytes(previous.id, row.id) >= 0))) return null;
      previous = row;
      let scoped = byScope.get(row.scope);
      if (!scoped) { scoped = new Map(); byScope.set(row.scope, scoped); }
      if (scoped.has(row.id)) return null;
      const definition = Object.freeze({
        scope: row.scope, moduleId: module.moduleId, id: row.id, title: row.title,
        repeatable: row.repeatable, key: row.scope + SEP + row.id
      });
      scoped.set(row.id, definition);
      all.push(definition);
    }
    return {all: Object.freeze(all), byScope};
  };

  const prepareEntry = (entry, modules, snapshot, fields, tagDictionary, commentFields) => {
    if (!isObject(entry) || own(entry, "tagIds") ||
        !nonemptyString(entry.id) || entry.snapshotId !== snapshot.id || !nonemptyString(entry.canonicalId) ||
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
        !Array.isArray(entry.commentFields) ||
        !entry.sections.every(validSection) || !entry.exposures.every(exposure =>
          isObject(exposure) && nonemptyString(exposure.id) &&
          Number.isSafeInteger(exposure.scope) && exposure.scope >= 0 &&
          exposure.scope < modules.length && nonemptyString(exposure.name) &&
          nonemptyString(exposure.qualifiedName) && nonemptyString(exposure.packageName))) return null;
    if ([entry.kind, entry.summary, entry.summaryDisplay, entry.body, entry.href,
        ...entry.parameterTypes].some(hasUnpairedSurrogate)) return null;
    const scopedFields = entry.concept ? null : commentFields.byScope.get(entry.scope);
    const fieldRows = [];
    let previousFieldId = null;
    for (const row of entry.commentFields) {
      if (!exactKeys(row, ["id", "values"]) || !validCommentFieldId(row.id) ||
          !Array.isArray(row.values) || row.values.length === 0 ||
          !row.values.every(validCommentFieldValue)) return null;
      if (previousFieldId !== null && compareBytes(previousFieldId, row.id) >= 0) return null;
      previousFieldId = row.id;
      const definition = scopedFields && scopedFields.get(row.id);
      if (!definition || (!definition.repeatable && row.values.length > 1)) return null;
      fieldRows.push(Object.freeze({id: row.id, values: Object.freeze(row.values.slice())}));
    }
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
      filterProperties: prepareFilterProperties(exposure, fields)
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
    const nameWords = wordParts(name);
    return {
      raw: entry, snapshotId: entry.snapshotId, canonicalId: entry.canonicalId,
      snapshotBytes: snapshot.bytes, canonicalBytes: utf8Bytes(entry.canonicalId),
      concept: entry.concept, scope: entry.scope, kind: entry.kind, name, qualifiedName,
      packageName, ownerName, symbolKey: entry.symbolKey || "",
      genericArity: entry.genericArity, parameterTypes, exposures, sections: entry.sections,
      classification, tagIds: Object.freeze(classification.tags.map(tag => tag.id)),
      commentFields: Object.freeze(fieldRows),
      tagFacets: Object.freeze(tagFacts), metadataText,
      filterProperties: prepareFilterProperties(entry, fields),
      nameFold: fold(name), qualifiedFold: fold(qualifiedName),
      identifierFold: fold([qualifiedName, name, ownerName].join("\n")),
      structuredFold: fold(structured + "\n" + metadataText),
      documentationFold: fold(entry.summary + "\n" + entry.body + "\n" + metadataText +
        (fieldRows.length ? "\n" + fieldRows.flatMap(row => row.values).join("\n") : "")),
      nameWords, ownerWords: wordParts(ownerName),
      nameAcronym: acronym(nameWords), qualifiedAcronym: acronym(wordParts(qualifiedName))
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
    if (index.schemaVersion !== "cjdoc.search-index/12") {
      return {error: "search_index_version_unsupported"};
    }
    if (!validateContract(index.contract)) return {error: "search_contract_unavailable"};
    if (!exactKeys(index, ["schemaVersion", "profile", "contract", "projectionId", "scope",
        "coverage", "modules", "tags", "commentFields", "entries"]) ||
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
    const commentFields = prepareCommentFieldDictionary(index.commentFields, modules, index.scope);
    if (!commentFields) return invalid;
    const usedFieldKeys = new Set();
    const entries = [];
    const byIdentity = new Map();
    const byCanonicalId = new Map();
    const usedTagKeys = new Set();
    // Every entry must bind to the same publication snapshot and filter contract.
    const snapshot = {id: index.scope.snapshotId, bytes: utf8Bytes(index.scope.snapshotId)};
    const fields = new Set(index.contract.filterFields.flatMap(field => propertyArray(field.property)));
    for (const entry of index.entries) {
      const facts = prepareEntry(entry, modules, snapshot, fields, tagDictionary.byScope,
        commentFields);
      if (!facts) return invalid;
      for (const tag of facts.tagFacets) usedTagKeys.add(tag.key);
      for (const row of facts.commentFields) usedFieldKeys.add(facts.scope + SEP + row.id);
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
    if (commentFields.all.some(field => !usedFieldKeys.has(field.key))) return invalid;
    for (const group of entries) {
      group.exposures.sort((a, b) => compareByteArrays(a.idBytes, b.idBytes));
    }
    return {contract: index.contract, modules, entries, byIdentity, byCanonicalId,
      tagDictionary, commentFields, scope: frozenCopy(index.scope), coverage: frozenCopy(index.coverage),
      projectionId: index.projectionId,
      contentBinding: index.projectionId + "\n" + canonicalJson(index.scope)};
  };

"#
