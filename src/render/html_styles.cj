package cjdoc.render


internal let HTML_STYLE = """
:root {
  color-scheme: light;
  --bg: #fbfcfe;
  --surface: #ffffff;
  --surface-raised: #ffffff;
  --surface-subtle: #f5f7fb;
  --code-bg: #f6f8fc;
  --ink: #171b24;
  --muted: #626b7b;
  --faint: #536071;
  --line: #e3e7ee;
  --line-strong: #d1d8e3;
  --accent: #087f70;
  --accent-strong: #065f54;
  --accent-soft: #e6f5f0;
  --success: #21865b;
  --warning: #a36816;
  --danger: #c63b4a;
  --code-keyword: #8a3ffc;
  --code-type: #087f8c;
  --code-comment: #6c7789;
  --shadow: 0 12px 32px rgba(23, 31, 48, .08);
  --content-width: 56rem;
  --ui-font: Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  --display-font: var(--ui-font);
  --code-font: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --bg: #0b0e13;
  --surface: #10141b;
  --surface-raised: #151b24;
  --surface-subtle: #111720;
  --code-bg: #0c121b;
  --ink: #f1f5fb;
  --muted: #9aa5b5;
  --faint: #8795a7;
  --line: #242c38;
  --line-strong: #354153;
  --accent: #5ed6bd;
  --accent-strong: #a0ead8;
  --accent-soft: #123b34;
  --success: #63d39b;
  --warning: #e8b45c;
  --danger: #ff8290;
  --code-keyword: #c19cff;
  --code-type: #64d2d8;
  --code-comment: #8491a4;
  --shadow: 0 18px 42px rgba(0, 0, 0, .26);
}
:root[data-theme="paper"] {
  color-scheme: light;
  --bg: #f7f2e8;
  --surface: #fffaf0;
  --surface-raised: #fffdf8;
  --surface-subtle: #f1e8d9;
  --code-bg: #f4ecdf;
  --ink: #2c2823;
  --muted: #665f55;
  --faint: #6c6256;
  --line: #ded3c2;
  --line-strong: #cbbca6;
  --accent: #a34f3d;
  --accent-strong: #7d392f;
  --accent-soft: #f3dfd6;
  --success: #2f7756;
  --warning: #996016;
  --danger: #b43e43;
  --code-keyword: #8a3d84;
  --code-type: #186b70;
  --code-comment: #766d61;
  --shadow: 0 12px 32px rgba(82, 58, 33, .1);
  --ui-font: "Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif;
  --display-font: var(--ui-font);
}
:root[data-theme="ocean"] {
  color-scheme: dark;
  --bg: #07111f;
  --surface: #0c1a2c;
  --surface-raised: #12243b;
  --surface-subtle: #0d2035;
  --code-bg: #061321;
  --ink: #eaf7ff;
  --muted: #9bb8c9;
  --faint: #8eafc2;
  --line: #1e3b57;
  --line-strong: #315677;
  --accent: #61d9ff;
  --accent-strong: #a1e9ff;
  --accent-soft: #123550;
  --success: #65ddb1;
  --warning: #f1c368;
  --danger: #ff8e9d;
  --code-keyword: #d4a7ff;
  --code-type: #70e4e6;
  --code-comment: #7595aa;
  --shadow: 0 18px 42px rgba(0, 0, 0, .3);
}
:root[data-theme="forest"] {
  color-scheme: light;
  --bg: #f1f5ef;
  --surface: #fbfdf8;
  --surface-raised: #ffffff;
  --surface-subtle: #e9f0e8;
  --code-bg: #edf4ed;
  --ink: #1d2c23;
  --muted: #5f7063;
  --faint: #5b6e60;
  --line: #d5e0d4;
  --line-strong: #b9cbbb;
  --accent: #2f7758;
  --accent-strong: #20573f;
  --accent-soft: #dfeee4;
  --success: #23734f;
  --warning: #8d6418;
  --danger: #b43f4a;
  --code-keyword: #7d4fa1;
  --code-type: #1b7070;
  --code-comment: #718173;
  --shadow: 0 12px 32px rgba(37, 74, 50, .09);
}
:root[data-theme="terminal"] {
  color-scheme: dark;
  --bg: #07100b;
  --surface: #0b1710;
  --surface-raised: #102219;
  --surface-subtle: #0c1d13;
  --code-bg: #050d08;
  --ink: #d9ffe7;
  --muted: #91b8a0;
  --faint: #8fbda0;
  --line: #1b3b27;
  --line-strong: #2b5b3b;
  --accent: #69e69a;
  --accent-strong: #a2ffc1;
  --accent-soft: #123d25;
  --success: #70e6a3;
  --warning: #f0c56b;
  --danger: #ff8997;
  --code-keyword: #d0a4ff;
  --code-type: #78e9de;
  --code-comment: #6c9b7c;
  --shadow: 0 18px 42px rgba(0, 0, 0, .34);
  --ui-font: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;
  --display-font: var(--ui-font);
}
:root[data-theme="violet"] {
  color-scheme: light;
  --bg: #f6f3fb;
  --surface: #ffffff;
  --surface-raised: #ffffff;
  --surface-subtle: #f0ecf8;
  --code-bg: #f1effa;
  --ink: #252235;
  --muted: #68627a;
  --faint: #655f79;
  --line: #e1dced;
  --line-strong: #cbc3dc;
  --accent: #6848c7;
  --accent-strong: #4b319b;
  --accent-soft: #ebe5ff;
  --success: #2e7659;
  --warning: #966315;
  --danger: #b64050;
  --code-keyword: #914bc0;
  --code-type: #19737c;
  --code-comment: #7c7591;
  --shadow: 0 12px 32px rgba(69, 49, 111, .1);
  --display-font: "Avenir Next","Segoe UI",ui-sans-serif,sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    color-scheme: dark;
    --bg: #0b0e13;
    --surface: #10141b;
    --surface-raised: #151b24;
    --surface-subtle: #111720;
    --code-bg: #0c121b;
    --ink: #f1f5fb;
    --muted: #9aa5b5;
    --faint: #8795a7;
    --line: #242c38;
    --line-strong: #354153;
    --accent: #5ed6bd;
    --accent-strong: #a0ead8;
    --accent-soft: #123b34;
    --success: #63d39b;
    --warning: #e8b45c;
    --danger: #ff8290;
    --code-keyword: #c19cff;
    --code-type: #64d2d8;
    --code-comment: #8491a4;
    --shadow: 0 18px 42px rgba(0, 0, 0, .26);
  }
}
/* Layout and density are shared tokens, not cascaded theme-specific overrides. */
:root{--header-height:4rem;--section-gap:1.25rem;--row-padding:.45rem;--content-width:70rem}
*{box-sizing:border-box}
[hidden]{display:none!important}
html{scroll-behavior:auto;scroll-padding-top:calc(var(--header-height) + 1rem)}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--ui-font);text-rendering:optimizeLegibility}
button,input,select,textarea{font:inherit}
button,summary{cursor:pointer}
a{color:var(--accent-strong);text-underline-offset:3px}
a:hover{color:var(--accent)}
a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
::selection{background:var(--accent-soft);color:var(--ink)}
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.skip-link{position:fixed;z-index:100;top:.5rem;left:.5rem;transform:translateY(-200%);padding:.5rem;background:var(--surface)}
.skip-link:focus{transform:none}
[id]{scroll-margin-top:calc(var(--header-height) + 1rem)}
h1,h2,h3,h4,h5,h6{color:var(--ink);font-family:var(--display-font);line-height:1.35;margin:var(--section-gap) 0 .55rem}
h1{font-size:1.75rem;margin:0;font-weight:730}
h2{font-size:1.2rem;padding-bottom:.35rem;border-bottom:1px solid var(--line)}
h3{font-size:1.05rem}h4,h5,h6{font-size:1rem}
p{margin:.55rem 0}ul,ol{padding-left:1.3rem;margin:.5rem 0}li+li{margin-top:.2rem}
code,pre{font-family:var(--code-font);font-size:.875rem}
pre{position:relative;max-width:100%;margin:.65rem 0;padding:.7rem 3rem .7rem .8rem;border:1px solid var(--line);border-radius:5px;background:var(--code-bg);overflow:auto;line-height:1.55}
pre code{font-size:inherit}
p code,li code,dt code,dd code{color:var(--ink);background:var(--code-bg);padding:.08rem .22rem;border-radius:3px;overflow-wrap:anywhere}
.type-link{color:var(--accent-strong);text-decoration:underline;text-decoration-color:var(--accent);text-underline-offset:3px;border-radius:2px}
.type-link:hover,.type-link:focus-visible{background:var(--accent-soft)}
.signature-block{white-space:pre;overflow-x:auto}
.signature-heading{border:0;padding:0;margin:.65rem 0 .25rem;font-size:.95rem}
.code-copy{position:absolute;right:.4rem;top:.4rem;width:30px;height:30px;display:grid;place-items:center;background:var(--surface);color:var(--muted);border:1px solid var(--line-strong);border-radius:4px}
.code-copy svg{width:16px;height:16px}
.code-copy[data-copied=true]{color:var(--success);border-color:var(--success)}
/* One header, one column grid; tablet TOC stays inside main, not above a full-height grid row. */
.site-nav{position:sticky;top:0;z-index:20;background:var(--surface);border-bottom:1px solid var(--line)}
.site-nav-inner{max-width:1600px;min-height:var(--header-height);margin:auto;padding:.55rem 1rem;display:grid;grid-template-columns:minmax(10rem,15rem) minmax(12rem,1fr) auto;gap:1rem;align-items:center}
.brand{display:flex;min-width:0;color:var(--ink);text-decoration:none;font-size:1rem;line-height:1.3}
.brand-copy{min-width:0}.brand-project{display:block;overflow-wrap:anywhere}
.brand-subtitle{display:block;color:var(--muted);font-size:.78rem;margin-top:.15rem}
.top-actions{display:flex;align-items:center;gap:.5rem}
.site-search{display:flex;position:relative;align-items:center;gap:.5rem;min-width:0}
.search-area{position:relative;flex:1;min-width:0}
.search-shell{display:flex;align-items:center;gap:.6rem;height:38px;padding:0 .65rem;background:var(--surface-subtle);border:1px solid var(--line-strong);border-radius:6px}
.search-shell:focus-within{border-color:var(--accent)}
.search-shell input{width:100%;min-width:0;border:0;outline:none;background:transparent;color:var(--ink)}
.search-shell input::placeholder{color:var(--muted)}
kbd{white-space:nowrap;border:1px solid var(--line);border-radius:3px;padding:.1rem .3rem;font:.75rem var(--code-font);color:var(--muted)}
.theme-toggle,.search-filter-toggle{display:inline-flex;align-items:center;justify-content:center;width:auto;min-height:36px;padding:0 .7rem;white-space:nowrap;background:var(--surface);color:var(--ink);border:1px solid var(--line-strong);border-radius:6px}
.theme-control{position:relative}
.theme-popover,.search-filters{position:absolute;right:0;top:calc(100% + .45rem);z-index:50;max-width:calc(100vw - 2rem);padding:.6rem;background:var(--surface-raised);border:1px solid var(--line-strong);border-radius:7px;box-shadow:var(--shadow)}
.theme-popover{min-width:15rem}
.theme-options{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.25rem}
.theme-options button,.search-tabs button{min-height:32px;padding:.25rem .45rem;border:1px solid transparent;border-radius:4px;background:transparent;color:var(--ink);font-size:.85rem}
.theme-options button[aria-pressed=true],.search-tabs button[aria-pressed=true]{background:var(--accent-soft);border-color:var(--accent);color:var(--accent-strong)}
.search-filters{display:none;flex-wrap:wrap;gap:.5rem}.search-filters.is-open{display:flex}
.search-tabs{display:flex;gap:.2rem}.search-filters select{max-width:12rem;min-height:32px;background:var(--surface);color:var(--ink);border:1px solid var(--line-strong);border-radius:4px}
.search-results{position:absolute;z-index:40;top:calc(100% + .4rem);left:0;width:100%;max-height:min(30rem,65vh);overflow:auto;margin:0;padding:.3rem;list-style:none;border:1px solid var(--line-strong);border-radius:6px;background:var(--surface-raised);box-shadow:var(--shadow)}
.search-results:empty{display:none}.search-results li{margin:0}
.search-results a{display:block;padding:.45rem .6rem;color:var(--ink);text-decoration:none;border-radius:4px}
.search-results a:hover,.search-results [aria-selected=true] a{background:var(--accent-soft)}
.search-result-head{display:flex;justify-content:space-between;gap:.5rem}.search-result-name{overflow-wrap:anywhere}
.search-kind,.search-context,.search-summary{font-size:.8rem;color:var(--muted)}
.search-context,.search-summary{display:block;overflow-wrap:anywhere}
.search-result-signature{display:block;margin:.2rem 0;white-space:pre-wrap;overflow-wrap:anywhere;font-size:.85rem;color:var(--ink)}
.search-status{margin:.3rem 0;color:var(--muted);font-size:.85rem}
.docs-layout{max-width:1600px;margin:auto;display:grid;grid-template-columns:248px minmax(0,1fr) 210px;align-items:start}
.docs-sidebar,.toc-panel{position:sticky;top:var(--header-height);height:calc(100vh - var(--header-height));overflow:auto;background:var(--surface);padding:1.1rem .85rem}
.docs-sidebar{border-right:1px solid var(--line)}.toc-panel{border-left:1px solid var(--line)}
.docs-main{min-width:0;padding:1.1rem clamp(1rem,2vw,2rem) 2.5rem}
.content-column{max-width:var(--content-width);margin:auto;min-width:0}
.sidebar-section+.sidebar-section{margin-top:1.1rem}.sidebar-label,.toc-title{color:var(--muted);font-size:.8rem;font-weight:700;margin:0 0 .4rem}
.sidebar-link,.sidebar-package,.context-item{display:block;min-height:30px;padding:.25rem .4rem;color:var(--muted);text-decoration:none;border-radius:4px;overflow-wrap:anywhere}
.sidebar-link:hover,.sidebar-package:hover,.context-item:hover{background:var(--surface-subtle);color:var(--ink)}
.sidebar-link.is-current,.sidebar-package.is-current,.context-item.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:650}
.context-item code{font-size:.82rem;line-height:1.45;background:transparent}
.sidebar-package{display:flex;justify-content:space-between;gap:.4rem;font-family:var(--code-font);font-size:.82rem}
.sidebar-package span:first-child{min-width:0;overflow-wrap:anywhere}.sidebar-package-count,.sidebar-count{color:var(--muted);font-size:.78rem}
.sidebar-group>summary{padding:.3rem .4rem;font-size:.9rem;font-weight:650}
.sidebar-count{float:right}.sidebar-packages{padding-left:.7rem;border-left:1px solid var(--line);margin-left:.4rem}
.sidebar-filter-label{display:block;margin:.3rem 0 .45rem}
.sidebar-filter{width:100%;min-width:0;height:32px;padding:0 .5rem;border:1px solid var(--line-strong);border-radius:4px;background:var(--surface-subtle);color:var(--ink);font-size:.85rem}
.sidebar-no-results,.sidebar-limit{font-size:.82rem;color:var(--muted)}
.toc-panel ol{list-style:none;padding:0;margin:0}.toc-panel li{margin:0}
.toc-link{display:block;padding:.25rem .4rem;border-left:2px solid transparent;font-size:.82rem;color:var(--muted);text-decoration:none;overflow-wrap:anywhere}
.toc-link.is-active{border-color:var(--accent);color:var(--accent-strong);background:var(--accent-soft)}
.toc-panel li[data-depth="3"]{padding-left:.7rem}.toc-panel li[data-depth="4"]{padding-left:1rem}
.mobile-toc{display:none;margin:0 0 .8rem;padding:.4rem .6rem;background:var(--surface-subtle);border:1px solid var(--line);border-radius:5px}
.mobile-toc nav{margin-top:.4rem;max-height:35vh;overflow:auto}.mobile-toc ol{padding-left:1rem}
.breadcrumbs{margin:0 0 .55rem;color:var(--muted);font-size:.85rem}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:.3rem;margin:0;padding:0;list-style:none}
.breadcrumbs li+li:before{content:"/";margin-right:.3rem}.breadcrumbs a{color:var(--muted)}
.page-header{margin-bottom:.55rem}.page-header h1 code{font:inherit;background:none;padding:0}
.page-lead,.page-meta,.meta{color:var(--muted);font-size:.9rem}.page-lead{margin:.35rem 0}
body[data-cjdoc-route=concept]{--section-gap:1.7rem}
body[data-cjdoc-route=concept] .content-column{max-width:52rem}
body[data-cjdoc-route=concept] .docs-main{padding-top:1.5rem}
.quick-start,.conceptual-entry{margin:.65rem 0;padding:.45rem .65rem;border-left:2px solid var(--line-strong)}
.quick-start h2,.conceptual-entry h2{font-size:1rem;border:0;padding:0;margin:0 0 .2rem}
.quick-start p,.conceptual-entry p{margin:.2rem 0}
.module-list{display:grid;gap:.4rem}.module-record{padding:.4rem 0}.module-record h3,.module-record p{margin:.2rem 0}
.package-index{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(12rem,1fr));gap:.15rem .7rem}
.package-index li{margin:0;border-bottom:1px solid var(--line)}.package-index a{display:block;padding:.4rem .25rem}
.record-list{list-style:none;margin:.5rem 0;padding:0}.record-list li{padding:.35rem 0;border-bottom:1px solid var(--line);overflow-wrap:anywhere}
.declaration-group{margin:var(--section-gap) 0}.declaration-group>h3{margin:.5rem 0}
.declaration-summary{margin:0;padding:var(--row-padding) .15rem;border-top:1px solid var(--line)}
.declaration-row-link{display:block;color:var(--ink);text-decoration:none;padding:.15rem .2rem;border-radius:4px}
.declaration-row-link:hover{background:var(--accent-soft)}
.declaration-signature{display:block;max-width:100%;overflow:auto;white-space:pre;font-size:.875rem;color:var(--ink)}
.declaration-summary p{margin:.15rem 0;color:var(--muted);font-size:.875rem}
/* A member summary is a native disclosure, not a nested link or a modal. */
.member-browser{margin-top:var(--section-gap)}.member-browser-toolbar{display:flex;align-items:center;flex-wrap:wrap;gap:.4rem;font-size:.875rem}
.member-browser-toolbar input{flex:1;min-width:8rem}.member-browser-toolbar input,.member-browser-toolbar select{height:34px;padding:0 .5rem;border:1px solid var(--line-strong);border-radius:4px;background:var(--surface-subtle);color:var(--ink)}
.member-filter-status{margin:.3rem 0;font-size:.82rem;color:var(--muted);min-height:1.3rem}
.member-group{margin:.8rem 0}.member-group-title{margin:.7rem 0 .3rem;font-size:.95rem;color:var(--muted)}
.member-entry{border-top:1px solid var(--line);min-width:0}
.member-entry>summary{padding:var(--row-padding) .2rem;list-style-position:inside;min-height:34px}
.member-entry>summary:hover{background:var(--surface-subtle)}
.member-summary{display:inline-flex;vertical-align:top;flex-direction:column;width:calc(100% - 1.5rem);min-width:0}
.member-summary-text{display:block;margin-top:.15rem;color:var(--muted);font-size:.875rem;line-height:1.45}
.member-entry[open]{margin-bottom:.7rem;border-bottom:1px solid var(--line)}
.member-entry[open]>summary{background:var(--accent-soft)}
.member-entry>.member-detail{padding:.65rem .8rem .9rem;border-top:1px solid var(--line);background:var(--surface)}
.member-actions{margin:0 0 .5rem;font-size:.85rem}
.member-origin,.extension-conditions{font-size:.85rem;color:var(--muted)}
.extension-signature{margin:.3rem 0 .6rem}
.symbol-kind{color:var(--muted);font-size:.82rem;margin:.3rem 0}.symbol-summary{margin:.4rem 0 .7rem}.symbol-summary p{margin:0}
.signature-context{font-size:.82rem;color:var(--muted)}
.contextual-metadata{margin:.55rem 0;padding:.4rem .6rem;border:1px solid var(--line);border-radius:5px}
.contextual-metadata>summary{font-size:.85rem;color:var(--muted)}
.source-action{margin:.45rem 0;font-size:.85rem}.source-action a{display:inline-flex;min-height:30px;align-items:center}
.relationships,.behavior-contracts dl{display:grid;grid-template-columns:minmax(5rem,max-content) minmax(0,1fr);gap:.3rem .6rem;margin:.5rem 0}
.relationships dt,.behavior-contracts dt{font-size:.85rem;color:var(--muted)}
.relationships dd,.behavior-contracts dd{margin:0;min-width:0;overflow-wrap:anywhere}
.parameter-list{margin:.5rem 0}.parameter-row{padding:0;border-bottom:0;display:grid;grid-template-columns:minmax(5rem,max-content) minmax(0,1fr);gap:.1rem .7rem;margin:.45rem 0}
.parameter-row dt{grid-column:1;grid-row:1}.parameter-row dd{margin:0;min-width:0}
.parameter-type{white-space:normal;overflow-wrap:anywhere}.parameter-description{grid-column:2}.parameter-description p{margin:0}
.parameter-default{font-size:.85rem}.parameter-colon{margin-right:.2rem}
.return-value{display:flex;flex-wrap:wrap;align-items:baseline;gap:.4rem .7rem;margin:.45rem 0}.return-type{min-width:0;overflow-wrap:anywhere}.return-description{min-width:0;flex:1 1 12rem}.return-description p{margin:0}
.example-list{display:grid;gap:.5rem}.example-block{min-width:0}.example-title{margin:.45rem 0 .25rem!important}.example-block pre{margin:.4rem 0}
.behavior-contracts,.symbol-relationships,.reverse-type-usages,.api-usages,.external-documentation{margin:.85rem 0}
.relation-scope,.usage-kind,.binding-meta,.binding-scope,.relation-more{color:var(--muted);font-size:.82rem}
.usage-signature{display:block}.conceptual-bindings ul{padding-left:1.2rem}.conceptual-bindings li{overflow-wrap:anywhere}
.binding-state{margin-right:.35rem;font-size:.82rem}.binding-meta{margin-left:.35rem}
.badge{display:inline-block;margin:0 .2rem;padding:.07rem .3rem;border:1px solid var(--line-strong);border-radius:4px;font-size:.8rem;color:var(--muted);vertical-align:baseline}
.badge[data-state=unavailable],.badge[data-state=ambiguous],.badge[data-state=partial]{border-color:var(--warning);color:var(--ink)}
.callout,.empty-state{margin:.65rem 0;padding:.6rem .8rem;border:1px solid var(--line);border-left:3px solid var(--warning);border-radius:4px}
.diagnostics-list{list-style:none;margin:.5rem 0;padding:0}.diagnostics-list li{overflow-wrap:anywhere;margin:.3rem 0}
.site-footer{border-top:1px solid var(--line);color:var(--muted);font-size:.82rem}
.footer-inner{max-width:1600px;margin:auto;padding:.7rem 1rem;display:flex;justify-content:space-between;align-items:baseline;gap:1rem}
.build-details{margin:0}.build-details dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.2rem .6rem}.build-details dd{margin:0;overflow-wrap:anywhere}
.validation-page table{border-collapse:collapse;width:100%;max-width:100%}.validation-page th,.validation-page td{padding:.4rem;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;overflow-wrap:anywhere}
.validation-message,.validation-context{font-size:.85rem;color:var(--muted)}
.cjdoc-version-selector{max-width:1600px;margin:auto;padding:.35rem 1rem;display:flex;flex-wrap:wrap;gap:.4rem;border-bottom:1px solid var(--line);font-size:.85rem}
.cjdoc-version-selector a{padding:.15rem .35rem}.cjdoc-version-selector [aria-current=page]{background:var(--accent-soft);font-weight:650}
.align-left{text-align:left}.align-center{text-align:center}.align-right{text-align:right}
.nav-menu,.nav-backdrop,.sidebar-close{display:none}
@media(max-width:1180px){
  .docs-layout{grid-template-columns:220px minmax(0,1fr)}
  .toc-panel{display:none}.mobile-toc{display:block}
  .site-nav-inner{grid-template-columns:minmax(9rem,13rem) minmax(10rem,1fr) auto;gap:.7rem}
}
@media(max-width:760px){
  :root{--header-height:7rem;--row-padding:.6rem}
  .site-nav-inner{min-height:0;grid-template-columns:auto minmax(0,1fr) auto;gap:.5rem;padding:.6rem .8rem}
  .nav-menu{display:grid;place-items:center;width:36px;height:36px;border:1px solid var(--line-strong);border-radius:4px;background:var(--surface);color:var(--ink)}
  .brand{min-width:0}.brand-project{font-size:.95rem}.brand-subtitle{font-size:.78rem}
  .site-search{grid-column:1/-1;grid-row:2;width:100%}.search-shell kbd{display:none}
  .theme-popover{position:fixed;top:3.5rem;right:.8rem}.search-filters{left:0;right:auto}
  .docs-layout{display:block}.docs-main{padding:.8rem .85rem 2rem}.content-column{min-width:0;width:100%}
  .docs-sidebar{display:none;position:fixed;z-index:40;inset:0 auto 0 0;width:min(88vw,22rem);height:100dvh;padding:1rem;box-shadow:var(--shadow)}
  .docs-sidebar.is-open{display:block}.sidebar-close{display:inline-flex;min-height:36px;padding:.25rem .6rem;margin-bottom:.7rem;border:1px solid var(--line-strong);border-radius:4px;background:var(--surface);color:var(--ink)}
  .nav-backdrop{display:block;position:fixed;z-index:35;inset:0;width:100%;height:100%;border:0;background:rgb(0 0 0/.38)}.nav-is-open{overflow:hidden}
  .member-browser-toolbar{align-items:stretch}.member-browser-toolbar input{width:100%;flex-basis:100%;min-width:0}.member-browser-toolbar select{max-width:100%}
  .member-entry>.member-detail{padding:.6rem .3rem}.relationships,.behavior-contracts dl{grid-template-columns:1fr;gap:.15rem}.relationships dd,.behavior-contracts dd{margin-bottom:.35rem}
  .parameter-row{grid-template-columns:minmax(4rem,max-content) minmax(0,1fr)}
  h1{font-size:1.55rem}.footer-inner{padding:.7rem .85rem}
}
@media print{.site-nav,.docs-sidebar,.toc-panel,.mobile-toc,.member-browser-toolbar,.code-copy{display:none}.docs-layout{display:block}.docs-main{padding:0}.member-entry::details-content{content-visibility:visible;height:auto}.member-entry:not([open])>div{display:block}pre{white-space:pre-wrap;overflow:visible}a{color:inherit}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition:none!important;animation:none!important}}
"""
