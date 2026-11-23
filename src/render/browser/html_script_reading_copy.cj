protected package cjdoc.render.browser

// Signature, link and code copy actions; preserve bound clipboard bytes.
internal let HTML_READING_COPY_SCRIPT = """
  const copyText = async value => {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(value); return true; } catch (_) { /* fallback */ }
    }
    const previousFocus = document.activeElement;
    const area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "");
    area.className = "cj-sr-only";
    document.body.append(area);
    area.select();
    let copied = false;
    const preserveOriginal = event => {
      if (event.clipboardData) {
        event.clipboardData.setData("text/plain", value);
        event.preventDefault();
      }
    };
    document.addEventListener("copy", preserveOriginal);
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    finally { document.removeEventListener("copy", preserveOriginal); area.remove(); }
    if (previousFocus && typeof previousFocus.focus === "function") previousFocus.focus();
    return copied;
  };
  const flashCopyState = (button, copied) => {
    button.dataset.cjdocCopyState = copied ? "copied" : "failed";
    window.setTimeout(() => { delete button.dataset.cjdocCopyState; }, 1500);
  };
  const initCopy = () => {
    document.addEventListener("click", async event => {
      const button = event.target.closest?.("[data-cjdoc-copy-link]");
      if (!button) return;
      const iconOnly = !button.textContent.trim();
      const label = button.getAttribute("aria-label") || button.textContent || "";
      const status = button.parentElement
        ? button.parentElement.querySelector("[data-cjdoc-copy-status]") : null;
      let url = button.dataset.cjdocCopyLink || "";
      try {
        url = new URL(globalThis.__CJDOC_API_ROUTE__(url), window.location.href).href;
      } catch (_) { /* keep raw */ }
      const copied = await copyText(url);
      const message = copied ? text("Link copied", "链接已复制")
        : text("Select and copy the link", "请选择并复制链接");
      flashCopyState(button, copied);
      if (iconOnly) {
        button.setAttribute("aria-label", message);
        button.setAttribute("title", message);
      } else {
        const labelNode = button.querySelector("span") || button.lastChild;
        if (labelNode) labelNode.textContent = message;
        if (button.hasAttribute("aria-label")) button.setAttribute("aria-label", message);
      }
      if (status) status.textContent = message;
      if (!copied) {
        let field = button.parentElement?.querySelector("[data-cjdoc-copy-link-fallback]");
        if (!field) {
          field = element("input", "cj-input");
          field.type = "text";
          field.readOnly = true;
          field.dataset.cjdocCopyLinkFallback = "";
          field.setAttribute("aria-label", text("Link address", "链接地址"));
          button.insertAdjacentElement("afterend", field);
        }
        field.value = url;
        field.focus();
        field.select();
      }
      window.setTimeout(() => {
        if (iconOnly) {
          button.setAttribute("aria-label", label);
          button.setAttribute("title", label);
          if (status) status.textContent = "";
        }
      }, 1800);
    });
    for (const code of all("pre > code")) {
      const panel = code.closest("[data-cjdoc-copy-panel]");
      const host = panel?.querySelector("[data-cjdoc-copy-toolbar]") || code.parentElement;
      if (!host || host.querySelector("[data-cjdoc-copy]")) continue;
      const copyLabel = panel?.dataset.cjdocCopyPanel === "output"
        ? text("Copy output", "复制输出") : text("Copy code", "复制代码");
      const button = attrs(element("button", "cj-button cj-button--quiet cj-code__copy"), {
        type: "button", "data-cjdoc-copy": "", "aria-label": copyLabel, title: copyLabel
      });
      const glyph = icon();
      glyph.append(svg("rect", {x: "8", y: "8", width: "12", height: "12", rx: "2"}),
        svg("path", {d: "M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"}));
      const idleCaption = panel ? copyLabel : text("Copy", "复制");
      const caption = element("span", "", idleCaption);
      button.append(glyph, caption);
      host.append(button);
      button.addEventListener("click", async () => {
        const original = code.getAttribute("data-cjdoc-source");
        let value = code.textContent || "";
        if (original !== null) {
          try { value = JSON.parse(original); } catch (_) { /* keep text */ }
        }
        const copied = await copyText(value);
        flashCopyState(button, copied);
        const feedback = copied ? text("Copied", "已复制") : copyLabel;
        caption.textContent = copied ? feedback : idleCaption;
        attrs(button, {"aria-label": feedback, title: feedback});
        setTimeout(() => {
          caption.textContent = idleCaption;
          attrs(button, {"aria-label": copyLabel, title: copyLabel});
        }, 1500);
      });
    }
  };

"""
