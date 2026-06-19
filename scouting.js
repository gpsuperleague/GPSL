import { supabase, initGlobal } from "./global.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, fullClubName, displayClubName } from "./clubs_lookup.js";
import {
  loadPlayerValueTables,
  formatRatingWithPotential,
} from "./player_economics.js";
import { playerThumbLinkHtml, playerNameLinkHtml } from "./player_links.js";
import {
  SCOUTING_TIER_LABELS,
  isScoutingAvailable,
  scoutingSetupHint,
  loadScoutingTargets,
  setScoutingTargetTier,
  toggleScoutingTarget,
  loadScoutingPlannerState,
  saveScoutingPlanner,
} from "./scouting_targets.js";
import { initMatchdaySquadPanel } from "./matchday_squad.js";

const PLAYER_COLUMNS =
  "Konami_ID, Name, Nation, Position, Rating, Potential, Calc_Potential, Age, market_value, Playstyle, Contracted_Team";

const PLAYER_COLUMNS_LEGACY =
  "Konami_ID, Name, Nation, Position, Rating, Age, market_value, Playstyle, Contracted_Team";

let clubShort = null;
let scoutingRows = [];
let scoutingPlayers = [];
let plannerApi = null;

function setPlannerStatus(msg, isError = false) {
  const el = document.getElementById("plannerStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("err", isError);
}

async function fetchPlayersByIds(ids) {
  const numericIds = [
    ...new Set(
      ids
        .map((id) => Number(id))
        .filter((n) => Number.isFinite(n))
    ),
  ];
  if (!numericIds.length) return new Map();

  let { data, error } = await supabase
    .from("Players")
    .select(PLAYER_COLUMNS)
    .in("Konami_ID", numericIds);

  if (error?.message?.toLowerCase().includes("potential")) {
    ({ data, error } = await supabase
      .from("Players")
      .select(PLAYER_COLUMNS_LEGACY)
      .in("Konami_ID", numericIds));
  }

  if (error) throw error;

  const map = new Map();
  for (const p of data || []) {
    map.set(String(p.Konami_ID), p);
  }
  return map;
}

function playersForPlanner() {
  return scoutingPlayers.map((p) => ({
    Konami_ID: p.Konami_ID,
    Name: p.Name,
    Nation: p.Nation,
    Position: p.Position,
    Rating: p.Rating,
    Playstyle: p.Playstyle,
  }));
}

function renderTierTable(tier, rows, playerMap) {
  if (!rows.length) {
    return `<p class="scout-empty">No players — star targets in GPDB (☆).</p>`;
  }

  return `
    <table class="scout-table">
      <thead>
        <tr>
          <th></th>
          <th class="name">Name</th>
          <th>Nation</th>
          <th>Pos</th>
          <th>Age</th>
          <th>Rating</th>
          <th>MV</th>
          <th>Playstyle</th>
          <th>Club</th>
          <th>Tier</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((row) => {
            const p = playerMap.get(String(row.player_id));
            const pid = String(row.player_id);
            const name = p?.Name || `Player ${pid}`;
            const rating = p
              ? formatRatingWithPotential(p.Rating, p.Potential, p.Calc_Potential)
              : "—";
            const mv =
              p?.market_value != null && p.market_value !== ""
                ? formatMoney(Number(p.market_value))
                : "—";
            const club = p?.Contracted_Team
              ? displayClubName(p.Contracted_Team)
              : "Free agent";

            return `
          <tr data-player-id="${pid}">
            <td>${playerThumbLinkHtml(pid, { className: "gpdb-thumb", alt: name })}</td>
            <td class="name">${playerNameLinkHtml(pid, name)}</td>
            <td>${p?.Nation || "—"}</td>
            <td>${p?.Position || "—"}</td>
            <td>${p?.Age ?? "—"}</td>
            <td>${rating}</td>
            <td>${mv}</td>
            <td>${p?.Playstyle || "—"}</td>
            <td>${club}</td>
            <td>
              <select class="scout-tier-select" data-player-id="${pid}" aria-label="Tier for ${name}">
                ${[1, 2, 3, 4]
                  .map(
                    (t) =>
                      `<option value="${t}"${Number(row.tier) === t ? " selected" : ""}>${SCOUTING_TIER_LABELS[t]}</option>`
                  )
                  .join("")}
              </select>
            </td>
            <td>
              <button type="button" class="scout-remove" data-player-id="${pid}" title="Remove from scouting">✕</button>
            </td>
          </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;
}

async function renderScoutingLists() {
  const wrap = document.getElementById("scoutingListsWrap");
  if (!wrap) return;

  if (!isScoutingAvailable()) {
    wrap.innerHTML = `<p style="color:#c96;">${scoutingSetupHint()}</p>`;
    return;
  }

  scoutingRows = await loadScoutingTargets(supabase, clubShort);

  if (!scoutingRows.length) {
    wrap.innerHTML =
      '<p class="scout-empty">No scouting targets yet. Open <a href="GPDB.html" style="color:#ff9900;">GPDB</a> and click ☆ on players to add them.</p>';
    scoutingPlayers = [];
    return;
  }

  const playerMap = await fetchPlayersByIds(scoutingRows.map((r) => r.player_id));
  scoutingPlayers = scoutingRows
    .map((r) => playerMap.get(String(r.player_id)))
    .filter(Boolean);

  wrap.innerHTML = [1, 2, 3, 4]
    .map((tier) => {
      const tierRows = scoutingRows.filter((r) => Number(r.tier) === tier);
      return `
        <div class="tier-block" data-tier="${tier}">
          <h3>${SCOUTING_TIER_LABELS[tier]} (${tierRows.length})</h3>
          ${renderTierTable(tier, tierRows, playerMap)}
        </div>`;
    })
    .join("");

  wrap.querySelectorAll(".scout-tier-select").forEach((sel) => {
    sel.addEventListener("change", async () => {
      const pid = sel.dataset.playerId;
      const tier = Number(sel.value);
      try {
        await setScoutingTargetTier(supabase, pid, tier);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not change tier.");
      }
    });
  });

  wrap.querySelectorAll(".scout-remove").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pid = btn.dataset.playerId;
      try {
        await toggleScoutingTarget(supabase, pid);
        await renderScoutingLists();
        if (document.getElementById("tab-planner")?.classList.contains("active")) {
          await initPlanner();
        }
      } catch (err) {
        alert(err?.message || "Could not remove target.");
      }
    });
  });
}

