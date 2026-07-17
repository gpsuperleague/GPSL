import { APP_VERSION } from "./app_version.js";

/**
 * Always load global.js with APP_VERSION so admin nav cache-busts when
 * app_version.js is bumped (bare ./global.js stays stuck in the browser forever).
 */
const __gpslGlobal = await import(`./global.js?v=${APP_VERSION}`);

export const supabase = __gpslGlobal.supabase;
export const initGlobal = __gpslGlobal.initGlobal;
export const isGpslAdminUser = __gpslGlobal.isGpslAdminUser;

/** Apply dark admin chrome immediately (avoids white flash before module loads). */
export function primeAdminPageChrome() {
  document.documentElement.classList.add("admin-root");
  document.body.classList.add("admin-page");
}

/**
 * Admin sub-page init: auth + top nav only (no duplicate sidebar).
 * Page titles live in each HTML <h1> — not overwritten here.
 */
export async function initAdminPage() {
  primeAdminPageChrome();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    window.location = "login.html";
    return null;
  }

  if (!isGpslAdminUser(user)) {
    window.location = "dashboard.html";
    return null;
  }

  await initGlobal();
  return user;
}

export function setStatus(elementId, msg, ok = true) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "status-line" : "status-line error";
}

export { APP_VERSION };
