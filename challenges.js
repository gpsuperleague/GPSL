import { supabase, initGlobal } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { loadClubsMap, fullClubName, clubPageHref } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";
import { renderChallengesIntro } from "./challenges_rules.js";
import { challengeStatDescription } from "./challenge_labels.js";

let standingsData = null;
let myClubShort = null;
let activeStandingsTab = "overall";
/** Big-prize race targets from packs (required_to_win), keyed by window_phase. */
let raceRequiredByPhase = { start: null, mid: null };

function windowLabel(phase) {
  if (phase === "mid") return "Mid-season";
  if (phase === "start") return "Start of season";
  return phase || "—";
}

function packDisplayName(pack) {
  return (
    pack?.pack_name ||
    (pack?.window_phase === "mid"
      ? "Mid-Season Challenge Prize"
      : "Start of Season Challenge Prize")
  );
}

function splitByPhase(items) {
  const start = [];
  const mid = [];
  for (const item of items || []) {
    if (item.window_phase === "mid") mid.push(item);
    else start.push(item);
  }
  return { start, mid };
}

/** Big prize stays claimable until the latest challenge deadline in that phase. */
function phaseWindowOpen(progressItems, phase) {
  const rows = (progressItems || []).filter((c) => c.window_phase === phase);
  if (!rows.length) return null;
  return rows.some((c) => !c.expired);
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  renderChallengesIntro();
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user.id)
    .maybeSingle();

  const clubShort = club?.ShortName || null;
  myClubShort = clubShort;
  document.title = clubShort
    ? `Season challenges — ${fullClubName(clubShort) || clubShort}`
    : "Season challenges";

  // Progress is only needed for big-prize open/closed status
  let progressItems = [];
  if (clubShort) {
    const { data } = await supabase.rpc("competition_challenge_club_progress", {
      p_club_short_name: clubShort,
    });
    progressItems = data?.challenges || [];
  }

  bindStandingsTabs();

  await Promise.all([
    loadBigPrizePacks(progressItems),
    loadStandings(),
    loadCatalog(),
  ]);
});

async function loadCurrentSeasonId() {
  const { data } = await supabase
    .from("competition_season_public")
    .select("id")
    .eq("is_current", true)
    .maybeSingle();
  return data?.id ?? null;
}

async function loadBigPrizeWinners(seasonId) {
  if (!seasonId) return new Map();
  const { data, error } = await supabase
    .from("competition_challenge_period_bonus_awarded")
    .select("window_phase, club_short_name, amount, awarded_at, pack_snapshot")
    .eq("season_id", seasonId);

  if (error) {
    console.warn("big prize winners:", error.message);
    return new Map();
  }

  const map = new Map();
  for (const row of data || []) {
    map.set(row.window_phase, row);
  }
  return map;
}

/** Prefer the Nth challenge completion time when stored on the award. */
function bigPrizeFinishedAt(winner) {
  const finish = winner?.pack_snapshot?.finished_at || winner?.pack_snapshot?.nth_completed_at;
  if (finish) return finish;
  return winner?.awarded_at || null;
}

function fallbackPackHtml(p) {
  const pack = p.pack || {};
  const med = (pack.medical_tokens || []).map((n) => `${n}-match`).join(", ") || "—";
  const disc = (pack.fee_discounts || []).map((n) => `${n}%`).join(", ") || "—";
  const appeals = pack.appeal_cards ?? 0;
  const drafts = pack.draft_tokens ?? 0;
  const credits = Number(pack.owner_credits || 0);
  return `Cash ${formatMoney(Number(p.cash_amount || 0))}` +
    (credits > 0 ? ` · Owner credits ${formatMoney(credits)}` : "") +
    ` · Medical: ${med} · Transfer discounts: ${disc} · Appeal cards: ${appeals} · Draft tokens: ${drafts}`;
}