async function initPlanner() {
  const root = document.getElementById("scoutingPlannerRoot");
  if (!root || !isScoutingAvailable()) return;

  if (!scoutingPlayers.length) {
    root.innerHTML =
      '<p class="scout-empty">Add scouting targets in GPDB first, then plan a lineup here.</p>';
    return;
  }

  const { pitchLayout, rows } = await loadScoutingPlannerState(supabase, clubShort);

  plannerApi = initMatchdaySquadPanel({
    root,
    allPlayers: playersForPlanner(),
    savedRows: rows,
    savedPitchLayout: pitchLayout,
    savedFormations: [],
    onChange: () => {},
    onSave: async (slots, pitchLayoutFromPanel) => {
      try {
        await saveScoutingPlanner(supabase, slots, pitchLayoutFromPanel);
        setPlannerStatus("Tactic board saved.");
      } catch (err) {
        setPlannerStatus(err?.message || "Save failed.", true);
        throw err;
      }
    },
    onSaveFormation: async () => {
      throw new Error("Custom formations are not saved on the scouting board.");
    },
    onLoadFormation: async () => null,
    onDeleteFormation: async () => null,
  });

  const saveBtn = root.querySelector("#squadSaveBtn");
  if (saveBtn) saveBtn.textContent = "Save tactic board";

  const formBar = root.querySelector(".squad-formations-bar");
  if (formBar) {
    const savedRow = formBar.querySelector(".formation-section-row:nth-child(2)");
    if (savedRow) savedRow.style.display = "none";
  }

  const hint = root.querySelector(".squad-hint");
  if (hint) {
    hint.innerHTML =
      "Drag <b>scouting targets</b> onto the pitch (11) and bench (12) to plan a potential lineup. " +
      "Click position labels to change roles. This is for planning only — not your matchday squad.";
  }
}

function wireTabs() {
  document.querySelectorAll(".scout-tabs button[data-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tab = btn.dataset.tab;
      document.querySelectorAll(".scout-tabs button").forEach((b) => {
        b.classList.toggle("active", b.dataset.tab === tab);
      });
      document.querySelectorAll(".scout-tab-panel").forEach((panel) => {
        panel.classList.toggle("active", panel.id === `tab-${tab}`);
      });
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadPlayerValueTables();
  wireTabs();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("scoutingListsWrap").innerHTML =
      '<p class="scout-empty">Link a club to your account to use scouting lists.</p>';
    return;
  }

  clubShort = club.ShortName;
  await loadClubsMap();

  const fullName = fullClubName(clubShort) || club.Club || clubShort;
  document.getElementById("pageTitle").textContent = `${fullName} — Scouting`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${clubShort}.png`;

  await renderScoutingLists();
  await initPlanner();
});
