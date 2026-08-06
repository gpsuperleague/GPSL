import {
  supabase,
  initGlobal,
  isGpslAdminUser,
  fetchIsGpslModUser,
} from "./global.js";
import { APP_VERSION } from "./app_version.js";
import { isModAllowedPage } from "./mod_nav.js";

/** Apply dark admin chrome immediately (avoids white flash before module loads). */
export function primeAdminPageChrome() {
  document.documentElement.classList.add("admin-root");
  document.body.classList.add("admin-page");
}

/**
 * Hide [data-admin-only] blocks when the signed-in user is mod-only (not league admin).
 */
export function applyModOnlyPageChrome(user) {
  if (!user || isGpslAdminUser(user)) return;
  document.body.classList.add("mod-only-user");
  document.querySelectorAll("[data-admin-only]").forEach((el) => {
    el.hidden = true;
  });
}

/**
 * Admin / Mod sub-page init: auth + top nav.
 * @param {{ allowMod?: boolean }} [opts]
 *   allowMod — also admit users in gpsl_site_mods (only for Mod-scoped pages).
 */
export async function initAdminPage(opts = {}) {
  primeAdminPageChrome();

  const allowMod = opts.allowMod === true;

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return null;
  }

  const isAdmin = isGpslAdminUser(user);
  let isMod = false;
  if (!isAdmin && allowMod) {
    isMod = await fetchIsGpslModUser();
  }

  if (!isAdmin && !(allowMod && isMod)) {
    window.location = "dashboard.html";
    return null;
  }

  // Extra guard: mod-only users may only open allowlisted pages.
  if (!isAdmin && isMod) {
    const path = (window.location.pathname || "").toLowerCase().replace(/\\/g, "/");
    const file = path.split("/").pop() || "";
    if (!isModAllowedPage(file)) {
      window.location = "dashboard.html";
      return null;
    }
  }

  await initGlobal();
  applyModOnlyPageChrome(user);
  return user;
}

export function setStatus(elementId, msg, ok = true) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.textContent = msg;
  if (ok === "warn") {
    el.className = "status-line warn";
  } else {
    el.className = ok ? "status-line" : "status-line error";
  }
}

export { supabase, APP_VERSION };

/**
 * Run page boot whether DOMContentLoaded already fired or not.
 * Needed when any import chain uses top-level await.
 */
export function whenDomReady(fn) {
  const run = () => {
    Promise.resolve(fn()).catch((err) => console.error(err));
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
  }
}
