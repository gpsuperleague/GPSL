import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let clubs = [];

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatCap(n) {
  return Number(n || 0).toLocaleString("en-GB");
}

function updateClubMeta() {
  const el = document.getElementById("clubMeta");
  const short = document.getElementById("clubSelect")?.value;
  const c = clubs.find((row) => row.ShortName === short);
  if (!el) return;
  if (!c) {
    el.textContent = "";
    return;
  }
  const base = c.base_capacity != null ? c.base_capacity : c.Capacity;
  el.textContent =
    `Stadium: ${c.Stadium || "—"} · Current capacity: ${formatCap(c.Capacity)} · Original (base): ${formatCap(base)}`;
}

async function loadClubs() {
  const { data, error } = await supabase
    .from("Clubs")
    .select('ShortName, Club, Stadium, Capacity, base_capacity')
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error) throw error;
  clubs = data || [];

  const sel = document.getElementById("clubSelect");
  if (!sel) return;

  sel.innerHTML =
    '<option value="">— Select club —</option>' +
    clubs
      .map((c) => {
        const base = c.base_capacity != null ? c.base_capacity : c.Capacity;
        const label = `${c.Club || c.ShortName} (${c.ShortName}) — ${formatCap(c.Capacity)} → base ${formatCap(base)}`;
        return `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(label)}</option>`;
      })
      .join("");

  sel.onchange = updateClubMeta;
}

async function resetStadium() {
  const short = document.getElementById("clubSelect")?.value;
  if (!short) {
    setStatus("resetStatus", "Select a club first.", false);
    return;
  }

  const c = clubs.find((row) => row.ShortName === short);
  const base = c?.base_capacity != null ? c.base_capacity : c?.Capacity;
  const confirmMsg =
    `Reset ${c?.Club || short} stadium to original capacity?\n\n` +
    `Current: ${formatCap(c?.Capacity)}\n` +
    `Original: ${formatCap(base)}\n\n` +
    `In-progress expansion orders will be cancelled (no auto-refund).`;

  if (!confirm(confirmMsg)) return;

  setStatus("resetStatus", "Resetting…");
  const btn = document.getElementById("resetBtn");
  if (btn) btn.disabled = true;

  const { data, error } = await supabase.rpc("admin_stadium_reset_to_base_capacity", {
    p_club_short_name: short,
  });

  if (btn) btn.disabled = false;

  if (error) {
    const msg = String(error.message || "");
    setStatus(
      "resetStatus",
      msg.includes("admin_stadium_reset_to_base_capacity")
        ? "❌ Run supabase/sql/patches/admin_stadium_reset_capacity.sql first."
        : "❌ " + msg,
      false
    );
    return;
  }

  setStatus(
    "resetStatus",
    `✅ ${short}: ${formatCap(data?.capacity_before)} → ${formatCap(data?.capacity_after)} ` +
      `(base ${formatCap(data?.base_capacity)}; cancelled ${data?.orders_cancelled ?? 0} open order(s)).`,
    true
  );

  await loadClubs();
  const sel = document.getElementById("clubSelect");
  if (sel) sel.value = short;
  updateClubMeta();
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage();
  if (!user) return;

  document.getElementById("resetBtn")?.addEventListener("click", () => {
    void resetStadium();
  });

  try {
    await loadClubs();
  } catch (err) {
    setStatus("resetStatus", "Failed to load clubs: " + err.message, false);
  }
});
