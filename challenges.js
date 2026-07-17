import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import { formatMoney } from "./competition.js";

const STAT_LABELS = {
  player_max_goals: "Player max goals",
  player_max_assists: "Player max assists",
  club_wins: "League/cup wins",
  club_goals_for: "Goals scored",
  club_clean_sheets: "Clean sheets",
  club_potm_awards: "POTM awards",
  transfer_sign_nation: "Sign by nationality",
};

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

document.addEventListener("DOMContentLoaded", async () => {
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

  await Promise.all([
    loadBigPrizePacks(progressItems),
    loadCatalog(),
  ]);
});

/** Big prize stays claimable until the latest challenge deadline in that phase. */
function phaseWindowOpen(progressItems, phase) {
  const rows = (progressItems || []).filter((c) => c.window_phase === phase);
  if (!rows.length) return null;
  return rows.some((c) => !c.expired);
}

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
    .select("window_phase, club_short_name, amount, awarded_at")
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

function fallbackPackHtml(p) {
  const pack = p.pack || {};
  const med = (pack.medical_tokens || []).map((n) => `${n}-match`).join(", ") || "—";
  const disc = (pack.fee_discounts || []).map((n) => `${n}%`).join(", ") || "—";
  const appeals = pack.appeal_cards ?? 0;
  const drafts = pack.draft_tokens ?? 0;
  return `Cash ${formatMoney(Number(p.cash_amount || 0))} · Medical: ${med} ·
    Transfer discounts: ${disc} · Appeal cards: ${appeals} · Draft tokens: ${drafts}`;
}

function renderBigPrizeCard(pack, winner, windowOpen) {
  const label = packDisplayName(pack);
  const phase = pack.window_phase;
  const phaseName = windowLabel(phase).toLowerCase();
  const summary = pack.pack_summary || fallbackPackHtml(pack);
  let statusHtml;

  if (winner?.club_short_name) {
    const clubName = fullClubName(winner.club_short_name) || winner.club_short_name;
    const when = winner.awarded_at
      ? new Date(winner.awarded_at).toLocaleDateString("en-GB")
      : "";
    statusHtml = `<div class="prize-status-won">
      Won by <b>${clubName}</b>
      ${winner.amount != null ? ` · ${formatMoney(Number(winner.amount))}` : ""}
      ${when ? ` · ${when}` : ""}
    </div>`;
  } else if (windowOpen === false) {
    statusHtml = `<div class="prize-status-closed">
      Not claimed — the ${phaseName} window closed with no winner.
    </div>`;
  } else {
    statusHtml = `<div class="prize-status-open">
      Still available — first club to complete all ${phaseName} challenges wins.
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

  el.innerHTML = ordered
    .map((p) =>
      renderBigPrizeCard(
        p,
        winners.get(p.window_phase),
        phaseWindowOpen(progressItems, p.window_phase)
      )
    )
    .join("");
}

function phaseWindowOpen(progressItems, phase) {
  const rows = (progressItems || []).filter((c) => c.window_phase === phase);
  if (!rows.length) return null;
  return rows.some((c) => !c.expired);
}

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
    .select("window_phase, club_short_name, amount, awarded_at")
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

function fallbackPackHtml(p) {
  const pack = p.pack || {};
  const med = (pack.medical_tokens || []).map((n) => `${n}-match`).join(", ") || "—";
  const disc = (pack.fee_discounts || []).map((n) => `${n}%`).join(", ") || "—";
  const appeals = pack.appeal_cards ?? 0;
  const drafts = pack.draft_tokens ?? 0;
  return `Cash ${formatMoney(Number(p.cash_amount || 0))} · Medical: ${med} ·
    Transfer discounts: ${disc} · Appeal cards: ${appeals} · Draft tokens: ${drafts}`;
}

function packDisplayName(pack) {
  return (
    pack?.pack_name ||
    (pack?.window_phase === "mid"
      ? "Mid-Season Challenge Prize"
      : "Start of Season Challenge Prize")
  );
}

function windowLabel(phase) {
  if (phase === "mid") return "Mid-season";
  if (phase === "start") return "Start of season";
  return phase || "—";
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
            ${STAT_LABELS[c.stat_type] || c.stat_type}${
              c.stat_param ? ` (${c.stat_param})` : ""
            } ≥ <b>${c.target_value}</b>
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
