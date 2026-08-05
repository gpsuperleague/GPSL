import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import { normalizeSearchText } from "./search_normalize.js";
import { NXGN_DEFAULT_SOURCE_URL, nxgnSearchQueries } from "./nextgen_nxgn_2026.js";

const FETCH_FUNCTION = "nextgen-goal-fetch";

/** @type {{ entry: { rank: number, name: string, club?: string }, hit: object|null, score: number }[]} */
let matchResults = [];
let matchSourceUrl = "";

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
  return normalizeSearchText(s);
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

function mapPlayerRows(rows) {
  return (rows || []).map((r) => ({
    player_id: String(r.player_id ?? r.Konami_ID),
    player_name: r.player_name ?? r.Name,
    position: r.position ?? r.Position,
    age: r.age ?? r.Age,
    rating: r.rating ?? r.Rating,
    club: r.club ?? r.Contracted_Team,
    nation: r.nation ?? r.Nation,
  }));
}

/** Accent-tolerant GPDB search (Joao ↔ João) via name_search_key. */
async function searchGpdb(query) {
  const raw = String(query || "").trim();
  const norm = normalizeSearchText(raw);
  if (norm.length < 2 && raw.length < 2) return [];

  // Prefer accent-folded column used by GPDB
  if (norm.length >= 2) {
    const { data, error } = await supabase
      .from("Players")
      .select("Konami_ID, Name, Position, Age, Rating, Contracted_Team, Nation")
      .ilike("name_search_key", `%${norm}%`)
      .order("Rating", { ascending: false, nullsFirst: false })
      .limit(15);
    if (!error && Array.isArray(data) && data.length) {
      return mapPlayerRows(data);
    }
    // Column missing or RLS — fall through
    if (error && !String(error.message || "").includes("name_search_key")) {
      // keep trying other paths
    }
  }

  const { data, error } = await supabase.rpc("admin_gpdb_search_players_for_exclusion", {
    p_query: raw || norm,
    p_limit: 15,
  });
  if (!error && Array.isArray(data) && data.length) {
    return mapPlayerRows(data);
  }

  // Last resort: plain Name ilike + client-side accent filter
  const { data: rows, error: err2 } = await supabase
    .from("Players")
    .select("Konami_ID, Name, Position, Age, Rating, Contracted_Team, Nation")
    .ilike("Name", `%${raw || norm}%`)
    .limit(40);
  if (err2) {
    if (error) throw error;
    throw err2;
  }
  const mapped = mapPlayerRows(rows);
  if (!norm) return mapped.slice(0, 15);
  return mapped
    .filter((r) => normalizeSearchText(r.player_name).includes(norm))
    .slice(0, 15);
}

async function resolveNxgnEntry(entry) {
  const queries = nxgnSearchQueries(entry);
  let best = null;
  let bestScore = 0;

  for (const q of queries) {
    const hits = await searchGpdb(q);
    for (const hit of hits) {
      const score = scoreNameMatch(entry.name, hit.player_name);
      let adj = score;
      const clubN = normalizeName(entry.club);
      const hitClub = normalizeName(hit.club || "");
      if (
        clubN &&
        hitClub &&
        (hitClub.includes(clubN.split(" ")[0]) || clubN.includes(hitClub.split(" ")[0]))
      ) {
        adj += 5;
      }
      if (adj > bestScore) {
        bestScore = adj;
        best = hit;
      }
    }
    if (bestScore >= 80) break;
  }

  // Require a solid name match — weak last-name-only hits hide "missing" wrongly
  return { entry, hit: bestScore >= 70 ? best : null, score: bestScore };
}

function sourceUrlInput() {
  return document.getElementById("sourceUrl");
}

function syncIdsFromMatches() {
  const ids = matchResults
    .filter((r) => r.hit)
    .map((r) => String(r.hit.player_id));
  const ta = document.getElementById("playerIds");
  if (ta) {
    ta.value = ids.join("\n");
    ta.dataset.dirty = "1";
  }
  return ids;
}

