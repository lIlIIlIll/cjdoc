package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func contentLanguageLabel(tag: DocTag, locale: String): String {
    let language = tag.contentLanguage.getOrDefault({ => label(locale, "unknown language", "语言未知") })
    match (tag.translationState) {
        case "fallback" => label(locale, "Original text: ", "原文：") + language
        case "empty-fallback" => label(locale, "Empty translation; original text: ", "译文为空；原文：") + language
        case "conflict-fallback" => label(locale, "Translation conflict; original text: ", "译文冲突；原文：") + language
        case "empty" => label(locale, "Translation is empty", "译文为空")
        case "conflict" => label(locale, "Translation conflict", "译文冲突")
        case "missing" => label(locale, "Translation missing", "翻译缺失")
        case "unpaired" => label(locale, "Independent entry: ", "独立条目：") + language
        case "unknown" => language
        case _ => language
    }
}

internal func appendContentLanguageHtml(out: RenderTextBuffer, tag: DocTag, locale: String): Unit {
    if (tag.translationState.isEmpty()) { return }
    out.append("<span class=\"content-language\" data-translation-state=\"" + escapeHtml(tag.translationState) + "\"")
    if (let Some(value) <- tag.contentLanguage) { out.append(" lang=\"" + value + "\"") }
    out.append(">" + escapeHtml(contentLanguageLabel(tag, locale)) + "</span>")
}

internal func appendDocumentationTagHtml(out: RenderTextBuffer, tag: DocTag,
    locale: String, assets: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    if (!tag.fieldId.isEmpty()) { out.append("<div id=\"" + documentationFieldAnchor(tag.fieldId) + "\">") }
    appendContentLanguageHtml(out, tag, locale)
    if (let Some(language) <- tag.contentLanguage) { out.append("<div lang=\"" + language + "\">") }
    match (tag.descriptionMarkdown) {
        case Some(tree) =>
            let fieldContext = HtmlMarkdownContext(3)
            collectMarkdownHeadings(tree, "field-" + contractFingerprint(tag.fieldId + tag.name + tag.subject), HashMap<String, Int64>(), fieldContext)
            appendMarkdownNodeHtml(out, tree, assets, rootPrefix, fieldContext)
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
  const update = () => {
    let anchor = location.hash.slice(1);
    try { anchor = decodeURIComponent(anchor); } catch (_) {}
    for (const link of links) {
      if (!link.dataset.languageBase) link.dataset.languageBase = link.getAttribute('href');
      let routes = {};
      try { routes = JSON.parse(link.dataset.languageRoutes || '{}'); } catch (_) {}
      const candidate = Object.prototype.hasOwnProperty.call(routes, anchor) ? routes[anchor] : null;
      const target = Array.isArray(candidate) && typeof candidate[0] === 'string' ? candidate : null;
      link.href = target ? target[0] : link.dataset.languageBase;
      link.dataset.positionState = anchor && !target ? 'page-start' : 'mapped';
      if (anchor && !target && link.dataset.switchState !== 'language-home') {
        link.title = document.documentElement.lang === 'zh-CN'
          ? '该语言没有对应章节，打开同一页面的开头'
          : 'No corresponding section in this language; open the start of the same page';
      }
    }
  };
  update();
  window.addEventListener('hashchange', update);
  window.addEventListener('pageshow', update);
})();
"""

internal let HTML_LANGUAGE_STYLE = """
.content-language{display:inline-block;font-size:.75rem;color:var(--muted);margin:.15rem .5rem .35rem 0}
.content-language[data-translation-state="complete"]{display:none}
.content-language[data-translation-state="fallback"],.content-language[data-translation-state="missing"],.content-language[data-translation-state="unpaired"]{border-inline-start:2px solid currentColor;padding-inline-start:.5rem}
.language-switcher{display:flex;gap:.6rem;flex-wrap:wrap;margin-block:.8rem}
.language-switcher [aria-current="page"]{font-weight:700;text-decoration-thickness:2px}
"""
