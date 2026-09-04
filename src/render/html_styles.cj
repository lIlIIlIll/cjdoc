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
  --faint: #8b95a6;
  --line: #e3e7ee;
  --line-strong: #d1d8e3;
  --accent: #2f6feb;
  --accent-strong: #1d55c7;
  --accent-soft: #edf3ff;
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
  --faint: #6e7b8e;
  --line: #242c38;
  --line-strong: #354153;
  --accent: #80a8ff;
  --accent-strong: #a9c4ff;
  --accent-soft: #162541;
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
  --faint: #887f73;
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
  --faint: #6f91a5;
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
  --faint: #7f9182;
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
  --faint: #5c886e;
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
  --faint: #8f89a2;
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
    --faint: #6e7b8e;
    --line: #242c38;
    --line-strong: #354153;
    --accent: #80a8ff;
    --accent-strong: #a9c4ff;
    --accent-soft: #162541;
    --success: #63d39b;
    --warning: #e8b45c;
    --danger: #ff8290;
    --code-keyword: #c19cff;
    --code-type: #64d2d8;
    --code-comment: #8491a4;
    --shadow: 0 18px 42px rgba(0, 0, 0, .26);
  }
}
*{box-sizing:border-box}
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 var(--ui-font);text-rendering:optimizeLegibility}
body,button,input,select{font-family:inherit}
::selection{background:var(--accent-soft);color:var(--ink)}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-track{background:var(--surface-subtle)}::-webkit-scrollbar-thumb{background:var(--line-strong);border:3px solid var(--surface-subtle);border-radius:8px}
a{color:var(--accent);text-decoration:none;text-underline-offset:3px}a:hover{text-decoration:underline}a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
h1,h2,h3,h4{color:var(--ink);line-height:1.2;letter-spacing:-.02em;font-family:var(--display-font)}h1{font-size:clamp(2rem,4vw,3rem);margin:0;font-weight:730}h2{font-size:1.35rem;margin:2.75rem 0 .9rem;padding-bottom:.65rem;border-bottom:1px solid var(--line)}h3{font-size:1rem;margin:1.6rem 0 .55rem}p{margin:.8rem 0}ul,ol{padding-left:1.3rem}li+li{margin-top:.3rem}
code,pre{font-family:var(--code-font)}code{font-size:.91em}p code,li code,dt code,dd code{padding:.13rem .35rem;border:1px solid var(--line);border-radius:5px;background:var(--code-bg);color:var(--ink)}
button,input,select{font-size:inherit}button{cursor:pointer}
.site-nav{position:sticky;top:0;z-index:20;border-bottom:1px solid var(--line);background:var(--surface)}
.site-nav-inner{max-width:1600px;min-height:64px;margin:0 auto;padding:.7rem 1.25rem;display:grid;grid-template-columns:10.5rem minmax(18rem,1fr) auto;align-items:center;gap:1.25rem}
.brand{display:inline-flex;align-items:center;gap:.58rem;color:var(--ink);font-size:1.12rem;font-weight:760;letter-spacing:-.035em}.brand:hover{text-decoration:none}.brand-mark{width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1.5px solid var(--accent);border-radius:6px;color:var(--accent);font:700 .78rem/1 ui-monospace,monospace;letter-spacing:-.08em}.brand-subtitle{display:block;margin-top:.08rem;color:var(--faint);font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase}
.site-search{min-width:0;display:flex;align-items:center;gap:.6rem}.search-area{position:relative;min-width:0;flex:1}.search-shell{height:40px;display:flex;align-items:center;gap:.65rem;padding:0 .75rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface-subtle);transition:border-color .18s ease,box-shadow .18s ease}.search-shell:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}.search-shell svg{flex:0 0 auto;color:var(--faint)}.search-shell input{width:100%;min-width:0;border:0;outline:0;background:transparent;color:var(--ink)}.search-shell input::placeholder{color:var(--muted)}kbd{padding:.18rem .38rem;border:1px solid var(--line-strong);border-bottom-width:2px;border-radius:4px;background:var(--surface);color:var(--muted);font:600 .7rem/1 ui-monospace,monospace;white-space:nowrap}
.search-filters{display:flex;gap:.35rem}.search-filters label{display:flex;align-items:center}.search-filters select{max-width:8.5rem;height:40px;padding:0 1.8rem 0 .65rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted)}
.top-actions{display:flex;align-items:center;gap:.2rem;white-space:nowrap}.version-label{padding:0 .65rem;color:var(--muted);font:600 .78rem/2 ui-monospace,monospace}.top-source{display:inline-flex;align-items:center;gap:.4rem;padding:0 .7rem;color:var(--muted);font-size:.82rem}.top-source-disabled{cursor:default;opacity:.72}.theme-picker{display:inline-flex;align-items:center}.theme-picker select{height:36px;max-width:8.8rem;padding:0 1.75rem 0 .65rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted);font-size:.78rem}.theme-picker select:hover{border-color:var(--accent);color:var(--ink)}.theme-toggle{width:36px;height:36px;display:grid;place-items:center;margin-left:.3rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted)}.theme-toggle:hover{border-color:var(--accent);color:var(--accent)}.theme-toggle .icon-moon{display:none}.theme-toggle[data-mode="dark"] .icon-sun{display:none}.theme-toggle[data-mode="dark"] .icon-moon{display:block}
.search-results{position:absolute;z-index:30;top:calc(100% + .55rem);left:0;width:100%;max-height:25rem;overflow:auto;margin:0;padding:.35rem;list-style:none;background:var(--surface-raised);border:1px solid var(--line-strong);border-radius:8px;box-shadow:var(--shadow)}.search-results:empty{display:none}.search-results a{display:block;padding:.55rem .65rem;border-radius:5px;color:var(--ink);text-decoration:none}.search-results a:hover,.search-results a:focus,.search-results [aria-selected=true] a{background:var(--accent-soft)}.search-kind{color:var(--muted);font-size:.82rem}
.docs-layout{max-width:1600px;margin:0 auto;display:grid;grid-template-columns:248px minmax(0,1fr) 220px;align-items:start}.docs-sidebar{position:sticky;top:64px;height:calc(100vh - 64px);overflow:auto;padding:2rem 1rem 3rem 1.25rem;border-right:1px solid var(--line);background:var(--surface)}.sidebar-label{margin:0 0 .7rem;color:var(--faint);font-size:.68rem;font-weight:750;letter-spacing:.12em;text-transform:uppercase}.sidebar-section+.sidebar-section{margin-top:1.8rem}.sidebar-link{display:flex;align-items:center;gap:.55rem;min-height:34px;margin:.12rem 0;padding:.38rem .6rem;border-radius:6px;color:var(--muted);font-size:.88rem;font-weight:560}.sidebar-link:hover{background:var(--surface-subtle);color:var(--ink);text-decoration:none}.sidebar-link.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:680}.sidebar-link svg{color:currentColor}.sidebar-group{margin-top:.3rem}.sidebar-group summary{display:flex;align-items:center;justify-content:space-between;gap:.4rem;padding:.42rem .6rem;color:var(--ink);font-size:.86rem;font-weight:680;cursor:pointer;list-style:none}.sidebar-group summary::-webkit-details-marker{display:none}.sidebar-group summary:before{content:"";width:7px;height:7px;border-right:1.5px solid var(--muted);border-bottom:1.5px solid var(--muted);transform:rotate(-45deg);transition:transform .16s ease}.sidebar-group[open] summary:before{transform:rotate(45deg) translate(-1px,-1px)}.sidebar-count{color:var(--faint);font:600 .7rem ui-monospace,monospace}.sidebar-packages{margin:.18rem 0 .4rem 1rem;padding-left:.45rem;border-left:1px solid var(--line)}.sidebar-package{display:flex;align-items:center;justify-content:space-between;gap:.4rem;padding:.34rem .55rem;color:var(--muted);font:500 .8rem ui-monospace,monospace;border-radius:5px}.sidebar-package:hover{background:var(--surface-subtle);color:var(--accent);text-decoration:none}.sidebar-package-count{color:var(--faint);font-size:.68rem}.sidebar-note{margin:1.8rem .6rem 0;padding-top:1rem;border-top:1px solid var(--line);color:var(--faint);font-size:.75rem}.sidebar-note code{display:block;margin-top:.28rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.docs-main{min-width:0;min-height:calc(100vh - 64px);padding:2.2rem clamp(1.25rem,4vw,4.5rem) 5rem}.content-column{max-width:var(--content-width);margin:0 auto}.toc-panel{position:sticky;top:64px;height:calc(100vh - 64px);padding:2.25rem 1.1rem 3rem 1.45rem;border-left:1px solid var(--line);background:var(--surface)}.toc-title{margin:0 0 .75rem;color:var(--faint);font-size:.68rem;font-weight:760;letter-spacing:.12em;text-transform:uppercase}.toc-panel nav{max-height:calc(100vh - 120px);overflow:auto}.toc-panel ol{margin:0;padding:0;list-style:none}.toc-panel li{margin:0}.toc-panel li[data-depth="3"]{padding-left:.7rem}.toc-panel a{display:block;padding:.32rem .65rem;border-left:2px solid transparent;color:var(--muted);font-size:.8rem;line-height:1.45}.toc-panel a:hover{color:var(--ink);text-decoration:none}.toc-panel a.is-active{border-left-color:var(--accent);color:var(--accent);font-weight:680}
.breadcrumbs{margin:0 0 1.4rem;color:var(--muted);font-size:.8rem}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:.45rem;margin:0;padding:0;list-style:none}.breadcrumbs li+li:before{content:"/";margin-right:.45rem;color:var(--faint)}.breadcrumbs a{color:var(--muted)}.page-header{margin-bottom:2.4rem}.page-header h1 code{padding:0;border:0;background:none;color:inherit;font-size:inherit}.page-lead{max-width:68ch;margin:1rem 0 0;color:var(--muted);font-size:1.03rem}.page-meta{display:flex;flex-wrap:wrap;gap:.55rem 1.25rem;margin:1.25rem 0 0;color:var(--muted);font-size:.78rem}.page-meta strong{color:var(--ink);font-weight:650}.page-meta-item{display:inline-flex;align-items:center;gap:.38rem}.status-dot{width:7px;height:7px;border-radius:50%;background:var(--success)}.status-dot.partial{background:var(--warning)}.status-dot.unavailable{background:var(--danger)}
.module-list{display:grid;gap:1rem}.module-record{padding:1rem 1.1rem;border:1px solid var(--line);border-radius:8px;background:var(--surface)}.module-record-head{display:flex;align-items:baseline;justify-content:space-between;gap:1rem}.module-record h3{margin:0;font-size:1rem}.module-record h3 code{padding:0;border:0;background:transparent;color:var(--ink)}.module-record p{margin:.35rem 0;color:var(--muted);font-size:.84rem}.record-role{color:var(--faint);font:600 .7rem ui-monospace,monospace;text-transform:uppercase}.package-links{display:grid;grid-template-columns:repeat(auto-fit,minmax(12rem,1fr));gap:.25rem .9rem;margin:.85rem 0 0;padding:.75rem 0 0;border-top:1px solid var(--line);list-style:none}.package-links li{margin:0}.package-links a{display:flex;align-items:center;justify-content:space-between;gap:.5rem;padding:.35rem .45rem;color:var(--accent);font:500 .82rem ui-monospace,monospace;border-radius:4px}.package-links a:hover{background:var(--accent-soft);text-decoration:none}.package-arrow{color:var(--faint)}.package-index{display:grid;grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));gap:.2rem .9rem;margin:0;padding:0;list-style:none}.package-index li{margin:0;border-bottom:1px solid var(--line)}.package-index a{display:flex;align-items:center;justify-content:space-between;gap:.5rem;padding:.7rem .4rem;color:var(--accent);font:500 .84rem ui-monospace,monospace}.package-index a:hover{background:var(--accent-soft);text-decoration:none}.package-index small{color:var(--faint);font:600 .7rem ui-monospace,monospace}
.record-list{margin:.5rem 0 0;padding:0;list-style:none}.record-list li{padding:.6rem 0;border-bottom:1px solid var(--line)}.record-list li:last-child{border-bottom:0}.record-list a{font-family:ui-monospace,monospace}.diagnostics-list{display:grid;gap:.45rem;margin:0;padding:0;list-style:none}.diagnostic-item{padding:.65rem .75rem;border:1px solid var(--line);border-radius:6px;background:var(--surface-subtle);font-size:.84rem}.diagnostic-item strong{font:650 .76rem ui-monospace,monospace}.diagnostic-item code{word-break:break-word}.callout{margin:1rem 0;padding:.8rem 1rem;border:1px solid color-mix(in srgb,var(--warning) 45%,var(--line));border-left:3px solid var(--warning);border-radius:6px;background:var(--surface-subtle);color:var(--muted);font-size:.84rem}.callout strong{color:var(--warning)}.meta{color:var(--muted);font-size:.8rem}.badge{display:inline-flex;align-items:center;gap:.25rem;padding:.16rem .42rem;margin-right:.3rem;border:1px solid var(--line-strong);border-radius:5px;background:var(--surface-subtle);color:var(--muted);font:650 .69rem/1.4 ui-monospace,monospace;vertical-align:middle}.badge[data-state="resolved"]{border-color:color-mix(in srgb,var(--success) 38%,var(--line));color:var(--success)}.badge[data-state="partial"]{border-color:color-mix(in srgb,var(--warning) 38%,var(--line));color:var(--warning)}.badge[data-state="unavailable"],.badge[data-state="ambiguous"]{border-color:color-mix(in srgb,var(--danger) 38%,var(--line));color:var(--danger)}
.symbol-entry{margin:2rem 0 0;padding:1.25rem 0 2rem;border-top:1px solid var(--line)}.symbol-entry h2,.declaration-summary h3{margin:.05rem 0 .8rem;padding:0;border:0;font-size:1.08rem}.symbol-entry h2 code,.declaration-summary h3 code{padding:0;border:0;background:transparent;color:var(--accent)}.symbol-entry h2 a:hover,.declaration-summary h3 a:hover{text-decoration:none}.symbol-meta{margin:.5rem 0 1rem}.symbol-contract{position:relative}.signature-heading{display:flex;align-items:center;gap:.55rem;margin:1.6rem 0 .65rem;font-size:.9rem}.signature-heading:after{content:"";height:1px;flex:1;background:var(--line)}.description>p:first-child,.summary>p:first-child{margin-top:0}.description h2{margin-top:2.2rem;font-size:1.22rem}.description h3{font-size:.98rem}.relationships{display:grid;grid-template-columns:max-content 1fr;gap:.4rem .9rem;margin:1rem 0;color:var(--muted);font-size:.83rem}.relationships dt{margin:0;color:var(--faint);font:650 .72rem ui-monospace,monospace;text-transform:uppercase}.relationships dd{margin:0}.symbol-entry dl:not(.relationships){display:grid;grid-template-columns:minmax(7rem,max-content) 1fr;gap:.75rem 1.25rem;margin:1rem 0}.parameter-list{margin:1rem 0;border-top:1px solid var(--line)}.parameter-row{display:grid;grid-template-columns:minmax(7rem,max-content) minmax(7rem,max-content) minmax(0,1fr);align-items:start;column-gap:1rem;padding:.7rem 0;border-bottom:1px solid var(--line)}.parameter-row dt,.parameter-row dd{margin:0}.parameter-row dt{color:var(--ink);font-weight:650}.parameter-type{color:var(--muted);white-space:nowrap}.parameter-colon{color:var(--faint);margin-right:.25rem}.parameter-description{min-width:0;color:var(--muted)}.parameter-description>:first-child{margin-top:0}.parameter-description>:last-child{margin-bottom:0}.symbol-entry dt{margin:0;color:var(--ink);font-weight:650}.symbol-entry dd{margin:0;color:var(--muted)}
pre{position:relative;margin:1rem 0;padding:1.1rem 3.3rem 1.1rem 1rem;overflow:auto;border:1px solid var(--line-strong);border-radius:8px;background:var(--code-bg);color:var(--ink);font-size:.83rem;line-height:1.7;white-space:pre-wrap;overflow-wrap:anywhere}pre code{padding:0;border:0;background:transparent;color:inherit;font-size:inherit}.code-copy{position:absolute;top:.55rem;right:.55rem;width:30px;height:30px;display:grid;place-items:center;border:1px solid transparent;border-radius:5px;background:transparent;color:var(--muted)}.code-copy:hover{border-color:var(--line-strong);background:var(--surface);color:var(--accent)}.code-copy[data-copied="true"]{color:var(--success)}.code-copy svg{pointer-events:none}.description blockquote{margin:1rem 0;padding:.1rem 1rem;border-left:2px solid var(--accent);color:var(--muted);background:var(--accent-soft)}.description img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:6px}.description table{width:100%;border-collapse:collapse;margin:1rem 0;font-size:.84rem}.description th,.description td{padding:.55rem .65rem;border:1px solid var(--line);text-align:left;vertical-align:top}.description th{background:var(--surface-subtle);font-weight:680}.description hr{margin:2rem 0;border:0;border-top:1px solid var(--line)}
.declaration-summary{margin:1.25rem 0;padding:1rem 0;border-top:1px solid var(--line)}.declaration-summary p{margin:.3rem 0;color:var(--muted);font-size:.84rem}.declaration-summary .meta{margin-top:.55rem}.empty-state{padding:1rem;border:1px dashed var(--line-strong);border-radius:7px;color:var(--muted)}
.site-footer{border-top:1px solid var(--line);background:var(--surface)}.footer-inner{max-width:1600px;margin:0 auto;padding:1rem 1.25rem;display:flex;align-items:center;justify-content:space-between;gap:1rem;color:var(--muted);font-size:.75rem}.footer-mark{color:var(--ink);font-weight:680}
.align-left{text-align:left}.align-center{text-align:center}.align-right{text-align:right}
@media(max-width:1180px){.docs-layout{grid-template-columns:220px minmax(0,1fr)}.toc-panel{display:none}.site-nav-inner{grid-template-columns:9rem minmax(15rem,1fr) auto}.search-filters{display:none}}
@media(max-width:760px){html{scroll-behavior:auto}.site-nav-inner{display:flex;flex-wrap:wrap;gap:.7rem;padding:.7rem .9rem}.brand{flex:0 0 auto}.top-actions{margin-left:auto}.theme-picker select{max-width:7.6rem}.site-search{order:3;width:100%}.search-shell{height:42px}.docs-layout{display:block}.docs-sidebar{position:static;height:auto;max-height:18rem;padding:1rem .9rem;border-right:0;border-bottom:1px solid var(--line)}.sidebar-section{display:inline}.sidebar-section+.sidebar-section{margin-top:1rem}.sidebar-link{display:inline-flex;margin:.1rem .2rem .1rem 0}.sidebar-group{margin-top:.65rem}.sidebar-packages{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));max-height:7rem;overflow:auto}.sidebar-note{display:none}.docs-main{padding:1.55rem .95rem 3.5rem}.content-column{max-width:none}.page-header{margin-bottom:1.8rem}.page-meta{gap:.4rem .8rem}.module-record{padding:.85rem .8rem}.package-links{grid-template-columns:1fr}.package-index{grid-template-columns:1fr}.symbol-entry dl:not(.relationships){grid-template-columns:1fr;gap:.25rem}.parameter-row{grid-template-columns:minmax(6rem,max-content) minmax(0,1fr);column-gap:.75rem}.parameter-description{grid-column:2}.symbol-entry dd{margin-bottom:.45rem}.relationships{grid-template-columns:1fr;gap:.2rem}.relationships dd{margin-bottom:.55rem}.footer-inner{align-items:flex-start;flex-direction:column;padding:.9rem}}
@media print{.site-nav,.docs-sidebar,.toc-panel{display:none}.docs-layout{display:block}.docs-main{padding:0}.site-footer{margin-top:2rem}.content-column{max-width:none}a{color:inherit;text-decoration:underline}pre{white-space:pre-wrap;overflow:visible}.code-copy{display:none}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition-duration:.01ms!important;animation-duration:.01ms!important;animation-iteration-count:1!important}}
.symbol-entry dl.parameter-list{display:grid;grid-template-columns:minmax(7rem,max-content) minmax(7rem,max-content) minmax(0,1fr);column-gap:1rem;row-gap:0}
.parameter-row{display:grid;grid-column:1/-1;grid-template-columns:subgrid}
.parameter-row dt,.parameter-row dd{min-width:0;margin:0;padding:.7rem 0;border-bottom:1px solid var(--line)}
@media(max-width:760px){.symbol-entry dl.parameter-list{grid-template-columns:minmax(6rem,max-content) minmax(0,1fr);column-gap:.75rem;row-gap:0}.parameter-description{grid-column:2}}
"""

internal let HTML_RETURN_LAYOUT_STYLE = """
.return-value{display:flex;align-items:baseline;flex-wrap:wrap;gap:.65rem;margin:1rem 0;color:var(--muted)}.return-type{flex:0 1 auto;min-width:0;overflow-wrap:anywhere;padding:.13rem .35rem;border:1px solid var(--line);border-radius:5px;background:var(--code-bg);color:var(--ink);font-size:.91em}.return-description{min-width:0;flex:1 1 14rem}.return-description>p{margin:0}
"""

internal let HTML_TYPE_LINK_STYLE = """
.type-link{color:inherit;text-decoration:none;border-radius:3px;transition:background-color .12s ease,color .12s ease}.type-link:hover,.type-link:focus-visible{color:var(--accent);text-decoration:underline;background:var(--accent-soft)}.type-link:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
"""

internal let HTML_NAVIGATION_STYLE = """
.sidebar-package.is-current{background:var(--accent-soft);color:var(--accent-strong);font-weight:680}.sidebar-package.is-current:hover{background:var(--accent-soft);color:var(--accent-strong)}
"""

internal let HTML_TOC_STYLE = """
.toc-panel nav{max-height:calc(100vh - 120px);overflow:auto}.toc-panel ol{margin:0;padding:0;list-style:none}.toc-panel li{margin:0}.toc-panel .toc-api-item+.toc-api-item{margin-top:.22rem}.toc-panel .toc-api-row{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:start;gap:.12rem}.toc-panel .toc-api-row>.toc-link{min-width:0}.toc-panel .toc-toggle{display:grid;place-items:center;width:1.45rem;height:1.8rem;margin:.08rem 0 0;border:0;border-radius:4px;background:transparent;color:var(--faint);cursor:pointer;font:inherit}.toc-panel .toc-toggle:hover{background:var(--accent-soft);color:var(--accent)}.toc-panel .toc-toggle:focus-visible{outline:2px solid var(--accent);outline-offset:-1px}.toc-panel .toc-toggle-icon{font-size:.9rem;line-height:1}.toc-panel .toc-link{display:block;min-width:0;padding:.32rem .58rem;border-left:2px solid transparent;color:var(--muted);font-size:.8rem;line-height:1.45;overflow-wrap:anywhere}.toc-panel .toc-api-link{font-weight:620}.toc-panel .toc-member-link{padding:.25rem .58rem;font-size:.76rem;line-height:1.4}.toc-panel .toc-children{margin:.08rem 0 .28rem .72rem;padding:.08rem 0 .12rem .5rem;border-left:1px solid var(--line)}.toc-panel .toc-children[hidden]{display:none}.toc-panel .toc-link:hover,.toc-panel .toc-link:focus-visible{background:var(--accent-soft);color:var(--ink);text-decoration:none}.toc-panel .toc-link:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}.toc-panel .toc-link.is-active{border-left-color:var(--accent);background:var(--accent-soft);color:var(--accent);font-weight:700}.toc-panel .toc-api-link.is-parent-active{border-left-color:color-mix(in srgb,var(--accent) 55%,transparent);color:var(--accent-strong)}.symbol-entry h3.symbol-title{margin:.05rem 0 .8rem;padding:0;border:0;font-size:1.08rem}.symbol-entry h3.symbol-title code{padding:0;border:0;background:transparent;color:var(--accent)}
"""

internal let HTML_LAYOUT_HARDENING_STYLE = """
.search-results a,.breadcrumbs,.declaration-summary h3,.page-header h1{overflow-wrap:anywhere}.sidebar-package span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.parameter-row{padding:0;border-bottom:0}.parameter-type{white-space:normal;overflow-wrap:anywhere}
"""

internal let HTML_EXAMPLE_STYLE = """
.example-list{display:grid;gap:1rem;margin:1rem 0 1.25rem}.example-block{min-width:0;padding:.85rem 1rem;border:1px solid var(--line);border-radius:8px;background:var(--surface-subtle)}.example-title{margin:0 0 .65rem;color:var(--ink);font-size:.82rem;letter-spacing:0}.example-block pre{margin:.75rem 0 0;background:var(--surface)}.example-block p:first-child{margin-top:0}.example-block p:last-child{margin-bottom:0}
"""
