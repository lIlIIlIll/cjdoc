package cjdoc.render

internal let HTML_RETURN_LAYOUT_STYLE = """
.return-value{display:grid;grid-template-columns:fit-content(14rem) minmax(0,1fr);align-items:baseline;gap:.75rem;margin:.5rem 0 .8rem;color:var(--muted)}.return-type{flex:0 1 auto;min-width:0;overflow-wrap:anywhere;padding:.13rem .35rem;border:1px solid var(--line);border-radius:5px;background:var(--code-bg);color:var(--ink);font-size:.91em}.return-description{min-width:0}.return-description>p{margin:0}
@media(max-width:760px){.return-value{grid-template-columns:minmax(0,1fr);gap:.2rem}}
"""

internal let HTML_TYPE_LINK_STYLE = """
.type-link{color:var(--accent-strong);text-decoration:underline;text-decoration-thickness:.06em;text-decoration-color:color-mix(in srgb,var(--accent) 55%,transparent);border-radius:3px;transition:background-color .12s ease,color .12s ease}.type-link:hover,.type-link:focus-visible{color:var(--accent);text-decoration:underline;background:var(--accent-soft)}.type-link:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
"""

internal let HTML_NAVIGATION_STYLE = """
.sidebar-package.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:680}.sidebar-package.is-current:hover{background:var(--accent-soft);color:var(--accent-strong)}
"""

internal let HTML_TOC_STYLE = """
.toc-panel nav{max-height:calc(100vh - 120px);overflow:auto}.toc-panel ol{margin:0;padding:0;list-style:none}.toc-panel li{margin:0}.toc-panel .toc-api-item+.toc-api-item{margin-top:.22rem}.toc-panel .toc-api-row{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:start;gap:.12rem}.toc-panel .toc-api-row>.toc-link{min-width:0}.toc-panel .toc-toggle{display:grid;place-items:center;width:1.45rem;height:1.8rem;margin:.08rem 0 0;border:0;border-radius:4px;background:transparent;color:var(--faint);cursor:pointer;font:inherit}.toc-panel .toc-toggle:hover{background:var(--accent-soft);color:var(--accent)}.toc-panel .toc-toggle:focus-visible{outline:2px solid var(--accent);outline-offset:-1px}.toc-panel .toc-toggle-icon{font-size:.9rem;line-height:1}.toc-panel .toc-link{display:block;min-width:0;padding:.32rem .58rem;border-left:2px solid transparent;color:var(--muted);font-size:.8rem;line-height:1.45;overflow-wrap:anywhere}.toc-panel .toc-api-link{font-weight:620}.toc-panel .toc-member-link{padding:.25rem .58rem;font-size:.76rem;line-height:1.4}.toc-panel .toc-children{margin:.08rem 0 .28rem .72rem;padding:.08rem 0 .12rem .5rem;border-left:1px solid var(--line)}.toc-panel .toc-children[hidden]{display:none}.toc-panel .toc-link:hover,.toc-panel .toc-link:focus-visible{background:var(--accent-soft);color:var(--ink);text-decoration:none}.toc-panel .toc-link:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}.toc-panel .toc-link.is-active{border-left-color:var(--accent);background:var(--accent-soft);color:var(--accent);font-weight:700}.toc-panel .toc-api-link.is-parent-active{border-left-color:color-mix(in srgb,var(--accent) 55%,transparent);color:var(--accent-strong)}.symbol-entry h3.symbol-title{margin:.05rem 0 .8rem;padding:0;border:0;font-size:1.08rem}.symbol-entry h3.symbol-title code{padding:0;border:0;background:transparent;color:var(--accent)}
"""