function renderList(data) {
  const meta = document.getElementById("listMeta");
  const body = document.getElementById("playerBody");
  const ta = document.getElementById("playerIds");
  const players = data?.players || [];
  const boost = Math.round(Number(data?.boost_pct || 0.1) * 100);
  const url = sourceUrlInput()?.value?.trim() || NXGN_DEFAULT_SOURCE_URL;

  if (meta) {
    const when = data?.refreshed_at
      ? new Date(data.refreshed_at).toLocaleString()
      : "never";
    meta.innerHTML = `Season <b>${escapeHtml(data?.season_label || data?.season_id || "—")}</b>
      · ${players.length} player(s) · +${boost}% MV boost
      · last refresh ${escapeHtml(when)}.
      Source: <a href="${escapeHtml(url)}" target="_blank" rel="noopener" style="color:#ff9900;">Goal NXGN</a>.`;
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

function persistMatchReview() {
  try {
    if (!matchResults.length) {
      sessionStorage.removeItem("nxgn_match_review");
      return;
    }
    sessionStorage.setItem(
      "nxgn_match_review",
      JSON.stringify({ sourceUrl: matchSourceUrl, results: matchResults })
    );
  } catch {
    /* ignore quota */
  }
}

function restoreMatchReview() {
  try {
    const raw = sessionStorage.getItem("nxgn_match_review");
    if (!raw) return false;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed?.results) || !parsed.results.length) return false;
    matchResults = parsed.results;
    matchSourceUrl = String(parsed.sourceUrl || "");
    return true;
  } catch {
    return false;
  }
}

function renderMatchReport() {
  const el = document.getElementById("matchReport");
  const card = document.getElementById("matchCard");
  const summary = document.getElementById("matchSummary");
  if (!el) return;

  if (!matchResults.length) {
    el.innerHTML = "";
    if (card) card.hidden = true;
    if (summary) summary.textContent = "Fetch a Goal NXGN list to review matches here.";
    return;
  }

  if (card) card.hidden = false;

  const matched = matchResults.filter((r) => r.hit);
  const missing = matchResults.filter((r) => !r.hit);
  const sourceUrl = matchSourceUrl || sourceUrlInput()?.value || "#";

  // Unmatched first (by Goal rank), then matched
  const orderedIdx = [
    ...matchResults
      .map((r, i) => ({ r, i }))
      .filter((x) => !x.r.hit)
      .sort((a, b) => (a.r.entry.rank || 0) - (b.r.entry.rank || 0)),
    ...matchResults
      .map((r, i) => ({ r, i }))
      .filter((x) => x.r.hit)
      .sort((a, b) => (a.r.entry.rank || 0) - (b.r.entry.rank || 0)),
  ];

  if (summary) {
    summary.innerHTML = `Matched <b>${matched.length}</b> / ${matchResults.length} from
      <a href="${escapeHtml(sourceUrl)}" target="_blank" rel="noopener" style="color:#ff9900;">Goal list</a>.
      ${
        missing.length
          ? `<span class="nxgn-status-miss">${missing.length} unmatched</span> listed first — search GPDB and click <b>Use</b> to attach.`
          : `<span class="nxgn-status-ok">All matched.</span>`
      }
      This panel stays until you fetch again.`;
  }

  el.innerHTML = `
    <div class="nxgn-missing-wrap">
      <table class="gpsl-table nxgn-missing-table">
        <thead>
          <tr>
            <th style="width:8%;">Status</th>
            <th style="width:28%;">Goal name</th>
            <th>GPDB match</th>
          </tr>
        </thead>
        <tbody>
          ${orderedIdx
            .map(({ r, i: idx }) => {
              if (!r.hit) {
                const defaultQ = escapeHtml(r.entry.name || "");
                return `
              <tr class="nxgn-row-miss" data-match-idx="${idx}">
                <td><span class="nxgn-status-miss">Missing</span></td>
                <td>
                  <b>#${escapeHtml(r.entry.rank)}</b> ${escapeHtml(r.entry.name)}
                  <div class="muted">${escapeHtml(r.entry.club || "—")}</div>
                </td>
                <td>
                  <div class="nxgn-manual-row">
                    <input
                      type="search"
                      class="nxgn-manual-q"
                      data-match-idx="${idx}"
                      value="${defaultQ}"
                      placeholder="Search GPDB name…"
                      autocomplete="off"
                    />
                    <button type="button" class="button secondary nxgn-manual-search" data-match-idx="${idx}">
                      Search
                    </button>
                  </div>
                  <div class="nxgn-manual-hits muted" data-hits-for="${idx}">Type a name and Search.</div>
                </td>
              </tr>`;
              }
              const club = r.hit.club ? displayClubName(r.hit.club) || r.hit.club : "—";
              return `
              <tr class="nxgn-row-ok" data-match-idx="${idx}">
                <td><span class="nxgn-status-ok">Matched</span></td>
                <td>
                  <b>#${escapeHtml(r.entry.rank)}</b> ${escapeHtml(r.entry.name)}
                  <div class="muted">${escapeHtml(r.entry.club || "—")}</div>
                </td>
                <td>
                  <b>${escapeHtml(r.hit.player_name)}</b>
                  <span class="muted"> · ${escapeHtml(club)} · <code>${escapeHtml(r.hit.player_id)}</code></span>
                  <div class="nxgn-manual-row" style="margin-top:6px;">
                    <input
                      type="search"
                      class="nxgn-manual-q"
                      data-match-idx="${idx}"
                      value="${escapeHtml(r.entry.name || "")}"
                      placeholder="Change match…"
                      autocomplete="off"
                    />
                    <button type="button" class="button secondary nxgn-manual-search" data-match-idx="${idx}">
                      Re-search
                    </button>
                    <button type="button" class="button secondary nxgn-clear-match" data-match-idx="${idx}">
                      Clear
                    </button>
                  </div>
                  <div class="nxgn-manual-hits muted" data-hits-for="${idx}"></div>
                </td>
              </tr>`;
            })
            .join("")}
        </tbody>
      </table>
    </div>
  `;
  persistMatchReview();
}

