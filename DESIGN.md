---
name: cjdoc API Documentation
description: Technical book pages for reading source-backed Cangjie documentation.
colors:
  bg: "#fcfbf8"
  surface: "#fcfbf8"
  surface-raised: "#ffffff"
  surface-subtle: "#f3f5ef"
  code-bg: "#f0f3ed"
  ink: "#24352e"
  muted: "#56665c"
  faint: "#58675e"
  line: "#dfe4dc"
  line-strong: "#c2cdc3"
  accent: "#176a54"
  accent-strong: "#125641"
  accent-soft: "#edf2ea"
  success: "#216b49"
  warning: "#835b15"
  danger: "#af3348"
  code-keyword: "#754197"
  code-type: "#14636d"
  code-comment: "#56665c"
  code-string: "#216b49"
  code-number: "#8c3c2c"
typography:
  reading-title:
    fontFamily: "Noto Serif SC, Noto Serif CJK SC, Source Han Serif SC, Georgia, serif"
    fontSize: "clamp(1.9rem, 3.5vw, 2.65rem)"
    fontWeight: 650
    lineHeight: "1.35"
    letterSpacing: "0"
  api-title:
    fontFamily: "IBM Plex Mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, monospace"
    fontSize: "clamp(2rem, 4vw, 3rem)"
    fontWeight: 730
    lineHeight: "1.2"
    letterSpacing: "-.02em"
  body:
    fontFamily: "Inter, Noto Sans SC, Noto Sans CJK SC, ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "16px"
    lineHeight: "1.8"
  prose:
    fontFamily: "Inter, Noto Sans SC, Noto Sans CJK SC, ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "16px"
    lineHeight: "1.9"
  summary:
    fontFamily: "Inter, Noto Sans SC, Noto Sans CJK SC, ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "15px"
    lineHeight: "1.8"
  code:
    fontFamily: "IBM Plex Mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, monospace"
    fontSize: "14px"
    lineHeight: "1.75"
rounded:
  sm: "5px"
  control: "6px"
  input: "7px"
  panel: "8px"
spacing:
  compact: ".55rem"
  control: ".75rem"
  base: "1rem"
  paragraph: "1em"
  code: "1.4rem"
  section: "2.75rem"
components:
  button-outline:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.muted}"
    rounded: "{rounded.sm}"
    padding: ".25rem .55rem"
  search:
    backgroundColor: "{colors.surface-subtle}"
    textColor: "{colors.ink}"
    rounded: "{rounded.input}"
    height: "40px"
  navigation-current:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent-strong}"
    rounded: "{rounded.control}"
  code-block:
    backgroundColor: "{colors.code-bg}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    padding: "1.1rem 3.3rem 1.1rem 1rem"
  badge:
    backgroundColor: "{colors.surface-subtle}"
    textColor: "{colors.muted}"
    rounded: "{rounded.sm}"
    padding: ".16rem .42rem"
---

# Design System: cjdoc API Documentation

## Overview

**Creative North Star: "技术书页 / The Technical Book"**

cjdoc presents source-backed documentation as a technical book: warm paper, deep ink, teal links, continuous explanation, and light divisions. Readers can follow an author's introduction, read a usable example, and continue into a guide or a complete API contract without the interface competing for attention.

Reading and reference share one visual system. Narrative pages use a controlled measure and serif titles; API pages keep identifiers, signatures, and complete member contracts easy to inspect. Structure, typography, and spacing carry hierarchy. Search, filters, themes, and generation evidence remain available as supporting tools.

**Key Characteristics:**

- Warm white paper with deep green ink and restrained teal wayfinding.
- Continuous prose, complete reference material, and lightweight separators.
- Distinct reading, summary, and code roles with local font fallbacks.
- Static routes, native disclosures, and progressively enhanced navigation.

