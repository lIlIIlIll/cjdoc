protected package cjdoc.render.browser

internal let HTML_SEARCH_KERNEL_EXECUTION_SCRIPT = #"  const cursorCanonicalRequest = request => {
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
    const selected = selectedIdentity(normalized);
    const filterOnly = queryEmpty && hasNarrowing && !selected;
    if (queryEmpty && !filterOnly && !selected) {
      return {unique: [], filterOnly, queryEmpty, hasNarrowing};
    }
    const hasOverload = overloadSelected(normalized);
    const wanted = tokens(query);
    const plan = filterOnly || selected ? null : planQuery(query, wanted, prepared, normalized.mode, hasOverload);
    const entryFilters = normalizedResult.filters.filter(filter => filter.definition.context === "entry");
    const contextual = normalizedResult.filters.filter(filter => filter.definition.context === "canonical-or-exposure");
    const filterRow = filterOnly ? evidenceFrom(prepared, normalized.mode, "filter_only") : null;
    const filterEvidence = filterRow ? [filterRow] : null;
    const scoped = [];
    for (const group of prepared.entries) {
      const facts = group.entry;
      if (restrictCanonicalIds && !restrictCanonicalIds.has(group.canonicalId)) continue;
      if (!moduleScopeAdmits(facts, prepared.modules, normalized)) continue;
      if (!selectorAdmits(facts, normalized)) continue;
      const matches = entryFilters.length || contextual.length
        ? filterExposures(facts, group.exposures, entryFilters, contextual) : NO_EXPOSURES;
      if (matches === null || !setPredicatesAdmit(facts, normalizedResult.setPredicates)) continue;
      let evidence;
      if (filterOnly) evidence = filterEvidence;
      else if (selected) {
        evidence = selectorEvidence(facts, group.exposures, normalized, prepared,
          normalized.mode, hasOverload);
      } else evidence = queryEvidence(facts, group.exposures, plan);
      if (!evidence || !evidence.length) continue;
      let best = evidence[0];
      let exposureIds = matches.length ? matches : null;
      for (const candidate of evidence) {
        if (candidate !== best && compareEvidence(candidate, best) < 0) best = candidate;
        if (candidate.exposureId) {
          if (!exposureIds) exposureIds = [];
          exposureIds.push(candidate.exposureId);
        }
      }
      if (exposureIds && exposureIds.length > 1) exposureIds = sortedUniqueStrings(exposureIds);
      const anchors = (best.reason === "documentation_text" || best.reason === "guide_text") && !facts.concept
        ? sortedUniqueStrings(facts.sections.filter(value => containsAll(fold(value.text), wanted)
          ).map(value => value.anchor)) : [];
      scoped.push({group, evidence: best, exposureIds,
        anchor: anchors[0] || ""});
    }
    scoped.sort(compareCandidate);
    // Index preparation already groups entries by their verified snapshot and canonical ID.
    return {unique: scoped, filterOnly, queryEmpty, hasNarrowing};
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
      matchedExposureIds: item.exposureIds || [], anchor: item.anchor,
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
