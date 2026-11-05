// lmux site: theme toggle, tour tabs, copy buttons, bar reveal, hero video. No dependencies.
// Everything here is an enhancement: the page reads fine with JS off.

const root = document.documentElement;
const mq = (q) => window.matchMedia(q);
const still = mq("(prefers-reduced-motion: reduce)").matches;

// Theme: every click flips what you see. Landing back on the system's own theme returns to auto,
// which follows prefers-color-scheme.
const themeBtn = document.querySelector("[data-theme-toggle]");
const darkSources = document.querySelectorAll("[data-dark-source]");
const themeColors = document.querySelectorAll('meta[name="theme-color"]');
for (const m of themeColors) m.dataset.auto = m.content;
let theme = root.dataset.theme || "auto";

const sysDark = () => mq("(prefers-color-scheme: dark)").matches;
const isDark = () => theme === "dark" || (theme === "auto" && sysDark());
const THEME_ICONS = {
  auto: '<circle cx="10" cy="10" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 3.75a6.25 6.25 0 0 1 0 12.5z" fill="currentColor"/>',
  light: '<circle cx="10" cy="10" r="3.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 2.5v1.8M10 15.7v1.8M2.5 10h1.8M15.7 10h1.8M4.7 4.7l1.27 1.27M14.03 14.03l1.27 1.27M4.7 15.3l1.27-1.27M14.03 5.97l1.27-1.27" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
  dark: '<path d="M15.8 12.1A6.5 6.5 0 0 1 7.9 4.2a6.5 6.5 0 1 0 7.9 7.9Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
};

function applyTheme() {
  if (theme === "auto") delete root.dataset.theme;
  else root.dataset.theme = theme;
  // <picture> sources only know prefers-color-scheme, so steer them by hand.
  const media = theme === "dark" ? "all" : theme === "light" ? "not all" : "(prefers-color-scheme: dark)";
  for (const s of darkSources) s.media = media;
  for (const m of themeColors) m.content = theme === "auto" ? m.dataset.auto : theme === "dark" ? "#20242C" : "#F5F7FA";
  if (themeBtn) {
    themeBtn.setAttribute("aria-label", `Theme: ${theme === "auto" ? "automatic" : theme}. Switch to ${isDark() ? "light" : "dark"}`);
    themeBtn.querySelector("svg").innerHTML = THEME_ICONS[theme];
  }
  heroVideo?.sync();
}

// Hero video: never under reduced motion, Save-Data or on a phone-sized screen, and only after load
// so the first view is just the poster. <source media> is unreliable for video, so light/dark is picked here.
const heroVideo = (() => {
  const fig = document.querySelector("[data-hero-video]");
  if (!fig || fig.dataset.video !== "on" || still || navigator.connection?.saveData || mq("(max-width: 720px)").matches) return null;
  const frame = fig.querySelector(".stage__frame");
  const poster = fig.querySelector("img");
  const base = fig.dataset.heroVideo;
  let video = null, current = "", paused = false;
  function sync() {
    if (!video) return;
    const want = isDark() ? "dark" : "light";
    if (want === current) return;
    current = want;
    video.classList.remove("is-playing");
    // Same size the <picture> already chose, so the poster costs nothing extra.
    const size = (poster.currentSrc.match(/-(1000|2400)\.webp$/) || [])[1];
    video.poster = `site/img/hero-${want}${size ? `-${size}` : ""}.webp`;
    video.replaceChildren(
      Object.assign(document.createElement("source"), { src: `${base}-${want}.webm`, type: "video/webm" }),
      Object.assign(document.createElement("source"), { src: `${base}-${want}.mp4`, type: "video/mp4" }),
    );
    video.load();
    if (!paused) video.play().catch(() => {});
  }
  function start() {
    video = document.createElement("video");
    Object.assign(video, { autoplay: true, muted: true, loop: true, playsInline: true, preload: "metadata", width: 1600, height: 1000 });
    video.setAttribute("aria-label", fig.dataset.videoLabel);
    video.setAttribute("role", "img");
    video.addEventListener("playing", () => { video.classList.add("is-playing"); poster.setAttribute("aria-hidden", "true"); });
    frame.append(video);
    // Outside the frame, so it never covers the recording.
    fig.append(pauseButton("video", (p) => { paused = p; p ? video.pause() : video.play().catch(() => {}); }));
    sync();
  }
  if (document.readyState === "complete") start();
  else window.addEventListener("load", start, { once: true });
  return { sync };
})();

applyTheme();
if (themeBtn) {
  themeBtn.hidden = false;
  themeBtn.addEventListener("click", () => {
    const next = isDark() ? "light" : "dark";
    theme = (next === "dark") === sysDark() ? "auto" : next;
    applyTheme();
    try {
      if (theme === "auto") localStorage.removeItem("lmux-theme");
      else localStorage.setItem("lmux-theme", theme);
    } catch (e) { /* storage blocked: the choice just won't stick */ }
  });
}
mq("(prefers-color-scheme: dark)").addEventListener?.("change", () => applyTheme());

