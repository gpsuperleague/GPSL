import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

let overview = [];
/** @type {Map<string, string>} club ShortName → owner tag (owned clubs only) */
let ownerByClub = new Map();

const OWNED_ONLY_KEY = "gpsl_ooo_owned_only";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  const ownedOnlyCb = document.getElementById("ownedOnlyCb");
  ownedOnlyCb.checked = localStorage.getItem(OWNED_ONLY_KEY) !== "0";
  ownedOnlyCb.onchange = () => {
    localStorage.setItem(OWNED_ONLY_KEY, ownedOnlyCb.checked ? "1" : "0");
    renderRows();
    updateSummary();
  };

  document.getElementById("reloadBtn").onclick = loadOverview;
  document.getElementById("selectAllBtn").onclick = () => toggleAll(true);
  document.getElementById("clearSelBtn").onclick = () => toggleAll(false);
  document.getElementById("drawBtn").onclick = drawSelected;

  await loadOverview();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadOverview() {
  setStatus("pageStatus", "Loading…");
  const [{ data, error }, ownersRes] = await Promise.all([
    supabase.rpc("competition_admin_one_of_our_own_overview"),
    supabase.from("Clubs").select("ShortName, owner, owner_id"),
  ]);
  if (error) {
    setStatus(
      "pageStatus",
      "❌ " + error.message + " — run patches/one_of_our_own_best_hg_fallback_20261005.sql",
      false
    );
    return;
  }
  ownerByClub = new Map();
  if (ownersRes.error) {
    console.warn("One of our Own: could not load club owners", ownersRes.error);
  } else {
    for (const row of ownersRes.data || []) {
      if (!row.owner_id) continue;
      ownerByClub.set(row.ShortName, String(row.owner || "").trim() || "Owned");
    }
  }
  overview = Array.isArray(data) ? data : [];
  renderRows();
  updateSummary();
}

function ownedOnly() {
  return !!document.getElementById("ownedOnlyCb")?.checked;
}

function visibleClubs() {
  return ownedOnly() ? overview.filter((c) => ownerByClub.has(c.short_name)) : overview;
}

function updateSummary() {
  const rows = visibleClubs();
  const pending = rows.filter((c) => !c.already_drawn).length;
  const scope = ownedOnly() ? "owned club(s)" : "club(s)";
  setStatus("pageStatus", `${rows.length} ${scope} — ${pending} without a draw yet.`, true);
}

function renderRows() {
  const tbody = document.getElementById("clubRows");
  const rows = visibleClubs();
  if (!rows.length) {
    const msg = ownedOnly() && overview.length ? "No owned clubs found." : "No clubs found.";
    tbody.innerHTML = `<tr><td colspan="6" class="note">${msg}</td></tr>`;
    return;
  }

  tbody.innerHTML = rows
    .map((c) => {
      const owner = ownerByClub.get(c.short_name);
      const ownerCell = owner
        ? escapeHtml(owner)
        : `<span class="ooo-unowned">Unowned</span>`;
      const eligible = Number(c.eligible_count || 0);
      const band = String(c.eligible_band || "79+");
      const best = c.best_rating != null && band === "best HG" ? ` (top ${Number(c.best_rating)})` : "";
      const eligibleLabel = `${eligible} · ${escapeHtml(band)}${best}`;
      if (c.already_drawn) {
        const player = escapeHtml(c.drawn_player_name || c.drawn_player_id || "—");
        const fee = formatMoney(Number(c.drawn_fee || 0));
        return `<tr class="drawn">
          <td></td>
          <td>${escapeHtml(c.club || c.short_name)}</td>
          <td>${ownerCell}</td>
          <td>${escapeHtml(c.nation || "—")}</td>
          <td>${eligibleLabel}</td>
          <td><span class="ooo-badge">${player} · ${fee}</span></td>
        </tr>`;
      }
      const disabled = eligible < 1 ? "disabled" : "";
      const countClass = eligible < 1 ? "ooo-count-0" : "";
      return `<tr>
        <td><input type="checkbox" class="ooo-cb" value="${escapeHtml(c.short_name)}" ${disabled}></td>
        <td>${escapeHtml(c.club || c.short_name)}</td>
        <td>${ownerCell}</td>
        <td>${escapeHtml(c.nation || "—")}</td>
        <td class="${countClass}">${eligibleLabel}</td>
        <td><span class="ooo-badge none">Not drawn</span></td>
      </tr>`;
    })
    .join("");
}

function toggleAll(checked) {
  document.querySelectorAll(".ooo-cb").forEach((cb) => {
    if (!cb.disabled) cb.checked = checked;
  });
}

function selectedClubs() {
  return Array.from(document.querySelectorAll(".ooo-cb"))
    .filter((cb) => cb.checked && !cb.disabled)
    .map((cb) => cb.value);
}

async function drawSelected() {
  const clubs = selectedClubs();
  if (!clubs.length) {
    setStatus("pageStatus", "Select at least one club (only clubs with eligible players can be picked).", false);
    return;
  }
  if (
    !confirm(
      `Draw a One of our Own for ${clubs.length} club(s)?\n\n` +
        "Each gets a free agent matching nationality: random 79+ if that nation has a free-agent star, otherwise random 78, otherwise the best home-grown free agent (highest rating → youngest → most valuable). Signed as a transfer and charged the market value. This cannot be undone and each club can only ever be drawn once."
    )
  ) {
    return;
  }

  setStatus("pageStatus", "Drawing…");
  document.getElementById("drawBtn").disabled = true;

  const { data, error } = await supabase.rpc("competition_admin_draw_one_of_our_own", {
    p_club_short_names: clubs,
  });

  document.getElementById("drawBtn").disabled = false;

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  renderResults(data);
  setStatus("pageStatus", `✅ Drew ${data?.drawn ?? 0} player(s).`, true);
  await loadOverview();
}

function renderResults(data) {
  const root = document.getElementById("drawResults");
  const results = Array.isArray(data?.results) ? data.results : [];
  if (!results.length) {
    root.innerHTML = "";
    return;
  }

  const labelFor = (r) => {
    switch (r.status) {
      case "drawn":
        return `✅ <b>${escapeHtml(r.club)}</b> drew ${escapeHtml(r.player_name || r.player_id)}${r.rating != null ? ` (${Number(r.rating)})` : ""} (${escapeHtml(r.nation || "")}, ${escapeHtml(r.eligible_band || "?")}) for ${formatMoney(Number(r.fee || 0))}`;
      case "skipped_already":
        return `↪︎ <b>${escapeHtml(r.club)}</b> already has its One of our Own (skipped)`;
      case "no_eligible_player":
        return `⚠️ <b>${escapeHtml(r.club)}</b> — no home-grown free agent at all (${escapeHtml(r.nation || "")})`;
      case "club_not_found":
        return `⚠️ <b>${escapeHtml(r.club)}</b> — club not found`;
      case "error":
        return `❌ <b>${escapeHtml(r.club)}</b> — ${escapeHtml(r.message || "error")}`;
      default:
        return `<b>${escapeHtml(r.club)}</b> — ${escapeHtml(r.status)}`;
    }
  };

  root.innerHTML =
    `<h2 style="font-size:15px;color:#ffaa22;margin:14px 0 6px;">Draw results</h2>` +
    results.map((r) => `<div class="row">${labelFor(r)}</div>`).join("");
}
