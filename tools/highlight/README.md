# Install and run the optional highlighting adapter

Add static highlighting to JSON, Bash, Python, TOML and YAML fences. Cangjie fences use the built-in highlighter and do not need this adapter. Node.js is needed when generating the site, not when reading it.

## Install the adapter

Use Node.js 26.11.1, or another version in the declared `>=26.10.0 <27.0.0` range. Install the lockfile-pinned Highlight.js 11.11.1 in a checkout that matches your cjdoc build:

```sh
cd tools/highlight
npm ci --ignore-scripts
```

If the dependency is already cached, add `--offline`. Keep `adapter.mjs`, the package files, `node_modules/`, and the license and notices together on the machine that generates the site. Do not upload them with the site.

## Enable highlighting in a project

Add or update `[highlight]` in the project's `cjdoc.toml`:

```toml
[highlight]
mode = "static"
languages = ["cangjie", "python"]
on-error = "warn"
```

Set `CJDOC_SOURCE` to the absolute path of the checkout where you installed the adapter. In Bash, from the project root, run:

```sh
cjdoc generate --project . --format html \
  --highlight-adapter "$CJDOC_SOURCE/tools/highlight/adapter.mjs" \
  --highlight-node "$(command -v node)"
```

Open `target/doc/html/index.html` (or the configured output directory) and find a `python` code block with recognized tokens, such as a string or keyword. Those tokens should be colored; copying still copies the original text. If the block stays plain, check the fence language and both executable paths. See the [highlighting guide](../../docs/how-to/highlighting.md) for diagnostics and fallback options.

## Languages and licensing

The adapter accepts five wire names. Highlight.js core and all five grammars are BSD-3-Clause; see the [license](highlight.js-LICENSE) and [notice](NOTICE).

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

## Maintainer notes: Cangjie integration

The Cangjie adapter in [`src/highlight/`](../../src/highlight/) must start this optional worker only when explicitly
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
CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS=2 \
CJDOC_HIGHLIGHT_FIXTURE="$TMPDIR/highlight-public-acceptance/crlf/html" \
  npx playwright test --config highlight.config.mjs
~~~

The native 200% capture uses a controlled Chromium extension's tabs.setZoom(2),
then checks actual CSS viewport/DPR and the exact type destination. Supply the
input identity oracle explicitly: this fixture has two references to its local
`Token` declaration, in the parameter and return positions. Use `0` only for a
fixture with no exact type identity; never derive the expected count from search
metadata.

Verify process lifecycle and protocol framing from the repository root:

~~~sh
python3 -m unittest scripts.test_highlight_adapter -v
~~~