Frontmatter records the default light tokens. The implementation lives in `src/render/html_styles.cj` and `src/render/html_component_styles.cj`; page and interaction behavior lives in `html_pages.cj`, `html_layout.cj`, and `html_scripts.cj` in the same directory. Theme overrides preserve the semantic roles.

## Colors

Paper neutrals, green-black ink, and teal wayfinding support reading and meaning.

### Primary

- **Teal:** `accent` identifies links, focus, active navigation, and actions. `accent-strong` supports linked type names and current entries; `accent-soft` provides quiet selection and hover surfaces.

### Neutral

- **Warm Paper:** `bg` and `surface` keep page and rails continuous. `surface-raised` distinguishes temporary panels; `surface-subtle` groups controls and supporting material.
- **Deep Ink:** `ink` carries primary text; `muted` and `faint` support descriptions, metadata, and navigation labels.
- **Light Divisions:** `line` separates sections and rows; `line-strong` defines inputs and code boundaries. `code-bg` gives code a pale green paper surface.

### Semantic and syntax roles

Success, warning, and danger retain their meanings across themes. Resolved, partial, unavailable, and ambiguous remain explicit in text; relationship-state labels may use a quieter neutral treatment. Keywords, types, comments, strings, and numbers have distinct syntax roles. Literals reuse numbers, operators and metadata reuse keywords, and functions and properties reuse types.

Eight choices are implemented: System, Light, Dark, Paper, Ocean, Forest, Terminal, and Violet. System follows device appearance; Light uses the frontmatter palette. Paper adds a warmer outer page, Ocean uses deep blue and cyan, Forest uses sage and green, Terminal uses dark phosphor green and a monospace UI, and Violet uses pale cool neutrals and violet. Dark supplies the blue-accented dark palette. Presets remap shared roles rather than creating per-page identities.

**The Semantic Color Rule.** A theme changes the palette while preserving link, selection, focus, syntax, and diagnostic roles.

## Typography

**Reading Title Font:** Noto Serif SC with CJK serif, Georgia, and generic serif fallbacks.
**Body Font:** Inter with Noto Sans CJK and platform sans-serif fallbacks.
**Code Font:** IBM Plex Mono with platform monospace fallbacks.

The stacks remain usable without font downloads. Serif titles establish a book-like entry to home and guide pages; monospace preserves API names and declarations. Prose uses the UI sans-serif stack for Chinese and English reading.

### Hierarchy

- **Reading title:** the responsive `reading-title` role introduces home and guide pages.
- **API title:** the responsive `api-title` role displays symbol identifiers; prose page headings use the UI heading stack.
- **Body and prose:** `body` supports the shell and document; `prose` opens the line height for authored narrative. Guide measure is capped at 72ch.
- **Summary:** `summary` carries descriptions, parameters, returns, and behavior. Compact member summaries use line height 1.75.
- **Code:** `code` carries signatures and examples. Member signatures use line height 1.7; narrative code and top-level API signatures use 1.75.
- **Labels:** compact metadata and reading aids use a smaller UI size; API identifiers and counts keep monospace where appropriate.

**The Full Text Rule.** Member signatures and descriptions wrap without line clamps or ellipses. Compact navigation and search-result labels may truncate; the contract remains readable in full.

## Layout

The desktop shell has a sticky global header and a three-column document grid capped at 1600px: navigation (248px), a flexible document, and a short section outline (220px). The document caps at 64rem, home content at 60rem, and guides at 72ch. Main horizontal padding grows from 1.25rem to 4.5rem. Paragraph, code, and section spacing use the frontmatter rhythm.

At 1180px and below, the outline moves into a native disclosure above the document and the left rail narrows to 220px. At 760px and below, navigation becomes a drawer, document padding is 1rem horizontally, and the header retains navigation, project identity, a search trigger, language, and theme controls. Global search opens on request. Enhanced member browsers initially fold filter fields behind a separate control while expand/collapse actions remain available; without enhancement the fields remain visible.

