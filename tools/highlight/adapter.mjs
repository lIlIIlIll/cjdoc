import hljs from 'highlight.js/lib/core';
import json from 'highlight.js/lib/languages/json';
import bash from 'highlight.js/lib/languages/bash';
import python from 'highlight.js/lib/languages/python';
import toml from 'highlight.js/lib/languages/ini';
import yaml from 'highlight.js/lib/languages/yaml';
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const PROTOCOL = 'cjdoc-highlight/1';
export const ENGINE = Object.freeze({ id: 'highlight.js', revision: '11.11.1/cjdoc-map-1' });
export const LIMITS = Object.freeze({ code: 262144, spans: 65536, input: 2097152, output: 3145728 });
const grammars = { json, bash, python, toml, yaml };
for (const [name, grammar] of Object.entries(grammars)) hljs.registerLanguage(name, grammar);
const scopeKinds = new Map(Object.entries({
  keyword: 'keyword', type: 'type', built_in: 'type', string: 'string',
  regexp: 'string', number: 'number', literal: 'literal', comment: 'comment',
  operator: 'operator', punctuation: 'punctuation', attr: 'property',
  attribute: 'property', property: 'property', variable: 'property',
  meta: 'meta', symbol: 'literal', params: null,
}));
const entities = new Map(Object.entries({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", '#x27': "'", '#39': "'" }));

function decodeText(text) {
  return text.replace(/&([^;]*);|&/g, (entity, name) => {
    if (entities.has(name)) return entities.get(name);
    if (/^#(?:[0-9]+|x[0-9a-f]+)$/i.test(name)) {
      const point = /^#x/i.test(name) ? parseInt(name.slice(2), 16) : Number(name.slice(1));
      if (point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff)) return String.fromCodePoint(point);
    }
    throw Error('invalid-spans');
  });
}

function spanKind(classes) {
  const [scope, ...modifiers] = classes.split(' ');
  if (!/^hljs-[a-z][a-z0-9_-]*$/.test(scope) ||
      modifiers.some(value => !/^[a-z][a-z0-9_]*_$/.test(value))) throw Error('invalid-spans');
  if (scope === 'hljs-title' && modifiers.includes('function_')) return 'function';
  if (scope === 'hljs-title' && modifiers.includes('class_')) return 'type';
  return scopeKinds.get(scope.slice(5)) ?? null;
}

// HTML is only an intermediate verification input. It never leaves this module.
export function convertHtml(html, code) {
  const stack = [];
  const pieces = [];
  let cursor = 0;
  while (cursor < html.length) {
    if (html[cursor] === '<') {
      const end = html.indexOf('>', cursor);
      if (end < 0) throw Error('invalid-spans');
      const tag = html.slice(cursor, end + 1);
      if (tag === '</span>') {
        if (!stack.length) throw Error('invalid-spans');
        stack.pop();
      } else {
        const match = /^<span class="([^"<>]+)">$/.exec(tag);
        if (!match) throw Error('invalid-spans');
        stack.push(spanKind(match[1]));
      }
      cursor = end + 1;
      continue;
    }
    const next = html.indexOf('<', cursor);
    const text = decodeText(html.slice(cursor, next < 0 ? html.length : next));
    pieces.push({ text, kind: stack.at(-1) });
    cursor = next < 0 ? html.length : next;
  }
  const reconstructed = pieces.map(piece => piece.text).join('');
  if (stack.length || reconstructed !== code ||
      !Buffer.from(reconstructed).equals(Buffer.from(code))) throw Error('invalid-spans');
  // Verify all text first; only then assign UTF-8 offsets to flattened runs.
  const spans = [];
  let byteOffset = 0;
  for (const { text, kind } of pieces) {
    const endByte = byteOffset + Buffer.byteLength(text, 'utf8');
    if (kind && endByte > byteOffset) {
      const previous = spans.at(-1);
      if (previous?.kind === kind && previous.endByte === byteOffset) previous.endByte = endByte;
      else spans.push({ startByte: byteOffset, endByte, kind });
      if (spans.length > LIMITS.spans) throw Error('resource-limit');
    }
    byteOffset = endByte;
  }
  return spans;
}