// A pause / play toggle for moving media. onToggle(paused) does the work; b.sync(paused) redraws it.
function pauseButton(what, onToggle) {
  const b = Object.assign(document.createElement("button"), { type: "button", className: "media-btn" });
  b.sync = (p) => {
    b.setAttribute("aria-label", `${p ? "Play" : "Pause"} the ${what}`);
    b.dataset.paused = String(p);
    b.innerHTML = p
      ? '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3.2v9.6L12.6 8z" fill="currentColor"/></svg>'
      : '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="3.2" width="2.6" height="9.6" rx=".8" fill="currentColor"/><rect x="9.4" y="3.2" width="2.6" height="9.6" rx=".8" fill="currentColor"/></svg>';
  };
  b.sync(false);
  b.addEventListener("click", () => { const p = b.dataset.paused !== "true"; b.sync(p); onToggle(p); });
  return b;
}

// Tour tabs (WAI-ARIA tabs, automatic activation). Without JS every clip is shown.
for (const tabs of document.querySelectorAll("[data-tabs]")) {
  const tablist = tabs.querySelector("[data-tablist]");
  const list = [...tabs.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    for (const t of list) {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    }
  };
  for (const [i, tab] of list.entries()) {
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (e) => {
      const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      let next = step ? list[(i + step + list.length) % list.length] : null;
      if (e.key === "Home") next = list[0];
      if (e.key === "End") next = list[list.length - 1];
      if (!next) return;
      e.preventDefault();
      select(next);
      next.focus();
    });
  }
  if (tablist) tablist.hidden = false;
  select(list.find((t) => t.getAttribute("aria-selected") === "true") || list[0]);
  tabs.classList.add("is-ready");
}

// Tour clips: the HTML ships the still frame; swap in the animation for the visible clip
// once the tour is near the viewport, so the first view never pays for it.
// Pausing puts the still frames back (an animated WebP can't be paused in place).
const tour = document.querySelector(".tour");
if (tour && !still) {
  let near = false, paused = false;
  const imgs = [...tour.querySelectorAll("img[data-anim]")];
  for (const img of imgs) img.dataset.still = img.getAttribute("src");
  const animate = () => {
    if (!near || paused) return;
    for (const img of tour.querySelectorAll(".clip:not([hidden]) img[data-anim]")) {
      if (img.getAttribute("src") !== img.dataset.anim) img.src = img.dataset.anim;
    }
  };
  const buttons = [];
  const setPaused = (p) => {
    paused = p;
    for (const b of buttons) b.sync(p);
    if (p) for (const img of imgs) img.src = img.dataset.still;
    else animate();
  };
  for (const media of tour.querySelectorAll(".clip__media")) {
    const b = pauseButton("animations", setPaused);
    buttons.push(b);
    media.append(b);
  }
  for (const tab of tour.querySelectorAll('[role="tab"]')) tab.addEventListener("click", animate);
  tour.addEventListener("keydown", () => requestAnimationFrame(animate));
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) { near = true; animate(); io.disconnect(); }
    }, { rootMargin: "300px 0px" });
    io.observe(tour);
  } else { near = true; animate(); }
}

// Copy buttons
for (const btn of document.querySelectorAll("[data-copy]")) {
  const label = btn.querySelector("[data-copy-label]");
  btn.hidden = false;
  btn.addEventListener("click", async () => {
    const text = btn.parentElement.querySelector("[data-copy-text]").textContent;
    let ok = false;
    try {
      await navigator.clipboard.writeText(text);
      ok = true;
    } catch (e) {
      const ta = Object.assign(document.createElement("textarea"), { value: text });
      ta.setAttribute("readonly", "");
      ta.style.cssText = "position:fixed;opacity:0";
      document.body.append(ta);
      ta.select();
      try { ok = document.execCommand("copy"); } catch (e2) { ok = false; }
      ta.remove();
    }
    label.textContent = ok ? "Copied" : "Copy failed";
    btn.classList.toggle("is-done", ok);
    clearTimeout(btn._t);
    btn._t = setTimeout(() => { label.textContent = "Copy"; btn.classList.remove("is-done"); }, 1600);
  });
}

// Grow the benchmark bars when they scroll in. Bars start visible and are only
// hidden once we know they're off screen, so nothing is lost if this never runs.
if ("IntersectionObserver" in window && !still) {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        requestAnimationFrame(() => e.target.classList.remove("is-pending"));
        io.unobserve(e.target);
      } else {
        e.target.classList.add("is-pending");
      }
    }
  }, { threshold: 0.2 });
  for (const el of document.querySelectorAll("[data-reveal]")) io.observe(el);
}
