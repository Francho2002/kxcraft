(() => {
  "use strict";

  const urlNode = document.getElementById("kxcraft-import-url");
  const copyButton = document.getElementById("kxcraft-copy-button");
  const status = document.getElementById("kxcraft-copy-status");
  if (!urlNode || !copyButton || !status) return;

  const importUrl = urlNode.textContent.trim();

  async function copyImportUrl() {
    let copied = false;
    try {
      if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") {
        throw new Error("Clipboard API unavailable");
      }
      await navigator.clipboard.writeText(importUrl);
      copied = true;
    } catch {
      const helper = document.createElement("textarea");
      helper.className = "kx-clipboard-helper";
      helper.value = importUrl;
      helper.setAttribute("readonly", "");
      helper.tabIndex = -1;
      document.body.append(helper);
      try {
        helper.focus({ preventScroll: true });
        helper.select();
        copied = document.execCommand("copy");
      } catch {
        copied = false;
      }
      helper.remove();
    }

    status.textContent = copied
      ? ""
      : "No se pudo copiar. Permití el acceso al portapapeles y volvé a intentarlo.";
    status.hidden = copied;
  }

  copyButton.addEventListener("click", () => { void copyImportUrl(); });
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
    if (dialogVideo && mod.detailsUrl && /^[a-z0-9_-]+\.html$/i.test(mod.detailsUrl)) {
      const detailsLink = makeElement("a", "dialog-video-link", "Ver ficha completa del mod ↗");
      detailsLink.href = mod.detailsUrl;
      dialogVideo.append(detailsLink);
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
  const pageScope = new AbortController();
  document.addEventListener("kxcraft:page-leave", () => pageScope.abort(), { once: true });
  document.addEventListener("keydown", (event) => {
    if (event.key === "/" && document.activeElement !== queryInput && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      queryInput.focus();
    }
  }, { signal: pageScope.signal });
  drawFilters();
  drawMods();
})();

