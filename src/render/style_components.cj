package cjdoc.render

// Component styles. Surfaces stay flat; only temporary tools (dialogs, menus,
// the mobile drawer) carry a shadow. Signatures are dense monospace blocks
// whose linked types keep a faint underline so links never rely on color.

private let HTML_CHROME_STYLE = """
.cj-icon { width: 1rem; height: 1rem; flex: none; vertical-align: -.15em; }
.cj-button {
  display: inline-flex; align-items: center; justify-content: center; gap: .4rem;
  min-height: 2rem; padding: 0 .7rem;
  border: 1px solid var(--cj-border-strong); border-radius: var(--cj-radius);
  background: var(--cj-bg); color: var(--cj-fg);
  font-size: .8125rem; font-weight: 500; line-height: 1; white-space: nowrap; cursor: pointer;
  transition: background-color .12s, color .12s, border-color .12s;
}
.cj-button:hover { background: var(--cj-surface-2); text-decoration: none; }
.cj-button:disabled { opacity: .5; cursor: default; }
.cj-button--quiet { border-color: transparent; background: transparent; color: var(--cj-muted); }
.cj-button--quiet:hover { color: var(--cj-fg); }
.cj-button--icon { width: 2.125rem; height: 2.125rem; min-height: 0; padding: 0; border-color: transparent; background: transparent; color: var(--cj-muted); }
.cj-button--icon:hover { color: var(--cj-fg); }
.cj-input, .cj-select {
  height: 2rem; padding: 0 .6rem;
  border: 1px solid var(--cj-border-strong); border-radius: var(--cj-radius);
  background: var(--cj-bg); color: var(--cj-fg); font-size: .8125rem;
}
.cj-input::placeholder { color: var(--cj-muted); opacity: 1; }
.cj-input:focus, .cj-select:focus { border-color: var(--cj-accent); outline: 2px solid color-mix(in srgb, var(--cj-accent) 30%, transparent); outline-offset: 0; }
.cj-kbd {
  display: inline-block; min-width: 1.25rem; padding: .05rem .35rem;
  border: 1px solid var(--cj-border); border-bottom-color: var(--cj-border-strong); border-radius: 4px;
  background: var(--cj-surface); color: var(--cj-muted);
  font: 500 .6875rem/1.4 var(--cj-font-sans); text-align: center;
}

.cj-header__inner {
  display: flex; align-items: center; gap: var(--cj-space-3);
  max-width: 100rem; height: 100%; margin: 0 auto; padding: 0 var(--cj-space-4);
}
.cj-header__brand {
  display: inline-flex; align-items: center; gap: .55rem; min-width: 0;
  color: var(--cj-fg); font-weight: 650; letter-spacing: -.01em;
}
.cj-header__brand::before { content: ""; flex: none; width: .625rem; height: .625rem; border-radius: 2px; background: var(--cj-accent); }
.cj-header__brand:hover { text-decoration: none; }
.cj-header__project { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.cj-search-trigger {
  display: inline-flex; align-items: center; gap: .55rem;
  flex: 0 1 21rem; min-width: 0; height: 2.125rem; margin-left: var(--cj-space-5); padding: 0 .4rem 0 .7rem;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius);
  background: var(--cj-surface); color: var(--cj-muted); font-size: .8125rem; cursor: pointer;
  transition: border-color .12s, color .12s;
}
.cj-search-trigger:hover { border-color: var(--cj-border-strong); color: var(--cj-fg); }
.cj-search-trigger__label { flex: 1; overflow: hidden; text-align: left; text-overflow: ellipsis; white-space: nowrap; }
.cj-header__actions { display: flex; align-items: center; gap: var(--cj-space-1); margin-left: auto; }
.cj-header__version, .cj-header__actions .language-label {
  padding: 0 .45rem; color: var(--cj-muted); font-size: .75rem; font-weight: 500; white-space: nowrap;
}
.cj-header__version { border: 1px solid var(--cj-border); border-radius: 999px; font-variant-numeric: tabular-nums; }
@media (max-width: 760px) {
  .cj-header__inner { gap: var(--cj-space-2); padding: 0 var(--cj-space-2); }
  .cj-search-trigger { flex: none; width: 2.125rem; margin-left: auto; padding: 0; justify-content: center; border-color: transparent; background: transparent; }
  .cj-search-trigger__label, .cj-search-trigger .cj-kbd { display: none; }
  .cj-header__actions { margin-left: 0; }
  .cj-header__version { display: none; }
}

.cj-lang-toggle { position: relative; }
.cj-lang-toggle__summary {
  display: inline-flex; align-items: center; gap: .35rem; height: 2.125rem; padding: 0 .55rem;
  border-radius: var(--cj-radius); color: var(--cj-muted); font-size: .8125rem; cursor: pointer; list-style: none;
}
.cj-lang-toggle__summary::-webkit-details-marker { display: none; }
.cj-lang-toggle__summary:hover, .cj-lang-toggle[open] > .cj-lang-toggle__summary { background: var(--cj-surface-2); color: var(--cj-fg); }
.cj-lang-toggle__menu {
  position: absolute; z-index: 40; top: calc(100% + .35rem); right: 0;
  display: grid; min-width: 11rem; padding: .3rem;
  border: 1px solid var(--cj-border); border-radius: 8px; background: var(--cj-bg); box-shadow: var(--cj-shadow);
}
.cj-lang-toggle__option { display: grid; gap: .1rem; padding: .4rem .6rem; border-radius: var(--cj-radius); color: var(--cj-fg); font-size: .8125rem; }
.cj-lang-toggle__option:hover { background: var(--cj-surface-2); text-decoration: none; }
.cj-lang-toggle__option[aria-current="page"] { color: var(--cj-accent); font-weight: 600; }
.cj-lang-toggle__notice { color: var(--cj-muted); font-size: .6875rem; font-weight: 400; }
.cj-version-select {
  display: flex; flex-wrap: wrap; align-items: center; gap: .35rem .5rem;
  max-width: 100rem; margin: 0 auto; padding: .35rem var(--cj-space-4);
  border-bottom: 1px solid var(--cj-border); background: var(--cj-surface); color: var(--cj-muted); font-size: .75rem;
}
.cj-version-select a { padding: .1rem .45rem; border-radius: 4px; color: var(--cj-muted); }
.cj-version-select a:hover { background: var(--cj-surface-2); color: var(--cj-fg); text-decoration: none; }
.cj-version-select a[aria-current="page"] { background: var(--cj-accent-soft); color: var(--cj-accent); font-weight: 600; }

.cj-search, .cj-settings {
  padding: 0; border: 1px solid var(--cj-border); border-radius: 10px;
  background: var(--cj-bg); color: var(--cj-fg); box-shadow: var(--cj-shadow);
}
.cj-search { width: min(42rem, calc(100vw - 2rem)); max-height: min(38rem, calc(100vh - 6rem)); margin: 9vh auto auto; overflow: hidden; }
.cj-search[open] { display: flex; flex-direction: column; }
.cj-search::backdrop, .cj-settings::backdrop { background: rgb(8 10 14 / .42); }
.cj-search__bar { display: flex; align-items: center; gap: .6rem; padding: .55rem .6rem .55rem .95rem; border-bottom: 1px solid var(--cj-border); color: var(--cj-muted); }
.cj-search__bar:focus-within { box-shadow: inset 0 -2px 0 var(--cj-accent); }
.cj-search__input { flex: 1; min-width: 0; height: 2.25rem; padding: 0; border: 0; background: transparent; color: var(--cj-fg); font-size: 1rem; }
.cj-search__input:focus { outline: none; }
.cj-search__input::placeholder { color: var(--cj-muted); opacity: 1; }
.cj-search__input::-webkit-search-cancel-button { display: none; }
.cj-search__filters { display: flex; flex-wrap: wrap; gap: .5rem; padding: .5rem .95rem; border-bottom: 1px solid var(--cj-border); background: var(--cj-surface); }
.cj-search__filter { display: flex; flex: 1 1 10rem; min-width: 0; }
.cj-search__filter .cj-select { width: 100%; }
.cj-search__facets { display: flex; flex-wrap: wrap; gap: .35rem; padding: .5rem .95rem; border-bottom: 1px solid var(--cj-border); }
.cj-search__facet {
  padding: .15rem .55rem; border: 1px solid var(--cj-border-strong); border-radius: 999px;
  background: var(--cj-bg); color: var(--cj-muted); font-size: .75rem; cursor: pointer;
}
.cj-search__facet:hover { color: var(--cj-fg); }
.cj-search__facet[aria-pressed="true"] { border-color: var(--cj-accent); background: var(--cj-accent-soft); color: var(--cj-accent); font-weight: 600; }
.cj-search__results {
  flex: 1 1 auto; min-height: 0; overflow-y: auto; margin: 0; padding: .35rem; list-style: none;
  scrollbar-width: thin; scrollbar-color: var(--cj-border-strong) transparent;
}
.cj-search__results:empty { display: none; }
.cj-search__hit { border-radius: var(--cj-radius); }
.cj-search__hit[aria-selected="true"] { background: var(--cj-accent-soft); }
.cj-search__hit-link { display: grid; gap: .15rem; padding: .5rem .65rem; color: var(--cj-fg); }
.cj-search__hit-link:hover { text-decoration: none; }
.cj-search__hit:not([aria-selected="true"]) .cj-search__hit-link:hover { background: var(--cj-surface); border-radius: var(--cj-radius); }
.cj-search__hit-head { display: flex; align-items: baseline; gap: .5rem; min-width: 0; }
.cj-search__hit-name { min-width: 0; font: 600 .875rem/1.4 var(--cj-font-mono); overflow-wrap: anywhere; }
.cj-search__hit[aria-selected="true"] .cj-search__hit-name { color: var(--cj-accent); }
.cj-search__hit-signature { overflow: hidden; color: var(--cj-muted); font-size: .75rem; text-overflow: ellipsis; white-space: nowrap; }
.cj-search__hit-summary, .cj-search__hit-context, .cj-search__hit-body, .cj-search__hit-field { color: var(--cj-muted); font-size: .8125rem; line-height: 1.45; }
.cj-search__hit-context { font-size: .75rem; }
.cj-search__hit-field { font-weight: 600; }
.cj-search__status, .cj-search__note { margin: 0; padding: .5rem .95rem; border-top: 1px solid var(--cj-border); color: var(--cj-muted); font-size: .75rem; }
.cj-search__note { background: var(--cj-surface); }
.cj-search__pages { display: flex; justify-content: space-between; gap: .5rem; padding: .45rem .95rem; border-top: 1px solid var(--cj-border); }
/* Every palette control is a touch target: the close button and the page
   continuations are the ones a reader hits with a thumb. */
.cj-search .cj-button { min-height: 2.5rem; }
.cj-search .cj-button--icon { width: 2.5rem; height: 2.5rem; }
@media (max-width: 760px) {
  .cj-search { width: 100vw; max-width: 100vw; height: 100%; max-height: none; margin: 0; border: 0; border-radius: 0; }
}

.cj-settings { width: min(23rem, calc(100vw - 2rem)); margin: calc(var(--cj-header-height) + .5rem) var(--cj-space-4) auto auto; }
.cj-settings__head { display: flex; align-items: center; justify-content: space-between; padding: .5rem .5rem .5rem 1rem; border-bottom: 1px solid var(--cj-border); }
.cj-settings__title { margin: 0; font-size: .9375rem; font-weight: 650; }
.cj-settings__group { margin: 0; padding: .75rem 1rem .85rem; border: 0; border-bottom: 1px solid var(--cj-border); }
.cj-settings__legend { margin-bottom: .5rem; padding: 0; color: var(--cj-muted); font-size: .75rem; font-weight: 600; }
.cj-settings__options { display: grid; grid-auto-columns: minmax(0, 1fr); grid-auto-flow: column; gap: .35rem; }
.cj-settings__options--themes { grid-auto-flow: row; grid-template-columns: repeat(4, minmax(0, 1fr)); }
.cj-settings__option {
  display: flex; flex-direction: column; align-items: center; justify-content: center; gap: .35rem;
  min-height: 2.25rem; padding: .4rem .25rem;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius);
  background: var(--cj-bg); color: var(--cj-fg); font-size: .75rem; cursor: pointer;
}
.cj-settings__option:hover { border-color: var(--cj-border-strong); }
.cj-settings__option[aria-pressed="true"] { border-color: var(--cj-accent); background: var(--cj-accent-soft); color: var(--cj-accent); font-weight: 600; box-shadow: inset 0 0 0 1px var(--cj-accent); }
.cj-settings__option[data-cjdoc-font-value="serif"] { font-family: var(--cj-font-serif); font-size: .875rem; }
.cj-settings__option[data-cjdoc-font-value="mono-ui"] { font-family: var(--cj-font-mono); }
.cj-settings__option[data-cjdoc-size-value="s"] { font-size: .75rem; }
.cj-settings__option[data-cjdoc-size-value="m"] { font-size: .875rem; }
.cj-settings__option[data-cjdoc-size-value="l"] { font-size: 1.0625rem; }
.cj-settings__swatch { width: 1.5rem; height: 1.5rem; border: 1px solid var(--cj-border-strong); border-radius: 50%; }
.cj-settings__hint { margin: 0; padding: .65rem 1rem .8rem; color: var(--cj-muted); font-size: .75rem; }
@media (max-width: 760px) {
  .cj-settings { width: 100vw; max-width: 100vw; margin: auto 0 0; border-width: 1px 0 0; border-radius: 12px 12px 0 0; }
}

.cj-sidebar { font-size: .875rem; }
.cj-sidebar__primary { display: grid; gap: 1px; margin-bottom: var(--cj-space-4); }
.cj-sidebar__link { display: block; padding: .3rem .55rem; border-radius: var(--cj-radius); color: var(--cj-fg); }
.cj-sidebar__link:hover, .cj-tree__link:hover, .cj-tree__more:hover { background: var(--cj-surface-2); text-decoration: none; }
.cj-sidebar__link--ancestor, .cj-tree__link--ancestor { color: var(--cj-fg); font-weight: 600; }
.cj-sidebar__link[aria-current="page"], .cj-tree__link[aria-current="page"] { background: var(--cj-accent-soft); color: var(--cj-accent); font-weight: 600; }
.cj-sidebar__filter { margin-bottom: var(--cj-space-3); }
.cj-sidebar__filter-input { width: 100%; }
.cj-sidebar__empty { margin: 0 .55rem var(--cj-space-3); color: var(--cj-muted); font-size: .8125rem; }
.cj-tree__module + .cj-tree__module { margin-top: var(--cj-space-4); }
.cj-tree__module-label { margin: 0 0 .2rem; padding: 0 .55rem; color: var(--cj-muted); font-size: .75rem; font-weight: 600; }
.cj-tree__list, .cj-tree__children { margin: 0; padding: 0; list-style: none; }
.cj-tree__children { margin: .1rem 0 .3rem .75rem; padding-left: .4rem; border-left: 1px solid var(--cj-border); }
.cj-tree__row { display: flex; align-items: center; gap: .1rem; min-width: 0; }
.cj-tree__toggle {
  display: inline-grid; flex: none; place-items: center; width: 1.25rem; height: 1.5rem; padding: 0;
  border: 0; border-radius: 4px; background: none; color: var(--cj-muted); cursor: pointer;
}
.cj-tree__toggle:hover { background: var(--cj-surface-2); color: var(--cj-fg); }
.cj-tree__link {
  display: flex; align-items: center; gap: .45rem; flex: 1; min-width: 0;
  padding: .22rem .5rem; border-radius: var(--cj-radius); color: var(--cj-fg); line-height: 1.35;
}
/* Rows without a toggle keep their label on the same column as siblings. */
.cj-tree__row > .cj-tree__link:first-child { margin-left: 1.35rem; }
.cj-tree__toggle::before, .cj-toc__toggle::before {
  content: ""; width: .36rem; height: .36rem;
  border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor;
  transform: translateX(-1px) rotate(-45deg); transition: transform .15s ease-out;
}
.cj-tree__toggle[aria-expanded="true"]::before, .cj-toc__toggle[aria-expanded="true"]::before { transform: translateY(-1px) rotate(45deg); }
.cj-tree__label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
[data-cjdoc-tree-item="type"] .cj-tree__label, [data-cjdoc-tree-item="member"] .cj-tree__label { font-family: var(--cj-font-mono); font-size: .8125rem; }
.cj-tree__count { margin-left: auto; color: var(--cj-muted); font-size: .6875rem; font-variant-numeric: tabular-nums; }
.cj-tree__kind { flex: none; width: .5rem; height: .5rem; border-radius: 2px; background: var(--cj-border-strong); }
.cj-tree__kind[data-kind="class"], .cj-tree__kind[data-kind="struct"] { background: var(--cj-code-type); }
.cj-tree__kind[data-kind="interface"] { background: var(--cj-code-keyword); border-radius: 50%; }
.cj-tree__kind[data-kind="enum"], .cj-tree__kind[data-kind="enumCase"] { background: var(--cj-code-number); }
.cj-tree__kind[data-kind="function"], .cj-tree__kind[data-kind="macro"], .cj-tree__kind[data-kind="constructor"] { background: var(--cj-code-function); border-radius: 50%; }
.cj-tree__kind[data-kind="property"], .cj-tree__kind[data-kind="variable"] { background: var(--cj-code-string); }
.cj-tree__kind[data-kind="extend"], .cj-tree__kind[data-kind="typeAlias"] { background: transparent; box-shadow: inset 0 0 0 1.5px var(--cj-code-type); }
.cj-tree__more { display: block; padding: .22rem .5rem; border-radius: var(--cj-radius); color: var(--cj-muted); font-size: .8125rem; }

.cj-toc__title { margin: 0 0 .5rem; color: var(--cj-muted); font-size: .75rem; font-weight: 600; }
.cj-toc__list, .cj-toc__children { margin: 0; padding: 0; list-style: none; }
.cj-toc__children { padding-left: .7rem; }
.cj-toc__row { display: flex; align-items: flex-start; }
.cj-toc__link {
  display: block; flex: 1; min-width: 0; padding: .2rem 0 .2rem .7rem;
  border-left: 1px solid var(--cj-border); color: var(--cj-muted); font-size: .8125rem; line-height: 1.4; overflow-wrap: anywhere;
}
.cj-toc__link:hover { color: var(--cj-fg); text-decoration: none; }
.cj-toc__link--active { border-left-color: var(--cj-accent); color: var(--cj-accent); font-weight: 600; }
.cj-toc__item--member .cj-toc__link, .cj-toc__item--api .cj-toc__link { font-family: var(--cj-font-mono); font-size: .75rem; }
.cj-toc__toggle {
  display: inline-grid; flex: none; place-items: center; width: 1.25rem; height: 1.5rem; padding: 0;
  border: 0; background: none; color: var(--cj-muted); cursor: pointer;
}
.cj-toc-mobile { margin: 0 0 var(--cj-space-5); border: 1px solid var(--cj-border); border-radius: var(--cj-radius); font-size: .875rem; }
.cj-toc-mobile__summary { padding: .5rem .8rem; color: var(--cj-muted); font-weight: 600; cursor: pointer; }
.cj-toc-mobile > .cj-toc__list { padding: 0 .8rem .65rem; }
"""

