import { supabase, initGlobal, isGpslAdminUser } from "./global.js";
import { renderAdminSidebar } from "./admin_nav.js";

export async function initAdminPage(pageId, title) {
  await initGlobal();

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

  const mount = document.getElementById("adminLayout");
  if (mount) {
    const main = document.getElementById("adminMain");
    const mainHtml = main ? main.innerHTML : "";
    mount.innerHTML = renderAdminSidebar(pageId) + `<div class="admin-main" id="adminMain">${mainHtml}</div>`;
  }

  if (title) {
    const h = document.querySelector(".admin-title");
    if (h) h.textContent = title;
  }

  document.body.classList.add("admin-page");
  return user;
}

export function setStatus(elementId, msg, ok = true) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "status-line" : "status-line error";
}

export { supabase };
