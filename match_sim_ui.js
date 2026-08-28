/**
 * Match result simulation — Instant result + Simulate match (20s momentum).
 */
import { supabase } from "./global.js";

function ensureMatchSimStyles() {
  let style = document.getElementById("matchSimStyles");
  if (!style) {
    style = document.createElement("style");
    style.id = "matchSimStyles";
    document.head.appendChild(style);
  }
  style.textContent = MATCH_SIM_BANNER_STYLE;
}

/**
 * @returns {Promise<{ enabled: boolean, isAdmin: boolean, isStaff: boolean, error: string|null }>}
 */
export async function loadMatchSimStatus() {
  ensureMatchSimStyles();
  const [{ data, error }, staffRes] = await Promise.all([
    supabase.rpc("match_result_simulation_status"),
    supabase.rpc("is_gpsl_admin_or_mod"),
  ]);
  if (error) {
    console.warn("match_result_simulation_status:", error);
    return {
      enabled: false,
      isAdmin: false,
      isStaff: false,
      error: error.message || "Simulation status unavailable (run match_result_simulation.sql)",
    };
  }
  const row = data && typeof data === "object" ? data : {};
  const isAdmin = row.is_admin === true;
  const isStaff =
    isAdmin ||
    staffRes.data === true ||
    (staffRes.error ? false : Boolean(staffRes.data));
  return {
    enabled: row.enabled === true || row.match_result_simulation_enabled === true,
    isAdmin,
    isStaff,
    error: null,
  };
}

export async function setMatchSimEnabled(enabled) {
  const { data, error } = await supabase.rpc("admin_set_match_result_simulation_enabled", {
    p_enabled: !!enabled,
  });
  if (error) throw error;
  return data?.match_result_simulation_enabled === true;
}

/**
 * @param {{ enabled: boolean, isAdmin?: boolean, error?: string|null }} status
 */
export function matchSimBannerHtml(status) {
  if (status?.error) {
    return `<p class="match-sim-banner match-sim-banner--err" id="matchSimBanner">${escapeHtml(status.error)}</p>`;
  }
  if (!status?.enabled && !status?.isAdmin) return "";

  const state = status.enabled
    ? `<span class="match-sim-on">ON</span> — Instant result &amp; Simulate match on your fixtures.`
    : `<span class="match-sim-off">OFF</span> — owners cannot simulate results.`;

  const toggle = status.isAdmin
    ? `<button type="button" class="btn-link match-sim-toggle" id="matchSimToggleBtn" data-next="${
        status.enabled ? "0" : "1"
      }">${status.enabled ? "Turn OFF" : "Turn ON"}</button>`
    : "";

  return `<p class="match-sim-banner" id="matchSimBanner">Match simulation ${state} ${toggle}</p>`;
}

export function wireMatchSimBannerToggle(onChanged) {
  const btn = document.getElementById("matchSimToggleBtn");
  if (!btn) return;
  btn.addEventListener("click", async () => {
    const next = btn.getAttribute("data-next") === "1";
    const label = next ? "Enable match simulation for all owners?" : "Disable match simulation?";
    if (!confirm(label)) return;
    btn.disabled = true;
    try {
      await setMatchSimEnabled(next);
      if (typeof onChanged === "function") await onChanged(next);
    } catch (err) {
      alert(err?.message || String(err));
      btn.disabled = false;
    }
  });
}

/** @deprecated use matchSimActionsHtml */
export function matchSimButtonHtml(fixtureId, opts) {
  return matchSimActionsHtml(fixtureId, opts);
}

/**
 * @param {string|number} fixtureId
 * @param {{ disabled?: boolean, title?: string }} [opts]
 */
export function matchSimActionsHtml(fixtureId, opts = {}) {
  const id = escapeHtml(String(fixtureId));
  const disabled = opts.disabled === true;
  const title = opts.title
    ? ` title="${escapeHtml(opts.title)}"`
    : disabled
      ? ` title="Available when this fixture’s GPSL month is active"`
      : "";
  const disAttr = disabled ? " disabled" : "";
  return `<span class="sim-actions">
    <button type="button" class="btn-link sim-result-btn sim-instant-btn"${disAttr}${title} data-sim-fixture="${id}" data-sim-mode="instant">Instant result</button>
    <button type="button" class="btn-link sim-result-btn sim-play-btn"${disAttr}${title} data-sim-fixture="${id}" data-sim-mode="play">Simulate match</button>
  </span>`;
}

/**
 * @param {(fixtureId: string, btn: HTMLButtonElement, mode: 'instant'|'play') => void} handler
 */
export function wireMatchSimButtons(root, handler) {
  root?.querySelectorAll("[data-sim-fixture]").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (btn.disabled) return;
      const id = btn.getAttribute("data-sim-fixture");
      if (!id) return;
      const mode = btn.getAttribute("data-sim-mode") === "play" ? "play" : "instant";
      handler(id, btn, mode);
    });
  });
}

/**
 * @param {string|number} fixtureId
 * @param {HTMLButtonElement|null} btn
 * @param {'instant'|'play'} [mode]
 * @param {{ homeName?: string, awayName?: string }} [meta]
 */
export async function runMatchSimulation(fixtureId, btn, mode = "instant", meta = {}) {
  const play = mode === "play";
  const group = btn?.closest?.(".sim-actions");
  const buttons = group
    ? [...group.querySelectorAll("button")]
    : btn
      ? [btn]
      : [];

  buttons.forEach((b) => {
    b.disabled = true;
    b.classList.add("sim-busy");
    if (b === btn) b.textContent = play ? "Simulating…" : "Result…";
  });

  const rpcName = meta.rpc || "competition_simulate_fixture_result";
  const { data, error } = await supabase.rpc(rpcName, {
    p_fixture_id: Number(fixtureId),
  });

  if (error) {
    buttons.forEach((b) => {
      b.disabled = false;
      b.classList.remove("sim-busy");
      if (b.classList.contains("sim-play-btn")) b.textContent = "Simulate match";
      else if (b.classList.contains("sim-instant-btn")) b.textContent = "Instant result";
      else b.textContent = "Simulate";
    });
    const detail = [error.message, error.details, error.hint].filter(Boolean).join(" — ");
    const err = new Error(detail || "Simulation failed");
    err.code = error.code;
    throw err;
  }

  const score =
    data?.home_goals != null && data?.away_goals != null
      ? `${data.home_goals}–${data.away_goals}`
      : "";

  if (play) {
    await playMatchMomentum(data, {
      homeName: meta.homeName || data?.home_name || data?.home_club,
      awayName: meta.awayName || data?.away_name || data?.away_club,
    });
  }

  buttons.forEach((b) => {
    b.textContent = score ? `Done ${score}` : "Done";
  });

  return data;
}