function renderBigPrizeCard(pack, winner, windowOpen) {
  const label = packDisplayName(pack);
  const phase = pack.window_phase;
  const phaseName = windowLabel(phase).toLowerCase();
  const summary = pack.pack_summary || fallbackPackHtml(pack);
  let statusHtml;

  if (winner?.club_short_name) {
    const clubName = fullClubName(winner.club_short_name) || winner.club_short_name;
    const finishedAt = bigPrizeFinishedAt(winner);
    const when = finishedAt
      ? new Date(finishedAt).toLocaleString("en-GB", {
          day: "numeric",
          month: "short",
          year: "numeric",
          hour: "2-digit",
          minute: "2-digit",
          timeZone: "Europe/London",
        })
      : "";
    statusHtml = `<div class="prize-status-won">
      Won by <b>${clubName}</b>
      ${winner.amount != null ? ` · ${formatMoney(Number(winner.amount))}` : ""}
      ${when ? ` · completed ${when}` : ""}
      <div class="challenge-meta" style="margin-top:4px;">
        Big prize claimed — other clubs can still complete challenges for individual cash prizes.
      </div>
    </div>`;
  } else if (windowOpen === false) {
    statusHtml = `<div class="prize-status-closed">
      Not claimed — the ${phaseName} window closed with no winner.
    </div>`;
  } else {
    statusHtml = `<div class="prize-status-open">
      Still available — first club to complete ${
        pack.required_to_win && pack.active_challenges
          ? `${pack.required_to_win} of the ${pack.active_challenges}`
          : pack.required_to_win
            ? pack.required_to_win
            : "all"
      } ${phaseName} challenges wins.
      Hitting the target after a winner is declared does not award this pack.
    </div>`;
  }

  return `<div class="big-prize-card">
    <span class="window-tag ${phase === "mid" ? "mid" : "start"}">${windowLabel(phase)}</span>
    <div style="margin-top:8px;"><b>${label}</b></div>
    <div class="challenge-meta" style="margin-top:6px;">${summary}</div>
    ${statusHtml}
  </div>`;
}

async function loadBigPrizePacks(progressItems = []) {
  const el = document.getElementById("challengeBigPrize");
  if (!el) return;

  const seasonId = await loadCurrentSeasonId();
  const winners = await loadBigPrizeWinners(seasonId);

  const { data, error } = await supabase
    .from("competition_challenge_period_packs_public")
    .select("*")
    .order("window_phase");

  let packs = data;
  if (error || !packs?.length) {
    const { data: fallback, error: err2 } = await supabase
      .from("competition_challenge_period_pack")
      .select("window_phase, cash_amount, pack, pack_name")
      .order("window_phase");
    if (err2 || !fallback?.length) {
      el.innerHTML =
        "Big prize packs not loaded yet — admin must run prize-pack SQL and set packs on Season challenges.";
      return;
    }
    packs = fallback;
  }

  const ordered = ["start", "mid"].map((phase) => {
    const pack = packs.find((p) => p.window_phase === phase);
    return pack || { window_phase: phase, pack_summary: "Pack not configured yet." };
  });

  raceRequiredByPhase = { start: null, mid: null };
  for (const p of ordered) {
    const phase = p.window_phase === "mid" ? "mid" : "start";
    const req = Number(p.required_to_win);
    if (Number.isFinite(req) && req > 0) {
      raceRequiredByPhase[phase] = req;
    }
  }

  el.innerHTML = ordered
    .map((p) =>
      renderBigPrizeCard(
        p,
        winners.get(p.window_phase),
        phaseWindowOpen(progressItems, p.window_phase)
      )
    )
    .join("");

  // Packs often load with standings — refresh bars once we know the race target (e.g. 6).
  if (standingsData) renderStandings();
}