function applyManualMatch(idx, hit) {
  const row = matchResults[idx];
  if (!row || !hit?.player_id) return;
  row.hit = {
    player_id: String(hit.player_id),
    player_name: hit.player_name,
    club: hit.club,
    position: hit.position,
    age: hit.age,
    rating: hit.rating,
    nation: hit.nation,
  };
  row.score = 100;
  const ids = syncIdsFromMatches();
  renderMatchReport();
  setStatus(
    "listStatus",
    `Attached ${hit.player_name}. ${ids.length}/${matchResults.length} IDs ready — Refresh when done.`,
    true
  );
}

function clearManualMatch(idx) {
  const row = matchResults[idx];
  if (!row) return;
  row.hit = null;
  row.score = 0;
  const ids = syncIdsFromMatches();
  renderMatchReport();
  setStatus(
    "listStatus",
    `Cleared match. ${ids.length}/${matchResults.length} IDs ready.`,
    true
  );
}

async function runManualSearch(idx) {
  const row = matchResults[idx];
  const hitsEl = document.querySelector(`[data-hits-for="${idx}"]`);
  const input = document.querySelector(`.nxgn-manual-q[data-match-idx="${idx}"]`);
  if (!row || !hitsEl) return;

  const q = (input?.value || row.entry.name || "").trim();
  if (q.length < 2) {
    hitsEl.innerHTML = `<span class="muted">Type at least 2 characters.</span>`;
    return;
  }

  hitsEl.textContent = "Searching…";
  let hits;
  try {
    hits = await searchGpdb(q);
  } catch (e) {
    hitsEl.innerHTML = `<span style="color:#e88;">${escapeHtml(e.message || String(e))}</span>`;
    return;
  }

  if (!hits.length) {
    hitsEl.innerHTML = `<span class="muted">No GPDB matches for “${escapeHtml(q)}”.</span>`;
    return;
  }

  hitsEl.innerHTML = hits
    .map((h) => {
      const club = h.club ? displayClubName(h.club) || h.club : "—";
      return `
      <div class="nxgn-hit">
        <button
          type="button"
          class="button nxgn-pick"
          data-match-idx="${idx}"
          data-player-id="${escapeHtml(h.player_id)}"
          data-player-name="${escapeHtml(h.player_name)}"
          data-club="${escapeHtml(h.club || "")}"
          data-position="${escapeHtml(h.position || "")}"
          data-age="${escapeHtml(h.age ?? "")}"
          data-rating="${escapeHtml(h.rating ?? "")}"
          data-nation="${escapeHtml(h.nation || "")}"
        >Use ${escapeHtml(h.player_name)}</button>
        <span class="muted"> · ${escapeHtml(club)} · ${escapeHtml(h.position || "—")} · age ${escapeHtml(
          h.age ?? "—"
        )} · OVR ${escapeHtml(h.rating ?? "—")} · <code>${escapeHtml(h.player_id)}</code></span>
      </div>`;
    })
    .join("");
}

