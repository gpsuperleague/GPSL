import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { GPSL_ADMIN_EMAILS } from "./global.js";

primeAdminPageChrome();

/** @type {Set<string>} */
let grantedEmails = new Set();

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

function statusLabel(row) {
  if (row.club_short_name) return row.club_short_name;
  if (row.registry_status === "archived") return "ARCHIVED";
  if (row.registry_status === "on_break") return "ON BREAK";
  if (row.registry_status === "member") return "WAITING LIST";
  if (row.registry_status === "on_absence") return "ABSENCE";
  if (row.registry_status === "awaiting_club_auction") return "CLUB AUCTION";
  return "NO CLUB";
}

function optionLabel(row) {
  const club = statusLabel(row);
  const tag = String(row.owner_tag || "").trim();
  const email = String(row.email || "").trim().toLowerCase();
  if (tag) return `${club} — ${tag} — ${email}`;
  return `${club} — ${email}`;
}

async function loadOwnerSelect() {
  const sel = document.getElementById("modEmailSelect");
  if (!sel) return;

  const keep = sel.value;
  const { data, error } = await supabase.rpc("admin_owner_list");
  if (error) {
    sel.innerHTML = `<option value="">❌ Could not load owners</option>`;
    return;
  }

  const adminSet = new Set(GPSL_ADMIN_EMAILS.map((e) => e.toLowerCase()));
  const owners = (Array.isArray(data) ? data : [])
    .filter((r) => r?.email)
    .filter((r) => !adminSet.has(String(r.email).toLowerCase()))
    .filter((r) => !grantedEmails.has(String(r.email).toLowerCase()))
    .sort((a, b) => optionLabel(a).localeCompare(optionLabel(b), "en"));

  sel.innerHTML = `<option value="">— Select owner —</option>`;
  for (const row of owners) {
    const email = String(row.email).trim().toLowerCase();
    const opt = document.createElement("option");
    opt.value = email;
    opt.textContent = optionLabel(row);
    sel.appendChild(opt);
  }

  if (keep && [...sel.options].some((o) => o.value === keep)) {
    sel.value = keep;
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
  grantedEmails = new Set(
    rows.map((r) => String(r.email || "").toLowerCase()).filter(Boolean)
  );
  await loadOwnerSelect();

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
  const email = document.getElementById("modEmailSelect")?.value?.trim().toLowerCase() || "";
  const note = document.getElementById("modNote")?.value?.trim() || "";
  if (!email) {
    setStatus("modStatus", "Select an owner.", false);
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
  document.getElementById("modEmailSelect").value = "";
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
