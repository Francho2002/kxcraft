(() => {
  "use strict";
  // Solo se recupera la foto og:image de la página EXACTA de CreateMod.
  // No utilizar imágenes por similitud de nombre ni thumbnails de otro schematic.
  const cachePrefix = "kxcraft-createmod-preview-v1:";
  const states = new Map();
  const queue = [];
  let inFlight = 0;
  const maximumParallel = 2;

  const validPage = (value) => {
    try {
      const url = new URL(value);
      return url.protocol === "https:" && url.hostname === "createmod.com" &&
        /^\/(?:[a-z]{2}(?:-[a-z]{2})?\/)?schematics\/[a-z0-9_-]+\/?$/.test(url.pathname) ? url : null;
    } catch { return null; }
  };
  const validPhoto = (value, page) => {
    if (!value) return null;
    try {
      const url = new URL(value, page.href);
      return url.protocol === "https:" && url.hostname === "createmod.com" &&
        /^\/api\/files\/schematics\/[a-zA-Z0-9_-]+\/[a-zA-Z0-9_.-]+$/.test(url.pathname)
        ? url.href : null;
    } catch { return null; }
  };

  const extract = (html, page) => {
    const doc = new DOMParser().parseFromString(html, "text/html");
    const canonical = doc.querySelector('link[rel="canonical"]')?.getAttribute("href");
    if (canonical) {
      const canonicalUrl = validPage(canonical);
      // El servidor pudo devolver una página distinta (redirect, búsqueda o error).
      if (!canonicalUrl || canonicalUrl.pathname.replace(/\/$/, "") !== page.pathname.replace(/\/$/, "")) return null;
    }
    const selectors = ['meta[property="og:image"]', 'meta[name="twitter:image"]',
      'meta[name="twitter:image:src"]', 'meta[itemprop="image"]'];
    for (const selector of selectors) {
      for (const meta of doc.querySelectorAll(selector)) {
        const url = validPhoto(meta.getAttribute("content"), page);
        if (url) return url;
      }
    }
    const linked = doc.querySelectorAll('img[src*="/api/files/schematics/"],source[srcset*="/api/files/schematics/"]');
    for (const img of linked) {
      const original = img.getAttribute("src") || img.getAttribute("data-src") ||
        (img.getAttribute("srcset") || "").split(",")[0].trim().split(" ")[0];
      const url = validPhoto(original, page);
      if (url) return url;
    }
    return null;
  };

  const request = async (url) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12500);
    try {
      const response = await fetch(url, {signal:controller.signal,credentials:"omit",redirect:"follow",mode:"cors"});
      if (!response.ok) return "";
      return await response.text();
    } catch { return ""; }
    finally {clearTimeout(timer);}
  };
  const resolve = async (page) => {
    const localKey = cachePrefix + page.pathname;
    try {
      const stored = localStorage.getItem(localKey);
      const valid = validPhoto(stored, page);
      if (valid) return valid;
    } catch {} // file:// y navegadores con almacenamiento restringido
    // El proxy CORS sólo consulta páginas públicas de createmod.com, sin credenciales.
    // Si el proxy falla, se mantiene el enlace original sin imagen incorrecta.
    const proxies = [
      "https://proxy.cors.dev/" + page.href,
      "https://api.allorigins.win/raw?url=" + encodeURIComponent(page.href)
    ];
    for (const proxy of proxies) {
      const html = await request(proxy);
      const photo = html ? extract(html, page) : null;
      if (photo) {
        try {localStorage.setItem(localKey, photo);} catch {}
        return photo;
      }
    }
    return null;
  };
  const dispatch = () => {
    while (inFlight < maximumParallel && queue.length) {
      const job = queue.shift();
      inFlight++;
      resolve(job.page).then(job.done).catch(() => job.done(null)).finally(() => {
        inFlight--;
        dispatch();
      });
    }
  };
  const get = (pageString, callback) => {
    const page = validPage(pageString);
    if (!page) return callback(null);
    const key = page.pathname;
    if (states.has(key)) return states.get(key).then(callback);
    let finish;
    const promise = new Promise((resolvePromise) => {finish = resolvePromise;});
    states.set(key,promise);
    queue.push({page,done:finish});
    dispatch();
    promise.then(callback);
  };
  const observer = typeof IntersectionObserver === "function"
    ? new IntersectionObserver((entries, observerInstance) => {
        for (const entry of entries) if (entry.isIntersecting) {
          observerInstance.unobserve(entry.target);
          entry.target._loadCreateModImage?.();
        }
      }, {rootMargin:"300px"}) : null;
  const watch = (element, pageString, callback) => {
    element._loadCreateModImage = () => get(pageString, callback);
    if (observer) observer.observe(element);
    else element._loadCreateModImage();
  };
  window.KxCreateModPreview = {watch};
})();