internal let HTML_LAYOUT_HARDENING_STYLE = """
.search-results a,.breadcrumbs,.declaration-summary h3,.page-header h1{overflow-wrap:anywhere}.sidebar-package span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.parameter-row{padding:0;border-bottom:0}.parameter-type{white-space:normal;overflow-wrap:anywhere}.symbol-relationships,.reverse-type-usages{margin:1.15rem 0;padding:.8rem 0;border-top:1px solid var(--line)}.symbol-relationships h2,.symbol-relationships h3,.reverse-type-usages h2{margin:.05rem 0 .6rem;font-size:1rem}.symbol-relationships dl{display:grid;grid-template-columns:minmax(8rem,max-content) minmax(0,1fr);gap:.4rem .9rem;margin:0}.symbol-relationships dt{color:var(--muted);font:650 .78rem/1.5 var(--code-font)}.symbol-relationships dd{margin:0;min-width:0}.relation-scope{margin:.25rem 0 .7rem;color:var(--muted);font-size:.82rem}.reverse-type-usages ol{margin:.4rem 0 0;padding-left:1.4rem}.reverse-type-usages li{padding:.25rem 0;overflow-wrap:anywhere}.usage-kind{display:inline-block;min-width:6.2rem;color:var(--muted);font-size:.76rem}.usage-signature{margin-left:.35rem;color:var(--muted);font-size:.78rem}.relation-more{color:var(--muted);font-size:.8rem}.signature-type-link{border-radius:3px}.signature-type-link:hover,.signature-type-link:focus-visible{color:var(--accent);text-decoration:underline;background:var(--accent-soft)}.member-browser{margin:1.1rem 0}.member-browser-toolbar{display:flex;align-items:center;gap:.55rem;margin:0 0 .45rem;flex-wrap:wrap}.member-browser-toolbar label{color:var(--muted);font-size:.8rem;font-weight:650}.member-browser-toolbar input{min-width:10rem;max-width:26rem;flex:1;height:34px;padding:0 .55rem;border:1px solid var(--line-strong);border-radius:6px;background:var(--surface-subtle);color:var(--ink)}.member-browser-toolbar select{height:34px;max-width:12rem;padding:0 .55rem;border:1px solid var(--line-strong);border-radius:6px;background:var(--surface-subtle);color:var(--ink)}.member-filter-status{margin:.4rem 0;color:var(--muted);font-size:.82rem}.declaration-summary[hidden]{display:none}.reference-context{max-width:1600px;margin:0 auto;padding:.45rem 1.25rem;display:flex;align-items:center;gap:.9rem;flex-wrap:wrap;border-bottom:1px solid var(--line);background:var(--surface-subtle);color:var(--muted);font-size:.73rem}.reference-context span{display:inline-flex;gap:.3rem;min-width:0}.reference-context strong{color:var(--ink);font-weight:680}.member-overload-group{margin:.6rem 0 1rem;padding:.5rem .75rem;border:0;border-left:0;border-radius:0;background:var(--surface-subtle)}
.member-overload-group .overload-group-label{display:flex;flex-wrap:wrap;align-items:baseline;gap:.6rem;margin:.1rem 0 .35rem;padding:.12rem .2rem .3rem;color:var(--ink);font-size:.88rem;font-weight:650}
.member-overload-group .overload-group-label code{color:var(--ink);font-size:inherit}
.member-overload-group .overload-count{color:var(--muted);font-size:.76rem;font-weight:600}
.member-overload-group .member-detail{margin:0;border-color:var(--line)}
.member-overload-group .member-row:first-of-type>.member-detail{border-top:1px solid var(--line)}
.member-overload-group .member-row:last-child>.member-detail{border-bottom:0}
.member-overload-group .member-detail>summary{padding:.55rem .35rem}
.member-overload-group .member-detail[open]>summary{background:var(--surface)}.behavior-contracts{margin:1.15rem 0;padding:.8rem 0;border-top:1px solid var(--line)}.behavior-contracts h3{margin:.05rem 0 .6rem;font-size:1rem}.behavior-contracts dl{display:grid;grid-template-columns:minmax(9rem,max-content) minmax(0,1fr);gap:.4rem .9rem;margin:0}.behavior-contracts dt{font:650 .78rem/1.5 var(--code-font);overflow-wrap:anywhere}.behavior-contracts dd{margin:0;min-width:0}.behavior-contracts dd .badge{font-size:.72rem}.signature-context{margin:.35rem 0 .9rem;color:var(--muted);font-size:.78rem}.signature-context .badge{margin-left:.35rem}.parameter-default{margin-left:.35rem;color:var(--muted);font-size:var(--code-size)}.conceptual-bindings{margin:2rem 0;padding:1rem 0;border-top:1px solid var(--line)}.conceptual-bindings h2{margin:.1rem 0 .6rem}.binding-scope{color:var(--muted);font-size:.82rem}.conceptual-bindings ul{margin:.6rem 0 0;padding-left:1.3rem}.conceptual-bindings li{padding:.25rem 0;overflow-wrap:anywhere}.binding-state{display:inline-block;margin-right:.35rem;color:var(--muted);font-size:.75rem}.binding-meta{display:block;margin-left:0;color:var(--muted);font-size:.75rem;overflow-wrap:anywhere;word-break:break-word}
.binding-version{margin-left:.4rem;color:var(--muted);font-size:.75rem}
.binding-details{margin:.25rem 0 0;color:var(--muted);font-size:.75rem}
.binding-details>summary{cursor:pointer;padding:.1rem 0}
.binding-details[open]>summary{margin-bottom:.2rem}.external-documentation{margin:1.15rem 0;padding:.8rem 0;border-top:1px solid var(--line)}.external-documentation h2{margin:.05rem 0 .6rem;font-size:1rem}.external-documentation ul{margin:.4rem 0;padding-left:1.3rem}.validation-page{max-width:1100px}.validation-page table{width:100%;border-collapse:collapse}.validation-page th,.validation-page td{padding:.45rem .55rem;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}.validation-message{color:var(--muted);font-size:.8rem}
@media(max-width:760px){.reference-context{padding:.45rem .9rem;gap:.45rem .7rem}.reference-context span{font-size:.68rem}}@media(max-width:760px){.member-browser-toolbar{align-items:stretch;flex-direction:column}.member-browser-toolbar input,.member-browser-toolbar select{min-width:0;max-width:none;width:100%}}
.reference-build-details{margin-left:auto}.reference-build-details>summary{cursor:pointer;color:var(--muted);font-weight:650}.reference-build-details>div{display:flex;gap:.65rem .9rem;flex-wrap:wrap;margin-top:.4rem}
.member-group{margin:var(--api-section-gap) 0}.member-group-heading{display:flex;align-items:baseline;gap:1rem;margin:1.4rem 0 .5rem;padding-bottom:.5rem;border-bottom:1px solid var(--line)}
.member-group-heading>h2{margin:0;padding:0;border:0;font-size:1.2rem;line-height:1.5}
.member-group-count{margin-left:auto;color:var(--muted);font-size:.8125rem;white-space:nowrap}.member-detail{border-bottom:1px solid var(--line);scroll-margin-top:5.5rem}.member-detail:first-of-type{border-top:1px solid var(--line)}.member-detail>summary{list-style:none;cursor:pointer;padding:var(--api-row-padding) .35rem;display:grid;grid-template-columns:.8rem minmax(0,1fr) auto;gap:.18rem .75rem;align-items:baseline;border-radius:6px;column-gap:.55rem}.member-detail>summary::-webkit-details-marker{display:none}.member-detail>summary:hover,.member-detail>summary:focus-visible{background:var(--surface-subtle)}.member-detail[open]>summary{background:var(--surface-subtle)}.member-summary-main{min-width:0;display:flex;flex-direction:column;gap:.2rem;grid-column:2;grid-row:1}.member-detail .declaration-signature{display:block;max-width:100%;overflow:visible;text-overflow:clip;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--ink);font:500 var(--code-size)/1.7 var(--code-font);font-size:var(--code-size)}.member-summary-description{grid-column:2/-1;color:var(--muted);font-size:var(--summary-size);line-height:1.75}.member-detail-body{padding-block:.65rem 1rem;padding-inline:var(--member-content-inset) var(--member-pad-start);border-inline-start:0}.member-detail-body p{display:block;-webkit-line-clamp:unset;overflow:visible}.member-permalink{font-size:.78rem}.compact-signature{margin:.45rem 0 .85rem;padding:.75rem 2.8rem .75rem .8rem}.member-group[hidden]{display:none}.member-origin,.extension-conditions{margin:.35rem 0;color:var(--muted);font-size:.8rem}.extension-signature{margin:.35rem 0 .6rem}.context-links{display:grid;gap:.08rem}.context-item{display:block;padding:.28rem .45rem;border-radius:5px;color:var(--muted);text-decoration:none;overflow-wrap:anywhere}.context-item:hover,.context-item:focus-visible{background:var(--surface-subtle);color:var(--ink);text-decoration:none}.context-item.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:650}.context-item code{padding:0;border:0;background:transparent;color:inherit;font-size:.78rem}.sidebar-context{padding-bottom:.25rem}.sidebar-limit{margin:.45rem .25rem;color:var(--muted);font-size:.75rem}
@media(max-width:760px){.reference-build-details{width:100%;margin-left:0}.reference-build-details>div{display:grid;grid-template-columns:1fr}.member-detail>summary{grid-template-columns:var(--member-chevron-width) minmax(0,1fr) auto;padding-block:.55rem;padding-inline-start:var(--member-pad-start);column-gap:var(--member-chevron-gap)}.member-detail-body{padding-block:.65rem 1rem;padding-inline:var(--member-content-inset) var(--member-pad-start);border-inline-start:0}.symbol-meta,.contextual-metadata,.member-browser,.symbol-relationships dl,.behavior-contracts dl{grid-template-columns:minmax(0,1fr)}.symbol-relationships dt,.symbol-relationships dd,.symbol-relationships code,.reverse-type-usages code,.member-origin code,.extension-signature code{min-width:0;max-width:100%;white-space:normal;overflow-wrap:anywhere;word-break:break-word}}
/* Only large member browsers defer idle closed rows. Small groups and no-JS
   retain ordinary layout; expanded contracts always retain complete rendered
   text and geometry. Unsupported selectors and print keep full layout. */
@media screen{
.member-browser.member-browser-large .member-row:not(:focus-within):not(.member-actions-open):has(>.member-detail:not([open])){content-visibility:auto;contain-intrinsic-size:auto 8rem}
}
"""

