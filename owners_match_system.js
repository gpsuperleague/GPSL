/**
 * Owners → Info → Match System board.
 * Shows each owned club's GPSL match arrangement system (ON / OFF).
 */
import { initGlobal, supabase, getAuthUser } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { loadClubsMap, clubWithOwnerHtml } from "./clubs_lookup.js";
import { loadOwnerSupporterMap } from "./owner_badge.js";

/** @type {{ clubs?: Array<Record<string, unknown>>, active_gpsl_month?: string, active_half_label?: string }} */
let directory = { clubs: [] };
let filterText = "";
let filterMode = "all";

function setStatus(msg, isError = false) {
  const el = document.getElementById("msStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("error", !!isError);
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function systemPill(on) {
  if (on) {
    return `<span class="ms-pill ms-pill--on" title="GPSL arranging">ON</span>`;
  }
  return `<span class="ms-pill ms-pill--off" title="Manual / Discord black box">OFF</span>`;
}

function halfCell(on, explicit) {
  const pill = systemPill(on !== false);
  if (explicit === false) {
    return `${pill} <span class="muted">(follows Aug–Dec)</span>`;
  }
  return pill;
}

function matchesFilter(row) {
  const arrangement = row.arrangement === "manual" || row.effective_gpsl_system_on === false
    ? "manual"
    : "gpsl";
  if (filterMode === "gpsl" && arrangement !== "gpsl") return false;
  if (filterMode === "manual" && arrangement !== "manual") return false;

  const q = filterText.trim().toLowerCase();
  if (!q) return true;
  const blob = [
    row.club_short_name,
    row.club_name,
    row.owner_tag,
    row.owner_timezone,
    arrangement,
    onOffLabel(row),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  return blob.includes(q);
}

function timezoneLabel(tz) {
  const raw = String(tz || "").trim();
  if (!raw) return "—";
  return raw.replace(/_/g, " ");
}

function onOffLabel(row) {
  return row.effective_gpsl_system_on === false ? "off manual" : "on gpsl";
}

function render() {
  const body = document.getElementById("msTableBody");
  if (!body) return;

  const list = (directory.clubs || []).filter(matchesFilter);
  if (!list.length) {
    body.innerHTML = `<tr><td colspan="6" class="muted">No clubs match this filter.</td></tr>`;
    return;
  }

  body.innerHTML = list
    .map((row, i) => {
      const on = row.effective_gpsl_system_on !== false;
      const club = clubWithOwnerHtml(
        row.club_name || row.club_short_name,
        row.club_short_name,
        "inline"
      );
      const h2Explicit = row.h2_explicitly_set === true;
      const tz = timezoneLabel(row.owner_timezone);
      return `<tr>
        <td>${i + 1}</td>
        <td>${club}</td>
        <td class="ms-tz" title="${escapeHtml(tz)}">${escapeHtml(tz)}</td>
        <td>${systemPill(on)} <span class="muted">${
          on ? "GPSL arranging" : "Manual / Discord"
        }</span></td>
        <td class="half-cell">${systemPill(row.h1_gpsl_system_on !== false)}</td>
        <td class="half-cell">${halfCell(row.h2_gpsl_system_on !== false, h2Explicit)}</td>
      </tr>`;
    })
    .join("");
}

function updateMeta() {
  const el = document.getElementById("msMeta");
  if (!el) return;
  const month = directory.active_gpsl_month
    ? String(directory.active_gpsl_month).replace(/^./, (c) => c.toUpperCase())
    : "—";
  const half = directory.active_half_label || "—";
  el.textContent = `Active GPSL month: ${month} · Current half: ${half}`;
}

async function loadDirectory() {
  setStatus("Loading…");
  const { data, error } = await supabase.rpc("owners_match_system_directory");
  if (error) {
    setStatus(
      `${error.message}${
        /owners_match_system_directory/i.test(error.message || "")
          ? " — run owners_match_system_directory_20261020.sql"
          : ""
      }`,
      true
    );
    directory = { clubs: [] };
    updateMeta();
    render();
    return;
  }
  directory = data && typeof data === "object" ? data : { clubs: [] };
  if (directory.ok === false) {
    setStatus(directory.error || "Could not load match systems.", true);
    directory.clubs = [];
    updateMeta();
    render();
    return;
  }
  const clubs = Array.isArray(directory.clubs) ? directory.clubs : [];
  const offN = clubs.filter((c) => c.effective_gpsl_system_on === false).length;
  const onN = clubs.length - offN;
  setStatus(
    `${clubs.length} club${clubs.length === 1 ? "" : "s"} · ${onN} GPSL ON · ${offN} manual OFF`
  );
  updateMeta();
  render();
}

async function main() {
  const user = await getAuthUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  await initGlobal();
  initGpslInfoTips();
  await Promise.all([loadClubsMap().catch(() => {}), loadOwnerSupporterMap().catch(() => {})]);

  document.getElementById("msSearch")?.addEventListener("input", (e) => {
    filterText = e.target.value || "";
    render();
  });
  document.getElementById("msFilter")?.addEventListener("change", (e) => {
    filterMode = e.target.value || "all";
    render();
  });
  document.getElementById("msRefreshBtn")?.addEventListener("click", () => {
    void loadDirectory();
  });

  await loadDirectory();
}

main().catch((err) => {
  console.error(err);
  setStatus(err?.message || String(err), true);
});
