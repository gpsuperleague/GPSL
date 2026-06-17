import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  loadInternationalNations,
  loadNationalSquad,
  loadMyNation,
  releaseCallup,
  summarizeNationalSquad,
  isGoalkeeper,
  renderNationFlag,
  NATIONAL_SQUAD_MAX,
  NATIONAL_SQUAD_MIN_GK,
} from "./international.js";
import {
  playerThumbLinkHtml,
  playerNameLinkHtml,
} from "./player_links.js";

const POSITION_GROUPS = {
  Goalkeepers: ["GK"],
  Defenders: ["LB", "CB", "RB"],
  Midfielders: ["DMF", "LMF", "CMF", "RMF", "AMF"],
  Attackers: ["LW", "LWF", "SS", "RW", "RWF", "CF"],
};

function getNationCode() {
  return new URLSearchParams(window.location.search).get("nation")?.toUpperCase() || null;
}

function renderSummary(summary, isMyNation) {
  const el = document.getElementById("squadSummary");
  if (!el) return;

  const gkLine = summary.gkOk
    ? `${summary.gkCount} goalkeepers`
    : `${summary.gkCount} goalkeeper(s) — need at least ${NATIONAL_SQUAD_MIN_GK}`;

  el.classList.toggle("warn", isMyNation && !summary.gkOk);
  el.innerHTML = `
    <b>Squad:</b> ${summary.total} / ${NATIONAL_SQUAD_MAX} players · ${gkLine}
    ${isMyNation ? ` · Call up more in <a href="GPDB.html" style="color:#ff9900;">GPDB</a> (My nation filter)` : ""}
  `;
}

function renderSquad(rows, isMyNation) {
  const tbody = document.getElementById("squad-body");
  const emptyEl = document.getElementById("emptySquad");
  if (!tbody) return;

  tbody.innerHTML = "";

  if (!rows.length) {
    if (emptyEl) emptyEl.hidden = false;
    return;
  }
  if (emptyEl) emptyEl.hidden = true;

  const byPosition = (pos) =>
    rows.filter((r) => {
      const p = String(r.player_position || "").trim();
      return pos.includes(p);
    });

  const used = new Set();

  for (const [groupName, positions] of Object.entries(POSITION_GROUPS)) {
    const groupPlayers = byPosition(positions).sort(
      (a, b) => (Number(b.player_rating) || 0) - (Number(a.player_rating) || 0)
    );
    if (!groupPlayers.length) continue;

    const headerRow = document.createElement("tr");
    headerRow.classList.add("squad-section-row");
    headerRow.innerHTML = `<td colspan="11" class="squad-section-title">${groupName}</td>`;
    tbody.appendChild(headerRow);

    for (const r of groupPlayers) {
      used.add(String(r.player_id));
      const rating = r.player_rating ?? "—";
      const avg =
        r.intl_avg_rating != null ? Number(r.intl_avg_rating).toFixed(2) : "—";
      const club = r.club_short_name
        ? fullClubName(r.club_short_name) || r.club_short_name
        : "Free agent";
      const releaseBtn = isMyNation
        ? `<button type="button" class="squad-release-btn" data-release="${r.player_id}">Release</button>`
        : "";

      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${playerThumbLinkHtml(r.player_id, { alt: r.player_name })}</td>
        <td>${playerNameLinkHtml(r.player_id, r.player_name || r.player_id)}</td>
        <td>${club}</td>
        <td>${r.player_position || "—"}</td>
        <td>${rating}</td>
        <td class="num">${r.intl_caps ?? 0}</td>
        <td class="num">${r.intl_goals ?? 0}</td>
        <td class="num">${r.intl_assists ?? 0}</td>
        <td class="num">${r.intl_potm ?? 0}</td>
        <td class="num">${avg}</td>
        <td>${releaseBtn}</td>
      `;
      tbody.appendChild(tr);
    }
  }

  const other = rows
    .filter((r) => !used.has(String(r.player_id)))
    .sort((a, b) => (Number(b.player_rating) || 0) - (Number(a.player_rating) || 0));

  if (other.length) {
    const headerRow = document.createElement("tr");
    headerRow.classList.add("squad-section-row");
    headerRow.innerHTML = `<td colspan="11" class="squad-section-title">Other</td>`;
    tbody.appendChild(headerRow);

    for (const r of other) {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${playerThumbLinkHtml(r.player_id, { alt: r.player_name })}</td>
        <td>${playerNameLinkHtml(r.player_id, r.player_name || r.player_id)}</td>
        <td>${fullClubName(r.club_short_name) || r.club_short_name || "—"}</td>
        <td>${r.player_position || "—"}</td>
        <td>${r.player_rating ?? "—"}</td>
        <td class="num">${r.intl_caps ?? 0}</td>
        <td class="num">${r.intl_goals ?? 0}</td>
        <td class="num">${r.intl_assists ?? 0}</td>
        <td class="num">${r.intl_potm ?? 0}</td>
        <td class="num">${r.intl_avg_rating != null ? Number(r.intl_avg_rating).toFixed(2) : "—"}</td>
        <td></td>
      `;
      tbody.appendChild(tr);
    }
  }

  if (isMyNation) {
    tbody.querySelectorAll("[data-release]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const res = await releaseCallup(btn.dataset.release, supabase);
        if (res.error) {
          alert(res.error);
          return;
        }
        location.reload();
      });
    });
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const code = getNationCode();
  const nations = await loadInternationalNations(supabase);
  const nation = nations.find((n) => n.code === code) || nations[0];
  if (!nation) {
    document.getElementById("natTitle").textContent = "National team not found";
    return;
  }

  const myNation = await loadMyNation(supabase);
  const isMyNation = myNation?.code === nation.code;

  const flagEl = document.getElementById("natFlag");
  if (flagEl) flagEl.innerHTML = renderNationFlag(nation, "lg");
  document.getElementById("natTitle").textContent = nation.name;
  let ownerTag = nation.owner_tag?.trim() || "";
  if (!ownerTag && nation.owner_club) {
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("owner")
      .eq("ShortName", nation.owner_club)
      .maybeSingle();
    ownerTag = clubRow?.owner?.trim() || nation.owner_club.trim();
  }
  document.getElementById("natMeta").innerHTML = nation.owner_club
    ? `Managed by <b>${ownerTag}</b>`
    : "Unassigned — available in nation selection";

  if (!code && nation.code) {
    history.replaceState(null, "", `?nation=${encodeURIComponent(nation.code)}`);
  }

  const squad = await loadNationalSquad(nation.code, supabase);
  const summary = summarizeNationalSquad(squad);
  renderSummary(summary, isMyNation);
  renderSquad(squad, isMyNation);
});