function ensureOverlay() {
  let el = document.getElementById("matchSimOverlay");
  if (!el) {
    el = document.createElement("div");
    el.id = "matchSimOverlay";
    el.className = "msim-overlay";
    el.hidden = true;
    el.innerHTML = `
      <div class="msim-modal" role="dialog" aria-modal="true" aria-label="Match simulation">
        <div class="msim-burst" id="msimBurst" hidden>
          <div class="msim-burst-card" id="msimBurstCard">
            <div class="msim-burst-art" id="msimBurstArt" aria-hidden="true"></div>
            <div class="msim-burst-title" id="msimBurstTitle"></div>
            <div class="msim-burst-player" id="msimBurstPlayer"></div>
            <div class="msim-burst-meta" id="msimBurstMeta"></div>
          </div>
        </div>
        <div class="msim-head">
          <div class="msim-teams">
            <span class="msim-home-name" id="msimHomeName">Home</span>
            <span class="msim-score" id="msimScore">0 – 0</span>
            <span class="msim-away-name" id="msimAwayName">Away</span>
          </div>
          <div class="msim-clock" id="msimClock">0'</div>
          <div class="msim-phase" id="msimPhase">1st half</div>
        </div>
        <div class="msim-ht" id="msimHt" hidden>
          <div class="msim-ht-label">HALF TIME</div>
          <div class="msim-ht-score" id="msimHtScore">0 – 0</div>
        </div>
        <div class="msim-pitch">
          <div class="msim-bar" id="msimBar">
            <div class="msim-goal-mouth msim-goal-mouth--home" aria-hidden="true"></div>
            <div class="msim-home-zone" id="msimHomeZone"></div>
            <div class="msim-away-zone" id="msimAwayZone"></div>
            <div class="msim-goal-mouth msim-goal-mouth--away" aria-hidden="true"></div>
          </div>
        </div>
        <div class="msim-stats" id="msimStats" aria-label="Match statistics">
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="poss">50%</span>
            <span class="msim-stat-label">Possession</span>
            <span class="msim-stat-a" data-stat="poss">50%</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="shots">0</span>
            <span class="msim-stat-label">Shots</span>
            <span class="msim-stat-a" data-stat="shots">0</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="sot">0</span>
            <span class="msim-stat-label">On target</span>
            <span class="msim-stat-a" data-stat="sot">0</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="xg">0.00</span>
            <span class="msim-stat-label">xG</span>
            <span class="msim-stat-a" data-stat="xg">0.00</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="tackles">0</span>
            <span class="msim-stat-label">Tackles</span>
            <span class="msim-stat-a" data-stat="tackles">0</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="saves">0</span>
            <span class="msim-stat-label">Saves</span>
            <span class="msim-stat-a" data-stat="saves">0</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="cards">0</span>
            <span class="msim-stat-label">Cards</span>
            <span class="msim-stat-a" data-stat="cards">0</span>
          </div>
          <div class="msim-stat-row">
            <span class="msim-stat-h" data-stat="fouls">0</span>
            <span class="msim-stat-label">Fouls</span>
            <span class="msim-stat-a" data-stat="fouls">0</span>
          </div>
        </div>
        <div class="msim-feed" id="msimFeed">
          <div class="msim-feed-col msim-feed-home" id="msimFeedHome"></div>
          <div class="msim-feed-col msim-feed-away" id="msimFeedAway"></div>
          <div class="msim-feed-center" id="msimFeedCenter"></div>
        </div>
        <div class="msim-foot">
          <button type="button" class="btn-link msim-skip" id="msimSkip">Skip to result</button>
        </div>
      </div>
    `;
    document.body.appendChild(el);
  }

  // Upgrade older overlay markup (arrow → colour pressure + burst above scoreboard)
  const bar = el.querySelector("#msimBar");
  el.querySelector("#msimArrow")?.remove();
  if (bar && !bar.querySelector(".msim-goal-mouth--home")) {
    bar.insertAdjacentHTML(
      "afterbegin",
      `<div class="msim-goal-mouth msim-goal-mouth--home" aria-hidden="true"></div>`
    );
    bar.insertAdjacentHTML(
      "beforeend",
      `<div class="msim-goal-mouth msim-goal-mouth--away" aria-hidden="true"></div>`
    );
  }
  const modal = el.querySelector(".msim-modal");
  const head = el.querySelector(".msim-head");
  let burst = el.querySelector("#msimBurst");
  if (!burst) {
    head?.insertAdjacentHTML(
      "beforebegin",
      `<div class="msim-burst" id="msimBurst" hidden>
        <div class="msim-burst-card" id="msimBurstCard">
          <div class="msim-burst-art" id="msimBurstArt" aria-hidden="true"></div>
          <div class="msim-burst-title" id="msimBurstTitle"></div>
          <div class="msim-burst-player" id="msimBurstPlayer"></div>
          <div class="msim-burst-meta" id="msimBurstMeta"></div>
        </div>
      </div>`
    );
    burst = el.querySelector("#msimBurst");
  } else if (head && burst.nextElementSibling !== head) {
    // Move burst above the scoreboard if it was inlined elsewhere
    modal?.insertBefore(burst, head);
  }
  if (!el.querySelector("#msimStats")) {
    const pitch = el.querySelector(".msim-pitch");
    pitch?.insertAdjacentHTML(
      "afterend",
      `<div class="msim-stats" id="msimStats" aria-label="Match statistics">
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="poss">50%</span><span class="msim-stat-label">Possession</span><span class="msim-stat-a" data-stat="poss">50%</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="shots">0</span><span class="msim-stat-label">Shots</span><span class="msim-stat-a" data-stat="shots">0</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="sot">0</span><span class="msim-stat-label">On target</span><span class="msim-stat-a" data-stat="sot">0</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="xg">0.00</span><span class="msim-stat-label">xG</span><span class="msim-stat-a" data-stat="xg">0.00</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="tackles">0</span><span class="msim-stat-label">Tackles</span><span class="msim-stat-a" data-stat="tackles">0</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="saves">0</span><span class="msim-stat-label">Saves</span><span class="msim-stat-a" data-stat="saves">0</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="cards">0</span><span class="msim-stat-label">Cards</span><span class="msim-stat-a" data-stat="cards">0</span></div>
        <div class="msim-stat-row"><span class="msim-stat-h" data-stat="fouls">0</span><span class="msim-stat-label">Fouls</span><span class="msim-stat-a" data-stat="fouls">0</span></div>
      </div>`
    );
  }
  return el;
}

