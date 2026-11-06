package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func contentLanguageLabel(tag: DocTag, locale: String): String {
    let language = tag.contentLanguage.getOrDefault({ => label(locale, "unknown language", "语言未知") })
    match (tag.translationState) {
        case "fallback" => label(locale, "Translation missing. Original text: ", "暂无当前语言翻译，原文：") + language
        case "empty-fallback" => label(locale, "Empty translation; original text: ", "译文为空；原文：") + language
        case "conflict-fallback" => label(locale, "Translation conflict; original text: ", "译文冲突；原文：") + language
        case "empty" => label(locale, "Translation is empty", "译文为空")
        case "conflict" => label(locale, "Translation conflict", "译文冲突")
        case "missing" => label(locale, "Translation missing", "翻译缺失")
        case "unpaired" => if (tag.contentLanguage == Some(locale)) { "" }
            else { label(locale, "Original text: ", "原文：") + language }
        case "unknown" => language
        case _ => language
    }
}

internal func appendContentLanguageHtml(out: RenderTextBuffer, tag: DocTag, locale: String): Unit {
    if (tag.translationState.isEmpty()) { return }
    let text = contentLanguageLabel(tag, locale)
    out.append("<span class=\"content-language\" data-translation-state=\"" + escapeHtml(tag.translationState) + "\"")
    if (text.isEmpty()) { out.append(" hidden") }
    if (let Some(value) <- tag.contentLanguage) { out.append(" lang=\"" + value + "\"") }
    out.append(">" + escapeHtml(text) + "</span>")
}

internal func appendDocumentationTagHtml(out: RenderTextBuffer, tag: DocTag,
    locale: String, assets: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let fieldIdentity = if (context.fieldAnchorNamespace.isEmpty()) { tag.fieldId }
        else { context.fieldAnchorNamespace + tag.fieldId }
    if (!tag.fieldId.isEmpty()) {
        out.append("<div id=\"" + documentationFieldAnchor(fieldIdentity) + "\">")
    }
    appendContentLanguageHtml(out, tag, locale)
    if (let Some(language) <- tag.contentLanguage) { out.append("<div lang=\"" + language + "\">") }
    match (tag.descriptionMarkdown) {
        case Some(tree) =>
            if (!tag.description.trimAscii().isEmpty() && !markdownTreeHasDescriptionContent(tree, assets)) {
                appendStructuredTextHtml(out, tag.description)
            } else {
                let fieldContext = HtmlMarkdownContext(3, locale: locale)
                collectMarkdownHeadings(tree, "field-" + contractFingerprint(
                    fieldIdentity + tag.name + tag.subject),
                    HashMap<String, Int64>(), fieldContext)
                appendMarkdownNodeHtml(out, tree, assets, rootPrefix, fieldContext)
            }
        case None => appendStructuredTextHtml(out, tag.description)
    }
    if (tag.contentLanguage.isSome()) { out.append("</div>") }
    if (!tag.fieldId.isEmpty()) { out.append("</div>") }
}

internal func documentationFieldAnchor(fieldId: String): String { "doc-field-" + contractFingerprint(fieldId) }

