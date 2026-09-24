# Showcase contract and native-route foundation — issue #50

## Status and scope

This is a **partial, additive implementation**, not completion of issue #50.
The source inspection baseline is
`f112524764732c70d23cedb37d171df677f51089` (2026-09-23).
PR #51, implementing #49, is present in that baseline. Initial preparation
used a recovered additive patch rather than a complete repository checkout.

The new Python package provides a fail-closed foundation for S-04 and part of
S-06. It has not been connected to `scripts/build_showcase.py`, the public
homepage, or `.github/workflows/pages.yml`. It must not be described as a working
replacement for the current showcase or as complete publication acceptance.

Implemented in this patch:

- A versioned author plan and resolved manifest with separate implementation and
  demonstration states, source input SHA-256 digests, a full source revision,
  explicit versions/locales, user instructions, and browser scenario IDs.
- Unique semantic-selector resolution through emitted
  `cjdoc.navigation-index/1` records. The resolver neither builds SymbolId slugs
  nor guesses missing targets. It checks project/version/audience, HTML language,
  route existence, and member anchors. Exact `headerSpelling` selectors join
  Doc IR v10 declarations to navigation by native SymbolId. Inline routes are
  projected from the owner page's actual member permalinks and IDs, not a copy
  of the generator's slug/hash algorithm.
- A homepage card renderer consuming the same resolved manifest as validation.
  Uncovered/blocked entries remain visible. A partial implementation's limitations
  remain visible even when a particular scenario is demonstrable.
- Static final-tree checks for HTML `href`/`src`, anchors, duplicate IDs,
  nonportable paths, symlinks, case collisions, and the test domain
  `docs.example.test`. No external website requests are made.
- A browser evidence identity/coverage checker, binding a supplied report to the
  full final-tree inventory, manifest, revision, required HTTP/file scenarios,
  entry/target, action counts, and attachment hashes. Missing, skipped, stale,
  wrong-version, duplicate, or unexpected results fail.
- A regression check against a separately reviewed previous manifest. Removing
  an available feature or its declared locale/version/scenario coverage fails.

Additional implementation in this continuation:

- Deterministic offline ZIP creation and safe extraction. Extraction checks the
  exact published payload inventory and every file's SHA-256; missing, stale,
  additional, duplicate, case-colliding, encrypted, special-file, symlink and
  path-traversal entries are rejected.
- A Playwright runner for native member and name-search scenarios. It starts at
  the resolved homepage card, checks the exact landing route and native member
  expansion, exercises filtering and simultaneous overloads where present, and
  records document navigation count, viewport overflow checks and screenshots.
  Root HTTP, project-subpath HTTP, and extracted `file://` transports have
  explicit scenario IDs. Unknown or mismatched scenarios fail rather than skip.
- Browser failures do not create a passing `results.json`. Evidence destinations
  must be new and outside the site. Screenshots use full case-tuple hashes to
  avoid delimiter collisions. The final tree must not change during execution.

Not implemented or validated here:

- The dedicated licensed example library, two versions, Chinese/English native
  generation, independent dependency documentation, doctest execution, actual
  version composition, API diff generation, report rendering,
  or source downloads. The archive mechanism exists, but its download UI and
  inclusion in the actual showcase build are not integrated.
- #49's renderer is reused from main, not reimplemented by this patch. Neither
  its existing CI nor this patch's Python tests establish final-showcase acceptance.
- Browser scenarios for guides, returned types, dependency navigation, real
  doctest/diff/quality results, version switching, back/forward, clipboard and
  download interactions; explicit theme-toggle testing and performance budgets.
- Passing final Pages browser screenshots, source reproducibility with the
  current native CLI, or remote CI on this patch.
- S-01–S-06 end-to-end integration. This patch does **not** justify closing #50.

## Local contract tests

Python 3.10+ and the standard library are sufficient:

```sh
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests/showcase_contract -v
```

The test suite creates synthetic navigation and HTML data. Its fake evidence
attachments and runner labels are explicitly synthetic. Passing these tests
proves the Python checks' tested behavior; it does not prove any cjdoc-generated
page, SDK compile/run result, browser interaction, or GitHub Actions execution.

## Author plan

The plan's schema identifier is `cjdoc.showcase-plan/1`. The normative strict
validator is `validate_plan()` in `scripts/showcase_contract/contract.py`.
Unknown fields, duplicate feature/target IDs, guessed `href`/`symbolId` selectors,
invalid state combinations, and missing required evidence scenarios are errors.

Each feature has:

| Field | Meaning |
| --- | --- |
| `id`, `title` | Stable feature identifier and human-readable title. |
| `implementation` | `complete`, `partial`, or `not-implemented`. |
| `demonstration` | `available`, `uncovered`, or `blocked`. |
| `reason` | Required for partial/unimplemented or uncovered/blocked features. |
| `trackingIssues` | Positive repository issue numbers; required when blocked. |
| `inputs` | Canonical repository-relative regular **file** paths. Required for available features. List all relevant source/configuration inputs. |
| `targets` | Explicit locale/version target variants and scenario declarations. Required for available features. |

A target contains `id`, `kind`, `locale`, `version`, `instructions`, and a nonempty
`scenarios` array. A scenario contains `id` and `mode` (`http` or `file`). Separate
scenario IDs should identify the actual desktop/mobile, light/dark, keyboard,
back/forward, or other product-specific behavior the browser suite exercises.

For a `navigation` target, also supply:

- `index`: the final site-relative generated navigation-index path;
- `project`: the exact emitted `{name, audience, version}` object;
- `match`: `{kind, title}` with `packageName` and/or `moduleId` for symbols.

`locale` must match the emitted page's exact HTML `lang` tag; do not silently
normalize `zh` to `zh-CN`. `version` must match the index's project version. A
navigation query must identify exactly one record. Ambiguous overload titles
without an exact Doc IR selector fail; the resolver
does not invent semantic type equivalence or a second symbol identity system.

To disambiguate an overload, add `docIr` with the final site-relative Doc IR JSON
path and `signature` equal to the **full exact** emitted `headerSpelling`. To land
on expanded type-page details instead of a standalone member page, also set
`placement: "member"`. The declaration needs a native `ownerId`, and that owner
page must contain exactly one member permalink pointing to the selected native
member page. Missing/ambiguous joins, owners and anchors fail. A changed source
spelling must be reviewed, not silently matched by a guessed parameter type.
`semanticState` is preserved as emitted; matching an AST signature does not turn
`partial` semantic information into authoritative type analysis.

For an `artifact` target, supply `path`. JSON reports may additionally specify
`jsonChecks`, mapping JSON pointers to exact expected emitted values. When
present, `/schemaVersion` is mandatory. These are identity checks, not a second
coverage calculator, diff engine, or doctest runner. Schema/version checks alone
never establish freshness or successful execution; the generated report must
also be tied to inputs and exercised by the declared trusted browser scenario.

## Integration sequence (not wired into the current build yet)

1. Generate the actual example/dependency/version/report trees with the native
   CLI and existing engines. Do not copy the negative/security test fixture into
   the public default demo. Do not overwrite arbitrary `cjdoc.toml` tables.
2. Prepare an explicit homepage template containing exactly one marker:
   `<!-- CJDOC_SHOWCASE_FEATURES -->`. The rendered card fragment belongs in the
   site-root homepage; its links are site-root-relative, not browser-root-relative.
3. Resolve the real author plan and render the homepage:

```sh
PYTHONPATH=scripts python -m showcase_contract resolve \
  --plan path/to/reviewed-showcase-plan.json \
  --site target/showcase-site \
  --repository . \
  --revision "$(git rev-parse HEAD)" \
  --template path/to/showcase-home-template.html
```

This writes `showcase-features.json` and `index.html`. It does not certify them.
An `available` state at this stage is a **publication requirement**, not a
completed test result. The printed status explicitly says browser evidence is
still required. A production release must not upload these files before the
verification step succeeds.

4. Finish all other output mutations, including reports and metadata. Create
   the archive **last**, before fingerprinting and testing:

```sh
PYTHONPATH=scripts python -m showcase_contract archive --site target/showcase-site
```

The archive is `downloads/showcase-offline.zip`; it excludes only itself to
avoid recursive packaging. All other downloads and assets are included. The
integrating homepage must handle its own archive-download link appropriately
when viewed offline; the module does not rewrite that UI. Rebuild the archive
if any payload changes. Then obtain a final-tree fingerprint:

```sh
PYTHONPATH=scripts python -m showcase_contract fingerprint --site target/showcase-site
```

5. Install the optional, pinned browser dependency and Chromium in an environment
   where browser testing is permitted, then run the implemented scenarios:

```sh
python -m pip install -r scripts/requirements-showcase.txt
python -m playwright install chromium
PYTHONPATH=scripts python -m showcase_contract.browser \
  --site target/showcase-site \
  --evidence target/showcase-evidence
```

The evidence directory must **not** exist already. A local Chromium binary may
be selected with `--chromium`; this does not bypass browser administrator policy.
The runner extracts the actual archive into a fresh temporary directory for
`file://` cases. Store the report and screenshot attachments in a separate
sibling tree, such as `target/showcase-evidence`.
   They must not be ancestors/descendants of the final site: otherwise a report
   containing the site digest would be self-referential.