const BURST_ART = {
  goal: `<svg class="msim-art-goal" viewBox="0 0 120 72" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <rect x="8" y="10" width="72" height="52" fill="none" stroke="#c8d0d8" stroke-width="3"/>
    <path d="M8 10 H80 M8 62 H80 M8 10 V62" fill="none" stroke="#c8d0d8" stroke-width="3"/>
    <path d="M20 18 V54 M32 18 V54 M44 18 V54 M56 18 V54 M68 18 V54" stroke="#6a7888" stroke-width="1.2" opacity=".7"/>
    <path d="M12 22 H76 M12 34 H76 M12 46 H76" stroke="#6a7888" stroke-width="1.2" opacity=".7"/>
    <circle class="msim-art-ball" cx="28" cy="36" r="9" fill="#f4f4f4" stroke="#222" stroke-width="1.5"/>
    <path d="M28 27 L31 33 L38 33 L32 38 L34 45 L28 41 L22 45 L24 38 L18 33 L25 33 Z" fill="none" stroke="#222" stroke-width="1"/>
  </svg>`,
  yellow: `<div class="msim-art-card msim-art-card--yellow" aria-hidden="true"></div>`,
  red: `<div class="msim-art-card msim-art-card--red" aria-hidden="true"></div>`,
  injury: `<svg class="msim-art-injury" viewBox="0 0 72 72" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <circle cx="36" cy="36" r="30" fill="#3a1f28" stroke="#e8a0a8" stroke-width="2"/>
    <rect x="32" y="16" width="8" height="40" rx="2" fill="#f2f2f2"/>
    <rect x="16" y="32" width="40" height="8" rx="2" fill="#f2f2f2"/>
  </svg>`,
};

function burstPlayerLabel(ev) {
  const raw = String(ev?.player || "").trim();
  if (!raw) return "Unknown";
  if (ev?.type === "injury") {
    const cut = raw.indexOf(" - ");
    return cut > 0 ? raw.slice(0, cut) : raw;
  }
  return raw;
}

function burstInjuryDetail(ev) {
  const raw = String(ev?.player || "");
  const cut = raw.indexOf(" - ");
  return cut > 0 ? raw.slice(cut + 3).trim() : "";
}

async function loadSeasonGoalTotals(playbackEvents) {
  const ids = [
    ...new Set(
      (playbackEvents || [])
        .filter((e) => e?.type === "goal" && e.player_id)
        .map((e) => String(e.player_id))
    ),
  ];
  if (!ids.length) return {};
  try {
    const { data, error } = await supabase
      .from("competition_player_season_stats_public")
      .select("player_id, goals")
      .in("player_id", ids);
    if (error || !data) return {};
    const map = {};
    for (const row of data) {
      const id = String(row.player_id);
      map[id] = (map[id] || 0) + Number(row.goals || 0);
    }
    return map;
  } catch {
    return {};
  }
}

/**
 * @param {object} data RPC result
 * @param {{ homeName?: string, awayName?: string }} labels
 */
