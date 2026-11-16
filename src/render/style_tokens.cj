package cjdoc.render

// Design tokens: one neutral ramp plus a single accent per theme. Every theme
// remaps the same roles, so components never branch on the theme name. All
// foreground/background role pairs meet WCAG AA (text 4.5:1, UI borders 3:1).
// Reader preferences (data-cj-font/data-cj-size) are declared after the
// themes and out-rank the optional `--html-font-*` override appended last.
internal let HTML_TOKENS_STYLE = """
:root {
  color-scheme: light;
  --cj-bg: #ffffff;
  --cj-surface: #f6f7f9;
  --cj-surface-2: #eceef2;
  --cj-fg: #16181d;
  --cj-muted: #565c66;
  --cj-border: #e3e6eb;
  --cj-border-strong: #858c97;
  --cj-accent: #2952c4;
  --cj-accent-fg: #ffffff;
  --cj-accent-soft: #ebf0fc;
  --cj-code-bg: #f5f6f8;
  --cj-code-keyword: #8b2fa8;
  --cj-code-type: #0f6a7d;
  --cj-code-string: #2c6b2f;
  --cj-code-number: #a1440f;
  --cj-code-comment: #5f6670;
  --cj-code-function: #3e4fb8;
  --cj-code-operator: #5a4f66;
  --cj-code-meta: #8b2fa8;
  --cj-success: #1d6b3a;
  --cj-warning: #8a5a00;
  --cj-danger: #b42335;
  --cj-shadow: 0 12px 32px rgb(16 24 40 / .12), 0 2px 6px rgb(16 24 40 / .06);
  --cj-font-sans: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
  --cj-font-mono: ui-monospace, "SFMono-Regular", "Cascadia Mono", "JetBrains Mono", Menlo, Consolas, monospace;
  --cj-font-serif: ui-serif, Georgia, "Songti SC", "Noto Serif CJK SC", serif;
  --cj-font-size: 100%;
  --cj-space-1: .25rem;
  --cj-space-2: .5rem;
  --cj-space-3: .75rem;
  --cj-space-4: 1rem;
  --cj-space-5: 1.5rem;
  --cj-space-6: 2.5rem;
  --cj-radius: 6px;
  --cj-header-height: 3.25rem;
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --cj-bg: #0e1014;
  --cj-surface: #15181e;
  --cj-surface-2: #1c2028;
  --cj-fg: #e6e8ec;
  --cj-muted: #a0a7b2;
  --cj-border: #262b34;
  --cj-border-strong: #6c7482;
  --cj-accent: #8aaeff;
  --cj-accent-fg: #0b0e14;
  --cj-accent-soft: #1b2540;
  --cj-code-bg: #13161c;
  --cj-code-keyword: #d19cf0;
  --cj-code-type: #6fd0dc;
  --cj-code-string: #9ad38a;
  --cj-code-number: #f0a874;
  --cj-code-comment: #959caa;
  --cj-code-function: #a9bcff;
  --cj-code-operator: #b9b2c6;
  --cj-code-meta: #d19cf0;
  --cj-success: #79d49a;
  --cj-warning: #e9bf6a;
  --cj-danger: #ff8a95;
  --cj-shadow: 0 16px 40px rgb(0 0 0 / .45), 0 2px 6px rgb(0 0 0 / .3);
}
:root[data-theme="paper"] {
  color-scheme: light;
  --cj-bg: #f7f3ea;
  --cj-surface: #efe9dc;
  --cj-surface-2: #e7dfcf;
  --cj-fg: #29241c;
  --cj-muted: #625a4c;
  --cj-border: #e0d7c5;
  --cj-border-strong: #8a7f69;
  --cj-accent: #8c3f13;
  --cj-accent-fg: #ffffff;
  --cj-accent-soft: #f1e3d4;
  --cj-code-bg: #f0eadd;
  --cj-code-keyword: #7d2f8c;
  --cj-code-type: #155e6e;
  --cj-code-string: #3d6624;
  --cj-code-number: #9a3d0c;
  --cj-code-comment: #685f51;
  --cj-code-function: #3b4f9c;
  --cj-code-operator: #5d5348;
  --cj-code-meta: #7d2f8c;
  --cj-success: #2f6a2a;
  --cj-warning: #7f5300;
  --cj-danger: #a3242f;
  --cj-shadow: 0 12px 32px rgb(16 24 40 / .12), 0 2px 6px rgb(16 24 40 / .06);
}
:root[data-theme="ocean"] {
  color-scheme: dark;
  --cj-bg: #0a1520;
  --cj-surface: #0f1e2c;
  --cj-surface-2: #152739;
  --cj-fg: #e2eef6;
  --cj-muted: #98afc0;
  --cj-border: #1d3244;
  --cj-border-strong: #52708a;
  --cj-accent: #5cc8e6;
  --cj-accent-fg: #04131c;
  --cj-accent-soft: #12304a;
  --cj-code-bg: #0c1a27;
  --cj-code-keyword: #c7a0f5;
  --cj-code-type: #62d6c4;
  --cj-code-string: #a5d98c;
  --cj-code-number: #f2b07a;
  --cj-code-comment: #8ea6b8;
  --cj-code-function: #8cc4ff;
  --cj-code-operator: #b0c2d0;
  --cj-code-meta: #c7a0f5;
  --cj-success: #6fd8a0;
  --cj-warning: #ecc36f;
  --cj-danger: #ff8f9a;
  --cj-shadow: 0 16px 40px rgb(0 0 0 / .45), 0 2px 6px rgb(0 0 0 / .3);
}
:root[data-theme="forest"] {
  color-scheme: light;
  --cj-bg: #f5f7f2;
  --cj-surface: #ecf0e7;
  --cj-surface-2: #e2e8db;
  --cj-fg: #1b241d;
  --cj-muted: #526055;
  --cj-border: #d8dfd1;
  --cj-border-strong: #7c8875;
  --cj-accent: #2a6a36;
  --cj-accent-fg: #ffffff;
  --cj-accent-soft: #e1eedf;
  --cj-code-bg: #edf1e8;
  --cj-code-keyword: #7c3592;
  --cj-code-type: #13646e;
  --cj-code-string: #2f6a22;
  --cj-code-number: #984210;
  --cj-code-comment: #56625a;
  --cj-code-function: #2f5596;
  --cj-code-operator: #4c5a50;
  --cj-code-meta: #7c3592;
  --cj-success: #25692f;
  --cj-warning: #7c5600;
  --cj-danger: #a92c34;
  --cj-shadow: 0 12px 32px rgb(16 24 40 / .12), 0 2px 6px rgb(16 24 40 / .06);
}
:root[data-theme="terminal"] {
  color-scheme: dark;
  --cj-bg: #070b07;
  --cj-surface: #0c130c;
  --cj-surface-2: #121b12;
  --cj-fg: #c9f2c7;
  --cj-muted: #86b487;
  --cj-border: #1a2a1a;
  --cj-border-strong: #3f6a42;
  --cj-accent: #62e07c;
  --cj-accent-fg: #031006;
  --cj-accent-soft: #12301a;
  --cj-code-bg: #091009;
  --cj-code-keyword: #e6d36b;
  --cj-code-type: #6fe0d0;
  --cj-code-string: #b5f28b;
  --cj-code-number: #f2a96a;
  --cj-code-comment: #7fa883;
  --cj-code-function: #9fe8a8;
  --cj-code-operator: #a9cfaa;
  --cj-code-meta: #e6d36b;
  --cj-success: #7fe39a;
  --cj-warning: #e8c86a;
  --cj-danger: #ff8d8d;
  --cj-shadow: 0 16px 40px rgb(0 0 0 / .45), 0 2px 6px rgb(0 0 0 / .3);
  --cj-font-sans: var(--cj-font-mono);
}
:root[data-theme="violet"] {
  color-scheme: light;
  --cj-bg: #fbfaff;
  --cj-surface: #f3f1fb;
  --cj-surface-2: #e9e5f6;
  --cj-fg: #1d1830;
  --cj-muted: #5e5775;
  --cj-border: #e3def2;
  --cj-border-strong: #8a82a0;
  --cj-accent: #5f35c0;
  --cj-accent-fg: #ffffff;
  --cj-accent-soft: #ece6fb;
  --cj-code-bg: #f4f2fb;
  --cj-code-keyword: #9a2f8c;
  --cj-code-type: #16637a;
  --cj-code-string: #2f6a35;
  --cj-code-number: #a1440f;
  --cj-code-comment: #615a74;
  --cj-code-function: #4740b8;
  --cj-code-operator: #584f6c;
  --cj-code-meta: #9a2f8c;
  --cj-success: #256a3a;
  --cj-warning: #825600;
  --cj-danger: #ad2640;
  --cj-shadow: 0 12px 32px rgb(16 24 40 / .12), 0 2px 6px rgb(16 24 40 / .06);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    color-scheme: dark;
    --cj-bg: #0e1014;
    --cj-surface: #15181e;
    --cj-surface-2: #1c2028;
    --cj-fg: #e6e8ec;
    --cj-muted: #a0a7b2;
    --cj-border: #262b34;
    --cj-border-strong: #6c7482;
    --cj-accent: #8aaeff;
    --cj-accent-fg: #0b0e14;
    --cj-accent-soft: #1b2540;
    --cj-code-bg: #13161c;
    --cj-code-keyword: #d19cf0;
    --cj-code-type: #6fd0dc;
    --cj-code-string: #9ad38a;
    --cj-code-number: #f0a874;
    --cj-code-comment: #959caa;
    --cj-code-function: #a9bcff;
    --cj-code-operator: #b9b2c6;
    --cj-code-meta: #d19cf0;
    --cj-success: #79d49a;
    --cj-warning: #e9bf6a;
    --cj-danger: #ff8a95;
    --cj-shadow: 0 16px 40px rgb(0 0 0 / .45), 0 2px 6px rgb(0 0 0 / .3);
  }
}
:root[data-cj-font="serif"] { --cj-font-sans: var(--cj-font-serif); }
:root[data-cj-font="mono-ui"] { --cj-font-sans: var(--cj-font-mono); }
:root[data-cj-size="s"] { --cj-font-size: 93.75%; }
:root[data-cj-size="l"] { --cj-font-size: 112.5%; }
.cj-settings__swatch[data-cjdoc-swatch="system"] { background: linear-gradient(135deg, #ffffff 0 50%, #0e1014 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="light"] { background: linear-gradient(135deg, #ffffff 0 50%, #2952c4 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="dark"] { background: linear-gradient(135deg, #0e1014 0 50%, #8aaeff 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="paper"] { background: linear-gradient(135deg, #f7f3ea 0 50%, #8c3f13 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="ocean"] { background: linear-gradient(135deg, #0a1520 0 50%, #5cc8e6 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="forest"] { background: linear-gradient(135deg, #f5f7f2 0 50%, #2a6a36 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="terminal"] { background: linear-gradient(135deg, #070b07 0 50%, #62e07c 50% 100%); }
.cj-settings__swatch[data-cjdoc-swatch="violet"] { background: linear-gradient(135deg, #fbfaff 0 50%, #5f35c0 50% 100%); }
"""
