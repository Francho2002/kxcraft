(() => {
  "use strict";

  const dataNode = document.getElementById("kxcraft-schematics");
  const grid = document.getElementById("schematics-grid");
  const countNode = document.getElementById("schematics-count");
  const emptyNode = document.getElementById("schematics-empty");
  const searchInput = document.getElementById("schematics-search");
  const categoryFilters = document.getElementById("schematics-category-filters");
  const aircraftClassifier = document.getElementById("schematics-aircraft-classifier");
  const aircraftFilters = document.getElementById("schematics-aircraft-filters");
  const backToTop = document.getElementById("back-to-top");
  if (backToTop) {
    const updateBackToTop = () => { backToTop.hidden = window.scrollY < 480; };
    window.addEventListener("scroll", updateBackToTop, { passive: true });
    backToTop.addEventListener("click", () => {
      window.scrollTo({ top: 0, behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    });
    updateBackToTop();
  }
  if (!dataNode || !grid || !countNode || !emptyNode || !searchInput || !categoryFilters || !aircraftClassifier || !aircraftFilters) return;

  const survivalWarningTypes = new Set([
    "creative_motor",
    "creative_power",
    "creative_ammunition",
    "creative_component",
    "survival_adaptation",
    "version_compatibility",
    "functional_issue",
    "dependency_note"
  ]);

  const makeElement = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  const safeUrl = (value) => {
    try {
      const url = new URL(String(value ?? ""));
      return url.protocol === "https:" && !url.username && !url.password ? url : null;
    } catch {
      return null;
    }
  };

  const localSchematicImages = new Set([
    "assets/kxcraft-jumbo-green-airplane.png",
    "assets/kxcraft-landkreuzer-ratte.png"
  ]);

  const safeSchematicImageUrl = (value) => {
    const source = String(value ?? "").trim();
    if (localSchematicImages.has(source)) {
      try {
        return new URL(source, document.baseURI);
      } catch {
        return null;
      }
    }
    const url = safeUrl(source);
    if (url?.hostname === "createmod.com" && url.pathname.startsWith("/api/files/schematics/")) return url;
    if (url?.hostname === "i.ytimg.com" && /^\/vi\/[a-zA-Z0-9_-]{11}\/hqdefault\.jpg$/.test(url.pathname)) return url;
    return null;
  };

  let source;
  try {
    source = JSON.parse(dataNode.textContent);
  } catch {
    source = [];
  }
  const allItems = Array.isArray(source) ? source : Array.isArray(source?.schematics) ? source.schematics : [];
  const items = allItems.filter((item) => {
    const createUrl = safeUrl(item?.createUrl);
    const imageUrl = String(item?.imageUrl ?? "").trim();
    const warnings = item?.survivalWarnings ?? [];
    const validImage = !imageUrl || localSchematicImages.has(imageUrl) || Boolean(safeSchematicImageUrl(imageUrl));
    const validSchematicPath = Boolean(createUrl &&
      (createUrl.pathname.startsWith("/schematics/") || createUrl.pathname.startsWith("/es/schematics/")));
    const validWarnings = Array.isArray(warnings) && warnings.every((warning) =>
      warning && survivalWarningTypes.has(warning.type) && typeof warning.description === "string");
    return item && typeof item.title === "string" && typeof item.category === "string" &&
      typeof item.price === "string" && Array.isArray(item.requiredMods) &&
      Array.isArray(item.missingMods) && ["listed", "not_listed"].includes(item.requirementsStatus) &&
      createUrl?.hostname === "createmod.com" && validSchematicPath && validImage && validWarnings;
  });

  // Preferir IDs de bloques publicados en CreateMod, con registro del origen.
  // El esquema histórico de auditoría de registros se conserva por compatibilidad.
  // Una coincidencia nominal de mods nunca demuestra paridad de IDs.
  const blockIdPattern = /^[a-z0-9_.-]+:[a-z0-9_.\/-]+$/;
  const isExactBlockIdAudit = (audit) => {
    if (!audit || audit.method !== "exact-block-id" ||
        audit.source !== "schematic-nbt-palette-vs-installed-block-registry" ||
        typeof audit.schematicSha256 !== "string" ||
        typeof audit.registrySha256 !== "string" ||
        !/^[0-9a-f]{64}$/.test(audit.schematicSha256) ||
        !/^[0-9a-f]{64}$/.test(audit.registrySha256) ||
        !Array.isArray(audit.requiredBlockIds) || !Array.isArray(audit.missingBlockIds) ||
        !Number.isSafeInteger(audit.registeredBlockCount) || audit.registeredBlockCount < 1 ||
        audit.requiredBlockIds.length < 1 ||
        !audit.requiredBlockIds.every((id) => typeof id === "string" && blockIdPattern.test(id)) ||
        !audit.missingBlockIds.every((id) => typeof id === "string" && blockIdPattern.test(id))) return false;
    const required = new Set(audit.requiredBlockIds);
    return required.size === audit.requiredBlockIds.length &&
      audit.missingBlockIds.length === new Set(audit.missingBlockIds).size &&
      audit.missingBlockIds.every((id) => required.has(id));
  };

  const categories = [...new Set(items.map((item) => item.category))].sort((a, b) => a.localeCompare(b, "es"));
  const categoryKeys = new Map([
    ["Aeronaves", "aeronaves"],
    ["Artillería y defensa", "defensa"],
    ["Bases e infraestructura", "infraestructura"],
    ["Energía y generación", "energia"],
    ["Granjas y recursos", "granjas"],
    ["Industria y automatización", "industria"],
    ["Náutica", "nautica"],
    ["Naves espaciales", "espacio"],
    ["Pociones y alquimia", "alquimia"],
    ["Robótica y mechas", "robotica"],
    ["Trenes y ferrocarril", "trenes"],
    ["Vehículos terrestres", "terrestres"]
  ]);
  const categoryKey = (category) => categoryKeys.get(category) || "general";
  const defaultCategory = categories.includes("Aeronaves") ? "Aeronaves" : "all";
  let activeCategory = defaultCategory;
  let activeAircraftSubcategory = null;
  const aircraftItems = items.filter((item) => item.category === "Aeronaves");
  const aircraftSubcategories = [
    "Cazas e interceptores",
    "Ataque y bombardeo",
    "Helicópteros",
    "VTOL y tiltrotor",
    "Transporte y carga",
    "Dirigibles y cruceros",
    "Hidroaviones",
    "Civiles y personales",
    "Prototipos",
    "Diseños especiales"
  ];
  const aircraftSubcategoryCounts = new Map(aircraftSubcategories.map((subcategory) => [
    subcategory,
    aircraftItems.filter((item) => item.subcategory === subcategory).length
  ]));

  const syncFilterStates = () => {
    aircraftClassifier.hidden = activeCategory !== "Aeronaves";
    for (const filter of categoryFilters.querySelectorAll(".schematic-category-filter")) {
      filter.setAttribute("aria-pressed", filter.dataset.category === activeCategory ? "true" : "false");
    }
    for (const filter of aircraftFilters.querySelectorAll(".schematic-subcategory-filter")) {
      filter.setAttribute("aria-pressed", filter.dataset.subcategory === activeAircraftSubcategory ? "true" : "false");
    }
  };

  const categoryButton = (category, count, filterValue = category) => {
    const button = makeElement("button", "schematic-category-filter");
    button.type = "button";
    button.dataset.category = filterValue;
    button.dataset.categoryKey = categoryKey(category);
    button.setAttribute("aria-pressed", "false");
    button.append(makeElement("span", "schematic-category-filter-name", category));
    button.append(makeElement("span", "schematic-category-filter-count", String(count)));
    button.addEventListener("click", () => {
      if (filterValue === "Aeronaves" && activeCategory === "Aeronaves" && activeAircraftSubcategory) {
        activeAircraftSubcategory = null;
      } else {
        activeCategory = activeCategory === filterValue ? "all" : filterValue;
        activeAircraftSubcategory = null;
      }
      syncFilterStates();
      render();
    });
    return button;
  };

  const categoryCounts = new Map(categories.map((category) => [category, items.filter((item) => item.category === category).length]));
  for (const category of categories) categoryFilters.append(categoryButton(category, categoryCounts.get(category)));
  for (const subcategory of aircraftSubcategories) {
    const count = aircraftSubcategoryCounts.get(subcategory);
    if (!count) continue;
    const button = makeElement("button", "schematic-category-filter schematic-subcategory-filter");
    button.type = "button";
    button.dataset.subcategory = subcategory;
    button.dataset.categoryKey = "aeronaves";
    button.setAttribute("aria-pressed", "false");
    button.append(makeElement("span", "schematic-category-filter-name", subcategory));
    button.append(makeElement("span", "schematic-category-filter-count", String(count)));
    button.addEventListener("click", () => {
      activeCategory = "Aeronaves";
      activeAircraftSubcategory = activeAircraftSubcategory === subcategory ? null : subcategory;
      syncFilterStates();
      render();
    });
    aircraftFilters.append(button);
  }

  const makeModList = (names, className) => {
    const list = makeElement("ul", className);
    for (const name of names) list.append(makeElement("li", "", name));
    return list;
  };

  const makeCard = (item) => {
    const createUrl = safeUrl(item.createUrl);
    const card = makeElement("article", "schematic-card");
    card.dataset.categoryKey = categoryKey(item.category);
    if (item.id === "mini-autokannon") card.classList.add("schematic-card--mini-spotlight");
    const media = makeElement("div", "schematic-media");
    media.dataset.categoryKey = categoryKey(item.category);
    const imageUrl = safeSchematicImageUrl(item.imageUrl);
    const makeCreateLink = (className, label) => {
      const link = makeElement("a", className, label);
      link.href = createUrl.href;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.setAttribute("aria-label", "Abrir " + item.title + " en CreateMod en una pestaña nueva");
      return link;
    };

    if (imageUrl) {
      const image = document.createElement("img");
      image.src = imageUrl.href;
      image.alt = item.imageAlt || (item.title + ", imagen de CreateMod");
      image.loading = "lazy";
      image.decoding = "async";
      image.referrerPolicy = "no-referrer";
      const imageLink = makeCreateLink("schematic-image-link", "");
      imageLink.append(image);
      image.addEventListener("error", () => {
        card.classList.add("schematic-card--image-missing");
        imageLink.replaceWith(makeCreateLink("schematic-image-fallback", "Ver imágenes originales en CreateMod"));
      }, { once: true });
      media.append(imageLink);
    } else {
      card.classList.add("schematic-card--image-missing");
      const fallback = makeCreateLink("schematic-image-fallback", "Ver imágenes originales en CreateMod");
      fallback.dataset.categoryKey = categoryKey(item.category);
      media.append(fallback);
      // Foto real en CreateMod: recuperación por metadatos de la ficha exacta.
      if (window.KxCreateModPreview) {
        window.KxCreateModPreview.watch(media, item.createUrl, (photoUrl) => {
          if (!photoUrl || !media.isConnected) return;
          const photo = safeSchematicImageUrl(photoUrl);
          if (!photo) return;
          const picture = document.createElement("img");
          picture.src = photo.href;
          picture.alt = "Vista original de " + item.title + " en CreateMod";
          picture.loading = "lazy";
          picture.decoding = "async";
          picture.referrerPolicy = "no-referrer";
          picture.addEventListener("load", () => {
            card.classList.remove("schematic-card--image-missing");
            const photoLink = makeCreateLink("schematic-image-link", "");
            photoLink.append(picture);
            fallback.replaceWith(photoLink);
          }, {once:true});
        });
      }
    }

    const body = makeElement("div", "schematic-body");
    const badgeRow = makeElement("div", "schematic-badges");
    const badge = makeElement("span", "schematic-category", item.category);
    badge.dataset.categoryKey = categoryKey(item.category);
    badgeRow.append(badge);
    if (item.id === "mini-autokannon") badgeRow.append(makeElement("span", "schematic-highlight-badge", "Cañón compacto"));
    if (item.category === "Aeronaves" && item.subcategory) {
      badgeRow.append(makeElement("span", "schematic-subcategory-badge", item.subcategory));
    }
    body.append(badgeRow);
    body.append(makeElement("h2", "schematic-title", item.title));
    // Mostrar exclusivamente una línea cuando la schematic utiliza elementos creativos.
    // Las auditorías técnicas permanecen en el JSON; no saturar las tarjetas con adaptaciones.
    if (typeof item.creativeNotice === "string" && item.creativeNotice.trim()) {
      body.append(makeElement("p", "schematic-creative-notice", "⚠ " + item.creativeNotice));
    }
    // Descripciones públicas solo para artillería y para fichas de construcción con precio.
    // Las demás tarjetas permanecen compactas.
    if (item.category === "Artillería y defensa"
        && typeof item.description === "string" && item.description.trim()) {
      body.append(makeElement("p", "schematic-description", item.description));
    }
    const required = Array.isArray(item.requiredMods) ? item.requiredMods : [];
    const details = document.createElement("details");
    details.className = "schematic-requirements";
    details.open = item.requirementsExpanded === true;
    details.append(makeElement("summary", "", "Mods requeridos (" + required.length + ")"));
    details.append(makeModList(required.length ? required : ["Sin datos"], "schematic-mod-list"));
    body.append(details);

    const inventory = item.requirementsInventory;
    const materials = item.materialsAudit;
    const missingByMaterials = Array.isArray(materials?.missingCatalogNamespaces)
      ? materials.missingCatalogNamespaces.map((entry) => entry?.modName).filter((name) => typeof name === "string" && name.trim())
      : [];
    // struts sigue en el inventario técnico, pero se retira su alerta pública a pedido.
    const hideStrutsWarning = (name) => /^struts(?:\s*\(mod no identificado\))?$/i.test(String(name).trim());
    const confirmed = [...new Set([...missingByMaterials, ...(item.missingMods || [])])]
      .filter((name) => !hideStrutsWarning(name));
    const maybeMissing = Array.isArray(inventory?.notInCatalog)
      ? inventory.notInCatalog.filter((name) =>
          typeof name === "string" && !hideStrutsWarning(name) &&
          // Create Train Lights se incorporó después de la fecha del catálogo privado.
          name !== "Create Train Lights" &&
          !confirmed.some((known) => known.toLocaleLowerCase("es") === name.toLocaleLowerCase("es")))
      : [];
    // Etiquetar únicamente los mods faltantes, sin cambiar sus nombres internos.
    // Los namespaces sin identidad resuelta no tienen categoría demostrada.
    const formatMissingMod = (name) => {
      if (/\(mod no identificado\)/i.test(name)) return name;
      const kind = /^(?:Create Aeronautics: Claims|Create: Claims)$/i.test(name.trim())
        ? "funcional" : "decorativo";
      return `${name} (${kind})`;
    };
    // Solo mostrar una advertencia cuando hay nombres concretos que enumerar.
    // Si no se identificó ninguno, no se crea ningún elemento de "Mods faltantes".
    if (confirmed.length || maybeMissing.length) {
      const missingPanel = makeElement("div", "schematic-fit " +
        (confirmed.length ? "schematic-fit--missing" : "schematic-fit--unknown"));
      if (confirmed.length) {
        missingPanel.append(makeElement("strong", "", "Mods faltantes: "));
        missingPanel.append(document.createTextNode(confirmed.map(formatMissingMod).join(", ")));
        if (maybeMissing.length) {
          missingPanel.append(makeElement("div", "", "Por confirmar: " + [...new Set(maybeMissing)].map(formatMissingMod).join(", ")));
        }
      } else {
        missingPanel.append(makeElement("strong", "", "Mods faltantes por confirmar: "));
        missingPanel.append(document.createTextNode([...new Set(maybeMissing)].map(formatMissingMod).join(", ")));
      }
      body.append(missingPanel);
    }

    const actions = makeElement("div", "schematic-actions");
    const freePlanNote = makeElement("p", "schematic-free-plan", imageUrl
      ? "Haz clic en la imagen para abrir los planos en CreateMod."
      : "Abrí la ficha en CreateMod para ver las imágenes y descargar los planos.");
    actions.append(freePlanNote);
    card.append(media, body, actions);
    return card;
  };

  const render = () => {
    const query = searchInput.value.trim().toLocaleLowerCase("es");
    const filtered = items.filter((item) => {
      const text = [item.title, item.category, item.subcategory, item.description, ...(item.requiredMods || []), ...(item.missingMods || []), ...(item.requirementsInventory?.notInCatalog || []), ...(item.materialsAudit?.missingCatalogNamespaces || []).flatMap(m => [m.modName, ...(m.blocks || []).map(b => b.id)]), item.creativeNotice || ""]
        .join(" ").toLocaleLowerCase("es");
      const matchesCategory = activeCategory === "all"
        || item.category === activeCategory;
      const matchesAircraftSubcategory = activeCategory !== "Aeronaves" || !activeAircraftSubcategory || item.subcategory === activeAircraftSubcategory;
      return (!query || text.includes(query)) && matchesCategory && matchesAircraftSubcategory;
    });
    const visible = filtered;

    grid.replaceChildren(...visible.map(makeCard));
    const displayedCategoryCount = categories.length;
    if (activeCategory === "Aeronaves" && activeAircraftSubcategory) {
      const subtypeCount = aircraftSubcategoryCounts.get(activeAircraftSubcategory) || 0;
      countNode.textContent = query
        ? visible.length + " de " + subtypeCount + " modelos · " + activeAircraftSubcategory
        : subtypeCount + " modelos · " + activeAircraftSubcategory + " · " + aircraftItems.length + " aeronaves";
    } else if (activeCategory === "Aeronaves") {
      const typeCount = aircraftSubcategories.filter((subcategory) => aircraftSubcategoryCounts.get(subcategory) > 0).length;
      countNode.textContent = query
        ? visible.length + " de " + aircraftItems.length + " aeronaves"
        : aircraftItems.length + " aeronaves · " + typeCount + " tipos";
    } else {
      countNode.textContent = visible.length === items.length
        ? items.length + " schematics · " + displayedCategoryCount + " categorías"
        : visible.length + " de " + items.length + " schematics";
    }
    emptyNode.hidden = visible.length > 0;
  };

  searchInput.addEventListener("input", render);
  render();
})();
