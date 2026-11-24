protected package cjdoc.render.browser

internal let HTML_SEARCH_CONTROLLER_FIELDS_SCRIPT = #"
    const fieldController = commentFieldControls && !indexCapabilityError ? (() => {
      let appliedCommentFields = [];
      const fieldDefinitions = index.commentFields;
      const fieldModule = definition => index.modules[definition.scope];
      const fieldCaption = definition => {
        const module = fieldModule(definition);
        return (module.moduleName || module.moduleId) + " · " + definition.title;
      };
      const selectedFieldDefinition = () => {
        const key = commentFieldControls?.definition.value;
        return key ? fieldDefinitions[Number(key)] : null;
      };
      let catalogCursor = null;
      let catalogScope;
      const clearFieldValueChoices = () => {
        const {value, more} = commentFieldControls;
        value.replaceChildren(value.options[0]);
        value.disabled = true;
        more.hidden = true;
        catalogCursor = null;
      };
      const loadFieldValues = (next = false) => {
        if (!next) clearFieldValueChoices();
        const definition = selectedFieldDefinition();
        if (!definition) return;
        const options = {id: definition.id};
        if (next) {
          if (!catalogCursor) return;
          options.cursor = catalogCursor;
        }
        const execution = kernel.execute(index, {operation: "search", profile: "bounded-static",
          moduleId: fieldModule(definition).moduleId, commentFieldFacets: options});
        if (execution.errorCode) { showError(execution.errorCode); return; }
        const {value, more} = commentFieldControls;
        const page = execution.facets.commentFields;
        for (const row of page.items) {
          const option = createElement("option", undefined, row.value + " (" + row.count + ")");
          option.value = row.value;
          value.append(option);
        }
        value.disabled = value.options.length < 2 || appliedCommentFields.length >= 64;
        catalogCursor = page.next;
        more.hidden = !catalogCursor;
        if (next && more.hidden) value.focus();
      };
      const moduleMatchesUrl = module => urlSearchState.moduleId === null ||
        urlSearchState.moduleId === module.moduleId || urlSearchState.moduleId === module.moduleName;
      const refreshFieldControls = () => {
        if (!fieldDefinitions.length) return;
        const {definition, value, active} = commentFieldControls;
        if (appliedCommentFields.some(row => !moduleMatchesUrl(fieldModule(row.definition)))) {
          appliedCommentFields = [];
          saveSelectedFilters();
        }
        const scopedModule = appliedCommentFields[0]?.definition.scope;
        const scope = JSON.stringify([urlSearchState.moduleId, scopedModule]);
        if (catalogScope !== scope) {
          catalogScope = scope;
          const previous = definition.value;
          definition.replaceChildren(definition.options[0]);
          for (const [position, choice] of fieldDefinitions.entries()) {
            if ((scopedModule !== undefined && choice.scope !== scopedModule) ||
                !moduleMatchesUrl(fieldModule(choice))) continue;
            const option = createElement("option", undefined, fieldCaption(choice));
            option.value = String(position);
            definition.append(option);
          }
          definition.value = previous;
          if (definition.selectedIndex === -1) definition.value = "";
          loadFieldValues();
        }
        definition.disabled = definition.options.length < 2;
        const current = selectedFieldDefinition();
        for (let i = 1; i < value.options.length; i += 1) {
          const option = value.options[i];
          option.disabled = appliedCommentFields.some(row =>
            row.definition === current && row.value === option.value);
        }
        value.disabled = value.options.length < 2 || appliedCommentFields.length >= 64;
        active.replaceChildren();
        for (const row of appliedCommentFields) {
          const label = fieldCaption(row.definition) + " = " + row.value;
          const button = createElement("button", "cj-search__facet", label + " ×");
          button.type = "button";
          button.setAttribute("aria-label", text("Remove ", "移除 ") + label);
          button.addEventListener("click", () => {
            appliedCommentFields = appliedCommentFields.filter(item => item !== row);
            selectedFilterChanged();
            definition.focus();
          });
          active.append(button);
        }
        if (appliedCommentFields.length > 1) {
          const clear = createElement("button", "cj-search__facet",
            text("Clear comment fields", "清空注释字段"));
          clear.type = "button";
          clear.addEventListener("click", () => {
            appliedCommentFields = [];
            selectedFilterChanged();
            definition.focus();
          });
          active.append(clear);
        }
        active.hidden = !appliedCommentFields.length;
      };
      const restoreCommentFields = saved => {
        if (!fieldDefinitions.length || !Array.isArray(saved) || saved.length > 64) return;
        for (const row of saved) {
          if (!row || typeof row.value !== "string" || !row.value) continue;
          const definition = fieldDefinitions.find(field => field.id === row.id &&
            fieldModule(field).moduleId === row.moduleId);
          if (!definition || !moduleMatchesUrl(fieldModule(definition)) ||
              appliedCommentFields.some(item => item.definition.scope !== definition.scope ||
                (item.definition === definition && item.value === row.value))) continue;
          appliedCommentFields.push({definition, value: row.value});
        }
      };
      if (fieldDefinitions.length) {
        const {definition, value, more} = commentFieldControls;
        definition.addEventListener("change", () => loadFieldValues());
        value.addEventListener("change", () => {
          const chosen = selectedFieldDefinition();
          if (chosen && value.value && appliedCommentFields.length < 64) {
            appliedCommentFields.push({definition: chosen, value: value.value});
            value.value = "";
            selectedFilterChanged();
          }
        });
        more.addEventListener("click", () => loadFieldValues(true));
      }
      return {
        refresh: refreshFieldControls, restore: restoreCommentFields,
        get hasPredicates() { return appliedCommentFields.length > 0; },
        constrain(request) {
          if (!appliedCommentFields.length) return;
          request.moduleId = fieldModule(appliedCommentFields[0].definition).moduleId;
          request.commentFields = appliedCommentFields.map(row => ({id: row.definition.id, value: row.value}));
        },
        saved() {
          if (!appliedCommentFields.length) return undefined;
          return {commentFieldSnapshotId: index.scope.snapshotId,
            commentFields: appliedCommentFields.map(row => ({
              moduleId: fieldModule(row.definition).moduleId, id: row.definition.id, value: row.value
            }))};
        }
      };
    })() : null;
"#
