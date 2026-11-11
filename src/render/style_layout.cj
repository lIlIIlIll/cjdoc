package cjdoc.render

// Page frame: three columns (navigation, document, outline) that collapse to
// two at 1180px and to one at 760px. The off-canvas drawer only exists when
// theme-bootstrap.js marked the document with data-cj-js; without scripts the
// navigation stays in normal flow after the document so every link remains
// reachable.
internal let HTML_LAYOUT_STYLE = """
*, *::before, *::after { box-sizing: border-box; }
html {
  font-size: var(--cj-font-size);
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
  scroll-padding-top: calc(var(--cj-header-height) + var(--cj-space-4));
  background: var(--cj-bg);
}
body {
  margin: 0;
  min-height: 100vh;
  background: var(--cj-bg);
  color: var(--cj-fg);
  font: 400 1rem/1.6 var(--cj-font-sans);
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
  overflow-wrap: break-word;
}
::selection { background: color-mix(in srgb, var(--cj-accent) 24%, transparent); color: var(--cj-fg); }
a { color: var(--cj-accent); text-decoration: none; text-underline-offset: .18em; text-decoration-thickness: 1px; }
a:hover { text-decoration: underline; }
:focus-visible { outline: 2px solid var(--cj-accent); outline-offset: 2px; border-radius: 3px; }
code, kbd, pre, samp { font-family: var(--cj-font-mono); }
img, svg { max-width: 100%; }
img { height: auto; }
button, input, select { font: inherit; color: inherit; }
input, select { caret-color: var(--cj-accent); }
table { font-variant-numeric: tabular-nums; }
[hidden] { display: none !important; }
.cj-sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0 0 0 0);
  clip-path: inset(50%);
  white-space: nowrap;
  border: 0;
}
.cj-skip-link {
  position: absolute;
  z-index: 100;
  top: -4rem;
  left: var(--cj-space-3);
  padding: var(--cj-space-2) var(--cj-space-3);
  border-radius: var(--cj-radius);
  background: var(--cj-accent);
  color: var(--cj-accent-fg);
  font-weight: 600;
}
.cj-skip-link:focus { top: var(--cj-space-2); text-decoration: none; }

.cj-header {
  position: sticky;
  top: 0;
  z-index: 30;
  height: var(--cj-header-height);
  border-bottom: 1px solid var(--cj-border);
  background: var(--cj-bg);
}
.cj-layout {
  display: grid;
  grid-template-columns: 17rem minmax(0, 1fr) 14rem;
  max-width: 100rem;
  margin: 0 auto;
  min-height: calc(100vh - var(--cj-header-height));
}
.cj-layout:has(> .cj-toc[hidden]) { grid-template-columns: 17rem minmax(0, 1fr); }
.cj-sidebar {
  position: sticky;
  top: var(--cj-header-height);
  align-self: start;
  height: calc(100vh - var(--cj-header-height));
  overflow-y: auto;
  overscroll-behavior: contain;
  padding: var(--cj-space-4) var(--cj-space-3) var(--cj-space-6);
  border-right: 1px solid var(--cj-border);
  scrollbar-width: thin;
  scrollbar-color: var(--cj-border-strong) transparent;
}
.cj-main { min-width: 0; padding: var(--cj-space-5) clamp(var(--cj-space-4), 3.5vw, 3.5rem) var(--cj-space-6); }
.cj-main:focus { outline: none; }
.cj-content { max-width: 54rem; margin: 0 auto; }
.cj-toc {
  position: sticky;
  top: var(--cj-header-height);
  align-self: start;
  max-height: calc(100vh - var(--cj-header-height));
  overflow-y: auto;
  padding: var(--cj-space-5) var(--cj-space-4) var(--cj-space-6) 0;
  scrollbar-width: thin;
  scrollbar-color: var(--cj-border-strong) transparent;
}
.cj-toc-mobile { display: none; }
.cj-drawer-backdrop { display: none; }
.cj-header__inner > .cj-header__menu, .cj-sidebar__head { display: none; }
/* Filters and bulk member actions only work once the reading script runs. */
html:not([data-cj-js]) :is(.cj-sidebar__filter, .cj-members__toolbar) { display: none; }
.cj-footer { border-top: 1px solid var(--cj-border); color: var(--cj-muted); font-size: .75rem; }
.cj-footer__inner {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: var(--cj-space-2) var(--cj-space-4);
  max-width: 100rem;
  margin: 0 auto;
  padding: var(--cj-space-4) var(--cj-space-5);
}
.cj-footer__mark { color: var(--cj-fg); font-weight: 650; }

@media (max-width: 1180px) {
  .cj-layout, .cj-layout:has(> .cj-toc[hidden]) { grid-template-columns: 15rem minmax(0, 1fr); }
  .cj-toc { display: none; }
  .cj-toc-mobile { display: block; }
}
@media (max-width: 760px) {
  .cj-layout, .cj-layout:has(> .cj-toc[hidden]) { display: flex; flex-direction: column; }
  .cj-main { padding: var(--cj-space-4) var(--cj-space-4) var(--cj-space-6); }
  html:not([data-cj-js]) .cj-sidebar {
    order: 2;
    position: static;
    align-self: stretch;
    min-width: 0;
    height: auto;
    border-right: 0;
    border-top: 1px solid var(--cj-border);
  }
  html[data-cj-js] .cj-header__menu { display: inline-flex; }
  html[data-cj-js] .cj-sidebar__head { display: flex; justify-content: flex-end; margin: calc(-1 * var(--cj-space-2)) 0 var(--cj-space-2); }
  html[data-cj-js] .cj-sidebar {
    position: fixed;
    z-index: 50;
    top: 0;
    bottom: 0;
    left: 0;
    width: min(20rem, 88vw);
    height: auto;
    /* Absolutely positioned boxes honour align-self; start would shrink-wrap. */
    align-self: stretch;
    border-right: 1px solid var(--cj-border);
    background: var(--cj-bg);
    box-shadow: var(--cj-shadow);
    transform: translateX(-102%);
    visibility: hidden;
    transition: transform .22s cubic-bezier(.16, 1, .3, 1), visibility 0s linear .22s;
  }
  html[data-cj-drawer="open"] .cj-sidebar {
    transform: none;
    visibility: visible;
    transition: transform .22s cubic-bezier(.16, 1, .3, 1);
  }
  html[data-cj-drawer="open"] { overflow: hidden; }
  .cj-drawer-backdrop {
    display: block;
    position: fixed;
    z-index: 45;
    inset: 0;
    padding: 0;
    border: 0;
    background: rgb(8 10 14 / .42);
  }
  .cj-footer__inner { padding: var(--cj-space-4); }
}
@media print {
  :root, :root[data-theme] {
    --cj-bg: #ffffff;
    --cj-surface: #ffffff;
    --cj-surface-2: #f2f2f2;
    --cj-fg: #000000;
    --cj-muted: #333333;
    --cj-border: #cccccc;
    --cj-code-bg: #ffffff;
    --cj-accent: #000000;
    color-scheme: light;
  }
  .cj-header, .cj-sidebar, .cj-toc, .cj-toc-mobile, .cj-drawer-backdrop, .cj-search, .cj-settings,
  .cj-member-actions, .cj-code__copy, .cj-page-header__copy, .cj-members__toolbar, .cj-skip-link { display: none !important; }
  .cj-layout { display: block; }
  .cj-main { padding: 0; }
  .cj-content { max-width: none; }
  .cj-member::details-content { content-visibility: visible; display: block; height: auto; }
  a { color: inherit; text-decoration: underline; }
  pre { white-space: pre-wrap; overflow: visible; overflow-wrap: anywhere; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    scroll-behavior: auto !important;
    transition-duration: .01ms !important;
    animation-duration: .01ms !important;
    animation-iteration-count: 1 !important;
  }
}
"""
