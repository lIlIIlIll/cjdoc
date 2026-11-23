protected package cjdoc.render.browser

internal let HTML_SEARCH_KERNEL_MATCHING_SCRIPT = #"  const canonicalJson = value => {
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
  const NO_EXPOSURES = Object.freeze([]);
  const filterExposures = (facts, exposures, entryFilters, contextual) => {
    if (!contextAdmits(facts, entryFilters)) return null;
    if (!contextual.length) return NO_EXPOSURES;
    const canonicalAdmits = contextAdmits(facts, contextual);
    let matched = null;
    for (const exposure of exposures) {
      if (!contextAdmits(exposure, contextual)) continue;
      if (!matched) matched = [];
      matched.push(exposure.raw.id);
    }
    return matched || (canonicalAdmits ? NO_EXPOSURES : null);
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
  const planQuery = (query, wanted, prepared, mode, hasOverload) => {
    const precise = mode === "precise";
    const policy = prepared.contract.textPolicy;
    const length = wanted.length === 1 ? runeCount(wanted[0]) : 0;
    const editToken = length >= policy.minEditRunes && length <= policy.maxEditRunes ? wanted[0] : "";
    const rules = [];
    for (const row of ruleRows(prepared, mode)) {
      const variant = row.primitive.endsWith("_with_selector");
      const primitive = variant ? row.primitive.slice(0, -"_with_selector".length) : row.primitive;
      if (precise && primitive !== "exact_symbol_id" && primitive !== "exact_symbol_key" &&
          primitive !== "concept_text" && hasOverload !== variant) continue;
      rules.push({primitive, level: row.level, score: row.score, reason: row.reason});
    }
    return {query, wanted, foldedQuery: fold(query), editToken, precise, rules};
  };
  const hasWordPrefix = (words, token) => {
    for (const word of words) if (word.startsWith(token)) return true;
    return false;
  };
  const matchesWordPrefixes = (facts, wanted) => {
    if (!wanted.length) return false;
    for (const token of wanted) {
      if (!hasWordPrefix(facts.nameWords, token) && !hasWordPrefix(facts.ownerWords, token)) return false;
    }
    return true;
  };
  const matchesOneEdit = (facts, token) => {
    if (!token || facts.concept) return false;
    if (oneEditApart(token, facts.nameFold)) return true;
    for (const word of facts.nameWords) if (oneEditApart(token, word)) return true;
    return false;
  };
  const queryEvidence = (facts, exposures, plan) => {
    const {query, wanted, foldedQuery, editToken, precise, rules} = plan;
    let matches = null;
    for (const {primitive, level, score, reason} of rules) {
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
        if (!facts.concept) {
          for (const exposure of exposures) {
            if (exposure.raw.name === query) {
              if (!matches) matches = [];
              matches.push({level, score, reason, exposureId: exposure.raw.id});
            }
          }
          if (precise && matches) return matches;
        }
        continue;
      } else if (primitive === "ascii_fold_name") matched = !!facts.name && facts.nameFold === foldedQuery;
      else if (primitive === "name_prefix") matched = !!facts.name && facts.nameFold.startsWith(foldedQuery);
      else if (primitive === "qualified_prefix") {
        matched = !!facts.qualifiedName && facts.qualifiedFold.startsWith(foldedQuery);
      } else if (primitive === "all_token_word_prefix") {
        matched = matchesWordPrefixes(facts, wanted);
      } else if (primitive === "acronym") {
        matched = !facts.concept && wanted.length === 1 &&
          (facts.nameAcronym === wanted[0] || facts.qualifiedAcronym === wanted[0]);
      } else if (primitive === "structured_text") {
        matched = !facts.concept && containsAll(precise ? facts.identifierFold : facts.structuredFold, wanted);
      } else if (primitive === "one_edit") {
        matched = matchesOneEdit(facts, editToken);
      } else if (primitive === "documentation_text") {
        matched = !facts.concept && containsAll(facts.documentationFold, wanted);
      } else if (primitive === "concept_text") {
        matched = facts.concept && containsAll(facts.documentationFold, wanted);
      }
      if (!matched) continue;
      const evidence = {level, score, reason, exposureId: ""};
      if (precise) return [evidence];
      if (!matches) matches = [];
      matches.push(evidence);
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

"#
