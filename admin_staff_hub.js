import { initAdminPage } from "./admin_common.js?v=20261114-staff-hub";
import { isGpslAdminUser } from "./global.js?v=20261114-staff-hub";

const TABS = ["alerts", "owners", "checklist", "mods"];
const ADMIN_TABS = new Set(["owners", "mods"]);
const booted = new Set();
let adminUser = null;

function isAdmin() {
  return !!(adminUser && isGpslAdminUser(adminUser));
}

function allowed(name) {
  return TABS.includes(name) && (!ADMIN_TABS.has(name) || isAdmin());
}

function tabFromHash() {
  const raw = (location.hash || "").replace(/^#/, "");
  if (raw === "season-owner-board" || raw === "owner-last-login") return "owners";
  if (TABS.includes(raw)) return raw;
  return isAdmin() ? "owners" : "alerts";
}

async function boot(name) {
  if (booted.has(name)) return;
  try {
    if (name === "alerts") {
      const mod = await import("./admin_staff_alerts.js?v=20261114-staff-hub");
      await mod.bootStaffAlerts();
    } else if (name === "owners") {
      const mod = await import("./admin_owners.js?v=20261114-board-filters");
      await mod.bootOwnerAdminPage();
    } else if (name === "checklist") {
      const mod = await import("./admin_club_checklist.js?v=20261114-checklist-fines");
      await mod.bootClubChecklist(adminUser);
    } else if (name === "mods") {
      const mod = await import("./admin_mods.js?v=20261114-staff-hub");
      await mod.bootManageMods();
    }
    booted.add(name);
  } catch (err) {
    console.error(err);
  }
}

async function show(name) {
  if (!allowed(name)) name = isAdmin() ? "owners" : "alerts";
  const special =
    name === "owners" &&
    (location.hash === "#season-owner-board" || location.hash === "#owner-last-login");
  if (!special && location.hash !== `#${name}`) {
    history.replaceState(null, "", `#${name}`);
  }
  document.querySelectorAll("[data-hub-tab]").forEach((btn) => {
    const on = btn.dataset.hubTab === name;
    btn.classList.toggle("is-on", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
  document.querySelectorAll("[data-panel]").forEach((panel) => {
    panel.classList.toggle("is-on", panel.dataset.panel === name);
  });
  await boot(name);
}

document.addEventListener("DOMContentLoaded", async () => {
  adminUser = await initAdminPage({ allowMod: true });
  if (!adminUser) return;
  document.querySelectorAll("[data-hub-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      void show(btn.dataset.hubTab);
    });
  });
  window.addEventListener("hashchange", () => {
    void show(tabFromHash());
  });
  await show(tabFromHash());
});
