// lmux docs: theme toggle (same rule as site.js), the phone menu, "On this page" highlight,
// the prompt's Copy button. No dependencies; every page reads fine with JS off.

const root = document.documentElement;
const mq = (q) => window.matchMedia(q);

// Theme: every click flips what you see; landing back on the system's own theme returns to auto.
const themeBtn = document.querySelector("[data-theme-toggle]");
const themeColors = document.querySelectorAll('meta[name="theme-color"]');
for (const m of themeColors) m.dataset.auto = m.content;
let theme = root.dataset.theme || "auto";
const sysDark = () => mq("(prefers-color-scheme: dark)").matches;
const isDark = () => theme === "dark" || (theme === "auto" && sysDark());
const ICONS = {
  auto: '<circle cx="10" cy="10" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 3.75a6.25 6.25 0 0 1 0 12.5z" fill="currentColor"/>',
  light: '<circle cx="10" cy="10" r="3.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 2.5v1.8M10 15.7v1.8M2.5 10h1.8M15.7 10h1.8M4.7 4.7l1.27 1.27M14.03 14.03l1.27 1.27M4.7 15.3l1.27-1.27M14.03 5.97l1.27-1.27" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
  dark: '<path d="M15.8 12.1A6.5 6.5 0 0 1 7.9 4.2a6.5 6.5 0 1 0 7.9 7.9Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
};
function applyTheme() {
  if (theme === "auto") delete root.dataset.theme;
  else root.dataset.theme = theme;
  for (const m of themeColors) m.content = theme === "auto" ? m.dataset.auto : theme === "dark" ? "#20242C" : "#F5F7FA";
  themeBtn.setAttribute("aria-label", `Theme: ${theme === "auto" ? "automatic" : theme}. Switch to ${isDark() ? "light" : "dark"}`);
  themeBtn.querySelector("svg").innerHTML = ICONS[theme];
}
applyTheme();
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
mq("(prefers-color-scheme: dark)").addEventListener?.("change", applyTheme);

// Phone menu: a panel under the bar. Esc or a link closes it and gives focus back.
const menuBtn = document.querySelector("[data-menu]");
const nav = document.getElementById("docs-nav");
const narrow = mq("(max-width: 900px)");
function setMenu(open, refocus) {
  nav.classList.toggle("is-open", open);
  menuBtn.setAttribute("aria-expanded", String(open));
  menuBtn.setAttribute("aria-label", open ? "Hide the docs menu" : "Show the docs menu");
  if (open) nav.querySelector('[aria-current="page"]')?.focus({ preventScroll: true });
  else if (refocus) menuBtn.focus();
}
const syncMenu = () => { menuBtn.hidden = !narrow.matches; if (!narrow.matches) setMenu(false); };
syncMenu();
narrow.addEventListener?.("change", syncMenu);
menuBtn.addEventListener("click", () => setMenu(!nav.classList.contains("is-open")));
nav.addEventListener("click", (e) => { if (e.target.closest("a")) setMenu(false); });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && nav.classList.contains("is-open")) setMenu(false, true);
});

// "On this page": mark the last heading scrolled past.
const toc = [...document.querySelectorAll(".docs-toc a")];
if (toc.length && "IntersectionObserver" in window) {
  const heads = toc.map((a) => document.getElementById(a.hash.slice(1))).filter(Boolean);
  const mark = () => {
    let cur = heads[0];
    for (const h of heads) if (h.getBoundingClientRect().top < 120) cur = h;
    for (const a of toc) a.classList.toggle("is-current", a.hash.slice(1) === cur.id);
  };
  const io = new IntersectionObserver(mark, { rootMargin: "0px 0px -60% 0px" });
  for (const h of heads) io.observe(h);
  mark();
}

// Copy buttons (the prompt on the docs home).
for (const btn of document.querySelectorAll("[data-copy]")) {
  const label = btn.querySelector("[data-copy-label]");
  btn.hidden = false;
  btn.addEventListener("click", async () => {
    const text = btn.parentElement.querySelector("[data-copy-text]").textContent;
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch (e) { ok = false; }
    label.textContent = ok ? "Copied" : "Copy failed";
    btn.classList.toggle("is-done", ok);
    clearTimeout(btn._t);
    btn._t = setTimeout(() => { label.textContent = "Copy"; btn.classList.remove("is-done"); }, 1600);
  });
}
