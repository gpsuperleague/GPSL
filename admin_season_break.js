import { initAdminPage, primeAdminPageChrome } from "./admin_common.js";
import { renderSeasonBreakNavHtml } from "./admin_season_break_nav.js?v=20260619-season-break-kits";

primeAdminPageChrome();

function renderSeasonBreakSidebar() {
  const root = document.getElementById("adminSeasonBreakNav");
  if (!root) return;
  root.innerHTML = renderSeasonBreakNavHtml(window.location.pathname, window.location.search || "");
}

function wireSeasonBreakSidebar() {
  const root = document.getElementById("adminSeasonBreakNav");
  if (!root) return;

  root.querySelectorAll("[data-nav-subgroup]").forEach((subgroup) => {
    const btn = subgroup.querySelector(".nav-subgroup-summary");
    if (!btn) return;
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const willOpen = !subgroup.classList.contains("open");
      subgroup.classList.toggle("open", willOpen);
      btn.setAttribute("aria-expanded", willOpen ? "true" : "false");
    });
  });
}

document.addEventListener("DOMContentLoaded", () => {
  renderSeasonBreakSidebar();
  wireSeasonBreakSidebar();
  initAdminPage();
});