6. Validate the final tree and the browser report immediately before upload:

```sh
PYTHONPATH=scripts python -m showcase_contract verify \
  --site target/showcase-site \
  --evidence target/showcase-evidence/results.json
```

`--previous path/to/reviewed-manifest.json` is supported by `resolve` and `verify`.
CI must provide the reviewed baseline for regression enforcement; omitting it
cannot detect feature deletion relative to an earlier release. There is no
automatic rebaseline or `allow-regression` switch.

## Evidence boundary

The evidence schema is `cjdoc.showcase-evidence/1`; the normative strict checker
is `validate_evidence()` in `scripts/showcase_contract/evidence.py`.

Top-level fields are `schemaVersion`, `revision`, `manifestSha256`, `siteSha256`,
`runner`, and `results`. `manifestSha256` hashes `canonical_json(manifest)`;
`siteSha256` is the `fingerprint` output. `runner` records name/version and
browser/browserVersion, not a hardcoded claim that Chromium ran.

Each result must match a feature/target/scenario/mode/locale/version tuple and
contain `status: "passed"`, `entry: "index.html"`, the exact resolved `href`,
nonnegative `activations`/`documentNavigations` (at least one activation), a
nonempty `assertions` array, and a `screenshot` path/SHA-256 pair. Assertions must
be emitted by actual tests, not written manually by a build script.

This checker verifies supplied evidence consistency. **It cannot authenticate
whether a screenshot or assertion really came from a browser, or establish the
adequacy of a test from its text.** Only the trusted, reviewed browser runner may
write that input. The fixture suite deliberately demonstrates that distinction.
Scenario-specific activation/navigation budgets and behavioral assertions belong
in those actual tests; the gate does not invent unmeasured thresholds.

Static URL checking covers `href` and `src` plus HTML anchors; it does not inspect
CSS `url()`, `srcset`, runtime-generated URLs, JavaScript errors, focus, layout,
clipboard behavior, or actual offline interactivity. Those remain browser tasks.

The tree must be quiescent during resolution, testing, fingerprinting, and
verification. Construct a new `Site` after output mutation: it is an inventory
snapshot, not a filesystem watcher. The build pipeline must use an isolated
staging directory and must not mutate the site after the final gate.


## Registered browser scope

| ID | Actual behavior selected | Transport / viewport |
| --- | --- | --- |
| `member-desktop-light-root` | Native member details/filter and a second overload when present | HTTP `/`, 1280×900, light preference |
| `member-desktop-dark-subpath` | Same member behavior | HTTP `/cjdoc-preview/`, 1280×900, dark preference |
| `member-mobile-dark-subpath` | Same member behavior | HTTP `/cjdoc-preview/`, 390×844, dark preference |
| `member-offline` | Same member behavior | Extracted `file://`, 1280×900 |
| `search-root` | Ctrl+K, `name:` query, unmatched query clearing stale links | HTTP `/`, 1280×900 |
| `search-subpath` | Same search behavior | HTTP `/cjdoc-preview/`, 1280×900 |
| `search-offline` | Same search behavior | Extracted `file://`, 1280×900 |

The manifest must explicitly request the relevant variants. The registry does
not automatically add missing coverage or certify the entire S-06 matrix.
Current tests do not measure every interaction: `activations` counts the
homepage activation and explicitly counted summary clicks, not keyboard events
or filter text edits. Viewport and OS color-scheme preference coverage is not
proof of all theme toggles or accessibility behavior.

## Observed validation in the continuation

108 Python unit tests passed. These include archive extraction and runner
control flow, not successful native builds or browser interactions.
A separate read-only probe used the real Pages artifact from main revision
`f112524764732c70d23cedb37d171df677f51089`: both `ReferenceBox.convert`
overloads resolve to distinct native anchors on the same owner page; an archive
round trip preserves all 782 published payload files and produces deterministic
ZIP bytes. This is baseline-artifact compatibility evidence, not a generated
showcase replacement.

Whole-site static validation does **not** yet pass: the baseline 404 page uses
three `/cjdoc/…` root-relative links that the portable-URL policy rejects.
Those links are not thereby proven broken on GitHub Pages; a controlled
404/deployment-base policy still needs to be designed and tested before this
gate is wired into publication. The check was not weakened just to accept them.

Both actual HTTP and `file://` browser navigation attempts failed with
`net::ERR_BLOCKED_BY_ADMINISTRATOR` in the available environment. No passing
browser evidence was produced during preparation. The native SDK build/doctest
runs were unavailable, and no remote CI was run during that preparation.
