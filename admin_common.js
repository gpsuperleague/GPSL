import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { APP_VERSION } from "./app_version.js";

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