private let HTML_DOCUMENT_STYLE = """
/* Zero-specificity base rules: any component class overrides them by order. */
:where(.cj-content) :where(h1, h2, h3, h4, h5, h6) {
  color: var(--cj-fg); font-weight: 650; line-height: 1.3; letter-spacing: -.01em; text-wrap: balance;
}
:where(.cj-content) :where(h2) { margin: 2.25rem 0 .75rem; padding-bottom: .4rem; border-bottom: 1px solid var(--cj-border); font-size: 1.3125rem; }
:where(.cj-content) :where(h3) { margin: 1.75rem 0 .5rem; font-size: 1.0625rem; }
:where(.cj-content) :where(h4) { margin: 1.4rem 0 .4rem; font-size: .9375rem; }
:where(.cj-content) :where(h5, h6) { margin: 1.2rem 0 .35rem; font-size: .875rem; }
:where(.cj-content) :where(p, ul, ol, dl, blockquote) { margin: .7rem 0; }
:where(.cj-content) :where(ul, ol) { padding-left: 1.4rem; }
:where(.cj-content) :where(li + li) { margin-top: .2rem; }
:where(.cj-content) :where(hr) { margin: 2rem 0; border: 0; border-top: 1px solid var(--cj-border); }
:where(.cj-content) :where(code) { font-size: .875em; }
.cj-prose, .cj-summary, .cj-description, .cj-introduction, .cj-home-intro, .cj-guide { max-width: 72ch; }
.cj-prose :not(pre) > code, .cj-summary :not(pre) > code, .cj-description :not(pre) > code,
.cj-params__description :not(pre) > code, .cj-member__body p > code, .cj-admonition :not(pre) > code, .cj-table code {
  padding: .1em .32em; border-radius: 4px; background: var(--cj-code-bg); font-size: .85em;
}
.cj-prose blockquote { margin-left: 0; padding: .1rem 0 .1rem 1rem; border-left: 1px solid var(--cj-border-strong); color: var(--cj-muted); }
.cj-prose img { border-radius: var(--cj-radius); }
.cj-summary { margin: .5rem 0 1rem; color: var(--cj-fg); font-size: 1.0625rem; line-height: 1.55; }
.cj-meta, .cj-empty, .cj-state-note { color: var(--cj-muted); font-size: .875rem; }
.cj-empty { margin: .75rem 0; }
.cj-state-note { font-style: italic; }
.cj-note { margin: .75rem 0; padding: .55rem .8rem; border: 1px solid var(--cj-border); border-radius: var(--cj-radius); background: var(--cj-surface); color: var(--cj-muted); font-size: .875rem; }
.cj-note--callout { color: var(--cj-fg); }
.cj-anchor-alias { display: block; width: 0; height: 0; overflow: hidden; }
:where(.cj-content) :where(pre) {
  position: relative; margin: 1rem 0; padding: .75rem 1rem; overflow-x: auto;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius); background: var(--cj-code-bg);
  font-size: .875rem; line-height: 1.55; tab-size: 4;
  scrollbar-width: thin; scrollbar-color: var(--cj-border-strong) transparent;
}
:where(.cj-content) :where(pre code) { font-size: inherit; }
.cj-code > .cj-code__pre { margin: 1rem 0; }
.cj-code__copy {
  position: absolute; top: .35rem; right: .35rem; min-height: 1.625rem; padding: 0 .45rem;
  border-color: var(--cj-border); background: var(--cj-bg); font-size: .75rem; opacity: 0; transition: opacity .12s;
}
.cj-code__copy .cj-icon { width: .875rem; height: .875rem; }
pre:hover > .cj-code__copy, .cj-code__copy:focus-visible, .cj-code__copy[data-cjdoc-copy-state] { opacity: 1; }
@media (hover: none) { .cj-code__copy { opacity: 1; } }
[data-cjdoc-copy-state="copied"] { color: var(--cj-success); }
[data-cjdoc-copy-state="failed"] { color: var(--cj-danger); }
.cj-tok-keyword { color: var(--cj-code-keyword); }
.cj-tok-meta { color: var(--cj-code-meta); }
.cj-tok-type { color: var(--cj-code-type); }
.cj-tok-string { color: var(--cj-code-string); }
.cj-tok-number, .cj-tok-literal { color: var(--cj-code-number); }
.cj-tok-comment { color: var(--cj-code-comment); font-style: italic; }
.cj-tok-function, .cj-tok-property { color: var(--cj-code-function); }
.cj-tok-operator, .cj-tok-punctuation { color: var(--cj-code-operator); }
.cj-table-wrap { max-width: 100%; margin: 1rem 0; overflow-x: auto; }
.cj-table { min-width: 50%; border-collapse: collapse; font-size: .875rem; }
.cj-table th, .cj-table td { padding: .4rem .75rem; border: 1px solid var(--cj-border); text-align: left; vertical-align: top; }
.cj-table th { background: var(--cj-surface); font-weight: 600; }
.cj-align-left { text-align: left; }
.cj-align-center { text-align: center; }
.cj-align-right { text-align: right; }
.cj-content .cj-table .cj-align-center { text-align: center; }
.cj-content .cj-table .cj-align-right { text-align: right; }
.cj-examples { display: grid; gap: 1rem; margin: 1rem 0 1.25rem; }
.cj-example { min-width: 0; }
.cj-example__title { margin: 0 0 .4rem; font-size: .9375rem; }
.cj-example > :last-child { margin-bottom: 0; }
.cj-contracts { margin: 1rem 0; }
.cj-contracts__subject { font-family: var(--cj-font-mono); font-size: .875rem; font-weight: 600; }
.cj-content-language { display: inline-block; margin: .15rem .5rem .35rem 0; color: var(--cj-muted); font-size: .75rem; }
.cj-content-language[data-translation-state="complete"] { display: none; }
.cj-admonition {
  margin: 1rem 0; padding: .7rem 1rem .75rem;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius); background: var(--cj-surface);
}
.cj-admonition__head { display: flex; align-items: center; gap: .45rem; margin-bottom: .3rem; color: var(--cj-accent); font-size: .875rem; font-weight: 650; }
.cj-admonition--warning { border-color: color-mix(in srgb, var(--cj-warning) 45%, var(--cj-border)); }
.cj-admonition--warning .cj-admonition__head { color: var(--cj-warning); }
.cj-admonition--danger { border-color: color-mix(in srgb, var(--cj-danger) 45%, var(--cj-border)); }
.cj-admonition--danger .cj-admonition__head { color: var(--cj-danger); }
.cj-admonition__icon { display: inline-flex; }
.cj-admonition__body { max-width: none; }
.cj-admonition__body > :first-child { margin-top: 0; }
.cj-admonition__body > :last-child { margin-bottom: 0; }
.cj-risks { display: inline-flex; flex-wrap: wrap; gap: .3rem; }
.cj-risk {
  display: inline-flex; align-items: center; gap: .25rem; padding: 0 .45rem;
  border: 1px solid currentColor; border-radius: 999px; font-size: .6875rem; font-weight: 600; line-height: 1.6; white-space: nowrap;
}
.cj-risk .cj-icon { width: .75rem; height: .75rem; }
.cj-risk--danger { color: var(--cj-danger); }
.cj-risk--warning { color: var(--cj-warning); }

.cj-breadcrumbs__list { display: flex; flex-wrap: wrap; gap: .2rem .4rem; margin: 0 0 1rem; padding: 0; list-style: none; color: var(--cj-muted); font-size: .8125rem; }
.cj-content .cj-breadcrumbs__item + .cj-breadcrumbs__item { margin-top: 0; }
.cj-breadcrumbs__item + .cj-breadcrumbs__item::before { content: "/"; margin-right: .4rem; color: var(--cj-border-strong); }
.cj-breadcrumbs a { color: var(--cj-muted); }
.cj-breadcrumbs a:hover { color: var(--cj-fg); }
.cj-breadcrumbs code { font-size: .8125rem; }
.cj-page-header { margin-bottom: 1.5rem; }
.cj-page-header__title-row { display: flex; flex-wrap: wrap; align-items: center; gap: .5rem .75rem; }
.cj-content .cj-page-header__title { margin: 0; font-size: 1.875rem; line-height: 1.2; letter-spacing: -.02em; overflow-wrap: anywhere; }
.cj-page-header--api .cj-page-header__title, .cj-page-header--extension .cj-page-header__title { font-size: 1.5rem; }
.cj-page-header__title code { font-size: inherit; font-weight: 650; }
.cj-page-header--home .cj-page-header__title { font-size: 2.125rem; }
.cj-page-header__badges { display: inline-flex; flex-wrap: wrap; gap: .3rem; }
.cj-page-header__copy { margin-left: auto; }
.cj-page-header__source { margin: .5rem 0 0; }
.cj-kind {
  display: inline-flex; align-items: center; padding: .05rem .42rem;
  border-radius: 4px; background: var(--cj-surface-2); color: var(--cj-muted);
  font: 600 .6875rem/1.5 var(--cj-font-sans); letter-spacing: .01em; white-space: nowrap;
}
.cj-kind[data-kind="class"], .cj-kind[data-kind="struct"], .cj-kind[data-kind="typeAlias"], .cj-kind[data-kind="extend"] { color: var(--cj-code-type); }
.cj-kind[data-kind="interface"] { color: var(--cj-code-keyword); }
.cj-kind[data-kind="enum"], .cj-kind[data-kind="enumCase"] { color: var(--cj-code-number); }
.cj-kind[data-kind="function"], .cj-kind[data-kind="macro"], .cj-kind[data-kind="constructor"] { color: var(--cj-code-function); }
.cj-kind[data-kind="property"], .cj-kind[data-kind="variable"] { color: var(--cj-code-string); }
.cj-badges { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .25rem; vertical-align: middle; }
.cj-badge {
  display: inline-flex; align-items: center; max-width: 100%; padding: 0 .45rem;
  border: 1px solid var(--cj-border); border-radius: 999px; background: var(--cj-bg); color: var(--cj-muted);
  font-size: .6875rem; font-weight: 500; line-height: 1.6; overflow-wrap: anywhere;
}
a.cj-badge, .cj-badge--tag { color: var(--cj-accent); }
a.cj-badge:hover { border-color: var(--cj-accent); background: var(--cj-accent-soft); text-decoration: none; }
.cj-badge--origin { background: var(--cj-surface-2); border-color: transparent; }
.cj-disclosure, .cj-generation, .cj-reexports, .cj-package-sources, .cj-page-source, .cj-usages {
  margin: 1rem 0; border-top: 1px solid var(--cj-border); color: var(--cj-muted); font-size: .875rem;
}
.cj-disclosure > summary, .cj-generation > summary, .cj-reexports > summary, .cj-package-sources > summary, .cj-page-source > summary, .cj-usages > summary {
  padding: .55rem 0; color: var(--cj-fg); font-weight: 600; cursor: pointer;
}
.cj-disclosure[open], .cj-generation[open], .cj-reexports[open], .cj-package-sources[open], .cj-page-source[open], .cj-usages[open] { padding-bottom: .75rem; }
.cj-record-list, .cj-diagnostics { margin: .5rem 0; padding: 0; list-style: none; }
.cj-record-list > li, .cj-diagnostics > li { padding: .3rem 0; border-bottom: 1px solid var(--cj-border); }
.cj-content .cj-record-list > li + li, .cj-content .cj-diagnostics > li + li { margin-top: 0; }
.cj-package-index, .cj-reading-paths, .cj-overview__links {
  margin: .5rem 0 2rem; padding: 0; list-style: none; border-top: 1px solid var(--cj-border);
}
.cj-package-index > li, .cj-overview__links > li, .cj-reading-paths > li {
  display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: .15rem 1rem;
  margin: 0; padding: .55rem 0; border-bottom: 1px solid var(--cj-border);
}
.cj-content .cj-package-index > li + li, .cj-content .cj-overview__links > li + li, .cj-content .cj-reading-paths > li + li { margin-top: 0; }
.cj-package-index > li > a, .cj-overview__links > li > a { min-width: 0; font-weight: 600; overflow-wrap: anywhere; }
.cj-package-index .cj-meta { flex: none; font-variant-numeric: tabular-nums; }
.cj-package-index p, .cj-overview__links p, .cj-reading-paths p { flex-basis: 100%; margin: 0; color: var(--cj-muted); font-size: .875rem; }
.cj-overview, .cj-decl-groups, .cj-api-group { margin: 1.5rem 0; }
.cj-decl-groups ul { display: flex; flex-wrap: wrap; gap: .5rem 1.25rem; margin: 1rem 0 2rem; padding: 0; list-style: none; }
.cj-content .cj-decl-groups li + li { margin-top: 0; }
.cj-package-overview, .cj-package-return, .cj-guide-entry { margin: 1rem 0; }
.cj-package-overview__link, .cj-package-return a { font-weight: 600; }
.cj-guide__related, .cj-bindings { margin: 2rem 0 0; padding-top: 1rem; border-top: 1px solid var(--cj-border); }
.cj-bindings__label, .cj-bindings__meta, .cj-bindings__scope, .cj-bindings__state, .cj-bindings__version { color: var(--cj-muted); font-size: .8125rem; }
.cj-binding { display: inline-flex; align-items: baseline; gap: .3rem; padding: 0 .4rem; border: 1px solid var(--cj-border); border-radius: var(--cj-radius); font-size: .875em; }
.cj-guide-sequence { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .75rem; margin: 2.5rem 0 0; }
.cj-guide-sequence a { display: grid; gap: .15rem; padding: .7rem .9rem; border: 1px solid var(--cj-border); border-radius: var(--cj-radius); color: var(--cj-fg); }
.cj-guide-sequence a:hover { border-color: var(--cj-accent); text-decoration: none; }
.cj-guide-sequence a:last-child:not(:first-child) { text-align: right; }
.cj-validation__context { color: var(--cj-muted); }
@media (max-width: 760px) {
  .cj-content .cj-page-header__title { font-size: 1.5rem; }
  .cj-page-header--api .cj-page-header__title, .cj-page-header--extension .cj-page-header__title { font-size: 1.25rem; }
  .cj-page-header__copy { margin-left: 0; }
  .cj-guide-sequence { grid-template-columns: minmax(0, 1fr); }
}
"""

