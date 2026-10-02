/** Optional per-browser light mode. Dark mode stays the GPSL default. */

const STORAGE_KEY = "gpsl_site_theme";
const STYLESHEET_ID = "gpslLightModeCss";
const STYLESHEET_HREF = "gpsl_light_mode.css?v=20261002-light-mode2";

function readStoredTheme() {
  try {
    return localStorage.getItem(STORAGE_KEY) === "light" ? "light" : "dark";
  } catch {
    return "dark";
  }
}

function ensureStylesheet() {
  if (typeof document === "undefined") return;
  if (document.getElementById(STYLESHEET_ID)) return;
  const link = document.createElement("link");
  link.id = STYLESHEET_ID;
  link.rel = "stylesheet";
  link.href = STYLESHEET_HREF;
  document.head.appendChild(link);
}

export function currentSiteTheme() {
  return document.documentElement.dataset.gpslTheme === "light" ? "light" : "dark";
}

function setSiteTheme(theme) {
  const root = document.documentElement;
  if (theme === "light") {
    root.dataset.gpslTheme = "light";
  } else {
    delete root.dataset.gpslTheme;
  }
}

export function applyStoredSiteTheme() {
  if (typeof document === "undefined") return;
  ensureStylesheet();
  setSiteTheme(readStoredTheme());
}

export function toggleSiteTheme() {
  const next = currentSiteTheme() === "light" ? "dark" : "light";
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    /* private mode — still switch for this page view */
  }
  setSiteTheme(next);
  syncThemeToggleButtons();
  return next;
}

function toggleLabel(theme) {
  return theme === "light" ? "Switch to dark mode" : "Switch to light mode";
}

export function renderNavThemeToggle() {
  const theme = typeof document !== "undefined" ? currentSiteTheme() : "dark";
  const label = toggleLabel(theme);
  return (
    `<button type="button" class="gpsl-theme-toggle" data-gpsl-theme-toggle="1" ` +
    `title="${label}" aria-label="${label}">` +
    `<span class="gpsl-no-invert" aria-hidden="true">${theme === "light" ? "🌙" : "☀️"}</span>` +
    `</button>`
  );
}

function syncThemeToggleButtons() {
  const theme = currentSiteTheme();
  const label = toggleLabel(theme);
  document.querySelectorAll("[data-gpsl-theme-toggle]").forEach((btn) => {
    btn.title = label;
    btn.setAttribute("aria-label", label);
    const icon = btn.querySelector("span");
    if (icon) icon.textContent = theme === "light" ? "🌙" : "☀️";
  });
}

export function wireNavThemeToggle(root = document) {
  root.querySelectorAll("[data-gpsl-theme-toggle]").forEach((btn) => {
    if (btn.dataset.wired === "1") return;
    btn.dataset.wired = "1";
    btn.addEventListener("click", () => toggleSiteTheme());
  });
}

if (typeof window !== "undefined") {
  window.addEventListener("storage", (e) => {
    if (e.key !== STORAGE_KEY) return;
    setSiteTheme(e.newValue === "light" ? "light" : "dark");
    syncThemeToggleButtons();
  });
}