function renderChallengeCards(items) {
  return items
    .map((c) => {
      const phaseClass = c.window_phase === "mid" ? "mid" : "start";
      return `
        <div class="challenge-card">
          <span class="window-tag ${phaseClass}">${windowLabel(c.window_phase)}</span>
          <h3>${c.title}</h3>
          <p class="challenge-meta">
            ${
              c.gpsl_month_from_label
                ? `${c.gpsl_month_from_label}–${c.gpsl_month_to_label}<br>`
                : ""
            }
            ${challengeStatDescription(c.stat_type, c.target_value, c.stat_param)}
            · Prize ${formatMoney(Number(c.prize_amount || 0))}
          </p>
        </div>
      `;
    })
    .join("");
}

function renderPhaseGrids(items, startId, midId, emptyMsg) {
  const { start, mid } = splitByPhase(items);
  const startEl = document.getElementById(startId);
  const midEl = document.getElementById(midId);
  if (startEl) {
    startEl.innerHTML = start.length
      ? renderChallengeCards(start)
      : `<p class="phase-empty">${emptyMsg}</p>`;
  }
  if (midEl) {
    midEl.innerHTML = mid.length
      ? renderChallengeCards(mid)
      : `<p class="phase-empty">${emptyMsg}</p>`;
  }
}

async function loadCatalog() {
  const { data, error } = await supabase
    .from("competition_challenges_public")
    .select("*")
    .order("window_phase")
    .order("sort_order");

  if (error) {
    renderPhaseGrids(
      [],
      "catalogStart",
      "catalogMid",
      `Could not load challenge list (${error.message}).`
    );
    return;
  }

  if (!data?.length) {
    renderPhaseGrids(
      [],
      "catalogStart",
      "catalogMid",
      "No challenges configured for the current season."
    );
    return;
  }

  renderPhaseGrids(data, "catalogStart", "catalogMid", "No targets in this window.");
}

function bindStandingsTabs() {
  const tabs = document.getElementById("standingsTabs");
  if (!tabs) return;
  tabs.addEventListener("click", (e) => {
    const btn = e.target.closest(".standings-tab");
    if (!btn) return;
    activeStandingsTab = btn.dataset.tab || "overall";
    tabs.querySelectorAll(".standings-tab").forEach((t) => {
      t.classList.toggle("active", t === btn);
    });
    renderStandings();
  });
}

async function loadStandings() {
  const el = document.getElementById("challengeStandings");
  if (!el) return;

  const { data, error } = await supabase.rpc("competition_challenge_league_table", {
    p_season_id: null,
  });
  if (error) {
    el.innerHTML = `<p class="phase-empty">Could not load standings (${error.message}). Run the league-table SQL patch if this is a new function.</p>`;
    return;
  }

  standingsData = data;
  renderStandings();
}

function standingsRowsForTab(tab) {
  if (!standingsData) return { rows: [], total: 0, mode: tab };
  if (tab === "start") {
    return {
      rows: standingsData.start || [],
      total: Number(standingsData.start_total || 0),
      mode: "start",
    };
  }
  if (tab === "mid") {
    return {
      rows: standingsData.mid || [],
      total: Number(standingsData.mid_total || 0),
      mode: "mid",
    };
  }
  return {
    rows: standingsData.overall || [],
    total:
      Number(standingsData.start_total || 0) + Number(standingsData.mid_total || 0),
    mode: "overall",
  };
}

