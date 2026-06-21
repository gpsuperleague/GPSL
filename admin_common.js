import { supabase, initGlobal, isGpslAdminUser } from "./global.js?v=20260621-checklist-presteason";

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

export { supabase };
