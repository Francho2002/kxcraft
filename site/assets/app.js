(() => {
  "use strict";

  const input = document.getElementById("kxcraft-import-url");
  const button = document.getElementById("kxcraft-copy-link");
  const status = document.getElementById("kxcraft-copy-status");
  if (!input || !button || !status) return;

  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(input.value);
      status.textContent = "¡Enlace copiado!";
      status.hidden = false;
    } catch {
      input.focus();
      input.select();
      if (typeof input.setSelectionRange === "function") input.setSelectionRange(0, input.value.length);
      status.textContent = "No se pudo copiar automáticamente. La URL quedó seleccionada; copiala manualmente.";
      status.hidden = false;
    }
  });
})();
(() => {
  "use strict";

  const dataNode = document.getElementById("kxcraft-playable-mods");
  const grid = document.getElementById("mods-grid");
  const filterRoot = document.getElementById("category-filters");
  const queryInput = document.getElementById("mod-search");
  const countNode = document.getElementById("results-count");
  const emptyNode = document.getElementById("empty-state");
  const dialog = document.getElementById("mod-dialog");
  const dialogTitle = document.getElementById("dialog-title");
  const dialogDescription = document.getElementById("dialog-description");
  const dialogCategory = document.getElementById("dialog-category");
  const dialogMedia = document.getElementById("dialog-media");
  const dialogVideo = document.getElementById("dialog-video");
  if (!dataNode || !grid || !filterRoot || !queryInput || !countNode || !emptyNode) return;

  let mods;
  try {
    mods = JSON.parse(dataNode.textContent);
  } catch {
    countNode.textContent = "No pudimos cargar el catálogo.";
    emptyNode.hidden = false;
    return;
  }

  if (!Array.isArray(mods) || mods.length === 0) {
    countNode.textContent = "Todavía no hay mods para mostrar.";
    emptyNode.hidden = false;
    return;
  }

  const normalize = (text) => String(text ?? "")
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLocaleLowerCase("es-AR")
    .trim();

  const categories = [...new Set(mods.map((mod) => mod.category))];
  let selectedCategory = "Todos";

  const makeElement = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  function makeIcon(mod, large = false, useGalleryImage = false) {
    const holder = makeElement("div", "icon-fallback", mod.initials || "KX");
    holder.setAttribute("aria-hidden", "true");
    const url = mod.icon || (useGalleryImage ? mod.image : "");
    if (!url || !/^https:\/\//i.test(url)) return holder;

    const image = document.createElement("img");
    image.className = large ? "mod-icon mod-icon-large" : "mod-icon";
    image.src = url;
    image.alt = mod.icon ? (mod.iconAlt || (mod.name + ", icono")) : (mod.imageAlt || (mod.name + ", imagen"));
    image.loading = "lazy";
    image.decoding = "async";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => image.replaceWith(holder), { once: true });
    return image;
  }

  // Galería ilustrativa: consultar solo al abrir la ficha, sin cargar 78 proyectos
  // al entrar en el catálogo. El error de red nunca impide abrir el detalle.
  const galleryCache = new Map();
  let currentDetailToken = 0;

  const safeProjectGallery = async (projectId) => {
    if (!/^[A-Za-z0-9]{7,12}$/.test(projectId)) return null;
    if (!galleryCache.has(projectId)) {
      const request = fetch("https://api.modrinth.com/v2/project/" + encodeURIComponent(projectId), {
        mode: "cors", credentials: "omit", referrerPolicy: "no-referrer"
      }).then(async (response) => {
        if (!response.ok) return null;
        const project = await response.json();
        if (!Array.isArray(project.gallery)) return null;
        const gallery = project.gallery.find((entry) => entry.featured) || project.gallery[0];
        if (!gallery || typeof gallery.url !== "string") return null;
        const url = new URL(gallery.url);
        return url.protocol === "https:" && url.hostname === "cdn.modrinth.com" ? url.href : null;
      }).catch(() => null);
      galleryCache.set(projectId, request);
    }
    return galleryCache.get(projectId);
  };

  const makeDetailImage = (url, alt, mod, token) => {
    if (!/^https:\/\//i.test(url)) return;
    const image = document.createElement("img");
    image.className = "mod-detail-image";
    image.src = url;
    image.alt = alt;
    image.loading = "lazy";
    image.decoding = "async";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => {
      if (currentDetailToken === token) dialogMedia.replaceChildren(makeIcon(mod, true));
    }, { once: true });
    dialogMedia.replaceChildren(image);
  };

  function openDetails(mod) {
    if (!dialog || typeof dialog.showModal !== "function") return;
    const token = ++currentDetailToken;
    dialogTitle.textContent = mod.name;
    dialogDescription.textContent = mod.description;
    dialogCategory.textContent = mod.category;
    dialogMedia.replaceChildren(makeIcon(mod, true));
    if (mod.image && /^https:\/\//i.test(mod.image)) {
      makeDetailImage(mod.image, mod.imageAlt || (mod.name + ", captura del mod"), mod, token);
    } else {
      // La miniatura de YouTube se presenta como tal; no se confunde con una
      // captura del mod. Si existe galería oficial, reemplaza esa miniatura.
      if (mod.video && /^[A-Za-z0-9_-]{11}$/.test(mod.video.id)) {
        makeDetailImage("https://i.ytimg.com/vi/" + mod.video.id + "/hqdefault.jpg",
          mod.name + ", miniatura del video enlazado", mod, token);
      }
      if (mod.galleryProjectId) {
        void safeProjectGallery(mod.galleryProjectId).then((galleryUrl) => {
          if (galleryUrl && currentDetailToken === token && dialog.open) {
            makeDetailImage(galleryUrl, mod.name + ", imagen de la galería del proyecto", mod, token);
          }
        });
      }
    }
    if (dialogVideo) {
      dialogVideo.replaceChildren();
      dialogVideo.hidden = false;
      if (mod.video && /^[A-Za-z0-9_-]{11}$/.test(mod.video.id)) {
        dialogVideo.append(makeElement("h3", "", mod.video.title));
        const frame = document.createElement("iframe");
        frame.className = "dialog-video-frame";
        frame.src = "https://www.youtube-nocookie.com/embed/" + encodeURIComponent(mod.video.id);
        frame.title = mod.video.title + " — " + mod.name;
        frame.loading = "lazy";
        frame.referrerPolicy = "strict-origin-when-cross-origin";
        frame.allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share";
        frame.allowFullscreen = true;
        dialogVideo.append(frame);
        dialogVideo.append(makeElement("p", "dialog-video-meta", [mod.video.language, mod.video.note].filter(Boolean).join(" · ")));
        const sourceLink = makeElement("a", "dialog-video-link", "Abrir video en YouTube ↗");
        sourceLink.href = mod.video.url;
        sourceLink.target = "_blank";
        sourceLink.rel = "noopener noreferrer";
        dialogVideo.append(sourceLink);
      } else {
        dialogVideo.append(makeElement("h3", "", "Demostraciones y tutoriales"));
        dialogVideo.append(makeElement("p", "dialog-video-meta", "Todavía no hay un video enlazado para este mod."));
        const findVideos = makeElement("a", "dialog-video-link", "Buscar videos de este mod en YouTube ↗");
        findVideos.href = "https://www.youtube.com/results?search_query=" + encodeURIComponent(mod.name + " Minecraft mod showcase");
        findVideos.target = "_blank";
        findVideos.rel = "noopener noreferrer";
        dialogVideo.append(findVideos);
      }
    }
    dialog.showModal();
  }

  if (dialog && dialogVideo) {
    dialog.addEventListener("close", () => {
      ++currentDetailToken;
      dialogVideo.replaceChildren();
    });
  }

  function drawFilters() {
    filterRoot.replaceChildren();
    ["Todos", ...categories].forEach((category) => {
      const button = makeElement("button", "category-filter", category);
      button.type = "button";
      button.setAttribute("aria-pressed", String(category === selectedCategory));
      button.addEventListener("click", () => {
        selectedCategory = category;
        drawFilters();
        drawMods();
      });
      filterRoot.append(button);
    });
  }

  function drawMods() {
    const query = normalize(queryInput.value);
    const visible = mods.filter((mod) => {
      const categoryMatches = selectedCategory === "Todos" || mod.category === selectedCategory;
      const textMatches = normalize([mod.name, mod.description, mod.category].join(" ")).includes(query);
      return categoryMatches && textMatches;
    });

    grid.replaceChildren();
    visible.forEach((mod) => {
      const card = makeElement("button", "mod-card");
      card.type = "button";
      card.setAttribute("aria-label", "Ver detalles de " + mod.name);
      const top = makeElement("span", "card-top");
      top.append(makeIcon(mod, false, true));
      const text = makeElement("span", "card-title-wrap");
      text.append(makeElement("span", "mod-name", mod.name));
      text.append(makeElement("span", "mod-category", mod.category));
      top.append(text);
      card.append(top);
      if (mod.video) card.append(makeElement("span", "video-tag", "Con video"));
      card.append(makeElement("span", "mod-description", mod.description));
      card.append(makeElement("span", "card-open", "Ver detalle →"));
      card.addEventListener("click", () => openDetails(mod));
      grid.append(card);
    });

    const noun = visible.length === 1 ? "mod" : "mods";
    countNode.textContent = visible.length + " " + noun;
    emptyNode.hidden = visible.length > 0;
  }

  queryInput.addEventListener("input", drawMods);
  document.addEventListener("keydown", (event) => {
    if (event.key === "/" && document.activeElement !== queryInput && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      queryInput.focus();
    }
  });
  drawFilters();
  drawMods();
})();
