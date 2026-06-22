import {
  getDashboardPanel,
  getPageDashboardPanel,
  normalizePageFile,
} from "./dashboard_registry.js";
import {
  isPanelOnDashboard,
  togglePanelOnDashboard,
} from "./dashboard_layout.js";

let ownerId = null;
let layoutTableMissing = false;

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

  if (!ownerId || layoutTableMissing) {
    btn.disabled = true;
    btn.textContent = "Add to Dashboard";
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
  btn.textContent = on ? "On dashboard ✓" : "Add to Dashboard";
  btn.title = on
    ? "Remove from your dashboard"
    : "Add this shortcut to your dashboard";
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

function mountPinButton(anchor, panelId, position = "after") {
  if (!anchor) return;
  if (document.querySelector(`.dashboard-pin-btn[data-panel-id="${panelId}"]`)) {
    return;
  }

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
export async function initDashboardPinUi(supabase) {
  if (!supabase) return;

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  setDashboardPinOwnerId(user.id);

  const page = normalizePageFile(window.location.pathname);

  document.querySelectorAll("[data-dashboard-panel]").forEach((el) => {
    const panelId = el.getAttribute("data-dashboard-panel");
    if (!getDashboardPanel(panelId)) return;
    mountPinButton(el, panelId, "panel-header");
  });

  const pagePanel = getPageDashboardPanel(page);
  if (
    pagePanel &&
    !document.querySelector(`[data-dashboard-panel="${pagePanel.id}"]`) &&
    !document.querySelector(`.dashboard-pin-btn[data-panel-id="${pagePanel.id}"]`)
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