Left navigation describes the project, packages, and types; the right outline locates short document sections. Author content leads home and guide pages. Package overviews and indexes lead into API declarations. Generation, source, and binding details use native disclosures where secondary to reading.

**The Reading Order Rule.** Supporting controls and evidence must not displace the author's explanation or remove complete API content. Use disclosure to manage density, retaining a direct route to the full material.

## Elevation & Depth

The document is flat at rest. Tonal surfaces and thin rules distinguish code, navigation, overload groups, and metadata. Shadows belong to temporary search/filter panels, theme selection, member action menus, and mobile navigation. Each theme supplies its shared shadow; the default is a diffuse low shadow (`0 12px 32px rgba(23, 31, 48, .08)`). Ordinary reference rows and narrative examples do not gain floating-card depth.

**The Paper Surface Rule.** Keep the reading plane continuous; reserve raised surfaces for tools that temporarily overlap it.

## Shapes

Controls and inline tokens use modest rounded corners: the frontmatter's small, control, input, and panel steps. Sections and member rows primarily use straight lightweight rules. Overload groups use a subtle rectangular field; narrative examples sit directly in the document. Mobile theme selection adopts a bottom sheet; that silhouette is a responsive interaction treatment, not a general container style.

## Components

### Buttons

Quiet outlined actions support copying, source navigation, filtering, and member expansion. Hover strengthens the border or uses a subtle/accent-soft surface. Keyboard focus uses a visible accent outline (2px) with a small offset. Copy confirmation uses success color and text or an accessible state. Keep labels concrete.

### Inputs / Fields

Global search uses a soft surface, stronger border, input radius, and the frontmatter height; the mobile expanded field is 42px high. Focus adds an accent border and soft ring. Package and member fields are compact supporting controls. Results form a bounded scrollable panel with keyboard selection and pagination; the coverage note remains available. Shortcut hints supplement real labels.

### Navigation

Current entries use the accent-soft field and strong accent text. Package trees retain package/type hierarchy; native disclosures expose branches. The section outline uses a slim active rule. Mobile navigation is a closeable drawer with a backdrop; the in-document outline remains a native disclosure.

### Tags and Containers

Badges carry compact metadata and explicit state with a thin border and soft surface. Diagnostics retain textual status. Module records use a light border and panel radius where grouping is needed. Reading paths use ordinary links and a quiet section rule rather than promotional cards.

### Code and Member Contracts

Code blocks use tinted paper, stronger borders, and a copy control. Narrative code scrolls horizontally on narrow screens; API summaries wrap. Type references remain recognizable as links within declarations.

Members use native `details` with a complete signature and summary. Expanded bodies retain parameters, returns, exceptions, conditions, and examples. Hover and keyboard focus reveal sibling member actions on desktop; touch layouts offer an action disclosure with labeled menu items. Native actions remain reachable without JavaScript. Overloads remain grouped and individually readable.

### Theme Selection

A labeled palette control names the active choice on desktop and opens a grouped list with a checked selection. On mobile it opens a bottom sheet with close action, backdrop, focus management, and Escape support. Motion is limited to brief state transitions; reduced-motion preference removes smooth scrolling and nearly eliminates transitions.

## Do's and Don'ts

### Do:

- **Do** use shared semantic tokens across all eight theme choices.
- **Do** preserve the 16px body, 15px summary, and 14px code roles for their established purposes.
- **Do** keep prose continuous and member contracts complete, with lightweight separators.
- **Do** retain visible focus, native disclosures, honest semantic states, and static source-backed links.
- **Do** let mobile search, filters, navigation, and themes reveal tools progressively.

### Don't:

- **Don't** clip API signatures, explanations, or behavioral conditions to make rows smaller.
- **Don't** make every paragraph, example, or member a raised card.
- **Don't** give individual packages independent accent palettes or decorative status colors.
- **Don't** invent source destinations or promote incomplete semantic evidence into a definite claim.
- **Don't** replace reading flow with repeated indexes, generation metadata, or decorative statistics.