internal let HTML_EXAMPLE_STYLE = """
.example-list{display:grid;gap:1rem;margin:1rem 0 1.25rem}.example-block{min-width:0;padding:.2rem 0;border:0;border-radius:0;background:transparent}.example-title{margin:0 0 .65rem;color:var(--ink);font-size:var(--summary-size);letter-spacing:0}.example-block pre{margin:.75rem 0 0;background:var(--surface)}.example-block p:first-child{margin-top:0}.example-block p:last-child{margin-bottom:0}
"""

internal let HTML_REFERENCE_BROWSER_STYLE = """
.theme-control{position:relative}.theme-toggle{min-height:36px;padding:0 .75rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted);font-size:.78rem}.theme-toggle:hover{border-color:var(--accent);color:var(--ink)}.theme-popover{position:absolute;z-index:50;top:calc(100% + .45rem);right:0;min-width:13rem;padding:.55rem;border:1px solid var(--line-strong);border-radius:8px;background:var(--surface-raised);box-shadow:var(--shadow)}.theme-options{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.3rem}.theme-options button{min-height:32px;border:1px solid transparent;border-radius:5px;background:transparent;color:var(--muted);font-size:.76rem}.theme-options button:hover,.theme-options button[aria-pressed=\"true\"]{border-color:var(--accent);background:var(--accent-soft);color:var(--ink)}.theme-popover details{margin-top:.45rem;border-top:1px solid var(--line);padding-top:.45rem}.theme-popover summary{cursor:pointer;color:var(--muted);font-size:.76rem}.search-tabs{display:flex;gap:.25rem;align-items:center}.search-tabs button{min-height:32px;padding:0 .55rem;border:1px solid transparent;border-radius:5px;background:transparent;color:var(--muted);font-size:.76rem}.search-tabs button:hover,.search-tabs button[aria-pressed=\"true\"]{border-color:var(--accent);background:var(--accent-soft);color:var(--ink)}.search-status{margin:.35rem 0 0;color:var(--muted);font-size:.78rem}
.declaration-summary.declaration-row{position:relative;isolation:isolate;display:flex;flex-wrap:wrap;align-items:baseline;gap:.12rem .7rem;min-width:0;min-height:2.75rem;padding:.45rem .5rem}
.declaration-row:hover{background:var(--accent-soft)}
.declaration-row:active{background:var(--surface-subtle)}
.declaration-row-link{min-width:0;max-width:100%;color:var(--accent);text-decoration:none}
.declaration-row-link::after{content:"";position:absolute;inset:0;border-radius:5px}
.declaration-row-link:hover{text-decoration:none}
.declaration-row-link:focus-visible{outline:none}
.declaration-row-link:focus-visible::after{outline:2px solid var(--accent);outline-offset:2px}
.declaration-summary-head{display:flex;align-items:baseline;gap:.65rem;min-width:0}
.declaration-summary-head code{min-width:0;padding:0;border:0;background:transparent;color:inherit;font:650 .85rem/1.45 var(--code-font);white-space:pre-wrap;overflow-wrap:anywhere}
.declaration-summary-head .declaration-kind{flex-shrink:0}
.declaration-row>.declaration-signature{flex:1 1 24rem;min-width:0;max-width:100%;margin:0;padding:0;border:0;background:transparent;color:var(--muted);font:500 var(--code-size)/1.7 var(--code-font);white-space:pre-wrap;overflow:visible;overflow-wrap:anywhere;text-overflow:clip}
.declaration-row .type-link{position:relative;z-index:1}
.declaration-row>.declaration-description{flex:1 0 100%;min-width:0;max-width:none;margin:0;color:var(--muted);font-size:var(--summary-size);line-height:1.75;overflow-wrap:anywhere;display:block;-webkit-line-clamp:unset;-webkit-box-orient:initial;overflow:visible}
.sidebar-close{display:none}@media(max-width:760px){.sidebar-close{display:inline-flex}}.sidebar-no-results{margin:.6rem .25rem;color:var(--muted);font-size:.78rem}.source-action{margin:.75rem 0 0}.source-action a{display:inline-flex;align-items:center;min-height:32px;padding:0 .65rem;border:1px solid var(--line-strong);border-radius:6px;font-size:.8rem}.source-action a:hover{background:var(--accent-soft);text-decoration:none}
.cjdoc-version-selector{max-width:1600px;margin:0 auto;padding:.55rem 1.25rem;display:flex;align-items:center;gap:.55rem;flex-wrap:wrap;border-bottom:1px solid var(--line);background:var(--surface-subtle);color:var(--muted);font-size:.78rem}.cjdoc-version-selector>span{font:700 .68rem/1.2 var(--code-font);letter-spacing:.08em;text-transform:uppercase}.cjdoc-version-selector a{padding:.2rem .45rem;border-radius:4px;color:var(--muted);text-decoration:none}.cjdoc-version-selector a:hover,.cjdoc-version-selector a:focus-visible{color:var(--ink);background:var(--accent-soft)}.cjdoc-version-selector a[aria-current=page]{color:var(--accent);font-weight:750;background:var(--accent-soft)}
.nav-menu{display:none;min-width:38px;width:auto;height:38px;padding:0 .5rem;white-space:nowrap;place-items:center;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--ink)}
.nav-backdrop{display:none}
.sidebar-filter-label{display:block;margin:.35rem .25rem .7rem}.sidebar-filter{width:100%;height:34px;padding:0 .55rem;border:1px solid var(--line-strong);border-radius:6px;background:var(--surface-subtle);color:var(--ink);font-size:.78rem}
.symbol-kind{margin:.5rem 0;color:var(--faint);font:650 .76rem/1.4 ui-monospace,monospace;text-transform:lowercase}.symbol-summary{max-width:68ch;margin:.75rem 0 1.2rem;color:var(--muted);font-size:1.03rem}.contextual-metadata{margin:1rem 0;padding:.65rem .8rem;border:1px solid var(--line);border-radius:7px;color:var(--muted)}.contextual-metadata>summary{cursor:pointer;color:var(--muted);font-size:.8rem;font-weight:650}.signature-block{white-space:pre;overflow-x:auto;overflow-wrap:normal}.declaration-group{margin:1.8rem 0}.declaration-group>h2,.declaration-group>h3{padding-bottom:.55rem;border-bottom:1px solid var(--line)}.declaration-list{display:grid}.declaration-list>.declaration-row:first-child{border-top:0;padding-top:.55rem}.section-anchor-alias{display:block;height:0}.declaration-summary{margin:0;padding:.48rem .15rem}.declaration-kind{color:var(--faint);font:600 .72rem ui-monospace,monospace}.declaration-signature{display:block;max-width:100%;overflow:visible;text-overflow:clip;white-space:pre-wrap;color:var(--muted);font-size:var(--code-size);overflow-wrap:anywhere}.search-result-head{display:flex;justify-content:space-between;gap:1rem}.search-result-name{min-width:0;overflow:hidden;text-overflow:ellipsis}.search-context,.search-summary{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted);font-size:.76rem}.search-summary{margin-top:.18rem;color:var(--faint)}
@media(max-width:760px){.nav-menu{display:grid;order:-1}.nav-backdrop{position:fixed;z-index:35;inset:0;display:block;width:100%;height:100%;border:0;background:rgb(0 0 0/.38);cursor:default}.nav-backdrop[hidden]{display:none}.nav-is-open{overflow:hidden}.brand{margin-right:auto;min-width:0;max-width:18rem;font-size:1rem}.docs-sidebar{display:none;position:fixed;z-index:40;inset:0 auto 0 0;width:min(86vw,20rem);height:100vh;max-height:none;padding:1.2rem;overflow:auto;border-right:1px solid var(--line-strong);box-shadow:var(--shadow)}.docs-sidebar.is-open{display:block}.sidebar-section{display:block}.sidebar-section+.sidebar-section{margin-top:1.5rem}.sidebar-link{display:flex}.sidebar-packages{display:block;max-height:none}.signature-block{white-space:pre-wrap;overflow-wrap:break-word}.declaration-summary-head{align-items:flex-start}.site-search{order:4}.top-actions{margin-left:auto}}
.theme-toggle{width:auto;height:auto;min-width:36px;min-height:36px;display:inline-flex;align-items:center;justify-content:center;white-space:nowrap}
.theme-toggle{width:auto;height:auto;min-width:36px;min-height:36px;display:inline-flex;align-items:center;justify-content:center;white-space:nowrap}.search-filter-toggle{display:inline-flex;align-items:center;justify-content:center;min-height:36px;padding:0 .7rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted);font-size:.78rem}.search-filter-toggle:hover{border-color:var(--accent);color:var(--ink)}.search-result-signature{display:block;margin-top:.2rem;color:var(--ink);font:500 var(--code-size)/1.6 var(--code-font);overflow-wrap:anywhere}.search-status-note{margin:.35rem .4rem;color:var(--muted);font-size:.78rem}.mobile-toc{display:none;margin:0 0 1.4rem;padding:.7rem .85rem;border:1px solid var(--line);border-radius:8px;background:var(--surface-subtle)}.mobile-toc summary{cursor:pointer;color:var(--ink);font-weight:650}.mobile-toc nav{margin-top:.6rem}.mobile-toc ol{margin:0;padding-left:1.15rem}.mobile-toc a{color:var(--muted);font-size:.84rem}.build-details{margin-top:2.4rem;padding:.8rem 1rem;border:1px solid var(--line);border-radius:8px;background:var(--surface-subtle)}.build-details summary{cursor:pointer;color:var(--muted);font-weight:650}.build-details .diagnostics{margin-bottom:0}
@media(max-width:1180px){.toc-panel{display:none}.mobile-toc:not([hidden]){display:block}.docs-main{min-width:0}.search-filter-toggle{display:inline-flex}}
@media(max-width:760px){.docs-layout{display:flex;flex-direction:column}.docs-sidebar{order:0}.mobile-toc{order:0}.docs-main{order:1;display:block}.toc-panel{order:2;display:none}.site-nav-inner{grid-template-columns:minmax(9rem,auto) minmax(0,1fr) auto;gap:1rem;padding:.75rem 1.25rem}.site-search{grid-column:1/-1;grid-row:2}.search-filter-toggle{flex:0 0 auto}.search-filters{left:0;right:auto;max-width:calc(100vw - 1.6rem)}}
@media(max-width:760px){.site-nav-inner{min-width:0;grid-template-columns:minmax(9rem,auto) minmax(0,1fr) auto;gap:1rem;padding:.75rem 1.25rem}.brand{min-width:0;max-width:18rem;font-size:1rem}.brand-copy{min-width:0}.brand-subtitle{max-width:11rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.top-actions{min-width:0}.version-label{display:none}.docs-main,.content-column{width:100%;min-width:0}.site-search{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:start;gap:.55rem}.search-area{grid-column:1;min-width:0}.search-filter-toggle{grid-column:2}.top-actions{grid-column:1/-1;justify-content:flex-end}}
@media(max-width:760px){.search-shell kbd{display:none}}
@media(max-width:760px){.theme-popover{position:fixed;top:4.1rem;right:.8rem;left:auto;min-width:0;width:13rem;max-width:calc(100vw - 1.6rem)}}
.toc-panel[hidden],.mobile-toc[hidden]{display:none}
/* A component's display layout must never override its hidden state. */
[hidden]{display:none!important}
:root{--cjdoc-header-height:64px}
.docs-main [id],.docs-main{scroll-margin-top:calc(var(--cjdoc-header-height,64px) + 1rem)}
.docs-sidebar,.toc-panel{top:var(--cjdoc-header-height,64px);height:calc(100vh - var(--cjdoc-header-height,64px))}
.skip-link{position:fixed;top:.5rem;left:.75rem;z-index:100;padding:.65rem 1rem;border:2px solid var(--accent);border-radius:6px;background:var(--surface);color:var(--ink);transform:translateY(-180%)}
.skip-link:focus{transform:translateY(0);outline:2px solid var(--ink);outline-offset:2px}
.brand-copy{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.brand{min-width:0;max-width:18rem;font-size:1rem}
.api-title-row{display:flex;align-items:center;gap:.75rem;flex-wrap:wrap}.api-title-row h1{margin:0;min-width:0}.copy-link{min-height:30px;padding:.25rem .5rem;border:1px solid var(--line);border-radius:5px;background:var(--surface);color:var(--muted);font-size:.76rem}.copy-link:hover{color:var(--accent);border-color:var(--accent)}.copy-link:focus-visible{outline:2px solid var(--accent);outline-offset:2px}.copy-link[data-copied="true"]{color:var(--success)}
.api-page-header{margin-bottom:1.5rem}
.api-extension-header .api-title-row h1{font-size:clamp(1.65rem,2.7vw,2.45rem);line-height:1.25}
.symbol-relationships .relation-target{text-decoration:underline;text-decoration-color:var(--line-strong);text-underline-offset:.16em}
.symbol-relationships .relation-target:hover,.symbol-relationships .relation-target:focus-visible{text-decoration-color:currentColor;outline-offset:2px}.api-page-header .symbol-kind{margin:.3rem 0;font-size:.8rem}.api-page-header .symbol-summary{margin:.5rem 0 .75rem}.api-page-header .signature-block{margin:.65rem 0;padding:.8rem 3rem .8rem .85rem;line-height:1.55}.api-page-header .source-action{margin:.4rem 0}
.member-detail>summary{grid-template-columns:var(--member-chevron-width) minmax(0,1fr) auto;align-items:baseline;column-gap:var(--member-chevron-gap);padding-inline-start:var(--member-pad-start)}
.member-detail>summary:before{content:"";grid-column:1;grid-row:1;align-self:start;width:.4rem;height:.4rem;margin:.35rem 0 0 .05rem;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:rotate(-45deg)}
.member-detail[open]>summary:before{transform:rotate(45deg)}
.member-summary-main{grid-column:2;grid-row:1;display:flex;flex-direction:column;gap:.2rem;min-width:0}.member-detail-summary>.declaration-kind{grid-column:3;grid-row:1}.member-summary-description{grid-column:2/-1;font-size:var(--summary-size);line-height:1.75}
.member-detail-body{padding-block:.65rem 1rem;padding-inline:var(--member-content-inset) var(--member-pad-start);border-inline-start:0}.member-detail-body h3{margin:.9rem 0 .4rem;font-size:.92rem}.member-detail-actions{gap:1rem;flex-wrap:wrap;justify-content:flex-start;margin:.1rem 0 .65rem;font-size:.78rem}.member-detail-body .parameter-list{margin:.4rem 0 .75rem}.member-detail-body .return-value{margin:.4rem 0 .75rem}.member-detail-body .behavior-contracts{margin:.8rem 0;padding:.55rem 0}.member-detail-body .example-list{margin:.4rem 0 .8rem;gap:.6rem}.member-detail-body .example-block{padding:.6rem .8rem}.member-detail-body .example-block pre{margin:.5rem 0;padding:.7rem 3rem .7rem .8rem;line-height:1.5}.member-detail-body .example-block>:last-child{margin-bottom:0}
.reverse-type-usages{margin:.6rem 0;padding:0;border:0;color:var(--muted);font-size:.8rem}.reverse-type-usages>summary{cursor:pointer;padding:.4rem 0}.symbol-relationships .relation-note{margin-left:.45rem;color:var(--muted);font-size:.8rem}.reference-state{font-family:inherit;font-weight:500}.badge.reference-state[data-state]{border-color:var(--line);color:var(--muted)}
.member-browser-actions{display:flex;gap:.35rem}.member-browser-actions button{min-height:34px;padding:.25rem .55rem;border:1px solid var(--line-strong);border-radius:5px;background:var(--surface);color:var(--muted);font-size:.78rem}.member-browser-actions button:hover:not(:disabled){border-color:var(--accent);color:var(--accent)}.member-browser-actions button:disabled{opacity:.5;cursor:default}
.parameter-row dt{overflow-wrap:anywhere}.parameter-description:empty{padding:0}.parameter-row .parameter-type-code{border:0;padding:0;background:transparent}
.code-keyword{color:var(--code-keyword)}.code-type{color:var(--code-type)}.code-string{color:var(--code-string)}.code-number{color:var(--code-number)}.code-literal{color:var(--code-literal)}.code-comment{color:var(--code-comment)}.code-operator{color:var(--code-operator)}.code-punctuation{color:var(--code-punctuation)}.code-function{color:var(--code-function)}.code-property{color:var(--code-property)}.code-meta{color:var(--code-meta)}
@media(max-width:760px){:root{--cjdoc-header-height:128px}.docs-sidebar{top:0;height:100dvh}.member-detail-summary>.declaration-kind{grid-column:2;grid-row:2;justify-self:start}.member-browser-toolbar input{min-width:8rem}.api-page-header{margin-bottom:.8rem}}
/* Contract reading: put the API name and its explanation in the same row. */
.throws-list{display:block;margin:.45rem 0 .85rem;padding:0}
.throws-row{display:grid;grid-template-columns:fit-content(14rem) minmax(0,1fr);gap:.75rem;padding:.55rem 0;border-bottom:1px solid var(--line)}
.throws-row:last-child{border-bottom:0}
.throws-list + .behavior-contracts{border-top:0;margin-top:.25rem;padding-top:.15rem}
.throws-row dt,.throws-row dd{margin:0;min-width:0;overflow-wrap:anywhere}
.throws-row dd>:first-child{margin-top:0}
.throws-row dd>:last-child{margin-bottom:0}
.reference-state-note{display:inline-block;margin-left:.25rem;color:var(--muted);font-size:.75rem}


@media(max-width:760px){.throws-row{grid-template-columns:minmax(0,1fr);gap:.15rem}.throws-row dd{padding-bottom:.1rem}.member-overload-group{padding:.5rem .75rem;border:0;border-radius:0;background:var(--surface-subtle)}}

/* Native details owns only expansion. Sibling actions stay reachable even
   when the member is closed; reserve their width without shifting signatures. */
.member-row{--member-pad-start:.35rem;--member-chevron-width:.8rem;--member-chevron-gap:.55rem;--member-content-inset:calc(var(--member-pad-start) + var(--member-chevron-width) + var(--member-chevron-gap));position:relative;min-width:0;margin:0}
.member-row[hidden]{display:none}
.member-row>.member-detail{margin:0;border-top:0}
.member-group>.member-row:first-of-type>.member-detail{border-top:0}
.member-overload-group>.member-row{margin:0}
.member-row>.member-detail>summary{min-height:3.35rem;padding-inline-end:8.5rem}
.member-row>.member-static>.member-detail-summary{display:grid;grid-template-columns:var(--member-chevron-width) minmax(0,1fr) auto;column-gap:var(--member-chevron-gap);align-items:baseline;min-height:3.35rem;padding-block:.65rem;padding-inline-start:var(--member-pad-start);padding-inline-end:8.5rem;border-radius:6px}
.member-row>.member-static>.member-detail-summary:before{content:"";grid-column:1;grid-row:1}
.member-row>.member-static>.member-detail-summary:hover{background:var(--surface-subtle)}
.member-row:focus-within,.member-row.member-actions-open{z-index:3}
.member-row>.member-detail-actions{
    position:absolute;inset-block-start:.5rem;inset-inline-end:.3rem;
    display:flex;align-items:center;width:max-content;max-width:100%;
    margin:0;padding:.12rem;border:1px solid var(--line);border-radius:8px;
    background:var(--surface);opacity:0;pointer-events:none
}
.member-row:hover>.member-detail-actions,
.member-row:focus-within>.member-detail-actions{
    opacity:1;pointer-events:auto
}
.member-detail-actions .member-actions-toggle{display:none}
.member-detail-actions .member-action-list{display:flex;align-items:center;gap:.12rem}
.member-detail-actions .member-action{
    display:inline-flex;align-items:center;justify-content:center;
    flex:0 0 38px;width:38px;height:38px;min-width:38px;min-height:38px;
    margin:0;padding:0;border:1px solid transparent;border-radius:6px;
    background:transparent;color:var(--muted);line-height:1;
    text-decoration:none;cursor:pointer
}
/* See-also is a readable link list, not a stack of code badges. */
.see-also-list{display:grid;gap:.35rem;margin:.4rem 0 1rem;padding:0;list-style:none}
.see-also-list li{min-width:0;margin:0;padding:.15rem 0;overflow-wrap:anywhere}
.see-also-list code{padding:0;border:0;border-radius:0;background:transparent;font-size:var(--code-size);white-space:normal;overflow-wrap:anywhere}
.see-also-list a{text-underline-offset:.17em}
.member-detail-actions .member-action:hover{
    background:var(--surface-subtle);color:var(--accent);text-decoration:none
}
.member-detail-actions .member-action:focus-visible,
.member-detail-actions .member-actions-toggle:focus-visible{
    outline:2px solid var(--accent);outline-offset:1px
}
.member-detail-actions .member-action-glyph{
    display:block;width:18px;height:18px;flex:none;pointer-events:none
}
.member-detail-actions .member-action-label{display:none}
.member-detail-actions .copy-link[data-copied="true"]{
    color:var(--success);background:var(--surface-subtle)
}
.member-detail-actions [data-cjdoc-copy-link-fallback]{
    flex:1 0 100%;min-width:0;max-width:100%;width:100%;margin:0;
    padding:.4rem;border:0;border-top:1px solid var(--line);
    background:var(--surface);color:var(--ink)
}
/* Without JavaScript, touch-sized views show the native links in normal flow.
   The compact disclosure is an enhancement installed after its listeners exist. */
@media (hover:none), (pointer:coarse), (any-pointer:coarse), (max-width:760px){
    .member-row>.member-detail>summary{padding-inline-end:.35rem}
    .member-row>.member-detail-actions{
        position:static;inset:auto;align-items:center;width:100%;max-width:100%;
        margin:.15rem 0 .35rem;padding:0;border:0;border-radius:0;
        background:transparent;opacity:1;pointer-events:auto
    }
    .member-detail-actions .member-action-list{
        display:flex;position:static;inset:auto;flex-direction:row;
        align-items:center;flex-wrap:wrap;gap:.25rem;
        width:100%;min-width:0;max-width:100%;margin:0;padding:0;
        border:0;border-radius:0;background:transparent;box-shadow:none
    }
    .member-detail-actions .member-action-list .member-action{
        justify-content:flex-start;gap:.4rem;flex:0 1 auto;
        width:auto;min-width:40px;min-height:40px;height:auto;
        padding:.4rem .55rem;font-size:.82rem;line-height:1.4;text-align:start
    }
    .member-detail-actions .member-action-label{display:inline;white-space:normal}
    .member-row.member-actions-enhanced>.member-detail>summary{padding-inline-end:3.25rem}
    .member-row.member-actions-enhanced>.member-detail-actions{
        position:absolute;inset-block-start:.25rem;inset-inline-end:.2rem;
        width:max-content;max-width:100%;margin:0;padding:0;
        border:0;border-radius:7px;background:transparent
    }
    .member-row.member-actions-enhanced .member-actions-toggle{
        display:inline-flex;align-items:center;justify-content:center;
        width:40px;height:40px;min-width:40px;margin:0;
        border:1px solid var(--line);border-radius:7px;
        background:var(--surface);color:var(--muted);cursor:pointer
    }
    .member-row.member-actions-enhanced .member-actions-toggle:hover,
    .member-row.member-actions-enhanced .member-actions-toggle[aria-expanded="true"]{
        background:var(--surface-subtle);color:var(--accent)
    }
    .member-row.member-actions-enhanced .member-action-list{
        display:none;position:absolute;inset-block-start:calc(100% + .3rem);
        inset-inline-end:0;z-index:5;align-items:stretch;flex-direction:column;
        flex-wrap:nowrap;gap:.1rem;
        /* Subtract mobile main padding and the trigger's right inset at 200% zoom. */
        min-width:min(12rem,calc(100vw - 2.25rem));
        max-width:min(18rem,calc(100vw - 2.25rem));
        padding:.25rem;border:1px solid var(--line-strong);border-radius:8px;
        background:var(--surface);box-shadow:var(--shadow)
    }
    .member-row.member-actions-enhanced .member-detail-actions[data-open="true"] .member-action-list{
        display:flex
    }
    .member-row.member-actions-enhanced .member-action-list .member-action{
        justify-content:flex-start;gap:.6rem;flex:0 0 auto;
        width:100%;min-height:40px;height:auto;padding:.5rem .6rem;
        font-size:.82rem;line-height:1.4;text-align:start
    }
}
/* A single documented contract does not need a redundant classification
   table beneath its concrete condition heading. */
.behavior-contracts .behavior-contract-single>:first-child{margin-top:0}
.behavior-contracts .behavior-contract-single>:last-child{margin-bottom:0}


/* Theme selection names the active preset rather than implying a binary toggle. */
.theme-control{position:relative}
.theme-control .theme-toggle{display:inline-flex;align-items:center;gap:.45rem;
  width:auto;min-width:36px;height:36px;margin:0;padding:0 .7rem;
  color:var(--ink);font-weight:650}
.theme-palette-icon{flex:0 0 auto;color:var(--muted)}
.theme-trigger-label{font-size:.78rem}
.theme-chevron{margin-left:.35rem;color:var(--muted)}
.theme-backdrop{display:none}
.theme-popover{position:absolute;z-index:50;top:calc(100% + .45rem);right:0;
  width:17.5rem;min-width:0;max-width:calc(100vw - 1.6rem);
  padding:.75rem;background:var(--surface-raised);border:1px solid var(--line-strong);
  border-radius:8px;box-shadow:var(--shadow);white-space:normal}
.theme-popover-header{display:flex;align-items:center;justify-content:space-between;gap:.7rem;
  padding:0 .25rem .2rem;color:var(--ink);font-size:.87rem}
.theme-popover-close{display:none;width:32px;height:32px;border:0;border-radius:50%;
  background:var(--surface-subtle);color:var(--muted);font-size:1.3rem}
.theme-section-title{margin:.3rem .25rem;color:var(--faint);font-size:.7rem;font-weight:700}
.theme-presets-title{margin-top:.55rem;padding-top:.65rem;border-top:1px solid var(--line)}
.theme-popover .theme-option{display:flex;align-items:center;gap:.6rem;width:100%;min-height:36px;
  padding:.45rem .65rem;border:1px solid transparent;border-radius:5px;
  background:transparent;color:var(--ink);font-size:.8rem;text-align:left}
.theme-option:before{content:'';width:16px;height:16px;flex:0 0 16px;
  border:1px solid var(--line-strong);border-radius:5px;background:var(--surface)}
.theme-option[data-cjdoc-theme-value='system']:before{background:#dfe6ef}
.theme-option[data-cjdoc-theme-value='light']:before{background:#fff}
.theme-option[data-cjdoc-theme-value='dark']:before{background:#10141b}
.theme-option[data-cjdoc-theme-value='paper']:before{background:#f7f2e8}
.theme-option[data-cjdoc-theme-value='ocean']:before{background:#07111f}
.theme-option[data-cjdoc-theme-value='forest']:before{background:#f1f5ef}
.theme-option[data-cjdoc-theme-value='terminal']:before{background:#07100b}
.theme-option[data-cjdoc-theme-value='violet']:before{background:#f6f3fb}
.theme-option[aria-pressed='true'],.theme-option:hover{background:var(--accent-soft);color:var(--accent)}
.theme-option[aria-pressed='true']:after{content:'✓';margin-left:auto;font-weight:750}
.theme-help{margin:.6rem .25rem .1rem;color:var(--faint);font-size:.7rem}
@media(max-width:760px){
  .theme-control .theme-trigger-label{display:none}
  .theme-control .theme-toggle{padding:0 .45rem}
  .theme-chevron{margin-left:0}
  .theme-backdrop:not([hidden]){display:block;position:fixed;z-index:49;inset:0;
    width:100%;height:100%;border:0;border-radius:0;background:rgb(0 0 0 / .38)}
  .theme-popover{position:fixed;z-index:50;top:auto;bottom:0;left:0;right:0;
    width:100%;max-width:none;max-height:calc(100dvh - 2rem);overflow-y:auto;
    padding:1rem .9rem max(1rem,env(safe-area-inset-bottom));
    border-radius:14px 14px 0 0}
  .theme-popover:before{content:'';display:block;width:36px;height:4px;
    margin:-.45rem auto .7rem;background:var(--line-strong);border-radius:3px}
  .theme-popover-close{display:inline-grid;place-items:center}
  html.theme-is-open{overflow:hidden}
}


/* A package and its visible symbol tree are one filterable navigation entry. */
.sidebar-symbols{margin:.15rem 0 .5rem;padding-left:.6rem;border-left:1px solid var(--line)}
.sidebar-symbol{display:flex;align-items:baseline;gap:.5rem;padding:.3rem .5rem;color:var(--muted);text-decoration:none;border-radius:4px;min-width:0}
.sidebar-symbol:hover,.sidebar-symbol:focus-visible{background:var(--surface-subtle);color:var(--ink)}
.sidebar-symbol.is-current{background:var(--accent-soft);color:var(--accent-strong)}
.sidebar-symbol-name{min-width:0;overflow-wrap:anywhere;font:500 .8125rem/1.6 var(--code-font)}
.sidebar-symbol-kind{margin-left:auto;flex-shrink:0;font-size:.7rem}

.sidebar-package-entry{min-width:0}
.sidebar-package-entry[hidden]{display:none}
.sidebar-symbol-more{display:block;margin:.4rem 0 .2rem;padding:.4rem .55rem;
  color:var(--accent);font-size:.75rem;text-decoration:none}
.sidebar-symbol-more:hover{text-decoration:underline}


/* Reading roles share tokens; narrative pages use a controlled measure. */
body[data-cjdoc-page='home'] .content-column{max-width:60rem}
body[data-cjdoc-page='guide'] .content-column{max-width:var(--reading-width)}
.home-header h1,.narrative-header h1{font-family:var(--reading-title-font);font-size:clamp(1.9rem,3.5vw,2.65rem);font-weight:650;line-height:1.35;letter-spacing:0}
.prose{font-size:var(--prose-size);line-height:1.9;overflow-wrap:anywhere}
.prose>p{margin:var(--space-paragraph) 0}
.prose>p:first-of-type{margin-top:0}
.prose h2{margin:var(--space-section) 0 .8rem;padding:0;border:0;font-size:1.45rem;line-height:1.4}
.prose h3{margin:2rem 0 .65rem;font-size:1.15rem;line-height:1.5}
.prose pre{margin:var(--space-code) 0;font-size:var(--code-size);line-height:1.75}
.prose li{margin-block:.35rem}
.prose img{display:block;max-width:100%;height:auto}
.prose table{display:block;max-width:100%;overflow-x:auto;border-collapse:collapse}
.prose th,.prose td{padding:.6rem .75rem;border:1px solid var(--line);text-align:start;vertical-align:top}
.prose blockquote{margin:1.5rem 0;padding:.5rem 1rem;border-inline-start:1px solid var(--accent);background:var(--surface-subtle)}
.prose blockquote>:first-child{margin-top:0}.prose blockquote>:last-child{margin-bottom:0}
.home-introduction{max-width:var(--reading-width);margin:0 0 2rem}
.reading-paths{margin:2rem 0;padding:0 0 1.25rem;border-bottom:1px solid var(--line)}
.reading-paths h2{margin:0 0 .65rem;padding:0;border:0;font-size:1.15rem}
.reading-paths ul{display:flex;flex-wrap:wrap;gap:.5rem 1.5rem;margin:0;padding:0;list-style:none}
.reading-paths li{margin:0;min-width:0;overflow-wrap:anywhere}
.project-metadata,.page-source{margin:1.75rem 0;color:var(--muted);font-size:.8125rem}
.project-metadata summary,.page-source summary{cursor:pointer;min-height:32px}
.page-source code{white-space:normal;overflow-wrap:anywhere}
.guide-related-api{margin:2rem 0;color:var(--muted)}
.guide-related-api ul{padding-left:1.25rem}
.guide-sequence{display:flex;flex-wrap:wrap;justify-content:space-between;gap:1.25rem;margin:2.5rem 0;padding-top:1.25rem;border-top:1px solid var(--line)}
.guide-sequence a{display:flex;flex:1 1 12rem;min-width:0;flex-direction:column;overflow-wrap:anywhere}
.guide-sequence span{color:var(--muted);font-size:.8125rem}
.guide-sequence a[rel='next']{text-align:end}
.api-introduction .description{margin:.5rem 0 1rem}
.api-introduction .description>p{margin:.5rem 0}
.api-guide-entry{margin:.65rem 0;font-size:.875rem}
.package-reading-paths ul{display:flex;flex-wrap:wrap;gap:.5rem 1.5rem;padding:0;margin:.75rem 0;list-style:none}
.package-reading-paths li{margin:0}.package-overview .page-source{margin:.5rem 0 1rem}
.home-api-index{margin:1.5rem 0}.home-api-index>summary{cursor:pointer;color:var(--accent)}
.reading-resources{margin-top:.6rem;font-size:.8125rem;color:var(--muted)}
.reading-resources>summary{cursor:pointer}.reading-resources ul{margin-top:.5rem}
.external-reference-note{margin:.75rem 0;color:var(--muted);font-size:.8125rem}
.external-reference-status{margin:1.5rem 0;color:var(--muted);font-size:.8125rem}
.external-reference-status>summary{cursor:pointer}
.inline-binding{display:flex;align-items:baseline;flex-wrap:wrap;gap:.25rem .5rem;margin:.6rem 0 1rem;font-size:.875rem}
.inline-binding .binding-details{margin:0;font-size:.75rem}.inline-binding .binding-details>summary{cursor:pointer}
.inline-binding .binding-details[open]{flex-basis:100%}
.conceptual-bindings>summary{cursor:pointer;font-size:.875rem;color:var(--muted)}
.description,.parameter-description,.return-description,.throws-row dd,.behavior-contracts dd{font-size:var(--summary-size);line-height:1.8}
.api-page-header .signature-block{font-size:var(--code-size);line-height:1.75}
.mobile-search-trigger{display:none}
.member-filter-fields{display:flex;align-items:center;flex:1;flex-wrap:wrap;gap:.55rem;min-width:0}
.member-filter-toggle{display:none}
@media(max-width:760px){
  .member-browser-toolbar{flex-direction:row;align-items:center;justify-content:space-between}
  .member-filter-fields{flex:1 0 100%;flex-direction:column;align-items:stretch;order:2}
  .member-browser-enhanced .member-filter-fields{display:none}
  .member-browser-enhanced .member-filter-fields.is-open{display:flex}
  .member-filter-toggle:not([hidden]){display:inline-flex;align-items:center;min-height:40px;padding:0 .65rem;border:1px solid var(--line-strong);border-radius:5px;background:var(--surface-subtle);color:var(--ink);font:inherit;font-size:.8125rem}
  .site-nav-inner{display:flex;flex-wrap:wrap;gap:.5rem}
  .site-nav .brand{flex:1 1 0;min-width:0;max-width:none;margin:0}
  .site-nav .nav-menu{order:0;flex:0 0 38px;height:38px}
  .brand{order:1}.mobile-search-trigger{display:inline-grid;place-items:center;order:2;flex:0 0 38px;width:38px;height:38px;padding:0;border:1px solid var(--line);border-radius:5px;background:var(--surface);color:var(--ink)}
  .site-nav .top-actions{order:3;flex:0 0 auto;margin:0}
  .site-nav .site-search{display:none;order:4;flex:1 0 100%;max-width:none;min-width:0}
  html.mobile-search-is-open .site-nav .site-search{display:grid}
  .docs-main{padding:1.5rem 1rem 3.5rem}
  .content-column{width:100%;min-width:0}
  .prose pre{white-space:pre;overflow-x:auto;overflow-wrap:normal}
}
@media print{.mobile-search-trigger{display:none}.prose{max-width:none}}

"""
