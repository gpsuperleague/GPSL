import { initAdminPage, primeAdminPageChrome } from "./admin_common.js";
import {
  renderAdminSidebarHtml,
  wireAdminSidebarNav,
} from "./admin_main_nav.js";

primeAdminPageChrome();

function renderSeasonBreakSidebar() {
  const root = document.getElementById("adminSeasonBreakNav");
  if (!root) return;
  root.innerHTML = renderAdminSidebarHtml(
    ["season_break"],
    window.location.pathname,
    window.location.search || ""
  );
}

document.addEventListener("DOMContentLoaded", () => {
  renderSeasonBreakSidebar();
  wireAdminSidebarNav(document.getElementById("adminSeasonBreakNav"));
  initAdminPage();
});
