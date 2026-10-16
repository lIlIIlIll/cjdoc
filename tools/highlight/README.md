# Install and run the optional highlighting adapter

This generation-time worker converts explicitly selected Highlight.js languages
into theme-independent UTF-8 byte ranges. Default Cangjie highlighting does not
need Node.js. Neither ordinary generation nor this worker installs packages,
reads project files, or accesses the network. Do not copy this directory or its
node_modules into the generated website.

## Reproducible installation

Use Node.js **26.11.1** (also recorded in .node-version and exercised by the
worker acceptance harness). The declared engine range is **>=26.10.0 <27.0.0**;
26.10.0 is the previous verified release. Other versions in that range are not
claimed as individually tested.
Highlight.js is pinned to **11.11.1** and the mapping revision is **cjdoc-map-1**.
An update requires reviewing source preservation, scope mapping and licenses,
then updating the lockfile and revision together. No floating latest is used:
exact versions and archive integrity allow reproducible offline provisioning.
The lockfile binds the archive to this SHA-512 checksum:


data-integrity: sha512-Xwwo44whKBVCYoliBQwaPvtd/2tYFkRQtXDWj1nackaV2JPXx3L0+Jvd8/qCJ2p+ML0/XVkJ2q+Mr+UVdpJK5w==

Provision once, outside document generation, from a populated npm cache:

~~~sh
cd tools/highlight
npm ci --ignore-scripts --offline
node --test
~~~

If the archive is not cached, explicitly provision it with npm ci --ignore-scripts
using the registry URL recorded in package-lock.json, then repeat the offline
command. There are no installation lifecycle scripts. Distribute adapter.mjs,
package.json, package-lock.json, .node-version, NOTICE, highlight.js-LICENSE and
the lockfile-installed node_modules together when shipping a ready-to-run worker.
The package needs no other npm dependency. node_modules is not version-controlled.

## Languages and licensing

Only the following modules from the fixed Highlight.js archive are imported and
registered; requests cannot provide modules or paths. All five grammars and core
use **BSD-3-Clause**, reproduced in highlight.js-LICENSE and NOTICE:

| Wire language | Upstream module |
| --- | --- |
| json | highlight.js/lib/languages/json |
| bash | highlight.js/lib/languages/bash |
| python | highlight.js/lib/languages/python |
| toml | highlight.js/lib/languages/ini (upstream TOML/INI grammar) |
| yaml | highlight.js/lib/languages/yaml |

No language autodetection or browser highlighting occurs. Unmapped scopes remain
plain text. Nested scopes are flattened into disjoint ranges, with the innermost
scope controlling the kind; an unmapped inner scope remains plain.

## Wire contract: cjdoc-highlight/1

Launch node tools/highlight/adapter.mjs from the repository root (or pass an
absolute adapter path without invoking a shell). Use UTF-8 JSON Lines on stdin
and stdout, one request and one response per line, in strict serial order.
A final nonempty line at EOF is also processed. Close stdin and wait for exit to
stop the worker. Every response write completes before the next request begins.
Diagnostics are fixed messages on stderr, each at most 160 bytes plus newline;
input code and exception messages are never logged.

Request fields are exactly protocol, id, language, code. Protocol must be
cjdoc-highlight/1. id is a safe integer or a string of at most 128 UTF-8 bytes.
language is one of the five names above; no aliases are accepted here.
code is the original source string, not HTML or a file path.

Response fields:

- protocol and id echo the request; language is the canonical wire name.
- engine is {"id":"highlight.js","revision":"11.11.1/cjdoc-map-1"}.
- state is complete or plain; plain always has an empty spans list and a reason.
- byteLength is the exact UTF-8 source byte length, including when oversized.
- sourceHash is lowercase hexadecimal SHA-256 of those exact UTF-8 bytes.
- spans contains {startByte,endByte,kind} objects, sorted, disjoint, half-open,
  positive-length, and bounded by byteLength. Gaps mean original plain text.
  Kinds are keyword, type, string, number, literal, comment, operator,
  punctuation, function, property, meta. There is no source text or HTML field.