function wireMatchReportEvents() {
  const el = document.getElementById("matchReport");
  if (!el || el.dataset.wired) return;
  el.dataset.wired = "1";

  el.addEventListener("click", async (e) => {
    const pick = e.target.closest(".nxgn-pick");
    if (pick) {
      const idx = Number(pick.dataset.matchIdx);
      applyManualMatch(idx, {
        player_id: pick.dataset.playerId,
        player_name: pick.dataset.playerName,
        club: pick.dataset.club,
        position: pick.dataset.position,
        age: pick.dataset.age,
        rating: pick.dataset.rating,
        nation: pick.dataset.nation,
      });
      return;
    }
    const clearBtn = e.target.closest(".nxgn-clear-match");
    if (clearBtn) {
      clearManualMatch(Number(clearBtn.dataset.matchIdx));
      return;
    }
    const searchBtn = e.target.closest(".nxgn-manual-search");
    if (searchBtn) {
      await runManualSearch(Number(searchBtn.dataset.matchIdx));
    }
  });

  el.addEventListener("keydown", async (e) => {
    if (e.key !== "Enter") return;
    const input = e.target.closest(".nxgn-manual-q");
    if (!input) return;
    e.preventDefault();
    await runManualSearch(Number(input.dataset.matchIdx));
  });
}

async function loadSettingsUrl() {
  const input = sourceUrlInput();
  if (!input) return;
  try {
    const { data, error } = await supabase.rpc("nextgen_youth_settings_get");
    if (error) throw error;
    input.value = String(data?.source_url || NXGN_DEFAULT_SOURCE_URL);
  } catch {
    input.value = NXGN_DEFAULT_SOURCE_URL;
  }
}