function raceRequired(phase) {
  const fromPack = raceRequiredByPhase[phase];
  if (Number.isFinite(fromPack) && fromPack > 0) return fromPack;

  if (phase === "start") {
    const n = Number(standingsData?.start_required);
    if (Number.isFinite(n) && n > 0) return n;
  }
  if (phase === "mid") {
    const n = Number(standingsData?.mid_required);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

function racePct(done, required) {
  if (!required || required <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((100 * done) / required)));
}

function rowMetrics(row, mode) {
  if (mode === "start") {
    const catalogue = Number(row.start_total || standingsData?.start_total || 0);
    const required = raceRequired("start") || catalogue;
    const done = Number(row.start_completed || 0);
    return {
      done,
      required,
      catalogue,
      pct: racePct(done, required),
      prize: Number(row.start_prize || 0),
    };
  }
  if (mode === "mid") {
    const catalogue = Number(row.mid_total || standingsData?.mid_total || 0);
    const required = raceRequired("mid") || catalogue;
    const done = Number(row.mid_completed || 0);
    return {
      done,
      required,
      catalogue,
      pct: racePct(done, required),
      prize: Number(row.mid_prize || 0),
    };
  }
  const startReq = raceRequired("start") || Number(standingsData?.start_total || 0);
  const midReq = raceRequired("mid") || Number(standingsData?.mid_total || 0);
  const required =
    Number(standingsData?.overall_required) > 0
      ? Number(standingsData.overall_required)
      : startReq + midReq;
  const done = Number(row.total_completed || 0);
  return {
    done,
    required,
    catalogue: Number(row.total_challenges || 0),
    pct: racePct(done, required),
    prize: Number(row.total_prize || 0),
  };
}

function raceDoneLabel(m) {
  const done = m.done;
  const req = m.required;
  if (!req) return String(done);
  if (done > req) return `${done} (${req} for prize)`;
  return `${done}/${req}`;
}

function renderStandings() {
  const el = document.getElementById("challengeStandings");
  if (!el) return;

  const { rows, total, mode } = standingsRowsForTab(activeStandingsTab);
  if (!total) {
    const label =
      mode === "start"
        ? "No start-of-season challenges configured."
        : mode === "mid"
          ? "No mid-season challenges configured."
          : "No challenges configured for the current season.";
    el.innerHTML = `<p class="phase-empty">${label}</p>`;
    return;
  }

  if (!rows.length) {
    el.innerHTML = `<p class="phase-empty">No clubs found for this season.</p>`;
    return;
  }

  const body = rows
    .map((row, i) => {
      const m = rowMetrics(row, mode);
      const short = row.club_short_name;
      const name = fullClubName(short) || row.club_name || short;
      const isMe = myClubShort && short === myClubShort;
      const pct = Math.max(0, Math.min(100, m.pct));
      const barClass = pct >= 100 ? "progress-bar complete" : "progress-bar";
      const href = clubPageHref(short);
      const clubCell = href
        ? `<a href="${href}">${name}</a>`
        : name;
      const raceTitle =
        m.required > 0
          ? `${m.done} completed · big prize needs ${m.required}${
              m.catalogue > m.required ? ` of ${m.catalogue} available` : ""
            }`
          : `${m.done} completed`;

      return `<tr class="${isMe ? "me" : ""}">
        <td class="pos">${i + 1}</td>
        <td class="club">${clubCell}</td>
        <td class="num" title="${raceTitle}">${raceDoneLabel(m)}</td>
        <td class="bar-cell">
          <span class="${barClass}" title="${pct}% of big-prize target"><span style="width:${pct}%"></span></span>
          <span class="pct-label">${pct}%</span>
        </td>
        <td class="num">${m.prize > 0 ? formatMoney(m.prize) : "—"}</td>
      </tr>`;
    })
    .join("");

  const startRace = raceRequired("start");
  const midRace = raceRequired("mid");
  const reqNote =
    mode === "start" && startRace
      ? `Big prize: first to ${startRace} start challenges.`
      : mode === "mid" && midRace
        ? `Big prize: first to ${midRace} mid challenges.`
        : startRace || midRace
          ? `Big prize targets: start ${startRace || "—"}, mid ${midRace || "—"}.`
          : "";

  el.innerHTML = `
    <table class="league-table">
      <thead>
        <tr>
          <th class="pos">#</th>
          <th>Club</th>
          <th class="num">Toward prize</th>
          <th>Progress</th>
          <th class="num">Prizes won</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
    ${reqNote ? `<p class="standings-note" style="margin-top:10px;">${reqNote}</p>` : ""}
  `;
}