private let HTML_REFERENCE_STYLE = """
.cj-symbol-meta { margin: 1rem 0 0; }
.cj-content .cj-signature, .cj-signature {
  margin: 1rem 0 0; padding: .75rem 1rem;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius); background: var(--cj-code-bg);
  color: var(--cj-fg); font: 500 .875rem/1.6 var(--cj-font-mono);
  white-space: pre-wrap; overflow-wrap: anywhere;
}
.cj-signature code { font-size: inherit; }
.cj-signature-inline { color: var(--cj-fg); font: 500 .875rem/1.55 var(--cj-font-mono); white-space: pre-wrap; overflow-wrap: anywhere; }
.cj-type-link {
  color: var(--cj-code-type);
  text-decoration: underline; text-decoration-color: color-mix(in srgb, currentColor 32%, transparent);
  text-decoration-thickness: 1px; text-underline-offset: .2em;
}
.cj-type-link:hover { text-decoration-color: currentColor; }
.cj-introduction { margin: 1.25rem 0; }
.cj-decl-group { margin-top: 1.5rem; }
.cj-decl-table { width: 100%; margin: .35rem 0 1.5rem; border-collapse: collapse; font-size: .875rem; }
.cj-decl-table__row { border-top: 1px solid var(--cj-border); }
.cj-decl-table__row:last-child { border-bottom: 1px solid var(--cj-border); }
.cj-decl-table__row:hover { background: var(--cj-surface); }
.cj-decl-table td { padding: .45rem .75rem .45rem 0; vertical-align: baseline; }
.cj-decl-table td:first-child { padding-left: .35rem; }
.cj-decl-table { table-layout: fixed; }
.cj-decl-table :is(th, td):nth-child(1) { width: 38%; }
.cj-decl-table :is(th, td):nth-child(2) { width: 6.5rem; }
.cj-decl-table__name { overflow-wrap: anywhere; }
.cj-decl-table__link { margin-right: .35rem; font: 600 .875rem/1.45 var(--cj-font-mono); }
.cj-decl-table__link code { font-size: inherit; }
.cj-decl-table__kind { white-space: nowrap; }
.cj-decl-table__summary { color: var(--cj-muted); font-size: .9375rem; line-height: 1.5; overflow-wrap: anywhere; }
@media (max-width: 760px) {
  .cj-decl-table, .cj-decl-table tbody { display: block; }
  .cj-decl-table__row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: .15rem .5rem; padding: .5rem .35rem; }
  .cj-decl-table td, .cj-decl-table td:first-child { display: block; width: auto; min-width: 0; padding: 0; }
  .cj-decl-table__summary { grid-column: 1 / -1; }
}

.cj-members { margin-top: 2.25rem; }
.cj-members__toolbar {
  display: flex; flex-wrap: wrap; align-items: center; gap: .5rem;
  margin: 0 0 1rem; padding: .25rem .4rem;
  border: 1px solid var(--cj-border); border-radius: var(--cj-radius); background: var(--cj-surface);
}
.cj-members__filters { display: flex; flex-wrap: wrap; align-items: center; gap: .4rem .5rem; flex: 1 1 18rem; min-width: 0; }
.cj-members__filters label { color: var(--cj-muted); font-size: .8125rem; }
.cj-members__filters .cj-input { flex: 1 1 12rem; min-width: 0; }
.cj-members__actions { display: flex; gap: .25rem; margin-left: auto; }
.cj-members__status { color: var(--cj-muted); font-size: .875rem; }
.cj-member-group { margin-top: 1.75rem; }
.cj-member-group__head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; margin-bottom: .1rem; border-bottom: 1px solid var(--cj-border); }
.cj-content .cj-member-group__title { margin: 0; padding: 0 0 .4rem; border: 0; }
.cj-member-group__count { flex: none; color: var(--cj-muted); font-size: .75rem; font-variant-numeric: tabular-nums; }
.cj-overloads { margin: .35rem 0 .5rem; padding-left: .75rem; border-left: 1px solid var(--cj-border-strong); }
.cj-content .cj-overloads__title { display: flex; align-items: baseline; gap: .5rem; margin: .8rem 0 .1rem; padding: 0; border: 0; font-size: .875rem; }
.cj-overloads__count { color: var(--cj-muted); font-size: .75rem; font-weight: 500; }
.cj-member-row {
  display: grid; grid-template-columns: minmax(0, 1fr) auto; column-gap: .25rem;
  border-bottom: 1px solid var(--cj-border);
}
.cj-member { grid-area: 1 / 1; min-width: 0; }
.cj-member-actions { grid-area: 1 / 2; position: relative; display: flex; align-items: flex-start; padding-top: .35rem; }
.cj-member-row__badges { grid-area: 2 / 1; display: flex; flex-wrap: wrap; gap: .25rem; padding: 0 0 .5rem 1.2rem; }
.cj-member-row__badges:empty { display: none; }
.cj-member__summary {
  position: relative; display: flex; flex-wrap: wrap; align-items: baseline; gap: .2rem .55rem;
  padding: .55rem .35rem .55rem 1.2rem; border-radius: var(--cj-radius); cursor: pointer; list-style: none;
}
.cj-member__summary::-webkit-details-marker { display: none; }
.cj-member__summary::before {
  content: ""; position: absolute; top: 1.05em; left: .35rem; width: .36rem; height: .36rem;
  border-right: 1.5px solid var(--cj-muted); border-bottom: 1.5px solid var(--cj-muted);
  transform: rotate(-45deg); transition: transform .15s ease-out;
}
.cj-member[open] > .cj-member__summary::before { transform: rotate(45deg); }
.cj-member__summary:hover { background: var(--cj-surface); }
.cj-member__signature { flex: 1 1 100%; min-width: 0; }
.cj-member__description { flex: 1 1 100%; color: var(--cj-muted); font-size: .9375rem; line-height: 1.5; }
.cj-member:target > .cj-member__summary { background: var(--cj-accent-soft); }
.cj-member__body { padding: .1rem .35rem 1rem 1.2rem; }
.cj-member__body > :first-child { margin-top: .35rem; }
.cj-member__origin, .cj-member__conditions { color: var(--cj-muted); font-size: .875rem; }
.cj-member__extension { font-size: .8125rem; }
.cj-member-actions__toggle { display: none; }
.cj-member-actions__list { display: flex; gap: .1rem; }
/* Without scripts the tray is plain inline content: no hover state to rely on. */
html:not([data-cj-js]) .cj-member-actions { position: static; }
/* With scripts the tray stays rendered but transparent at rest, revealed by the
   row's hover or by keyboard focus, so it never covers the signature and its
   links stay in the tab order. A wide viewport keeps this inline tray even when
   the pointer cannot hover (headless, touch-screen laptops); only a narrow row
   swaps it for the toggle popup below. */
@media (min-width: 761px) {
  html[data-cj-js] .cj-member-actions {
    opacity: 0; pointer-events: none; transition: opacity .12s;
  }
  html[data-cj-js] .cj-member-row:hover .cj-member-actions,
  html[data-cj-js] .cj-member-row:focus-within .cj-member-actions {
    opacity: 1; pointer-events: auto;
  }
}
.cj-member-actions__item {
  display: inline-grid; place-items: center; width: 1.875rem; height: 1.875rem; padding: 0;
  border: 0; border-radius: var(--cj-radius); background: none; color: var(--cj-muted); cursor: pointer;
}
.cj-member-actions__item:hover { background: var(--cj-surface-2); color: var(--cj-fg); text-decoration: none; }
.cj-member-actions__label {
  position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); clip-path: inset(50%); white-space: nowrap;
}
/* The compact popup exists because a narrow row has no room for the inline
   tray, so only width decides it: a wide viewport keeps the inline tray even
   when the pointer cannot hover (headless, touch-screen laptops). */
@media (max-width: 760px) {
  html[data-cj-js] .cj-member-actions__toggle { display: inline-flex; }
  html[data-cj-js] .cj-member-actions__list {
    position: absolute; z-index: 20; top: 2.4rem; right: 0; display: none; flex-direction: column;
    width: max-content; min-width: min(13rem, calc(100vw - 2rem)); max-width: calc(100vw - 2rem); padding: .3rem;
    border: 1px solid var(--cj-border); border-radius: 8px; background: var(--cj-bg); box-shadow: var(--cj-shadow); opacity: 1;
  }
  html[data-cj-js] .cj-member-actions__toggle[aria-expanded="true"] + .cj-member-actions__list { display: flex; }
  html[data-cj-js] .cj-member-actions__item { justify-content: start; grid-auto-flow: column; gap: .5rem; width: auto; padding: 0 .6rem; }
  html[data-cj-js] .cj-member-actions__label { position: static; width: auto; height: auto; overflow: visible; clip: auto; clip-path: none; font-size: .8125rem; }
}

.cj-params, .cj-throws { margin: .5rem 0 1rem; border-top: 1px solid var(--cj-border); }
.cj-params__row, .cj-throws__row {
  display: grid; grid-template-columns: minmax(7rem, max-content) minmax(0, 1fr); gap: .2rem 1rem;
  padding: .45rem 0; border-bottom: 1px solid var(--cj-border);
}
.cj-params__row > dt, .cj-params__row > dd, .cj-throws__row > dt, .cj-throws__row > dd { min-width: 0; margin: 0; }
.cj-params__declaration { font-size: .875rem; overflow-wrap: anywhere; }
.cj-params__name { color: var(--cj-fg); font-weight: 600; }
.cj-params__colon { margin-right: .15rem; color: var(--cj-muted); }
.cj-params__type, .cj-params__default { color: var(--cj-muted); }
.cj-params__description:empty { display: none; }
.cj-params__description > :first-child, .cj-throws__row > dd > :first-child { margin-top: 0; }
.cj-params__description > :last-child, .cj-throws__row > dd > :last-child { margin-bottom: 0; }
.cj-returns { margin: .5rem 0 1rem; }
.cj-returns__description > :first-child { margin-top: 0; }
@media (max-width: 760px) {
  .cj-params__row, .cj-throws__row { grid-template-columns: minmax(0, 1fr); }
}
.cj-relations dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: .35rem 1rem; margin: .5rem 0 1rem; }
.cj-relations dt { color: var(--cj-muted); font-size: .875rem; }
.cj-relations dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.cj-relations__note { margin-left: .35rem; color: var(--cj-muted); font-size: .8125rem; font-style: italic; }
.cj-usages ul { margin: .5rem 0 0; padding-left: 1.2rem; }
.cj-owner-context { margin: 2rem 0; }
.cj-owner-context ol { margin: .5rem 0; padding: 0; list-style: none; }
.cj-owner-context__source { margin: .75rem 0; padding: .75rem 1rem; border: 1px solid var(--cj-border); border-radius: var(--cj-radius); }
.cj-content .cj-owner-context__source h3, .cj-content .cj-owner-context__source h4 { margin-top: 0; }
.cj-owner-context__provenance { color: var(--cj-muted); font-size: .8125rem; }
.cj-symbol-entry { margin: 1.5rem 0; }
.cj-symbol-entry__title { font-family: var(--cj-font-mono); }
.cj-external { margin: 2rem 0 0; padding-top: .5rem; border-top: 1px solid var(--cj-border); }
.cj-external__note, .cj-external__status { color: var(--cj-muted); font-size: .875rem; }
@media (max-width: 760px) {
  .cj-relations dl { grid-template-columns: minmax(0, 1fr); }
  .cj-members__actions { margin-left: 0; }
  html[data-cj-js] .cj-members__filters:not([data-cj-open]) { display: none; }
}
@media (min-width: 761px) {
  .cj-members__filter-toggle { display: none; }
}
"""

internal let HTML_COMPONENT_STYLE = HTML_CHROME_STYLE + HTML_DOCUMENT_STYLE + HTML_REFERENCE_STYLE
