---
name: cjdoc API Documentation
description: A quiet, dense reference surface for source-backed Cangjie API documentation.
colors:
  bg: "#ffffff"
  surface: "#f6f7f9"
  surface-2: "#eceef2"
  fg: "#16181d"
  muted: "#565c66"
  border: "#e3e6eb"
  border-strong: "#858c97"
  accent: "#2952c4"
  accent-fg: "#ffffff"
  accent-soft: "#ebf0fc"
  code-bg: "#f5f6f8"
  code-keyword: "#8b2fa8"
  code-type: "#0f6a7d"
  code-string: "#2c6b2f"
  code-number: "#a1440f"
  code-comment: "#5f6670"
  code-function: "#3e4fb8"
  code-operator: "#5a4f66"
  success: "#1d6b3a"
  warning: "#8a5a00"
  danger: "#b42335"
typography:
  body:
    fontFamily: "system-ui, -apple-system, Segoe UI, PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
    fontSize: "16px"
    lineHeight: "1.6"
  page-title:
    fontFamily: "system-ui, -apple-system, Segoe UI, PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
    fontSize: "1.875rem"
    fontWeight: 650
    lineHeight: "1.2"
    letterSpacing: "-.02em"
  section-title:
    fontFamily: "system-ui, -apple-system, Segoe UI, PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
    fontSize: "1.3125rem"
    fontWeight: 650
    lineHeight: "1.3"
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Cascadia Mono, JetBrains Mono, Menlo, Consolas, monospace"
    fontSize: ".875rem"
    lineHeight: "1.55"
  signature:
    fontFamily: "ui-monospace, SFMono-Regular, Cascadia Mono, JetBrains Mono, Menlo, Consolas, monospace"
    fontSize: ".875rem"
    fontWeight: 500
    lineHeight: "1.6"
  label:
    fontFamily: "system-ui, -apple-system, Segoe UI, PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
    fontSize: ".75rem"
    fontWeight: 600
rounded:
  control: "6px"
  dialog: "10px"
  pill: "999px"
spacing:
  1: ".25rem"
  2: ".5rem"
  3: ".75rem"
  4: "1rem"
  5: "1.5rem"
  6: "2.5rem"
components:
  button:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.fg}"
    rounded: "{rounded.control}"
    height: "2rem"
  search-trigger:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.muted}"
    rounded: "{rounded.control}"
    height: "2.125rem"
  tree-link-current:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
  signature-block:
    backgroundColor: "{colors.code-bg}"
    textColor: "{colors.fg}"
    rounded: "{rounded.control}"
    padding: ".75rem 1rem"
  kind-badge:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.muted}"
    rounded: "4px"
    padding: ".05rem .42rem"
  dialog:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.fg}"
    rounded: "{rounded.dialog}"
---

# Design System: cjdoc API Documentation

## Overview

**Creative North Star: "The Reference Desk"**

The generated site is a working reference, not a brochure. A reader arrives with a question about a package, a type or one overload, finds it in the navigation tree or the search dialog, and reads a dense, exact answer: the signature, the contract, the source link. Gray neutrals and one accent keep attention on identifiers and prose; typography and rules carry hierarchy.

**Key characteristics:**

- Neutral gray ramp, one accent per theme, no decorative color.
- System font stacks only; nothing is downloaded or embedded. Monospace is reserved for code, signatures and identifiers.
- Three-column desktop frame: navigation tree, document, on-page outline.
- Progressive enhancement: every page is complete without scripts; search, the lazy tree, filters, copy actions and display settings are enhancements.

Tokens live in `src/render/style_tokens.cj`; the frame in `style_layout.cj`; components in `style_components.cj`. Markup is built by `HtmlWriter` (`src/render/html_writer.cj`) with a `cj-` BEM vocabulary.

## Colors

Restrained strategy: neutrals plus one accent. Every theme remaps the same roles (`--cj-bg`, `--cj-surface`, `--cj-surface-2`, `--cj-fg`, `--cj-muted`, `--cj-border`, `--cj-border-strong`, `--cj-accent`, `--cj-accent-fg`, `--cj-accent-soft`, `--cj-code-bg`, eight `--cj-code-*` syntax roles, `--cj-success`, `--cj-warning`, `--cj-danger`, `--cj-shadow`), so components never branch on a theme name.

- **Accent** marks links, focus, the current navigation entry, pressed options and the active outline entry. `accent-soft` is the quiet field behind the current entry and the selected search hit.
- **Neutrals**: `bg` is the reading plane; `surface` groups tools (search trigger, toolbars, notes); `surface-2` carries hover and kind badges; `border` divides rows, `border-strong` outlines inputs (≥3:1 against its ground).
- **Syntax roles** color highlighted code, linked types (`code-type`) and declaration-kind badges and dots, so a kind reads the same in the tree, the tables and search results.
- **Status**: success/warning/danger appear only in copy feedback, admonitions and risk badges, always with text.

Eight choices: System (follows `prefers-color-scheme`, light by default), Light, Dark, Paper (warm neutrals, rust accent), Ocean (deep blue, cyan), Forest (sage neutrals, green), Terminal (near-black, phosphor green, monospace UI) and Violet (cool neutrals, violet). Every theme meets WCAG AA for each foreground/background pair it uses (text 4.5:1, UI borders 3:1). Print forces black on white.