(() => {
  "use strict";
  if (window.__kxcraftSpaNavigationInstalled) return;
  window.__kxcraftSpaNavigationInstalled = true;

  const pageFiles = new Set(["index.html", "mods.html", "schematics.html", "tienda.html"]);
  const basePath = new URL("./", window.location.href).pathname;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const transitionTime = reducedMotion ? 0 : 80;
  let navigationActive = false;

  function waitForTransition(element) {
    if (!transitionTime || !element) return Promise.resolve();
    return new Promise((resolve) => {
      let finished = false;
      const finish = () => {
        if (finished) return;
        finished = true;
        element.removeEventListener("transitionend", finish);
        window.clearTimeout(timeout);
        resolve();
      };
      const timeout = window.setTimeout(finish, transitionTime + 100);
      element.addEventListener("transitionend", finish, { once: true });
    });
  }

  function resolvePageUrl(value) {
    let url;
    try {
      url = new URL(value, window.location.href);
    } catch {
      return null;
    }
    if (url.origin !== window.location.origin || url.search || !url.pathname.startsWith(basePath)) return null;
    const relativePath = url.pathname === basePath ? "index.html" : url.pathname.slice(basePath.length);
    if (!pageFiles.has(relativePath) || relativePath.includes("/")) return null;
    return url;
  }

  async function ensureStyles(nextDocument, pageUrl) {
    const stylesheets = Array.from(nextDocument.querySelectorAll('link[rel~="stylesheet"][href]'));
    for (const source of stylesheets) {
      const href = new URL(source.getAttribute("href"), pageUrl).href;
      const alreadyLoaded = Array.from(document.querySelectorAll('link[rel~="stylesheet"][href]'))
        .some((link) => link.href === href);
      if (alreadyLoaded) continue;
      const link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = href;
      await new Promise((resolve, reject) => {
        link.addEventListener("load", resolve, { once: true });
        link.addEventListener("error", reject, { once: true });
        document.head.append(link);
      });
    }
  }

  function isInertScript(script) {
    const type = (script.getAttribute("type") || "").trim().toLowerCase();
    if (!type) return false;
    return !["module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript"].includes(type);
  }

  function appendScript(source, pageUrl) {
    const script = document.createElement("script");
    for (const attribute of Array.from(source.attributes)) {
      if (["src", "defer", "async"].includes(attribute.name.toLowerCase())) continue;
      script.setAttribute(attribute.name, attribute.value);
    }
    script.dataset.kxSpaScript = "true";

    if (source.hasAttribute("src")) {
      script.src = new URL(source.getAttribute("src"), pageUrl).href;
      if (script.type !== "module") script.async = false;
      return new Promise((resolve, reject) => {
        script.addEventListener("load", resolve, { once: true });
        script.addEventListener("error", reject, { once: true });
        document.body.append(script);
      });
    }

    script.textContent = source.textContent;
    document.body.append(script);
    return Promise.resolve();
  }

  function syncPageMetadata(nextDocument) {
    document.title = nextDocument.title;
    if (nextDocument.documentElement.lang) {
      document.documentElement.lang = nextDocument.documentElement.lang;
    }
    const nextDescription = nextDocument.querySelector('meta[name="description"]');
    const currentDescription = document.querySelector('meta[name="description"]');
    if (nextDescription && currentDescription) {
      currentDescription.setAttribute("content", nextDescription.getAttribute("content") || "");
    }
  }

  async function navigate(pageUrl, addHistoryEntry) {
    if (navigationActive) return;
    navigationActive = true;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(pageUrl.href, {
        credentials: "same-origin",
        signal: controller.signal
      });
      if (!response.ok) throw new Error("Page request failed");
      const html = await response.text();
      const nextDocument = new DOMParser().parseFromString(html, "text/html");
      const nextHeader = nextDocument.querySelector(".topbar");
      const nextMain = nextDocument.querySelector("main#main");
      const nextFooter = nextDocument.querySelector(".footer");
      const currentHeader = document.querySelector(".topbar");
      const currentMain = document.querySelector("main#main");
      const currentFooter = document.querySelector(".footer");
      if (!nextHeader || !nextMain || !nextFooter || !currentHeader || !currentMain || !currentFooter) {
        throw new Error("Page structure is not compatible with SPA navigation");
      }

      await ensureStyles(nextDocument, pageUrl);
      document.body.classList.add("kx-page-transition-out");
      await waitForTransition(currentMain);
      document.dispatchEvent(new Event("kxcraft:page-leave"));

      const header = document.importNode(nextHeader, true);
      const main = document.importNode(nextMain, true);
      const footer = document.importNode(nextFooter, true);
      currentHeader.replaceWith(header);
      currentMain.replaceWith(main);
      currentFooter.replaceWith(footer);
      document.body.querySelectorAll("script").forEach((script) => script.remove());
      syncPageMetadata(nextDocument);

      const scripts = Array.from(nextDocument.querySelectorAll("script"));
      for (const script of scripts.filter(isInertScript)) {
        await appendScript(script, pageUrl);
      }
      for (const script of scripts.filter((item) => !isInertScript(item))) {
        await appendScript(script, pageUrl);
      }

      await new Promise((resolve) => requestAnimationFrame(resolve));
      if (addHistoryEntry) {
        window.history.pushState({ kxcraftSpa: true }, "", pageUrl.href);
      }

      if (pageUrl.hash) {
        let id = pageUrl.hash.slice(1);
        try { id = decodeURIComponent(id); } catch {}
        const anchor = document.getElementById(id);
        if (anchor) anchor.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth" });
        else window.scrollTo(0, 0);
      } else {
        window.scrollTo(0, 0);
      }

      document.body.classList.remove("kx-page-transition-out");
      document.body.classList.add("kx-page-transition-in");
      requestAnimationFrame(() => requestAnimationFrame(() => {
        document.body.classList.add("kx-page-transition-in-active");
      }));
      await waitForTransition(main);
      document.body.classList.remove("kx-page-transition-in", "kx-page-transition-in-active");
    } catch {
      document.body.classList.remove("kx-page-transition-out", "kx-page-transition-in", "kx-page-transition-in-active");
      window.location.assign(pageUrl.href);
    } finally {
      window.clearTimeout(timeout);
      navigationActive = false;
    }
  }

  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const target = event.target instanceof Element ? event.target : event.target.parentElement;
    const link = target && target.closest("a[href]");
    if (!link || link.hasAttribute("download") || (link.target && link.target !== "_self") || link.relList.contains("external")) return;
    const pageUrl = resolvePageUrl(link.href);
    if (!pageUrl || (pageUrl.pathname === window.location.pathname && pageUrl.hash !== window.location.hash)) return;
    if (pageUrl.href === window.location.href) return;
    event.preventDefault();
    void navigate(pageUrl, true);
  });

  window.addEventListener("popstate", () => {
    const pageUrl = resolvePageUrl(window.location.href);
    if (pageUrl) void navigate(pageUrl, false);
  });
})();
