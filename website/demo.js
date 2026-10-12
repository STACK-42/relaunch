// A miniature, browser-only version of Relaunch's grid: paging by drag,
// trackpad and keys, page dots, a folder and live search. The apps are
// fictional; tiles are drawn with simple shapes so no real app art is used.
(() => {
  const glyphs = {
    circle: '<circle cx="12" cy="12" r="7"/>',
    square: '<rect x="5" y="5" width="14" height="14" rx="3"/>',
    wave: '<path d="M3 13c3-6 6 6 9 0s6 6 9 0"/>',
    bars: '<path d="M6 19V11M12 19V5M18 19v-6"/>',
    star: '<path d="m12 4 2.4 5 5.6.6-4.2 3.8 1.2 5.5L12 16l-5 2.9 1.2-5.5L4 9.6 9.6 9z"/>',
    note: '<path d="M9 18V6l10-2v12"/><circle cx="7" cy="18" r="2"/><circle cx="17" cy="16" r="2"/>',
    bolt: '<path d="M13 3 5 14h6l-1 7 8-11h-6z"/>',
    leaf: '<path d="M5 19C5 10 11 5 19 5c0 8-5 14-14 14zM5 19l7-7"/>',
    chat: '<path d="M4 6h16v10H9l-5 4z"/>',
    grid: '<path d="M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"/>',
    pen: '<path d="m4 20 4-1 11-11-3-3L5 16zM14 6l3 3"/>',
    globe: '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c3 3 3 13 0 16M12 4c-3 3-3 13 0 16"/>',
  };
  const names = [
    "Orbit", "Ledger", "Canvas", "Tempo", "Northstar", "Chorus", "Spark", "Fern",
    "Parlor", "Mosaic", "Quill", "Atlas", "Pulse", "Harbor", "Lumen", "Cadence",
    "Drift", "Beacon", "Ember", "Sable", "Meadow", "Relay", "Prism", "Juniper",
    "Comet", "Ripple", "Saga", "Tundra", "Willow", "Vista", "Ink", "Halo",
    "Basil", "Cobalt", "Dune", "Fable", "Glint", "Hive", "Iris", "Jade",
    "Kite", "Lark", "Marble", "Nimbus", "Opal", "Pebble", "Quartz", "Rune",
  ];
  const glyphNames = Object.keys(glyphs);
  const app = (name, i) => ({
    name,
    glyph: glyphNames[i % glyphNames.length],
    hue: (i * 47) % 360,
  });
  const apps = names.map(app);
  const folder = {
    folder: true,
    name: "Utilities",
    apps: ["Gauge", "Console", "Archive", "Keychain", "Monitor", "Disk"].map((n, i) => app(n, i + 3)),
  };
  // Folder sits at the end of the first page, as Launchpad's "Other" did.
  const entries = [...apps.slice(0, 34), folder, ...apps.slice(34)];

  const demo = document.getElementById("demo");
  const track = document.getElementById("demo-track");
  const dots = document.getElementById("demo-dots");
  const query = document.getElementById("demo-query");
  const folderEl = document.getElementById("demo-folder");
  const folderTitle = document.getElementById("demo-folder-title");
  const folderGrid = document.getElementById("demo-folder-grid");

  let page = 0;
  let pageCount = 1;
  let cols = 7;
  let rows = 5;

  const artFor = (a) => {
    const el = document.createElement("span");
    el.className = "art";
    if (a.folder) {
      el.classList.add("folder");
      const minis = document.createElement("span");
      minis.className = "minis";
      for (const inner of a.apps.slice(0, 9)) {
        const dot = document.createElement("i");
        dot.style.background = gradient(inner.hue);
        minis.append(dot);
      }
      el.append(minis);
    } else {
      el.style.background = gradient(a.hue);
      el.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${glyphs[a.glyph]}</svg>`;
    }
    return el;
  };
  const gradient = (h) => `linear-gradient(160deg, hsl(${h} 75% 62%), hsl(${(h + 30) % 360} 70% 42%))`;

  const tileFor = (a) => {
    const b = document.createElement("button");
    b.className = "tile";
    b.type = "button";
    b.setAttribute("aria-label", a.folder ? `${a.name} folder` : a.name);
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = a.name;
    b.append(artFor(a), label);
    b.addEventListener("click", (e) => {
      if (suppressClick) { e.preventDefault(); return; }
      if (a.folder) openFolder(a);
      else {
        b.classList.remove("launching");
        void b.offsetWidth;
        b.classList.add("launching");
      }
    });
    return b;
  };

  const visibleEntries = () => {
    const q = query.value.trim().toLowerCase();
    if (!q) return entries;
    const all = entries.flatMap((e) => (e.folder ? e.apps : [e]));
    return all.filter((a) => a.name.toLowerCase().split(/\s+/).some((w) => w.startsWith(q)));
  };

  function render() {
    const narrow = demo.clientWidth < 560;
    cols = narrow ? 4 : 7;
    rows = narrow ? 6 : 5;
    const cap = cols * rows;
    const list = visibleEntries();
    pageCount = Math.max(1, Math.ceil(list.length / cap));
    page = Math.min(page, pageCount - 1);

    track.replaceChildren();
    for (let p = 0; p < pageCount; p++) {
      const el = document.createElement("div");
      el.className = "demo-page";
      el.style.setProperty("--cols", cols);
      el.style.setProperty("--rows", rows);
      const slice = list.slice(p * cap, (p + 1) * cap);
      if (!slice.length) {
        const empty = document.createElement("p");
        empty.className = "demo-empty";
        empty.textContent = "No Results";
        el.append(empty);
      }
      for (const a of slice) el.append(tileFor(a));
      track.append(el);
    }
    folderGrid.style.setProperty("--cols", cols);
    renderDots();
    go(page, false);
  }

  function renderDots() {
    dots.replaceChildren();
    if (pageCount < 2) return;
    for (let i = 0; i < pageCount; i++) {
      const d = document.createElement("button");
      d.type = "button";
      d.setAttribute("role", "tab");
      d.setAttribute("aria-label", `Page ${i + 1}`);
      d.addEventListener("click", () => go(i));
      dots.append(d);
    }
  }

  function go(p, animate = true) {
    page = Math.max(0, Math.min(p, pageCount - 1));
    track.classList.toggle("dragging", !animate);
    track.style.transform = `translateX(${-page * 100}%)`;
    [...dots.children].forEach((d, i) => d.setAttribute("aria-selected", String(i === page)));
    // Keep off-page tiles out of the tab order.
    [...track.children].forEach((el, i) => {
      el.inert = i !== page;
    });
  }

  // Pointer drag with rubber-banding and flick detection.
  let startX = 0, lastX = 0, lastT = 0, velocity = 0, dragging = false, suppressClick = false;
  const width = () => track.parentElement.clientWidth;
  const rubber = (x) => {
    const d = width();
    const r = (1 - 1 / ((Math.abs(x) * 0.55) / d + 1)) * d;
    return x < 0 ? -r : r;
  };
  const setOffset = (dx) => {
    let off = dx;
    if ((page === 0 && dx > 0) || (page === pageCount - 1 && dx < 0)) off = rubber(dx);
    track.style.transform = `translateX(calc(${-page * 100}% + ${off}px))`;
  };

  track.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    dragging = true;
    suppressClick = false;
    startX = lastX = e.clientX;
    lastT = e.timeStamp;
    velocity = 0;
    track.classList.add("dragging");
  });
  window.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const dx = e.clientX - startX;
    if (Math.abs(dx) > 5 && !suppressClick) {
      suppressClick = true;
      track.setPointerCapture?.(e.pointerId);
    }
    const dt = Math.max(e.timeStamp - lastT, 1);
    velocity = 0.6 * velocity + 0.4 * ((e.clientX - lastX) / dt) * 1000;
    lastX = e.clientX;
    lastT = e.timeStamp;
    if (suppressClick) setOffset(dx);
  });
  const endDrag = (e) => {
    if (!dragging) return;
    dragging = false;
    const dx = e.clientX - startX;
    let target = page;
    if (Math.abs(velocity) > 450) target += velocity < 0 ? 1 : -1;
    else if (Math.abs(dx) > width() * 0.15) target += dx < 0 ? 1 : -1;
    go(target);
    // Let the click that follows a drag be ignored, then re-enable.
    setTimeout(() => { suppressClick = false; }, 0);
  };
  window.addEventListener("pointerup", endDrag);
  window.addEventListener("pointercancel", endDrag);

  // Trackpad horizontal swipe: one page per gesture.
  let wheelAcc = 0, wheelLock = 0;
  demo.addEventListener("wheel", (e) => {
    if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return; // let vertical scroll the page
    e.preventDefault();
    if (e.timeStamp < wheelLock) return;
    wheelAcc += e.deltaX;
    if (Math.abs(wheelAcc) > 40) {
      go(page + (wheelAcc > 0 ? 1 : -1));
      wheelAcc = 0;
      wheelLock = e.timeStamp + 450;
    }
  }, { passive: false });

  demo.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if (!folderEl.hidden) closeFolder();
      else if (query.value) { query.value = ""; page = 0; render(); }
      return;
    }
    if (e.target === query && query.value) return;
    if (e.key === "ArrowRight") { go(page + 1); e.preventDefault(); }
    if (e.key === "ArrowLeft") { go(page - 1); e.preventDefault(); }
  });

  query.addEventListener("input", () => { page = 0; render(); });

  let folderOpener = null;
  function openFolder(f) {
    folderOpener = document.activeElement;
    folderTitle.textContent = f.name;
    folderGrid.replaceChildren(...f.apps.map(tileFor));
    folderEl.hidden = false;
    folderGrid.querySelector(".tile")?.focus();
  }
  function closeFolder() {
    folderEl.hidden = true;
    folderOpener?.focus?.();
  }
  folderEl.addEventListener("click", (e) => { if (e.target === folderEl) closeFolder(); });

  let resizeTimer;
  new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(render, 80);
  }).observe(demo);

  render();
})();
