import test from 'node:test';
import assert from 'node:assert/strict';
import { PROTOCOL, LIMITS, responseFromHtml } from '../adapter.mjs';

test('serialized output is bounded independently of span count', () => {
  const count = LIMITS.spans;
  const code = 'x '.repeat(count);
  const html = '<span class="hljs-punctuation">x</span> '.repeat(count);
  const response = responseFromHtml({protocol: PROTOCOL, id: 1, language: 'json', code}, html);
  assert.equal(response.state, 'plain');
  assert.equal(response.reason, 'resource-limit');
  assert.equal(response.byteLength, Buffer.byteLength(code));
  assert.deepEqual(response.spans, []);
});

test('decimal and hexadecimal entities decode to exact original bytes', () => {
  const code = '<😀>';
  const response = responseFromHtml({protocol: PROTOCOL, id: 2, language: 'json', code},
    '<span class="hljs-string">&#60;&#x1f600;&gt;</span>');
  assert.equal(response.state, 'complete');
  assert.deepEqual(response.spans, [{startByte: 0, endByte: 6, kind: 'string'}]);
});
