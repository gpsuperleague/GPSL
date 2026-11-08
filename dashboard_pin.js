import {
  ensureAdminMenuPanels,
  getDashboardPanel,
  getDashboardPanelByHref,
  getPageDashboardPanel,
  normalizePageFile,
} from "./dashboard_registry.js?v=20261108-pin-cache";
import {
  isPanelOnDashboard,
  togglePanelOnDashboard,
} from "./dashboard_layout.js?v=20261108-pin-cache";

let ownerId = null;
let layoutTableMissing = false;
let adminKnown = false;
let viewerIsAdmin = false;

export function setDashboardPinOwnerId(id) {
  ownerId = id;
}

function isMissingTableError(err) {
  const msg = String(err?.message || err || "").toLowerCase();
  return msg.includes("owner_dashboard_layout") || msg.includes("does not exist");
}

function createPinButton(panelId) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "dashboard-pin-btn";
  btn.dataset.panelId = panelId;
  btn.setAttribute("aria-pressed", "false");
  return btn;
}

async function refreshPinButton(btn) {
  const panelId = btn.dataset.panelId;
  const panel = getDashboardPanel(panelId);
  if (!panel) return;

  const compact = btn.classList.contains("dashboard-pin-btn-nav");
  if (!ownerId || layoutTableMissing) {
    btn.disabled = true;
    btn.textContent = compact ? "+" : "Add to Dashboard";
    btn.title = layoutTableMissing
      ? "Run owner_dashboard_layout.sql in Supabase first"
      : "Sign in to customize dashboard";
    return;
  }

  let on = false;
  try {
    on = await isPanelOnDashboard(window.supabase, ownerId, panelId);
  } catch (err) {
    if (isMissingTableError(err)) {
      layoutTableMissing = true;
      btn.disabled = true;
      btn.title = "Run owner_dashboard_layout.sql in Supabase";
      return;
    }
    console.warn("Dashboard pin state:", err);
    return;
  }

  btn.disabled = false;
  btn.setAttribute("aria-pressed", on ? "true" : "false");
  btn.textContent = compact ? (on ? "✓" : "+") : on ? "On dashboard ✓" : "Add to Dashboard";
  btn.title = on ? "Remove from your dashboard" : "Add this shortcut to your dashboard";
  if (compact) {
    const panel = getDashboardPanel(panelId);
    btn.setAttribute(
      "aria-label",
      on ? `Remove ${panel?.label || "shortcut"} from dashboard` : `Add ${panel?.label || "shortcut"} to dashboard`
    );
  }
  btn.classList.toggle("dashboard-pin-on", on);
}

async function wirePinClick(btn) {
  btn.addEventListener("click", async (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!ownerId || layoutTableMissing) return;

    const panelId = btn.dataset.panelId;
    btn.disabled = true;
    try {
      await togglePanelOnDashboard(window.supabase, ownerId, panelId);
      document.querySelectorAll(`.dashboard-pin-btn[data-panel-id="${panelId}"]`).forEach((b) => {
        refreshPinButton(b);
      });
    } catch (err) {
      if (isMissingTableError(err)) layoutTableMissing = true;
      console.error("Toggle dashboard panel:", err);
      alert(
        err?.message ||
          "Could not update dashboard. Ensure owner_dashboard_layout.sql has been run."
      );
    } finally {
      btn.disabled = false;
    }
  });
}

function resolvePinButton(btn) {
  if (!(btn instanceof HTMLButtonElement) || btn.dataset.pinWired === "1") return;
  const href = btn.dataset.adminMenuHref;
  if (href && !btn.dataset.panelId) {
    const fromHref = getDashboardPanelByHref(href);
    if (!fromHref) {
      btn.remove();
      return;
    }
    btn.dataset.panelId = fromHref.id;
  }
  const panel = getDashboardPanel(btn.dataset.panelId);
  if (!panel) {
    btn.remove();
    return;
  }
  if (panel.adminOnly && (!adminKnown || !viewerIsAdmin)) {
    if (adminKnown && !viewerIsAdmin) btn.remove();
    return;
  }
  btn.dataset.pinWired = "1";
  wirePinClick(btn);
  if (btn.classList.contains("dashboard-pin-btn-nav") && btn.closest(".nav-dropdown-admin")) return;
  refreshPinButton(btn);
}

function armAdminPinRefresh() {
  if (!viewerIsAdmin) return;
  const summary = document
    .querySelector(".nav-dropdown-admin")
    ?.closest("[data-nav-group]")
    ?.querySelector(":scope > .nav-group-summary");
  if (!summary || summary.dataset.pinRefreshArmed === "1") return;
  summary.dataset.pinRefreshArmed = "1";
  summary.addEventListener("click", () => {
    document.querySelectorAll(".dashboard-pin-btn-nav").forEach((btn) => refreshPinButton(btn));
  }, { once: true });
}

