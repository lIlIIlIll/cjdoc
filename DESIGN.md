---
name: cjdoc API Documentation
description: Dense, readable static API reference pages for Cangjie libraries.
colors:
  ink-light: "#171b24"
  muted-light: "#626b7b"
  bg-light: "#fbfcfe"
  surface-light: "#ffffff"
  line-light: "#e3e7ee"
  accent-light: "#2f6feb"
  ink-dark: "#f1f5fb"
  muted-dark: "#9aa5b5"
  bg-dark: "#0b0e13"
  surface-dark: "#10141b"
  line-dark: "#242c38"
  accent-dark: "#80a8ff"
typography:
  display:
    fontFamily: "Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "clamp(2rem, 4vw, 3rem)"
    fontWeight: 730
    lineHeight: "1.2"
    letterSpacing: "-.02em"
  body:
    fontFamily: "Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "15px"
    lineHeight: "1.65"
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, monospace"
    fontSize: ".8rem"
    fontWeight: 600
rounded:
  sm: "5px"
  md: "7px"
  lg: "8px"
spacing:
  sm: ".55rem"
  md: "1rem"
  lg: "2.2rem"
components:
  search:
    backgroundColor: "{colors.surface-light}"
    textColor: "{colors.ink-light}"
    rounded: "{rounded.md}"
    height: "40px"
  code-block:
    backgroundColor: "{colors.bg-light}"
    textColor: "{colors.ink-light}"
    rounded: "{rounded.lg}"
    padding: "1.1rem 3.3rem 1.1rem 1rem"
---

## Overview

### North Star

The Working Reference: a maintainer's workbench for finding a symbol, checking its contract, and copying a usable signature with minimal visual interruption.

### Product Character

cjdoc is documentation-first. The interface is dense enough for API reference work, but uses generous line height, clear hierarchy, and restrained borders to keep long pages readable. The visual language is a quiet developer tool: cool neutral surfaces, one blue action color, monospace for identifiers, and no gradients or decorative hero treatment.

The layout has three persistent jobs on desktop: navigation on the left, the Doc IR rendered in the center, and page context on the right. On narrower screens the context rail disappears first, then the navigation becomes a compact section, while the document remains the primary surface.

## Colors

Light mode uses `#fbfcfe` as the page background and `#ffffff` for structural surfaces. `#171b24` is primary ink, `#626b7b` supports secondary copy, and `#e3e7ee` establishes quiet boundaries. `#2f6feb` is reserved for links, active navigation, focus, and explicit actions.

Dark mode swaps to `#0b0e13`, `#10141b`, and `#151b24` while keeping the same hierarchy. The accent becomes `#80a8ff` for contrast. State colors are semantic: green for resolved, amber for partial, and red for unavailable or ambiguous.

Do not introduce additional brand colors for individual modules. Syntax colors are limited to keywords, types, and comments inside code blocks.

## Typography

Use the system UI stack for prose and headings so generated pages remain usable without a font download. Body text is `15px` at `1.65` line height. Display headings are responsive from `2rem` to `3rem`, weight `730`, with a small negative tracking value to keep API names compact.

Use the monospace stack for package names, module paths, symbols, signatures, schema versions, counts, and badges. Typography should carry hierarchy before color or decoration does.

## Layout

The desktop shell is a sticky top bar followed by a three-column grid: a `248px` navigation rail, a flexible document column capped at `56rem`, and a `220px` table-of-contents rail. The main document uses responsive horizontal padding between `1.25rem` and `4.5rem`.

The header contains the cjdoc mark, global search, optional package/kind filters, version, source affordance, a theme preset picker, and the light/dark toggle. The source affordance is visibly disabled when the Doc IR does not include a repository URL; it must not invent an external destination.

At `1180px`, the table of contents yields to the document. At `760px`, the header wraps, navigation becomes compact, and record grids collapse to one column. Focus rings remain visible in every layout.

## Elevation & Depth

Depth is tonal and structural rather than ornamental. Cards and controls use `surface` versus `surface-subtle`, one-pixel borders, and small radii. Search results may use the shared shadow `0 12px 32px rgba(23, 31, 48, .08)` in light mode and `0 18px 42px rgba(0, 0, 0, .26)` in dark mode. Avoid glass, blur, gradients, and floating marketing panels.

## Shapes

Use `5px` for compact inline controls and badges, `7px` for inputs and navigation controls, and `8px` for records and code blocks. Corners are softened enough to distinguish groups without making the reference feel like a consumer dashboard. Dividers are straight and quiet; the active table-of-contents marker is a two-pixel vertical rule.

## Components

### Buttons

The theme picker offers System, Light, Dark, Paper, Ocean, Forest, Terminal, and Violet presets. Paper is warm editorial, Ocean is deep blue and cyan, Forest is calm sage, Terminal is phosphor green and monospace, and Violet is cool indigo. Each preset remaps the same semantic tokens, preserving resolved/partial/unavailable meanings and readable focus states. The adjacent theme toggle remains a compact icon button with a visible focus ring, an accessible label, and a sun/moon state. Do not add a primary CTA style to reference pages.

### Cards / Containers

Module records, declaration summaries, diagnostics, and empty states are low-emphasis containers. They are defined by borders, spacing, and semantic headings rather than strong shadows. A code block is the highest-contrast container because it carries executable reference material.

### Inputs / Fields

Search is the main input. It is `40px` high, keyboard accessible, and paired with optional package and kind filters. Search results are rendered as a bounded, navigable list below the field. The keyboard hint is supplementary and must not replace a real label.

### Navigation

The left rail groups Getting Started, API Reference, and package/module links. The current section uses the accent-soft surface and accent text. The right rail is generated from `h2`/`h3` headings and marks the section currently in view.

### Signature Component

Signatures are rendered as labeled code blocks with a copy control. The control copies text content only and reports its state without injecting markup. Inline code, declaration metadata, relationships, parameters, returns, examples, and diagnostics retain the same token hierarchy across light and dark themes.

## Do's and Don'ts

- Do keep the Doc IR and source comments authoritative; the renderer only presents them.
- Do preserve explicit `unavailable`, `partial`, and `ambiguous` states in the UI.
- Do keep links, focus states, and code readable in both themes.
- Do use stable semantic headings so the table of contents remains useful.
- Don't turn an API page into a marketing landing page.
- Don't use gradients, glass effects, oversized illustrations, or decorative statistics.
- Don't create repository links when the generated document has no repository URL.
- Don't place user documentation into `innerHTML`; escape or construct DOM content safely.
