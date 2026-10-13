import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { PROTOCOL, ENGINE, LIMITS, handleRequest, responseFromHtml } from '../adapter.mjs';

const request = (language, code, id = 1) => ({ protocol: PROTOCOL, id, language, code });
const kinds = new Set('keyword type string number literal comment operator punctuation function property meta'.split(' '));

function reconstruct(response, code) {
  const bytes = Buffer.from(code);
  const pieces = [];
  let cursor = 0;
  for (const span of response.spans) {
    assert(kinds.has(span.kind));
    assert(Number.isInteger(span.startByte) && span.startByte >= cursor);
    assert(Number.isInteger(span.endByte) && span.endByte > span.startByte && span.endByte <= bytes.length);
    pieces.push(bytes.subarray(cursor, span.startByte), bytes.subarray(span.startByte, span.endByte));
    cursor = span.endByte;
  }
  pieces.push(bytes.subarray(cursor));
  assert.deepEqual(Buffer.concat(pieces), bytes);
  assert.equal(response.sourceHash, createHash('sha256').update(bytes).digest('hex'));
}

const samples = {
  json: '{"名称":"😀 & <", "count":42, "ok":true}\n',
  bash: '# comment\nprintf "%s" "你好"\nif true; then echo 42; fi\n',
  python: '# comment\ndef hello(name):\n    return "你好😀" + str(42)\n',
  toml: '# comment\n[package]\nname = "你好"\ncount = 42\n',
  yaml: '# comment\nname: "你好😀"\ncount: 42\nready: true\n',
};
for (const [language, code] of Object.entries(samples)) {
  test(language + ' preserves source bytes', () => {
    const response = handleRequest(request(language, code));
    assert.equal(response.state, 'complete');
    assert(response.spans.length > 0);
    assert.equal(response.byteLength, Buffer.byteLength(code));
    assert.deepEqual(response.engine, ENGINE);
    reconstruct(response, code);
  });
}

test('hostile HTML remains original source, never response HTML', () => {
  const code = JSON.stringify({ value: '<script>alert(1)</script></span>&lt;&amp;<span class="hljs-keyword">' });
  const response = handleRequest(request('json', code));
  assert.equal(response.state, 'complete');
  reconstruct(response, code);
  assert(!JSON.stringify(response).includes('<'));
  assert(!JSON.stringify(response).includes('&lt;'));
  assert.equal(Object.hasOwn(response, 'value'), false);
});

test('unlisted languages and module paths are refused', () => {
  for (const language of ['javascript', '../../evil.mjs', 'constructor', '__proto__']) {
    const response = handleRequest(request(language, 'const value = 1'));
    assert.equal(response.state, 'plain');
    assert.equal(response.reason, 'unsupported-language');
    assert.deepEqual(response.spans, []);
  }
});

test('bad reconstruction, tags, attributes and entities fail closed', () => {
  for (const html of ['ab', 'xy', '<script>abc</script>', '<span class="hljs-string" onclick="x">abc</span>',
    '<span class="hljs-string">abc', '</span>abc', '&unknown;', 'a&bc']) {
    const response = responseFromHtml(request('json', 'abc'), html);
    assert.equal(response.state, 'plain');
    assert.equal(response.reason, 'invalid-spans');
    assert.deepEqual(response.spans, []);
  }
});

test('nested scopes flatten; unmapped scopes stay plain; entities decode once', () => {
  const code = '&lt;你好!';
  const html = '<span class="hljs-string">&amp;lt;<span class="hljs-unknown">你好</span>!</span>';
  const response = responseFromHtml(request('json', code), html);
  assert.equal(response.state, 'complete');
  assert.deepEqual(response.spans, [{startByte: 0, endByte: 4, kind: 'string'}, {startByte: 10, endByte: 11, kind: 'string'}]);
  reconstruct(response, code);
});

test('code and span budgets never return partial output', () => {
  const code = '你'.repeat(Math.ceil(LIMITS.code / 3) + 1);
  const response = handleRequest(request('python', code));
  assert.equal(response.reason, 'resource-limit');
  assert.equal(response.byteLength, Buffer.byteLength(code));
  assert.deepEqual(response.spans, []);
  const many = '<span class="hljs-string">x</span> '.repeat(LIMITS.spans + 1);
  const result = responseFromHtml(request('json', 'x '.repeat(LIMITS.spans + 1)), many);
  assert.equal(result.reason, 'resource-limit');
  assert.deepEqual(result.spans, []);
});

test('subprocess stdout consists only of serial protocol lines', () => {
  const requests = Object.entries(samples).map(([language, code], id) => request(language, code, id));
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../adapter.mjs', import.meta.url))],
    {input: requests.map(value => JSON.stringify(value)).join('\n') + '\n', encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  const responses = result.stdout.trimEnd().split('\n').map(line => JSON.parse(line));
  assert.equal(responses.length, requests.length);
  responses.forEach((response, id) => {
    assert.equal(response.protocol, PROTOCOL);
    assert.equal(response.id, id);
    reconstruct(response, requests[id].code);
  });
});

// A symlinked adapter path is a normal way to authorize a pinned install, and
// Node resolves the main module through symlinks while leaving process.argv[1]
// unresolved. Before the resolved-path check this subprocess exited 0 with no
// response, which the caller could only read as "no highlighting". The link
// lives beside the adapter so its pinned dependency still resolves.
test('adapter responds when invoked through a symlink', () => {
  const directory = mkdtempSync(join(dirname(fileURLToPath(new URL('../adapter.mjs', import.meta.url))), 'link-'));
  const link = join(directory, 'alias.mjs');
  symlinkSync(fileURLToPath(new URL('../adapter.mjs', import.meta.url)), link);
  try {
    const value = request('python', 'x = 1\n', 'symlink');
    const result = spawnSync(process.execPath, [link],
      {input: JSON.stringify(value) + '\n', encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    const response = JSON.parse(result.stdout.trimEnd());
    assert.equal(response.id, 'symlink');
    assert.equal(response.state, 'complete');
    reconstruct(response, value.code);
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});