function ensureAdminMenuPinButtons() {
  if (!viewerIsAdmin) return;
  document.querySelectorAll(".nav-dropdown-admin a.nav-link").forEach((link) => {
    if (link.closest(".nav-admin-pin-row") || link.closest("[data-mod-preview]")) return;
    const href = link.getAttribute("href");
    if (!href || !getDashboardPanelByHref(href)) return;
    const row = document.createElement("span");
    row.className = "nav-admin-pin-row";
    link.parentNode.insertBefore(row, link);
    row.appendChild(link);
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "dashboard-pin-btn dashboard-pin-btn-nav";
    btn.dataset.adminMenuHref = href;
    btn.textContent = "+";
    btn.title = "Add to your dashboard";
    row.appendChild(btn);
  });
}

/** Wire pin buttons already in the page. Safe to call again after a sidebar render. */
export function wireDashboardPinRoots(root = document) {
  (root || document).querySelectorAll(".dashboard-pin-btn").forEach((btn) => resolvePinButton(btn));
}

function mountPinButton(anchor, panelId, position = "after") {
  if (!anchor) return;
  const panel = getDashboardPanel(panelId);
  if (panel?.adminOnly && !viewerIsAdmin) return;
  if (anchor.querySelector?.(`.dashboard-pin-btn[data-panel-id="${panelId}"]`)) return;

  const wrap = document.createElement("div");
  wrap.className = "dashboard-pin-wrap";
  const btn = createPinButton(panelId);
  wrap.appendChild(btn);
  wirePinClick(btn);
  refreshPinButton(btn);

  if (position === "prepend-title" && anchor.tagName === "H1") {
    const row = document.createElement("div");
    row.className = "dashboard-pin-title-row";
    anchor.parentNode.insertBefore(row, anchor);
    row.appendChild(anchor);
    row.appendChild(wrap);
    return;
  }

  if (position === "panel-header") {
    const h2 = anchor.querySelector("h2") || anchor;
    let head = anchor.querySelector(".dashboard-panel-head");
    if (!head) {
      head = document.createElement("div");
      head.className = "dashboard-panel-head";
      h2.parentNode.insertBefore(head, h2);
      head.appendChild(h2);
    }
    head.appendChild(wrap);
    return;
  }

  anchor.appendChild(wrap);
}

/** Call after auth; adds pin controls for this page and [data-dashboard-panel] sections. */
export async function initDashboardPinUi(supabase, opts = {}) {
  if (!supabase) return;

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  adminKnown = true;
  viewerIsAdmin = opts.isAdmin === true;
  setDashboardPinOwnerId(user.id);
  if (viewerIsAdmin) await ensureAdminMenuPanels();
  ensureAdminMenuPinButtons();
  wireDashboardPinRoots(document);
  armAdminPinRefresh();

  const page = normalizePageFile(window.location.pathname);

  document.querySelectorAll("[data-dashboard-panel]").forEach((el) => {
    const panelId = el.getAttribute("data-dashboard-panel");
    if (!getDashboardPanel(panelId)) return;
    mountPinButton(el, panelId, "panel-header");
  });

  const pagePanel = getPageDashboardPanel(page, window.location);
  if (
    pagePanel &&
    !pagePanel.noPagePin &&
    !document.querySelector(`[data-dashboard-panel="${pagePanel.id}"]`)
  ) {
    const h1 =
      document.getElementById("pageTitle") ||
      document.querySelector("h1") ||
      document.querySelector(".admin-title");
    const header =
      document.getElementById("headerLeft") ||
      document.getElementById("headerContainer") ||
      document.querySelector(".header-row") ||
      document.querySelector(".page-container");
    let mounted = false;
    if (h1) {
      mountPinButton(h1, pagePanel.id, "prepend-title");
      mounted = true;
    } else if (header) {
      mountPinButton(header, pagePanel.id);
      mounted = true;
    }
    if (!mounted) {
      const nav = document.getElementById("nav");
      if (nav) {
        let bar = document.getElementById("dashboardPagePinBar");
        if (!bar) {
          bar = document.createElement("div");
          bar.id = "dashboardPagePinBar";
          bar.className = "dashboard-page-pin-bar";
          nav.insertAdjacentElement("afterend", bar);
        }
        mountPinButton(bar, pagePanel.id);
      }
    }
  }
}

export async function refreshAllDashboardPins() {
  document.querySelectorAll(".dashboard-pin-btn").forEach((btn) => refreshPinButton(btn));
}
