import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

async function loadAlerts() {
  setStatus("status", "Loading…");
  const { data, error } = await supabase.rpc("gpsl_staff_alerts_list", { p_limit: 80 });
  const wrap = document.getElementById("alertList");
  if (error) {
    setStatus(
      "status",
      error.message + " — run gpsl_staff_alerts.sql",
      false
    );
    if (wrap) wrap.innerHTML = "";
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  const unread = rows.filter((r) => !r.is_read).length;
  setStatus(
    "status",
    rows.length
      ? `${rows.length} alert(s)${unread ? ` · ${unread} unread` : ""}.`
      : "No staff alerts yet.",
    true
  );
  if (!wrap) return;
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">When someone joins via Join GPSL, an alert appears here for admins and mods.</p>`;
    return;
  }
  wrap.innerHTML = rows
    .map((r) => {
      const unreadBadge = r.is_read ? "" : `<span class="badge-new">NEW</span>`;
      const href = r.action_href
        ? `<a class="button secondary" href="${escapeHtml(r.action_href)}">Open</a>`
        : "";
      const mark = r.is_read
        ? ""
        : `<button type="button" class="button secondary" data-mark="${r.id}">Mark read</button>`;
      return `
        <article class="alert-card${r.is_read ? "" : " unread"}" data-id="${r.id}">
          <h3>${escapeHtml(r.title)}${unreadBadge}</h3>
          <div class="alert-meta">${escapeHtml(r.alert_type)} · ${escapeHtml(formatWhen(r.created_at))}</div>
          <div class="alert-body">${escapeHtml(r.body || "")}</div>
          <div class="alert-actions">${href}${mark}</div>
        </article>`;
    })
    .join("");

  wrap.querySelectorAll("[data-mark]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.getAttribute("data-mark"));
      const { error: err } = await supabase.rpc("gpsl_staff_alert_mark_read", {
        p_alert_id: id,
      });
      if (err) {
        setStatus("status", err.message, false);
        return;
      }
      await loadAlerts();
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  document.getElementById("refreshBtn")?.addEventListener("click", loadAlerts);
  document.getElementById("markAllBtn")?.addEventListener("click", async () => {
    const { data, error } = await supabase.rpc("gpsl_staff_alerts_mark_all_read");
    if (error) {
      setStatus("status", error.message, false);
      return;
    }
    setStatus("status", `Marked ${data ?? 0} alert(s) read.`, true);
    await loadAlerts();
  });
  await loadAlerts();
});