**The one-accent rule.** A new component gets its emphasis from weight, position or the existing accent — never from a new hue.

## Typography

**UI and prose:** the platform sans stack with CJK fallbacks. **Code:** the platform monospace stack. **Serif** exists only as a reader-selected option. Publishers can override either stack with `--html-font-sans` / `--html-font-mono`; the reader's own font choice wins over both.

- Root size is 100% (16px at default), scaled by the reader's text-size setting (93.75% / 100% / 112.5%). All component sizes are rem-based, so the setting scales the whole page.
- Reading floors: prose 1rem, summaries and member descriptions .9375rem, code blocks and signatures .875rem. Navigation, badges and metadata may go smaller; content never does.
- Page titles 1.875rem (API pages 1.5rem, identifiers in monospace); section titles 1.3125rem with a hairline rule beneath; subsections 1.0625rem and .9375rem.
- Prose measure caps at 72ch. Signatures wrap (`pre-wrap`, break anywhere) and are never truncated; navigation labels may ellipsize, the full name stays in the document.

## Layout

Desktop grid: `17rem | minmax(0, 1fr) | 14rem`, capped at 100rem, under a 3.25rem sticky header. The document column caps at 54rem. The left tree and right outline are independently scrolling sticky columns; when the page has no outline the grid drops to two columns.

- **≤1180px:** the outline column goes away; a native `<details>` "On this page" sits above the document. The tree narrows to 15rem.
- **≤760px:** single column. With scripts the tree becomes an off-canvas drawer (`html[data-cj-drawer="open"]`, backdrop, focus trap, Escape); without scripts it follows the document in normal flow. Search and settings dialogs become full-screen and bottom-sheet respectively. Member filter fields fold behind a toggle; member actions collapse into a menu.

Navigation tree: every package; the current package's types; the current type's members. The server renders a bounded window (12 entries centered on the current one) and a "Full package index" / "All members" link; the script completes the branch from `sidebar-index.js` and lazily builds any other branch on expand. One filter narrows packages, types and members by name and expands the matching ancestors.

## Elevation & Depth

Flat at rest. Rules and tonal surfaces separate rows, signatures and toolbars. Only temporary tools overlap the page and carry `--cj-shadow`: the search and settings dialogs, the language menu, the mobile drawer and the touch member-action menu. Dialog backdrops dim the page.

## Shapes

One control radius (6px) for buttons, inputs, code blocks, signatures and tree rows; 10px for dialogs; pills only for small badges and facet chips. Disclosure chevrons are drawn with CSS borders and rotate with `aria-expanded` / `open`.

## Components

- **Header:** brand (accent square + project name), search trigger with `Ctrl K` hint, optional version pill, language toggle (`cj-lang-toggle`, a `<details>` on the language label), display-settings button.
- **Search dialog:** native `<dialog>`; input as combobox over a listbox of hits (name, kind badge, signature, summary, context). Kind/package selects, tag facets, pagination and the coverage note sit inside. Opens with the trigger, Ctrl/Cmd+K or `/`; Escape closes and restores focus.
- **Display settings dialog:** theme swatches (8), font (System / Serif / Monospace), text size (S / M / L). Stored in `localStorage` (`cjdoc-theme`, `cjdoc-reader`) and applied by `theme-bootstrap.js` before first paint.
- **Tree:** `cj-tree__toggle` + link with a kind dot (`data-kind`) and label; current page uses `aria-current="page"`, containing package/type `cj-tree__link--ancestor`.
- **Package declaration table:** per kind group, rows of name (navigation label, monospace link) | kind badge | one-line summary. No signatures in the table.
- **Declaration header:** title, kind badge, classification badges, quiet "Copy link" action, summary, signature block (`cj-signature`, copyable, linked types underlined in `code-type`), "View source".
- **Members:** grouped by kind with counts; overload families grouped under one title. Each member is a native `<details class="cj-member">` whose summary is the signature line plus a one-line description; the body holds parameters (`cj-params` definition rows), returns, throws, examples and relationships. Row actions (standalone page, source, copy link) are icon buttons revealed on hover/focus, a menu on touch.
- **Admonitions:** bordered aside tinted by level (note uses the accent, warning and danger their status colors) with an icon and title; risk badges repeat the level on collapsed members.
- **Code blocks:** tinted `code-bg`, hairline border, copy button revealed on hover/focus (always visible on touch), copy state in `data-cjdoc-copy-state`.

## Do's and Don'ts

### Do:

- **Do** express state through ARIA first (`aria-current`, `aria-expanded`, `aria-pressed`, `hidden`) and style from it.
- **Do** keep every page complete without scripts; enhancements only add.
- **Do** reuse the shared roles across all eight themes and check AA for any new pair.
- **Do** keep signatures and member contracts complete; wrap, never clip.

### Don't:

- **Don't** add web fonts, CDN assets, inline styles or inline scripts (the CSP forbids them).
- **Don't** add a second accent or per-package colors.
- **Don't** give ordinary rows or prose blocks card elevation; shadows belong to overlays.
- **Don't** render unbounded per-page navigation; anything repeated on every page stays a fixed window.