internal let LANGUAGE_NAVIGATION_SCRIPT = """
(() => {
  const links = [...document.querySelectorAll('[data-language-routes]')];
  if (!links.length) return;
  const switcher = document.querySelector('details.language-switcher');
  if (switcher) {
    const toggle = switcher.querySelector('.language-label');
    document.addEventListener('click', event => {
      if (!switcher.contains(event.target)) switcher.open = false;
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && switcher.open) {
        switcher.open = false;
        toggle?.focus();
        event.preventDefault();
      }
    });
    switcher.addEventListener('click', event => {
      if (event.target instanceof Element && event.target.closest('a')) switcher.open = false;
    });
  }
  const sectionNotice = document.documentElement.lang === 'zh-CN'
    ? '该语言没有对应章节，打开同一页面的开头'
    : 'No corresponding section in this language; open the start of the same page';
  const pageNotice = document.documentElement.lang === 'zh-CN'
    ? '该语言无此页面，打开语言首页'
    : 'This page is unavailable; open the language home';
  const update = () => {
    let anchor = location.hash.slice(1);
    try { anchor = decodeURIComponent(anchor); } catch (_) {}
    let current = null;
    try { current = new URL(location.href); } catch (_) {}
    for (const link of links) {
      if (!link.dataset.languageBase) link.dataset.languageBase = link.getAttribute('href');
      let routes = {};
      try { routes = JSON.parse(link.dataset.languageRoutes || '{}'); } catch (_) {}
      const candidate = Object.prototype.hasOwnProperty.call(routes, anchor) ? routes[anchor] : null;
      const target = Array.isArray(candidate) && typeof candidate[0] === 'string' ? candidate : null;
      const homeFallback = link.dataset.switchState === 'language-home';
      const missingPosition = !homeFallback && Boolean(anchor) && !target;
      const destination = target && !homeFallback ? target[0] : link.dataset.languageBase;
      try {
        const url = new URL(destination, location.href);
        url.searchParams.delete('tag');
        url.searchParams.delete('moduleId');
        url.searchParams.delete('snapshotId');
        if (current) {
          for (const tag of current.searchParams.getAll('tag')) url.searchParams.append('tag', tag);
          for (const moduleId of current.searchParams.getAll('moduleId')) {
            url.searchParams.append('moduleId', moduleId);
          }
        }
        link.href = url.href;
      } catch (_) { link.href = destination; }
      const state = homeFallback ? 'language-home' : missingPosition ? 'page-start' : 'mapped';
      const noticeText = homeFallback ? pageNotice : missingPosition ? sectionNotice : '';
      link.dataset.positionState = state;
      const notice = link.querySelector('.language-position-notice');
      if (notice) {
        notice.textContent = noticeText;
        notice.hidden = !noticeText;
      }
      if (noticeText) link.title = noticeText;
      else link.removeAttribute('title');
    }
  };
  update();
  if (switcher) {
    // pushState changes search tags without a navigation event; resolve links when used.
    switcher.addEventListener('click', update, true);
    switcher.addEventListener('focusin', update);
  }
  window.addEventListener('popstate', update);
  window.addEventListener('hashchange', update);
  window.addEventListener('pageshow', update);
})();
"""

internal let HTML_LANGUAGE_STYLE = """
.content-language{display:inline-block;font-size:.75rem;color:var(--muted);margin:.15rem .5rem .35rem 0}
.content-language[data-translation-state="complete"]{display:none}
.content-language[hidden]{display:none}
.content-language[data-translation-state="fallback"],.content-language[data-translation-state="missing"],.content-language[data-translation-state="unpaired"]{border-inline-start:2px solid currentColor;padding-inline-start:.5rem}
.site-nav .top-actions{position:relative}
.language-switcher{position:static;flex:0 0 auto;margin:0}
.language-switcher>.language-label{display:flex;align-items:center;gap:.35rem;min-height:36px;padding:0 .6rem;list-style:none;cursor:pointer;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--muted);font-size:.78rem;white-space:nowrap}
.language-label::-webkit-details-marker{display:none}
.language-switcher>.language-label:hover,.language-switcher[open]>.language-label{border-color:var(--accent);background:var(--accent-soft);color:var(--ink)}
.language-label:focus-visible,.language-options a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.language-label svg{flex-shrink:0}
.language-switcher[open]>.language-label svg{transform:rotate(180deg)}
.language-options{position:absolute;z-index:50;top:calc(100% + .45rem);right:0;display:grid;min-width:10rem;max-width:calc(100vw - 2rem);padding:.4rem;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface-raised);box-shadow:var(--shadow)}
.language-options a{display:flex;align-items:flex-start;flex-wrap:wrap;gap:.35rem .55rem;padding:.4rem .6rem;border-radius:5px;color:var(--muted);font-size:.82rem;white-space:normal;min-width:0}
.language-name{flex:0 0 auto;white-space:nowrap}
.language-position-notice{flex:1 1 100%;min-width:0;color:var(--muted);line-height:1.35;overflow-wrap:anywhere}
.language-position-notice[hidden]{display:none}
.language-options a:hover{background:var(--accent-soft);color:var(--ink);text-decoration:none}
.language-options [aria-current="page"]{background:var(--surface-subtle);color:var(--accent-strong);font-weight:700}
"""