async function saveSourceUrl() {
  const url = sourceUrlInput()?.value?.trim() || "";
  if (!url) {
    setStatus("listStatus", "Enter a Goal.com NXGN list URL first.", false);
    return;
  }
  setStatus("listStatus", "Saving source URL…", true);
  const { data, error } = await supabase.rpc("admin_nextgen_youth_settings_set", {
    p_source_url: url,
  });
  if (error) {
    setStatus(
      "listStatus",
      error.message.includes("admin_nextgen_youth_settings_set")
        ? "Run supabase/sql/patches/nextgen_youth_source_url.sql (or the updated nextgen_youth_mv_boost.sql) first."
        : error.message,
      false
    );
    return;
  }
  if (sourceUrlInput() && data?.source_url) {
    sourceUrlInput().value = data.source_url;
  }
  setStatus("listStatus", "Source URL saved.", true);
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
  const note = sourceUrlInput()?.value?.trim() || "Goal NXGN";
  const { data, error } = await supabase.rpc("admin_nextgen_youth_refresh", {
    p_player_ids: ids,
    p_season_id: null,
    p_note: note,
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
  // Keep Goal match review (incl. unmatched) so admin can still see who was missing
  persistMatchReview();
  await reloadList();
  const stillMissing = matchResults.filter((r) => !r.hit).length;
  setStatus(
    "listStatus",
    `✅ Refreshed ${data?.season_label || "season"}: ${data?.player_count ?? 0} on list (added ${data?.added ?? 0}, removed ${data?.removed ?? 0}, recalculated ${data?.recalculated ?? 0}).${
      stillMissing ? ` ${stillMissing} Goal names still unmatched in the review panel above.` : ""
    }`,
    true
  );
}

async function invokeGoalFetch(url) {
  const { data, error } = await supabase.functions.invoke(FETCH_FUNCTION, {
    body: { url, save_url: true },
  });
  if (error) {
    let detail = error.message || "Fetch failed";
    try {
      const ctx = error.context;
      if (ctx && typeof ctx.json === "function") {
        const payload = await ctx.json();
        if (payload?.error) detail = String(payload.error);
      }
    } catch {
      /* ignore */
    }
    if (data?.error) detail = String(data.error);
    const hint = /Failed to send|FunctionsFetchError|not found/i.test(detail)
      ? ` — deploy edge function ${FETCH_FUNCTION} (see scripts/README_nextgen_goal_fetch.md)`
      : "";
    throw new Error(detail + hint);
  }
  if (data?.error) throw new Error(String(data.error));
  return data;
}

async function fetchAndMatchFromUrl() {
  const url = sourceUrlInput()?.value?.trim() || "";
  if (!url) {
    setStatus("listStatus", "Enter a Goal.com NXGN list URL first.", false);
    return;
  }

  setStatus("listStatus", "Fetching Goal NXGN list…", true);
  const report = document.getElementById("matchReport");
  if (report) report.innerHTML = `<p class="muted">Fetching article…</p>`;

  let fetched;
  try {
    fetched = await invokeGoalFetch(url);
  } catch (e) {
    if (report) report.innerHTML = "";
    setStatus("listStatus", e.message || String(e), false);
    return;
  }

  const players = Array.isArray(fetched?.players) ? fetched.players : [];
  const sourceUrl = fetched?.source_url || url;
  if (sourceUrlInput()) sourceUrlInput().value = sourceUrl;
  matchSourceUrl = sourceUrl;

  if (!players.length) {
    matchResults = [];
    renderMatchReport();
    setStatus("listStatus", "No players parsed from that URL.", false);
    return;
  }

  setStatus("listStatus", `Parsed ${players.length} names — matching in GPDB…`, true);
  if (report) report.innerHTML = `<p class="muted">Matching ${players.length} names…</p>`;

  const results = [];
  for (const entry of players) {
    try {
      results.push(await resolveNxgnEntry(entry));
    } catch (e) {
      results.push({ entry, hit: null, score: 0, error: e.message });
    }
  }

  matchResults = results;
  syncIdsFromMatches();
  renderMatchReport();

  const ids = matchResults.filter((r) => r.hit);
  setStatus(
    "listStatus",
    `Loaded ${ids.length}/${matchResults.length} Konami IDs. Unmatched (Missing) rows are listed first in the review table — search and attach, then Refresh.`,
    ids.length > 0
  );
}

document.addEventListener("DOMContentLoaded", async () => {
  await initAdminPage();
  await loadClubsMap();
  await loadSettingsUrl();
  wireMatchReportEvents();

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
  document.getElementById("saveUrlBtn")?.addEventListener("click", () => saveSourceUrl());
  document.getElementById("fetchNxgnBtn")?.addEventListener("click", () => fetchAndMatchFromUrl());

  try {
    if (restoreMatchReview()) {
      syncIdsFromMatches();
      renderMatchReport();
    }
    await reloadList();
  } catch (e) {
    setStatus("listStatus", e.message || String(e), false);
  }
});
