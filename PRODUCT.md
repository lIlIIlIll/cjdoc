# Product

<!-- impeccable:product-schema 1 -->

<!--
This first record uses repository evidence and the user's explicit request.
The primary audience and success framing are working assumptions because no
structured interview tool was available in this session.
-->

## Platform

web

## Stack

delegated: generated static HTML, CSS, and small same-origin JavaScript assets
emitted by the existing pure-Cangjie renderer

## Users

Working assumption: Cangjie library authors and maintainers who need to inspect,
share, and publish API documentation generated from a project source tree.

## Product Purpose

`cjdoc` reads Cangjie source declarations and documentation comments, then
generates deterministic HTML, Markdown, and JSON API documentation. The HTML
surface succeeds when a reader can move from the project overview to a package,
symbol, and source-backed explanation without needing a server or a network.

## Positioning

The generator is pure Cangjie and uses `std.ast` plus lexer input as source
truth, binding comments to a schema-versioned Doc IR before rendering static
artifacts. HTML search works from local files through a generated JavaScript
index, so the published site does not depend on `fetch()` or a hosted runtime.

## Operating Context

Users run `cjdoc generate --format html` or render an existing `docs.json`, then
open the generated `html/index.html` directly or publish the static directory.
The site contains an overview, package pages, symbol pages, local search, and
copied local assets. Chinese and English structural labels are supported.

## Capabilities and Constraints

- Preserve source comments as documentation content and keep renderer input at
  the public Doc IR boundary.
- Keep semantic states such as `resolved`, `partial`, `unavailable`, and
  `ambiguous` explicit; do not turn AST spelling into a false canonical claim.
- Preserve deterministic routes, JSON/search artifacts, audience projection,
  local-file operation, content escaping, CSP compatibility, and responsive
  behavior.
- Unsupported source constructs should produce visible diagnostics or partial
  results rather than crash the complete generation.
- CHIR is not part of the current dependency graph; any future semantic adapter
  enters through the public `SemanticProvider` SPI.

## Evidence on Hand

The repository contains the HTML renderer in `src/render/renderers.cj`, renderer
safety tests in `src/render/renderer_safety_test.cj`, HTML validation scripts in
`scripts/validate_html_site.py` and `scripts/test_validate_html_site.py`, and
fixtures under `tests/fixtures/projects/` and `tests/fixtures/golden-v8/`.
No user-supplied logo, imagery, testimonials, or commercial claims are part of
the product brief; future work must not fabricate them.

## Brand Commitments

The HTML API documentation surface uses a developer-tool aesthetic: dense but
readable, documentation-first rather than marketing-first, with typography and
wayfinding doing most of the work. The requested visual reference set is
Stripe, Mintlify, and Scalar. The site must support both light and dark themes,
plus five selectable visual presets for paper, ocean, forest, terminal, and
violet environments, and use a desktop three-column structure of global header,
documentation content, and an "On this page" outline.

## Product Principles

- Source-backed: every useful detail should lead back to generated API truth.
- Calmly scannable: hierarchy and wayfinding should serve readers navigating
  unfamiliar packages and symbols.
- Local-first: a generated site remains useful when opened as files.
- Fail-closed and honest: safety, incomplete semantics, and diagnostics stay
  visible rather than being smoothed over.

## Accessibility & Inclusion

The generated site should retain semantic headings, landmarks, labels, keyboard
search behavior, visible focus states, readable contrast, and a responsive layout
that remains usable at narrow widths. These are implementation commitments
derived from the existing HTML structure and validation scope.
