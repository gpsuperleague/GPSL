import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString("en-GB", {
      timeZone: "Europe/London",
      day: "2-digit",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return String(iso);
  }
}

async function loadMods() {
  const wrap = document.getElementById("modListWrap");
  setStatus("modStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_mod_list");
  if (error) {
    wrap.innerHTML = `<p class="note">❌ ${escapeHtml(error.message)}</p>`;
    setStatus(
      "modStatus",
      error.message.includes("admin_mod_list")
        ? "❌ Run gpsl_mods.sql in Supabase first."
        : `❌ ${error.message}`,
      false
    );
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">No mods granted yet.</p>`;
    setStatus("modStatus", "0 mods", true);
    return;
  }

  wrap.innerHTML = `
    <table class="mod-table">
      <thead>
        <tr>
          <th>Email</th>
          <th>Tag / club</th>
          <th>Granted</th>
          <th>Note</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((r) => {
            const email = String(r.email || "");
            const tagClub = [r.owner_tag, r.club_short_name].filter(Boolean).join(" · ") || "—";
            return `
          <tr>
            <td>${escapeHtml(email)}</td>
            <td>${escapeHtml(tagClub)}</td>
            <td>${escapeHtml(formatWhen(r.granted_at))}</td>
            <td>${escapeHtml(r.note || "—")}</td>
            <td>
              <button type="button" class="button danger mod-revoke" data-email="${escapeHtml(
                email
              )}">Revoke</button>
            </td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  wrap.querySelectorAll(".mod-revoke").forEach((btn) => {
    btn.addEventListener("click", () => revokeMod(btn.getAttribute("data-email")));
  });
  setStatus("modStatus", `${rows.length} mod${rows.length === 1 ? "" : "s"}`, true);
}

async function grantMod() {
  const email = document.getElementById("modEmail")?.value?.trim().toLowerCase() || "";
  const note = document.getElementById("modNote")?.value?.trim() || "";
  if (!email) {
    setStatus("modStatus", "Enter an owner email.", false);
    return;
  }
  setStatus("modStatus", `Granting mod to ${email}…`);
  const { error } = await supabase.rpc("admin_mod_grant", {
    p_email: email,
    p_note: note || null,
  });
  if (error) {
    setStatus("modStatus", `❌ ${error.message}`, false);
    return;
  }
  document.getElementById("modEmail").value = "";
  document.getElementById("modNote").value = "";
  setStatus("modStatus", `✅ Granted mod to ${email}`, true);
  await loadMods();
}

async function revokeMod(email) {
  if (!email) return;
  if (!confirm(`Revoke mod access for ${email}?`)) return;
  setStatus("modStatus", `Revoking ${email}…`);
  const { error } = await supabase.rpc("admin_mod_revoke", { p_email: email });
  if (error) {
    setStatus("modStatus", `❌ ${error.message}`, false);
    return;
  }
  setStatus("modStatus", `✅ Revoked ${email}`, true);
  await loadMods();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("modGrantBtn")?.addEventListener("click", grantMod);
  document.getElementById("modRefreshBtn")?.addEventListener("click", loadMods);
  await loadMods();
});
