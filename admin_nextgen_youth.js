import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import {
  NXGN_2026_PLAYERS,
  NXGN_2026_SOURCE_URL,
  nxgn2026SearchQueries,
} from "./nextgen_nxgn_2026.js";

primeAdminPageChrome();

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function parsePlayerIds(raw) {
  return [
    ...new Set(
      String(raw || "")
        .split(/[\s,;]+/)
        .map((s) => s.trim())
        .filter(Boolean)
    ),
  ];
}

function normalizeName(s) {
  return String(s || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function scoreNameMatch(query, playerName) {
  const q = normalizeName(query);
  const n = normalizeName(playerName);
  if (!q || !n) return 0;
  if (n === q) return 100;
  if (n.includes(q) || q.includes(n)) return 80;
  const qParts = q.split(" ");
  const nParts = n.split(" ");
  const overlap = qParts.filter((p) => nParts.includes(p)).length;
  if (overlap >= 2) return 70;
  if (overlap === 1 && qParts.length === 1) return 50;
  return 0;
}

async function searchGpdb(query) {
  const { data, error } = await supabase.rpc("admin_gpdb_search_players_for_exclusion", {
    p_query: query,
    p_limit: 15,
  });
  if (error) {
    // Fallback: direct Players name search
    const { data: rows, error: err2 } = await supabase
      .from("Players")
      .select('Konami_ID, Name, Position, Age, Rating, Contracted_Team, Nation')
      .ilike("Name", `%${query}%`)
      .limit(15);
    if (err2) throw error;
    return (rows || []).map((r) => ({
      player_id: String(r.Konami_ID),
      player_name: r.Name,
      position: r.Position,
      age: r.Age,
      rating: r.Rating,
      club: r.Contracted_Team,
      nation: r.Nation,
    }));
  }
  return Array.isArray(data) ? data : [];
}

async function resolveNxgnEntry(entry) {
  const queries = nxgn2026SearchQueries(entry);
  let best = null;
  let bestScore = 0;

  for (const q of queries) {
    const hits = await searchGpdb(q);
    for (const hit of hits) {
      const score = scoreNameMatch(entry.name, hit.player_name);
      // Prefer exact-ish name; slight bump if club text overlaps
      let adj = score;
      const clubN = normalizeName(entry.club);
      const hitClub = normalizeName(hit.club || "");
      if (clubN && hitClub && (hitClub.includes(clubN.split(" ")[0]) || clubN.includes(hitClub.split(" ")[0]))) {
        adj += 5;
      }
      if (adj > bestScore) {
        bestScore = adj;
        best = hit;
      }
    }
    if (bestScore >= 80) break;
  }

  return { entry, hit: bestScore >= 50 ? best : null, score: bestScore };
}

function renderList(data) {
  const meta = document.getElementById("listMeta");
  const body = document.getElementById("playerBody");
  const ta = document.getElementById("playerIds");
  const players = data?.players || [];
  const boost = Math.round(Number(data?.boost_pct || 0.1) * 100);

  if (meta) {
    const when = data?.refreshed_at
      ? new Date(data.refreshed_at).toLocaleString()
      : "never";
    meta.innerHTML = `Season <b>${escapeHtml(data?.season_label || data?.season_id || "—")}</b>
      · ${players.length} player(s) · +${boost}% MV boost
      · last refresh ${escapeHtml(when)}.
      Source list: <a href="${NXGN_2026_SOURCE_URL}" target="_blank" rel="noopener" style="color:#ff9900;">Goal NXGN 2026</a> (${NXGN_2026_PLAYERS.length} names).`;
  }

  if (ta && !ta.dataset.dirty) {
    ta.value = players.map((p) => p.player_id).join("\n");
  }

  if (!body) return;
  if (!players.length) {
    body.innerHTML = `<tr><td colspan="7" class="muted">No players on the current-season Next Gen list.</td></tr>`;
    return;
  }

  body.innerHTML = players
    .map((p) => {
      const club = p.club ? displayClubName(p.club) || p.club : "—";
      return `
      <tr>
        <td><b>${escapeHtml(p.player_name || p.player_id)}</b></td>
        <td>${escapeHtml(club)}</td>
        <td>${escapeHtml(p.position || "—")}</td>
        <td>${escapeHtml(p.age ?? "—")}</td>
        <td>${escapeHtml(p.rating ?? "—")}</td>
        <td>${formatMoney(Number(p.market_value || 0))}</td>
        <td><code>${escapeHtml(p.player_id)}</code></td>
      </tr>`;
    })
    .join("");
}

function renderMatchReport(results) {
  const el = document.getElementById("matchReport");
  if (!el) return;
  const matched = results.filter((r) => r.hit);
  const missing = results.filter((r) => !r.hit);
  el.innerHTML = `
    <p class="note" style="margin:0 0 8px;">
      Matched <b>${matched.length}</b> / ${results.length} NXGN names in GPDB.
      ${missing.length ? `<span style="color:#e88;">Missing ${missing.length}.</span>` : "All found."}
    </p>
    ${
      missing.length
        ? `<ul class="muted" style="margin:0;padding-left:18px;">${missing
            .map(
              (r) =>
                `<li>#${r.entry.rank} ${escapeHtml(r.entry.name)} (${escapeHtml(r.entry.club)})</li>`
            )
            .join("")}</ul>`
        : ""
    }
  `;
}

async function reloadList() {
  setStatus("listStatus", "Loading…", true);
  const { data, error } = await supabase.rpc("nextgen_youth_list", {
    p_season_id: null,
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("nextgen_youth_list")
        ? "Run supabase/sql/patches/nextgen_youth_mv_boost.sql first."
        : error.message,
      false
    );
    return;
  }
  const ta = document.getElementById("playerIds");
  if (ta) delete ta.dataset.dirty;
  renderList(data);
  setStatus(
    "listStatus",
    `${(data?.players || []).length} player(s) on current season list.`,
    true
  );
}

async function refreshList(ids) {
  if (
    !confirm(
      `Replace the current-season Next Gen list with ${ids.length} player(s)?\n\nMarket values will recalc for anyone who enters or leaves (+10% on / off).`
    )
  ) {
    return;
  }

  setStatus("listStatus", "Refreshing list and recalculating market values…");
  const { data, error } = await supabase.rpc("admin_nextgen_youth_refresh", {
    p_player_ids: ids,
    p_season_id: null,
    p_note: "Goal NXGN 2026",
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("admin_nextgen_youth_refresh")
        ? "Run supabase/sql/patches/nextgen_youth_mv_boost.sql first."
        : error.message,
      false
    );
    return;
  }

  const ta = document.getElementById("playerIds");
  if (ta) delete ta.dataset.dirty;
  await reloadList();
  setStatus(
    "listStatus",
    `✅ Refreshed ${data?.season_label || "season"}: ${data?.player_count ?? 0} on list (added ${data?.added ?? 0}, removed ${data?.removed ?? 0}, recalculated ${data?.recalculated ?? 0}).`,
    true
  );
}

async function loadNxgn2026IntoForm() {
  setStatus("listStatus", `Matching ${NXGN_2026_PLAYERS.length} NXGN 2026 names in GPDB…`, true);
  const report = document.getElementById("matchReport");
  if (report) report.innerHTML = `<p class="muted">Searching…</p>`;

  const results = [];
  // Sequential to avoid hammering PostgREST; still fine for 50
  for (const entry of NXGN_2026_PLAYERS) {
    try {
      results.push(await resolveNxgnEntry(entry));
    } catch (e) {
      results.push({ entry, hit: null, score: 0, error: e.message });
    }
  }

  renderMatchReport(results);

  const ids = results.filter((r) => r.hit).map((r) => String(r.hit.player_id));
  const ta = document.getElementById("playerIds");
  if (ta) {
    ta.value = ids.join("\n");
    ta.dataset.dirty = "1";
  }

  setStatus(
    "listStatus",
    `Loaded ${ids.length}/${NXGN_2026_PLAYERS.length} Konami IDs from Goal NXGN 2026. Review the list, then click Refresh Next Gen list.`,
    ids.length > 0
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  await loadClubsMap();

  document.getElementById("playerIds")?.addEventListener("input", (e) => {
    e.target.dataset.dirty = "1";
  });
  document.getElementById("reloadBtn")?.addEventListener("click", () => reloadList());
  document.getElementById("refreshBtn")?.addEventListener("click", () => {
    const ids = parsePlayerIds(document.getElementById("playerIds")?.value);
    refreshList(ids);
  });
  document.getElementById("clearBtn")?.addEventListener("click", () => {
    const ta = document.getElementById("playerIds");
    if (ta) {
      ta.value = "";
      ta.dataset.dirty = "1";
    }
    refreshList([]);
  });
  document.getElementById("loadNxgnBtn")?.addEventListener("click", () => loadNxgn2026IntoForm());

  try {
    await reloadList();
  } catch (e) {
    setStatus("listStatus", e.message || String(e), false);
  }
});
