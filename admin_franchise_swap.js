import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let clubs = [];
let seasonOpen = false;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubByShort(short) {
  return clubs.find((row) => row.ShortName === short) || null;
}

function metaText(club) {
  if (!club) return "";
  const owner = club.owner ? `Owner: ${club.owner}` : "No owner";
  return `${club.Stadium || "No stadium"} · ${club.Nation || "No nation"} · ${owner}`;
}

function fillSelect(id) {
  const sel = document.getElementById(id);
  if (!sel) return;
  sel.innerHTML =
    '<option value="">— Select club —</option>' +
    clubs
      .map((c) => {
        const label = `${c.Club || c.ShortName} (${c.ShortName})`;
        return `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(label)}</option>`;
      })
      .join("");
}

function updateMeta() {
  const left = clubByShort(document.getElementById("leftSelect")?.value);
  const right = clubByShort(document.getElementById("rightSelect")?.value);
  const leftMeta = document.getElementById("leftMeta");
  const rightMeta = document.getElementById("rightMeta");
  if (leftMeta) leftMeta.textContent = metaText(left);
  if (rightMeta) rightMeta.textContent = metaText(right);
}

async function loadClubs() {
  const { data, error } = await supabase
    .from("Clubs")
    .select('ShortName, Club, Stadium, Nation, owner')
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error) throw error;
  clubs = data || [];
  fillSelect("leftSelect");
  fillSelect("rightSelect");
  updateMeta();
}

function seasonAllowsSwap(status) {
  const key = String(status || "").toLowerCase();
  return key === "" || key === "complete" || key === "summer_break";
}

async function loadSeasonWindow() {
  const note = document.getElementById("seasonWindow");
  const btn = document.getElementById("swapBtn");
  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .eq("is_current", true)
    .order("id", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    seasonOpen = false;
    if (btn) btn.disabled = true;
    if (note) note.textContent = "Could not read the season, so the swap stays closed.";
    return;
  }

  const status = String(data?.status || "").toLowerCase();
  seasonOpen = seasonAllowsSwap(data ? status : "");
  if (btn) btn.disabled = !seasonOpen;
  if (!note) return;
  if (!data) {
    note.textContent = "No season is running. A swap here rewrites both clubs' history.";
    return;
  }
  note.textContent = seasonOpen
    ? `${data.label} is ${data.status}. A swap rewrites both clubs' history.`
    : `${data.label} is ${data.status}. The swap opens after this season is closed, before the next one starts.`;
}

async function swapClubs() {
  if (!seasonOpen) {
    setStatus("swapStatus", "The swap is closed while a season is running.", false);
    return;
  }
  const left = document.getElementById("leftSelect")?.value;
  const right = document.getElementById("rightSelect")?.value;
  const a = clubByShort(left);
  const b = clubByShort(right);

  if (!a || !b) {
    setStatus("swapStatus", "Select two clubs.", false);
    return;
  }
  if (a.ShortName === b.ShortName) {
    setStatus("swapStatus", "Pick two different clubs.", false);
    return;
  }

  const confirmMsg =
    `Swap ${a.Club || a.ShortName} and ${b.Club || b.ShortName}?\n\n` +
    `${a.ShortName} keeps ${a.Stadium || "its stadium"}, kits and badge.\n` +
    `The owner, squad, fixtures, scores and money now on ${b.ShortName} move onto ${a.ShortName}.\n\n` +
    `${b.ShortName} keeps ${b.Stadium || "its stadium"}, kits and badge.\n` +
    `The owner, squad, fixtures, scores and money now on ${a.ShortName} move onto ${b.ShortName}.\n\n` +
    `Scores stay on the same matches. Run the swap again to undo it.`;

  if (!confirm(confirmMsg)) return;

  setStatus("swapStatus", "Swapping…");
  const btn = document.getElementById("swapBtn");
  if (btn) btn.disabled = true;

  const { data, error } = await supabase.rpc("admin_franchise_identity_swap", {
    p_left: a.ShortName,
    p_right: b.ShortName,
  });

  if (btn) btn.disabled = false;

  if (error) {
    const msg = [error.message, error.details, error.hint].filter(Boolean).join(" — ");
    setStatus(
      "swapStatus",
      msg.includes("schema cache")
        ? "❌ The swap function is not in the database yet. Run supabase/sql/patches/swap_cop_to_lyo.sql in the Supabase SQL editor, then press Swap again."
        : "❌ " + (msg || "Swap failed"),
      false
    );
    return;
  }

  setStatus(
    "swapStatus",
    `✅ ${data?.left} (${data?.left_name}, ${data?.left_stadium}) and ` +
      `${data?.right} (${data?.right_name}, ${data?.right_stadium}) swapped. ` +
      `Refresh club pages to see the new squads.`,
    true
  );

  try {
    await loadClubs();
  } catch (err) {
    setStatus("swapStatus", "Swapped, then failed to reload clubs: " + err.message, false);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage();
  if (!user) return;

  document.getElementById("leftSelect")?.addEventListener("change", updateMeta);
  document.getElementById("rightSelect")?.addEventListener("change", updateMeta);
  document.getElementById("swapBtn")?.addEventListener("click", () => {
    void swapClubs();
  });

  try {
    await loadSeasonWindow();
    await loadClubs();
  } catch (err) {
    setStatus("swapStatus", "Failed to load clubs: " + err.message, false);
  }
});