function baseResponse(request) {
  const code = typeof request?.code === 'string' ? request.code : '';
  return { protocol: PROTOCOL, id: request?.id ?? null, language: request?.language ?? null,
    engine: ENGINE, state: 'plain', byteLength: Buffer.byteLength(code),
    sourceHash: createHash('sha256').update(code, 'utf8').digest('hex'), spans: [] };
}

export function handleRequest(request) {
  const validId = typeof request?.id === 'string' && Buffer.byteLength(request.id) <= 128 ||
    Number.isSafeInteger(request?.id);
  const valid = request && typeof request === 'object' && !Array.isArray(request) &&
    request.protocol === PROTOCOL && validId && typeof request.language === 'string' &&
    Buffer.byteLength(request.language) <= 64 && typeof request.code === 'string' &&
    Object.keys(request).every(key => ['protocol', 'id', 'language', 'code'].includes(key));
  if (!valid) return { ...baseResponse(null), reason: 'invalid-request' };
  const response = baseResponse(request);
  if (!Object.hasOwn(grammars, request.language)) return { ...response, reason: 'unsupported-language' };
  if (response.byteLength > LIMITS.code) return { ...response, reason: 'resource-limit' };
  try {
    const result = hljs.highlight(request.code, { language: request.language, ignoreIllegals: true });
    if (Buffer.byteLength(result.value) > LIMITS.output) return { ...response, reason: 'resource-limit' };
    return responseFromHtml(request, result.value);
  } catch (error) {
    return { ...response, reason: error.message === 'resource-limit' ? 'resource-limit' : 'invalid-spans' };
  }
}
export function responseFromHtml(request, html) {
  const response = baseResponse(request);
  try {
    response.spans = convertHtml(html, request.code);
    response.state = 'complete';
    if (Buffer.byteLength(JSON.stringify(response)) > LIMITS.output) {
      return { ...response, state: 'plain', reason: 'resource-limit', spans: [] };
    }
    return response;
  } catch (error) {
    return { ...response, reason: error.message === 'resource-limit' ? 'resource-limit' : 'invalid-spans' };
  }
}

async function emit(response) {
  // Await the write callback so requests stay serial even when the pipe is full.
  await new Promise((resolve, reject) => {
    process.stdout.write(JSON.stringify(response) + '\n', error => error ? reject(error) : resolve());
  });
}

async function processLine(line, overflow) {
  let response;
  if (overflow) response = { ...baseResponse(null), reason: 'resource-limit' };
  else {
    try {
      const decoded = new TextDecoder('utf-8', { fatal: true }).decode(line);
      response = handleRequest(JSON.parse(decoded));
    } catch {
      response = { ...baseResponse(null), reason: 'malformed-json' };
    }
  }
  if (overflow || ['malformed-json', 'invalid-request'].includes(response.reason)) {
    process.exitCode = 2;
    process.stderr.write(('cjdoc-highlight: ' + response.reason).slice(0, 160) + '\n');
  }
  await emit(response);
}

export async function run() {
  let chunks = [];
  let length = 0;
  let overflow = false;
  for await (const chunk of process.stdin) {
    let cursor = 0;
    while (cursor < chunk.length) {
      const newline = chunk.indexOf(10, cursor);
      const end = newline < 0 ? chunk.length : newline;
      const part = chunk.subarray(cursor, end);
      length += part.length;
      if (length > LIMITS.input) { overflow = true; chunks = []; }
      if (!overflow) chunks.push(part);
      if (newline >= 0) {
        await processLine(overflow ? null : Buffer.concat(chunks, length), overflow);
        chunks = []; length = 0; overflow = false;
      }
      cursor = newline < 0 ? chunk.length : newline + 1;
    }
  }
  if (length || overflow) await processLine(overflow ? null : Buffer.concat(chunks, length), overflow);
}

// Node resolves the main module through symlinks for import.meta.url but leaves
// process.argv[1] as the invoked path, so an authorized adapter reached through a
// symlink must be compared after resolution. A path-equality check would skip
// run(), exit 0 with no response, and silently degrade every external block.
function isMainModule() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(realpathSync(entry)).href;
  } catch {
    return false;
  }
}

if (isMainModule()) {
  run().catch(() => {
    process.stderr.write('cjdoc-highlight: worker I/O failure\n');
    process.exitCode = 2;
  });
}