export function playMatchMomentum(data, labels = {}) {
  return new Promise((resolve) => {
    void (async () => {
    ensureMatchSimStyles();
    const overlay = ensureOverlay();
    const feed = overlay.querySelector("#msimFeed");
    const scoreEl = overlay.querySelector("#msimScore");
    const clockEl = overlay.querySelector("#msimClock");
    const phaseEl = overlay.querySelector("#msimPhase");
    const htEl = overlay.querySelector("#msimHt");
    const bar = overlay.querySelector("#msimBar");
    const homeZone = overlay.querySelector("#msimHomeZone");
    const awayZone = overlay.querySelector("#msimAwayZone");
    const skipBtn = overlay.querySelector("#msimSkip");
    const burstEl = overlay.querySelector("#msimBurst");
    const burstCard = overlay.querySelector("#msimBurstCard");
    const burstArt = overlay.querySelector("#msimBurstArt");
    const burstTitle = overlay.querySelector("#msimBurstTitle");
    const burstPlayer = overlay.querySelector("#msimBurstPlayer");
    const burstMeta = overlay.querySelector("#msimBurstMeta");
    const statsEl = overlay.querySelector("#msimStats");

    // Ensure HT / phase nodes exist on older overlay markup
    if (!phaseEl) {
      const clock = overlay.querySelector("#msimClock");
      const phase = document.createElement("div");
      phase.className = "msim-phase";
      phase.id = "msimPhase";
      clock?.after(phase);
    }
    if (!htEl) {
      const pitch = overlay.querySelector(".msim-pitch");
      const ht = document.createElement("div");
      ht.className = "msim-ht";
      ht.id = "msimHt";
      ht.hidden = true;
      ht.innerHTML = `<div class="msim-ht-label">HALF TIME</div><div class="msim-ht-score" id="msimHtScore">0 – 0</div>`;
      pitch?.before(ht);
    }
    const phaseNode = overlay.querySelector("#msimPhase");
    const htNode = overlay.querySelector("#msimHt");
    const htScoreNode = overlay.querySelector("#msimHtScore");

    const homeColor = data?.colours?.home?.primary || "#3b82f6";
    const awayColor = data?.colours?.away?.primary || "#ef4444";
    homeZone.style.background = `linear-gradient(90deg, ${homeColor}, ${homeColor}cc)`;
    awayZone.style.background = `linear-gradient(90deg, ${awayColor}cc, ${awayColor})`;
    homeZone.style.boxShadow = `inset -10px 0 14px -8px ${homeColor}`;
    awayZone.style.boxShadow = `inset 10px 0 14px -8px ${awayColor}`;

    overlay.querySelector("#msimHomeName").textContent =
      labels.homeName || data?.home_name || data?.home_club || "Home";
    overlay.querySelector("#msimAwayName").textContent =
      labels.awayName || data?.away_name || data?.away_club || "Away";

    const playback = data?.playback || {};
    // Total graphic length: play both halves + HT pause
    const htPauseSec = 3;
    const playBudgetSec = Math.max(10, Number(playback.duration_sec) || 20);
    const totalSec = playBudgetSec + htPauseSec;

    const add1 = 1 + Math.floor(Math.random() * 5); // 1–5
    const add2 = 1 + Math.floor(Math.random() * 5);
    const fhMins = 45 + add1;
    const shMins = 45 + add2;
    const matchMins = fhMins + shMins;
    const fhPlaySec = playBudgetSec * (fhMins / matchMins);
    const shPlaySec = playBudgetSec - fhPlaySec;
    const fhEndSec = fhPlaySec;
    const htEndSec = fhEndSec + htPauseSec;
    const ftSec = htEndSec + shPlaySec;

    const rawEvents = Array.isArray(playback.events) ? [...playback.events] : [];
    const seasonGoalTotals = await loadSeasonGoalTotals(rawEvents);
    const matchGoalsByPlayer = {};
    for (const e of rawEvents) {
      if (e?.type === "goal" && e.player_id) {
        const id = String(e.player_id);
        matchGoalsByPlayer[id] = (matchGoalsByPlayer[id] || 0) + 1;
      }
    }
    const shownGoalsByPlayer = {};

    // Remap events onto half-aware timeline by match minute
    const events = rawEvents
      .filter((e) => e && e.type !== "kickoff")
      .map((e) => {
        let minute = Number(e.minute);
        if (!Number.isFinite(minute)) {
          const t0 = Number(e.t) || 0;
          const dur0 = Math.max(1, Number(playback.duration_sec) || 20);
          minute = Math.max(1, Math.min(90 + add2, Math.round((t0 / dur0) * (90 + add2))));
        }
        // Clamp into match span (0..fhMins for 1H, 45..90+add2 for 2H)
        if (minute <= 45) {
          // keep; stoppage shown via clock when >45 in FH remap below
        } else if (minute > 45 && minute < 46) {
          minute = 45;
        }
        // Spread old 46-90 into second half; stoppage 90+ into add2
        let at = 0;
        if (e.type === "fulltime") {
          at = ftSec;
        } else if (minute <= 45) {
          // Scale 0-45 across first 45 mins of FH play (before added time window)
          const inReg = minute / 45;
          at = inReg * (45 / fhMins) * fhPlaySec;
        } else if (minute <= 90) {
          const shProg = (minute - 45) / 45;
          at = htEndSec + shProg * (45 / shMins) * shPlaySec;
        } else {
          // 90+ stoppage
          const stop = Math.min(add2, minute - 90);
          at = htEndSec + ((45 + stop) / shMins) * shPlaySec;
        }
        // First-half stoppage events (minute 45 with late t): place into FH added time
        if (e.type !== "fulltime" && minute === 45 && Number(e.t) > (Number(playback.duration_sec) || 20) * 0.45) {
          at = fhPlaySec * (45 / fhMins) + (fhPlaySec * (add1 / fhMins)) * 0.5;
        }
        return { ...e, minute, at };
      })
      .sort((a, b) => a.at - b.at);

    // Inject synthetic stoppage / HT markers (display only)
    // (clock handles added-time labels; HT banner from phase)

    let hg = 0;
    let ag = 0;
    let htShown = false;
    scoreEl.textContent = "0 – 0";
    clockEl.textContent = "0'";
    if (phaseNode) phaseNode.textContent = "1st half";
    if (htNode) htNode.hidden = true;
    let add1Announced = false;
    let add2Announced = false;

    if (!overlay.querySelector("#msimFeedHome")) {
      feed.innerHTML = `
        <div class="msim-feed-col msim-feed-home" id="msimFeedHome"></div>
        <div class="msim-feed-col msim-feed-away" id="msimFeedAway"></div>
        <div class="msim-feed-center" id="msimFeedCenter"></div>
      `;
    }
    const feedHome = overlay.querySelector("#msimFeedHome");
    const feedAway = overlay.querySelector("#msimFeedAway");
    const feedCenter = overlay.querySelector("#msimFeedCenter");
    feedHome.innerHTML = "";
    feedAway.innerHTML = "";
    feedCenter.innerHTML = "";
    if (burstEl) {
      burstEl.hidden = true;
      burstEl.className = "msim-burst";
    }

    /** @type {{ home: HTMLElement|null, away: HTMLElement|null }} */
    const lastGoalBlock = { home: null, away: null };

    let momentum = 0.5;
    let target = 0.55;
    let surgeUntil = 0;
    let lastSide = "home";
    let burstHideTimer = 0;

    const blankSide = () => ({
      poss: 0,
      shots: 0,
      sot: 0,
      xg: 0,
      tackles: 0,
      saves: 0,
      cards: 0,
      fouls: 0,
      shotAcc: 0,
      foulAcc: 0,
      tackleAcc: 0,
    });
    const live = { home: blankSide(), away: blankSide() };
    let statsPaintAt = 0;

    function paintStats() {
      if (!statsEl) return;
      const ht = live.home.poss;
      const at = live.away.poss;
      const total = ht + at;
      const hp = total > 0 ? Math.round((ht / total) * 100) : 50;
      const ap = 100 - hp;
      const set = (side, key, text) => {
        const el = statsEl.querySelector(
          `.msim-stat-${side === "home" ? "h" : "a"}[data-stat="${key}"]`
        );
        if (el) el.textContent = text;
      };
      set("home", "poss", `${hp}%`);
      set("away", "poss", `${ap}%`);
      for (const key of ["shots", "sot", "tackles", "saves", "cards", "fouls"]) {
        set("home", key, String(live.home[key]));
        set("away", key, String(live.away[key]));
      }
      set("home", "xg", live.home.xg.toFixed(2));
      set("away", "xg", live.away.xg.toFixed(2));
    }

    function addShot(side, { onTarget = false, xg = 0.08, isGoal = false } = {}) {
      const s = live[side];
      const opp = live[side === "home" ? "away" : "home"];
      s.shots += 1;
      if (onTarget || isGoal) {
        s.sot += 1;
        if (!isGoal) opp.saves += 1;
      }
      s.xg = Math.round((s.xg + Math.max(0.02, xg)) * 100) / 100;
    }

    function syncGoalStats(side) {
      // A goal is always a shot on target with meaningful xG
      addShot(side, { onTarget: true, xg: 0.55 + Math.random() * 0.35, isGoal: true });
    }

    function tickMatchStats(dt, m) {
      live.home.poss += m * dt;
      live.away.poss += (1 - m) * dt;

      // Attacking side builds shot pressure; defending side builds tackles
      const homeAtk = Math.max(0, m - 0.48);
      const awayAtk = Math.max(0, 0.52 - m);
      live.home.shotAcc += homeAtk * dt * 1.15;
      live.away.shotAcc += awayAtk * dt * 1.15;
      live.home.tackleAcc += awayAtk * dt * 1.6;
      live.away.tackleAcc += homeAtk * dt * 1.6;
      live.home.foulAcc += (0.35 + awayAtk * 1.2) * dt * 0.55;
      live.away.foulAcc += (0.35 + homeAtk * 1.2) * dt * 0.55;

      while (live.home.shotAcc >= 1) {
        live.home.shotAcc -= 1;
        const sot = Math.random() < 0.38 + homeAtk * 0.35;
        addShot("home", {
          onTarget: sot,
          xg: sot ? 0.08 + Math.random() * 0.22 : 0.03 + Math.random() * 0.08,
        });
      }
      while (live.away.shotAcc >= 1) {
        live.away.shotAcc -= 1;
        const sot = Math.random() < 0.38 + awayAtk * 0.35;
        addShot("away", {
          onTarget: sot,
          xg: sot ? 0.08 + Math.random() * 0.22 : 0.03 + Math.random() * 0.08,
        });
      }
      while (live.home.tackleAcc >= 1) {
        live.home.tackleAcc -= 1;
        live.home.tackles += 1;
      }
      while (live.away.tackleAcc >= 1) {
        live.away.tackleAcc -= 1;
        live.away.tackles += 1;
      }
      while (live.home.foulAcc >= 1) {
        live.home.foulAcc -= 1;
        live.home.fouls += 1;
      }
      while (live.away.foulAcc >= 1) {
        live.away.foulAcc -= 1;
        live.away.fouls += 1;
      }
    }

    overlay.hidden = false;
    const started = performance.now();
    let idx = 0;
    let raf = 0;
    let done = false;
    let prevNow = started;

    function eventTarget(ev) {
      const pressure = Math.max(0.35, Math.min(0.95, Number(ev.pressure) || 0.7));
      if (ev.side === "away") return (1 - pressure) * 0.42;
      if (ev.side === "home") return 0.58 + pressure * 0.38;
      return 0.5;
    }

    /** Full bar push toward the opponent goal (1 = home attacking, 0 = away). */
    function goalAttackTarget(side) {
      return side === "away" ? 0 : 1;
    }

    /** Colour bar push: home (left) expands toward away goal (right) when pressing. */
    function paintPressure(m) {
      const homeShare = Math.max(0, Math.min(1, m));
      const awayShare = 1 - homeShare;
      homeZone.style.flexGrow = String(Math.max(0.001, homeShare));
      awayZone.style.flexGrow = String(Math.max(0.001, awayShare));
      homeZone.style.flexBasis = "0";
      awayZone.style.flexBasis = "0";
      const homeAttack = m >= 0.5;
      bar?.classList.toggle("msim-bar--home-push", homeAttack);
      bar?.classList.toggle("msim-bar--away-push", !homeAttack);
      if (homeAttack !== (lastSide === "home")) {
        bar?.classList.remove("msim-bar--pulse");
        void bar?.offsetWidth;
        bar?.classList.add("msim-bar--pulse");
      }
      lastSide = homeAttack ? "home" : "away";
    }

    /** Upcoming goal within the wind-up window → drive bar to 100%. */
    function upcomingGoal(tSec) {
      for (let i = idx; i < events.length; i++) {
        const ev = events[i];
        const at = Number(ev.at);
        if (at > tSec + 1.15) break;
        if (ev.type === "goal" && (ev.side === "home" || ev.side === "away") && at > tSec) {
          return ev;
        }
      }
      return null;
    }

    function hideBurst() {
      if (!burstEl) return;
      burstEl.classList.remove("msim-burst--show");
      burstEl.hidden = true;
    }

    function showBurst(ev) {
      if (!burstEl || !burstArt || !burstTitle || !burstPlayer || !burstMeta) return;
      const type = ev.type;
      if (type !== "goal" && type !== "yellow" && type !== "red" && type !== "injury") return;

      clearTimeout(burstHideTimer);
      burstEl.className = `msim-burst msim-burst--${type} msim-burst--${ev.side === "away" ? "away" : "home"}`;
      burstArt.innerHTML = BURST_ART[type] || "";
      if (burstCard) {
        const accent =
          type === "goal"
            ? ev.side === "away"
              ? awayColor
              : homeColor
            : type === "yellow"
              ? "#e6c35c"
              : type === "red"
                ? "#ef4444"
                : "#e8a0a8";
        burstCard.style.setProperty("--msim-burst-accent", accent);
      }
      if (type === "goal") {
        burstTitle.textContent = "GOAL!";
        burstPlayer.textContent = burstPlayerLabel(ev);
        const pid = ev.player_id != null ? String(ev.player_id) : "";
        let meta = "";
        if (pid && seasonGoalTotals[pid] != null) {
          shownGoalsByPlayer[pid] = (shownGoalsByPlayer[pid] || 0) + 1;
          const seasonAt =
            Number(seasonGoalTotals[pid]) -
            Number(matchGoalsByPlayer[pid] || 0) +
            Number(shownGoalsByPlayer[pid]);
          meta = `${seasonAt} goal${seasonAt === 1 ? "" : "s"} this season`;
        }
        burstMeta.textContent = meta;
      } else if (type === "yellow") {
        burstTitle.textContent = "YELLOW CARD";
        burstPlayer.textContent = burstPlayerLabel(ev);
        burstMeta.textContent = "";
      } else if (type === "red") {
        burstTitle.textContent = "RED CARD";
        burstPlayer.textContent = burstPlayerLabel(ev);
        burstMeta.textContent = "";
      } else {
        burstTitle.textContent = "INJURY";
        burstPlayer.textContent = burstPlayerLabel(ev);
        burstMeta.textContent = burstInjuryDetail(ev);
      }
      burstEl.hidden = false;
      void burstEl.offsetWidth;
      burstEl.classList.add("msim-burst--show");
      const holdMs = type === "goal" ? 2100 : 1600;
      burstHideTimer = setTimeout(hideBurst, holdMs);
    }

    function formatClock(matchMin, phase) {
      if (phase === "ht") return "HT";
      if (phase === "ft") return "FT";
      if (phase === "fh") {
        if (matchMin <= 45) return `${Math.max(0, Math.floor(matchMin))}'`;
        const extra = Math.min(add1, Math.max(1, Math.ceil(matchMin - 45)));
        return `45+${extra}'`;
      }
      // second half
      if (matchMin <= 90) return `${Math.max(45, Math.floor(matchMin))}'`;
      const extra = Math.min(add2, Math.max(1, Math.ceil(matchMin - 90)));
      return `90+${extra}'`;
    }

    function timelineState(tSec) {
      if (tSec < fhEndSec) {
        const p = tSec / fhPlaySec;
        const matchMin = p * fhMins;
        return { phase: "fh", matchMin, playing: true };
      }
      if (tSec < htEndSec) {
        return { phase: "ht", matchMin: 45, playing: false };
      }
      if (tSec < ftSec) {
        const p = (tSec - htEndSec) / shPlaySec;
        const matchMin = 45 + p * shMins;
        return { phase: "sh", matchMin, playing: true };
      }
      return { phase: "ft", matchMin: 90 + add2, playing: false };
    }

    function shortEventLabel(ev) {
      const minLabel =
        ev.minute != null
          ? ev.minute > 90
            ? `90+${Math.min(add2, ev.minute - 90)}' `
            : ev.minute > 45 && ev.minute <= 45 + add1 && ev.at < htEndSec
              ? `45+${Math.min(add1, Math.max(1, Math.round(ev.minute - 45) || 1))}' `
              : `${ev.minute}' `
          : "";
      const name = ev.player || "";
      if (ev.type === "goal") return `${minLabel}${name || "Goal"}`;
      if (ev.type === "assist") return name ? `a ${name}` : "assist";
      if (ev.type === "yellow") return `${minLabel}Y ${name || "Yellow"}`;
      if (ev.type === "red") return `${minLabel}R ${name || "Red"}`;
      if (ev.type === "injury") return `${minLabel}Inj ${name || "Injury"}`;
      if (ev.type === "halftime") return ev.text || "HALF TIME";
      if (ev.type === "fulltime") return ev.text || "Full time";
      return ev.text || ev.type || "";
    }

    function colFor(side) {
      if (side === "away") return feedAway;
      if (side === "home") return feedHome;
      return feedCenter;
    }

    function pushFeed(ev) {
      const side = ev.side === "away" ? "away" : ev.side === "home" ? "home" : null;

      if (ev.type === "assist" && side) {
        const block = lastGoalBlock[side];
        if (block) {
          let assistEl = block.querySelector(".msim-ev-assist");
          if (!assistEl) {
            assistEl = document.createElement("div");
            assistEl.className = "msim-ev-assist";
            block.appendChild(assistEl);
          }
          assistEl.textContent = shortEventLabel(ev);
          return;
        }
      }

      if (ev.type === "fulltime" || ev.type === "halftime" || !side) {
        const row = document.createElement("div");
        row.className = `msim-ev msim-ev--${escapeHtml(ev.type || "info")} msim-ev--center`;
        row.textContent = shortEventLabel(ev);
        feedCenter.prepend(row);
        return;
      }

      if (ev.type === "goal") {
        const block = document.createElement("div");
        block.className = `msim-goal-block msim-ev--${side}`;
        const goalEl = document.createElement("div");
        goalEl.className = "msim-ev msim-ev--goal";
        goalEl.textContent = shortEventLabel(ev);
        block.appendChild(goalEl);
        colFor(side).prepend(block);
        lastGoalBlock[side] = block;

        const next = events[idx];
        if (next && next.type === "assist" && next.side === side) {
          idx += 1;
          const assistEl = document.createElement("div");
          assistEl.className = "msim-ev-assist";
          assistEl.textContent = shortEventLabel(next);
          block.appendChild(assistEl);
        }
        return;
      }

      const row = document.createElement("div");
      row.className = `msim-ev msim-ev--${escapeHtml(ev.type || "info")} msim-ev--${side}`;
      row.textContent = shortEventLabel(ev);
      colFor(side).prepend(row);
    }

    function showHalfTime() {
      if (htShown) return;
      htShown = true;
      if (htNode) htNode.hidden = false;
      if (htScoreNode) htScoreNode.textContent = `${hg} – ${ag}`;
      if (phaseNode) phaseNode.textContent = "Half time";
      clockEl.textContent = "HT";
      pushFeed({
        type: "halftime",
        text: `HALF TIME ${hg} – ${ag}`,
      });
    }

    function hideHalfTime() {
      if (htNode) htNode.hidden = true;
      if (phaseNode) phaseNode.textContent = "2nd half";
    }

    function updatePhaseLabel(state) {
      if (!phaseNode) return;
      if (state.phase === "ht") {
        phaseNode.textContent = "Half time";
        return;
      }
      if (state.phase === "ft") {
        phaseNode.textContent = "Full time";
        return;
      }
      if (state.phase === "fh") {
        // Board goes up in the last minute of regulation (not mid-half)
        if (state.matchMin >= 44) {
          phaseNode.textContent = `1st half · +${add1} mins`;
          if (!add1Announced) {
            add1Announced = true;
            pushFeed({ type: "halftime", text: `Added time +${add1}` });
          }
        } else {
          phaseNode.textContent = "1st half";
        }
        return;
      }
      if (state.phase === "sh") {
        if (state.matchMin >= 89) {
          phaseNode.textContent = `2nd half · +${add2} mins`;
          if (!add2Announced) {
            add2Announced = true;
            pushFeed({ type: "halftime", text: `Added time +${add2}` });
          }
        } else {
          phaseNode.textContent = "2nd half";
        }
      }
    }

    function finish() {
      if (done) return;
      done = true;
      cancelAnimationFrame(raf);
      clearTimeout(burstHideTimer);
      hideBurst();
      hg = data?.home_goals ?? hg;
      ag = data?.away_goals ?? ag;
      scoreEl.textContent = `${hg} – ${ag}`;
      clockEl.textContent = "FT";
      if (phaseNode) phaseNode.textContent = "Full time";
      if (htNode) htNode.hidden = true;
      // Ensure goals are reflected in shot / xG floors
      live.home.shots = Math.max(live.home.shots, hg);
      live.home.sot = Math.max(live.home.sot, hg);
      live.home.xg = Math.max(live.home.xg, hg * 0.75);
      live.away.shots = Math.max(live.away.shots, ag);
      live.away.sot = Math.max(live.away.sot, ag);
      live.away.xg = Math.max(live.away.xg, ag * 0.75);
      paintStats();
      setTimeout(() => {
        overlay.hidden = true;
        resolve(data);
      }, 900);
    }

    function tick(now) {
      if (done) return;
      const elapsed = now - started;
      const tSec = elapsed / 1000;
      const dt = Math.min(0.05, (now - prevNow) / 1000);
      prevNow = now;

      const state = timelineState(tSec);

      if (state.phase === "ht") {
        showHalfTime();
      } else if (state.phase === "sh" && htShown) {
        hideHalfTime();
      }
      updatePhaseLabel(state);

      while (idx < events.length && Number(events[idx].at) <= tSec) {
        const ev = events[idx++];
        if (ev.type === "momentum") {
          if (ev.side === "home" || ev.side === "away") {
            target = eventTarget(ev);
            surgeUntil = tSec + 0.85;
            momentum += (target - momentum) * 0.35;
          }
          continue;
        }
        if (
          (ev.type === "goal" || ev.type === "red") &&
          (ev.side === "home" || ev.side === "away")
        ) {
          if (ev.type === "goal") {
            target = goalAttackTarget(ev.side);
            surgeUntil = tSec + 1.2;
            momentum = target;
          } else {
            target = eventTarget(ev);
            surgeUntil = tSec + 0.85;
            momentum += (target - momentum) * 0.35;
          }
        }
        if (ev.type === "goal") {
          hg = ev.score_home ?? hg;
          ag = ev.score_away ?? ag;
          scoreEl.textContent = `${hg} – ${ag}`;
          scoreEl.classList.add("msim-score--flash");
          setTimeout(() => scoreEl.classList.remove("msim-score--flash"), 400);
          if (ev.side === "home" || ev.side === "away") syncGoalStats(ev.side);
        }
        if (ev.type === "yellow" || ev.type === "red") {
          const side = ev.side === "away" ? "away" : ev.side === "home" ? "home" : null;
          if (side) {
            live[side].cards += 1;
            live[side].fouls += 1;
          }
        }
        if (ev.type !== "momentum") {
          pushFeed(ev);
          showBurst(ev);
          paintStats();
        }
        if (ev.type === "fulltime") {
          finish();
          return;
        }
      }

      if (state.playing) {
        const nextGoal = upcomingGoal(tSec);
        const wave =
          Math.sin(tSec * 2.4) * 0.14 +
          Math.sin(tSec * 5.1 + 1.3) * 0.08 +
          Math.sin(tSec * 0.9 + 0.4) * 0.1;
        const bias = 0.5 + Math.sin(tSec * 0.55) * 0.12;
        let liveTarget = bias + wave;
        let chase = 4.2;

        if (nextGoal) {
          // Wind-up: slam to 100% attack toward the goal about to be scored
          const eta = Math.max(0.05, Number(nextGoal.at) - tSec);
          const wind = Math.min(1, (1.15 - eta) / 1.15);
          target = goalAttackTarget(nextGoal.side);
          liveTarget = target;
          chase = 6 + wind * 14;
          surgeUntil = Math.max(surgeUntil, Number(nextGoal.at) + 0.35);
        } else if (tSec < surgeUntil) {
          const blend = Math.min(1, (surgeUntil - tSec) / 0.9);
          liveTarget = target * (0.55 + 0.35 * blend) + liveTarget * (0.45 - 0.25 * blend);
          chase = 7.5;
        }

        liveTarget = Math.max(0, Math.min(1, liveTarget));
        momentum += (liveTarget - momentum) * (1 - Math.exp(-chase * dt));
        momentum = Math.max(0, Math.min(1, momentum));
        paintPressure(momentum);
        tickMatchStats(dt, momentum);
        if (tSec - statsPaintAt >= 0.2) {
          statsPaintAt = tSec;
          paintStats();
        }
        clockEl.textContent = formatClock(state.matchMin, state.phase);
      } else if (state.phase === "ht") {
        clockEl.textContent = "HT";
      }

      if (tSec >= ftSec) {
        finish();
        return;
      }
      raf = requestAnimationFrame(tick);
    }

    paintPressure(momentum);
    paintStats();
    skipBtn.onclick = () => finish();
    raf = requestAnimationFrame(tick);
    })();
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Shared CSS for banners + momentum modal. */
export const MATCH_SIM_BANNER_STYLE = `
.match-sim-banner { font-size:13px; color:#bbb; margin:0 0 12px; padding:8px 12px; background:#1a221a; border:1px solid #345; border-radius:6px; }
.match-sim-banner--err { background:#2a1515; border-color:#633; color:#f88; }
.match-sim-on { color:#9fd4b0; font-weight:bold; }
.match-sim-off { color:#f88; font-weight:bold; }
.sim-actions { display:inline-flex; flex-wrap:wrap; gap:6px; align-items:center; }
.btn-link.sim-result-btn, button.sim-result-btn {
  display:inline-block; padding:4px 10px; font-size:12px; font-weight:bold;
  background:#2a5535; color:#cfc; border:1px solid #3a6; border-radius:4px; cursor:pointer;
}
.btn-link.sim-instant-btn { background:#333; border-color:#555; color:#ddd; }
.btn-link.sim-result-btn:disabled, button.sim-result-btn:disabled,
button.sim-instant-btn:disabled, button.sim-play-btn:disabled {
  opacity:.4; cursor:not-allowed; background:#2a2a2a !important; border-color:#444 !important; color:#777 !important;
}
.btn-link.sim-result-btn.sim-busy:disabled, button.sim-result-btn.sim-busy:disabled,
button.sim-instant-btn.sim-busy:disabled, button.sim-play-btn.sim-busy:disabled {
  opacity:.6; cursor:wait;
}
.match-sim-toggle { margin-left:8px; background:#444; color:#eee; border:0; }

.msim-overlay {
  position:fixed; inset:0; z-index:9999; background:rgba(0,0,0,.72);
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.msim-overlay[hidden] { display:none !important; }
.msim-modal {
  position:relative; width:min(520px, 100%); background:#121212; border:1px solid #333; border-radius:10px;
  padding:16px 18px 14px; box-shadow:0 12px 40px rgba(0,0,0,.55); color:#eee;
}
.msim-head { display:flex; flex-direction:column; gap:6px; margin-bottom:12px; }
.msim-teams {
  display:grid; grid-template-columns:1fr auto 1fr; gap:10px; align-items:center;
  font-weight:700; font-size:15px;
}
.msim-home-name { text-align:left; }
.msim-away-name { text-align:right; }
.msim-score { font-size:22px; font-variant-numeric:tabular-nums; color:#ff9900; min-width:4.5ch; text-align:center; }
.msim-score--flash { transform:scale(1.12); transition:transform .15s ease; }
.msim-clock { font-size:14px; color:#ff9900; text-align:center; font-weight:700; font-variant-numeric:tabular-nums; }
.msim-phase { font-size:11px; color:#888; text-align:center; margin-top:2px; }
.msim-ht {
  margin:8px 0 10px; padding:12px 10px; text-align:center;
  border:1px solid #445; border-radius:8px; background:#161a22;
}
.msim-ht[hidden] { display:none !important; }
.msim-ht-label { font-size:12px; font-weight:800; letter-spacing:.08em; color:#9ab; }
.msim-ht-score { font-size:26px; font-weight:800; color:#ff9900; margin-top:4px; font-variant-numeric:tabular-nums; }
.msim-ev--halftime { color:#9ab; font-weight:700; }
.msim-pitch { margin:8px 0 10px; position:relative; }
.msim-bar {
  position:relative; height:40px; border-radius:6px; overflow:hidden;
  border:1px solid #333; display:flex; align-items:stretch;
}
.msim-home-zone, .msim-away-zone {
  flex:1 1 0; min-width:0; opacity:.95;
  transition: flex-grow .1s linear;
}
.msim-goal-mouth {
  position:absolute; top:0; bottom:0; width:6px; z-index:2; pointer-events:none;
  background:repeating-linear-gradient(
    180deg, #c8d0d8 0 3px, transparent 3px 6px
  );
  opacity:.55;
}
.msim-goal-mouth--home { left:0; border-right:2px solid #c8d0d8; }
.msim-goal-mouth--away { right:0; border-left:2px solid #c8d0d8; }
.msim-bar--home-push .msim-goal-mouth--away { opacity:.95; box-shadow:0 0 10px rgba(255,255,255,.25); }
.msim-bar--away-push .msim-goal-mouth--home { opacity:.95; box-shadow:0 0 10px rgba(255,255,255,.25); }
.msim-bar--pulse { animation:msimBarPulse .35s ease; }
@keyframes msimBarPulse {
  0%{ filter:brightness(1) }
  40%{ filter:brightness(1.25) }
  100%{ filter:brightness(1) }
}

.msim-stats {
  display:flex; flex-direction:column; gap:3px;
  margin:0 0 10px; padding:8px 10px;
  border:1px solid #2a2a2a; border-radius:6px; background:#0d0d0d;
  font-variant-numeric:tabular-nums;
}
.msim-stat-row {
  display:grid; grid-template-columns:1fr auto 1fr; gap:8px; align-items:center;
  font-size:12px; line-height:1.25;
}
.msim-stat-h { text-align:left; color:#cde; font-weight:700; }
.msim-stat-a { text-align:right; color:#cde; font-weight:700; }
.msim-stat-label { text-align:center; color:#778; font-size:10px; letter-spacing:.04em; text-transform:uppercase; }

.msim-burst {
  display:flex; align-items:center; justify-content:center;
  margin:0 0 10px; min-height:0;
  pointer-events:none; opacity:0;
  transition:opacity .2s ease, margin .2s ease;
}
.msim-burst[hidden] { display:none !important; }
.msim-burst--show {
  opacity:1; margin-bottom:12px;
}
.msim-burst-card {
  min-width:min(280px, 86%);
  padding:12px 16px 10px; border-radius:10px; text-align:center;
  background:linear-gradient(180deg, #1a1f28 0%, #10141a 100%);
  border:2px solid var(--msim-burst-accent, #ff9900);
  box-shadow:0 8px 24px rgba(0,0,0,.4), 0 0 0 1px rgba(255,255,255,.06) inset;
  transform:scale(.92); transition:transform .22s cubic-bezier(.2,1.2,.3,1);
}
.msim-burst--show .msim-burst-card { transform:scale(1); }
.msim-burst-art { display:flex; justify-content:center; align-items:center; min-height:52px; margin-bottom:4px; }
.msim-burst-title {
  font-size:22px; font-weight:900; letter-spacing:.06em; line-height:1.1;
  color:#fff; text-shadow:0 2px 10px rgba(0,0,0,.5);
}
.msim-burst--goal .msim-burst-title { color:#9fd4b0; font-size:28px; }
.msim-burst--yellow .msim-burst-title { color:#e6c35c; font-size:18px; }
.msim-burst--red .msim-burst-title { color:#f66; font-size:18px; }
.msim-burst--injury .msim-burst-title { color:#e8a0a8; font-size:18px; }
.msim-burst-player { margin-top:4px; font-size:15px; font-weight:700; color:#eee; }
.msim-burst-meta { margin-top:2px; font-size:12px; color:#9ab; min-height:1em; }

.msim-art-goal { width:120px; height:72px; overflow:visible; }
.msim-art-ball {
  transform-box:fill-box; transform-origin:center;
  animation:msimBallIn .85s cubic-bezier(.2,.7,.2,1) both;
}
@keyframes msimBallIn {
  0% { transform:translate(-46px, 8px) scale(.7); opacity:.3; }
  70% { transform:translate(8px, -2px) scale(1.05); opacity:1; }
  100% { transform:translate(22px, 0) scale(1); opacity:1; }
}
.msim-art-card {
  width:42px; height:58px; border-radius:5px;
  box-shadow:0 4px 12px rgba(0,0,0,.4);
  animation:msimCardFlip .55s ease both;
}
.msim-art-card--yellow { background:linear-gradient(145deg, #ffe566, #d4a017); border:1px solid #a67c00; }
.msim-art-card--red { background:linear-gradient(145deg, #ff6b6b, #b91c1c); border:1px solid #7f1d1d; }
@keyframes msimCardFlip {
  0% { transform:rotateY(-90deg) scale(.6); opacity:0; }
  100% { transform:rotateY(0) scale(1); opacity:1; }
}
.msim-art-injury { width:64px; height:64px; animation:msimInjPop .5s ease both; }
@keyframes msimInjPop {
  0% { transform:scale(.5); opacity:0; }
  100% { transform:scale(1); opacity:1; }
}

.msim-feed {
  display:grid; grid-template-columns:1fr 1fr; gap:8px 12px; align-items:start;
  max-height:200px; overflow:auto; font-size:13px; line-height:1.35;
  border:1px solid #2a2a2a; border-radius:6px; background:#0d0d0d; padding:8px 10px;
  min-height:88px; position:relative;
}
.msim-feed-col { display:flex; flex-direction:column; gap:6px; min-width:0; }
.msim-feed-home { text-align:left; }
.msim-feed-away { text-align:right; }
.msim-feed-center {
  grid-column:1 / -1; text-align:center; display:flex; flex-direction:column; gap:4px;
}
.msim-goal-block { display:flex; flex-direction:column; gap:1px; }
.msim-feed-away .msim-goal-block { align-items:flex-end; }
.msim-feed-home .msim-goal-block { align-items:flex-start; }
.msim-ev { padding:2px 0; color:#ccc; }
.msim-ev--goal { color:#9fd4b0; font-weight:700; font-size:13px; }
.msim-ev-assist {
  color:#8aa; font-size:10px; font-weight:500; line-height:1.2; opacity:.9;
  margin-top:0; padding:0 2px 2px;
}
.msim-feed-away .msim-ev-assist { text-align:right; }
.msim-feed-home .msim-ev-assist { text-align:left; }
.msim-ev--red { color:#f88; font-weight:700; }
.msim-ev--yellow { color:#e6c35c; }
.msim-ev--injury { color:#f0a070; }
.msim-ev--fulltime { color:#ff9900; font-weight:700; }
.msim-ev--center { width:100%; }
.msim-foot { margin-top:10px; text-align:right; }
.msim-skip { background:#333; color:#ddd; border:0; padding:6px 12px; border-radius:4px; cursor:pointer; }
`;