The adapter parses only text and span tags with Highlight.js scope classes,
decodes entities once, and verifies reconstructed text against the original
before assigning byte offsets. Failed reconstruction yields plain/invalid-spans.
Resource limits are 262144 source bytes, 65536 spans, 2097152 input-line bytes,
and 3145728 output-line bytes excluding the newline. No partial spans or
truncated source are returned. Oversized valid code yields plain/resource-limit
with its real length/hash. An oversized wire line is discarded through newline
and yields a null-id/null-language resource-limit response with empty-source
length/hash because its request was never decoded.

Unsupported language yields plain/unsupported-language and exit status 0.
Malformed JSON or UTF-8 yields plain/malformed-json; invalid fields or protocol
yield plain/invalid-request. These protocol-abuse responses use null id/language
and empty-source length/hash, mark exit status 2, and permit subsequent lines to
be handled before shutdown. Oversized wire lines likewise mark exit status 2.
Normal EOF exits 0. I/O failure exits 2 with a bounded static stderr diagnostic.

## Cangjie integration boundary

src/code_highlight_external.cj must start this optional worker only when explicitly
configured. It must never install npm packages or make generation depend on Node
for the built-in Cangjie path. Send canonical allowed languages and original
source with a unique id; bound request size and response reads independently.
Match protocol, id, language, exact engine revision, byteLength, SHA-256 and
state/reason; validate kind membership, span count, sorted nonoverlapping ranges
and UTF-8 character boundaries before consuming any complete response. Render
only slices of the caller's original source and escape those slices normally,
never adapter HTML. Keep plain as whole-block fallback with an explicit reason.
Use a bounded worker timeout, drain bounded stderr without exposing code, and
close/wait or terminate/wait on every shutdown/failure path. Cache keys must bind
engine revision, language and sourceHash. Do not ship worker files with site
assets. The generator reuses one serial worker per generation, including captured
guides. Each request has a five-second deadline; failures allow at most two later
restarts (three starts total). Generation cleanup and thread cancellation kill
the supervised process tree. Only validated non-transient lexical results are
cached in memory; no owner or semantic links enter that cache.

After building cjdoc, exercise the real integration, including reuse, alias
cache hits, wrong-ID recovery, crash/timeout restart limits and tree cleanup:

~~~sh
python3 scripts/highlight_acceptance.py --binary target/release/bin/main --workdir "$TMPDIR/highlight-acceptance"
~~~

The work directory must not already exist. The harness keeps generated sites,
protocol observations and timings there; it does not alter frozen baselines.
It also checks host termination, stderr/stdout limits, an independent adapter ZIP
installed into an isolated offline npm cache, source-ZIP reproduction, full
offline extraction, and byte-identical `generate`/`render` replay with empty PATH.
The five locked grammars must already be available in the host npm cache.

For the public `Future.cancel()` path, build the explicit optional test host with
the same SDK/stdx setup as cjdoc, then pass it to the harness:

~~~sh
(cd tests/fixtures/projects/highlight_host && cjpm build)
python3 scripts/highlight_acceptance.py --binary target/release/bin/main \
  --api-probe tests/fixtures/projects/highlight_host/target/release/bin/main \
  --workdir "$TMPDIR/highlight-public-acceptance"
~~~

`--sdk-receipt <path>` records and verifies the pinned SDK/stdx archive receipt;
only archive names, hashes and target/version facts enter the report, not paths.
The built-in revision is a bounded Lexer-behavior witness plus mapping revision,
not a claim to identify every grammar behavior or the complete SDK build.
`--baseline-binary <path>` additionally measures the same input against a prior
binary. `report.json` records elapsed generation time and IR/HTML/DOM/span counts
for static, off and baseline outputs; these are observations, not speed claims.
For real clipboard/CRLF, CSP/no-JavaScript, themes and layout checks, use the
harness's `crlf/html` output as `CJDOC_HIGHLIGHT_FIXTURE` and run:

~~~sh
cd tests/browser
CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS=0 \
CJDOC_HIGHLIGHT_FIXTURE="$TMPDIR/highlight-public-acceptance/crlf/html" \
  npx playwright test --config highlight.config.mjs
~~~

The native 200% capture uses a controlled Chromium extension's tabs.setZoom(2),
then checks actual CSS viewport/DPR and the exact type destination. Supply the
input identity oracle explicitly: 0 links for this source-only fixture, or 2 for
a public-IR fixture with resolved parameter/return evidence; never derive the
expected count from generated search metadata.

Verify process lifecycle and protocol framing from the repository root:

~~~sh
python3 -m unittest scripts.test_highlight_adapter -v
~~~
