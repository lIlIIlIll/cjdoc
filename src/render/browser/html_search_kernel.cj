protected package cjdoc.render.browser

// The browser half of the published search contract. This script is shipped
// with the index and is also a pure ES2020 API usable from Node and file://.
// Admit exact schemas (including enum order), printable titles and well-formed
// identity strings. Return the first validation error. Precise and discovery
// share selector primitives, but resolve their own evidence and overload rules.
internal let HTML_SEARCH_KERNEL_PRIMITIVES_SCRIPT = #"
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

  // Unicode-mode matching treats a valid pair as one scalar outside this range.
  const SURROGATE = /[\uD800-\uDFFF]/u;
  const hasUnpairedSurrogate = value => SURROGATE.test(value);
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
    if (left === right) return 0;
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
  const containsAll = (haystack, wanted) => {
    if (!wanted.length) return false;
    for (const token of wanted) if (!haystack.includes(token)) return false;
    return true;
  };
  const pointWidth = point => point > 0xffff ? 2 : 1;
  const sameSuffix = (left, li, right, ri) => {
    if (left.length - li !== right.length - ri) return false;
    while (li < left.length) if (left.charCodeAt(li++) !== right.charCodeAt(ri++)) return false;
    return true;
  };
  const oneEditApart = (left, right) => {
    let li = 0;
    let ri = 0;
    while (li < left.length && ri < right.length) {
      const point = left.codePointAt(li);
      if (point !== right.codePointAt(ri)) break;
      li += pointWidth(point);
      ri += pointWidth(point);
    }
    if (li === left.length) return ri < right.length && ri + pointWidth(right.codePointAt(ri)) === right.length;
    if (ri === right.length) return li + pointWidth(left.codePointAt(li)) === left.length;
    const nextLeft = li + pointWidth(left.codePointAt(li));
    const nextRight = ri + pointWidth(right.codePointAt(ri));
    return sameSuffix(left, nextLeft, right, nextRight) ||
      sameSuffix(left, nextLeft, right, ri) || sameSuffix(left, li, right, nextRight);
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

"#
