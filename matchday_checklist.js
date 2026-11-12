/**
 * Matchday checklist — per-fixture owner tick list (dashboard).
 * Data: dashboard_matchday_checklist() RPC.
 */

import { supabase } from "./global.js";
import { cupFixtureKind, cupSwitchNote } from "./matchday_console_rules.js?v=20261111-cup-settings";
import { fullClubName } from "./clubs_lookup.js";
import {
  fetchFixturesHomeWeatherMeta,
  formatMatchConditionsHtml,
} from "./competition_conditions.js";

async function enrichChecklistFixturesWithHomeWeather(data, arrange) {
  const fx = Array.isArray(data?.fixtures) ? data.fixtures : [];
  const arr = Array.isArray(arrange?.fixtures) ? arrange.fixtures : [];
  const ids = [...fx, ...arr].map((r) => r.fixture_id);
  const meta = await fetchFixturesHomeWeatherMeta(supabase, ids);
  if (!meta.size) return;

  const merge = (row) => {
    const m = meta.get(Number(row.fixture_id));
    if (!m) return row;
    return {
      ...row,
      home_club_short_name: m.home_club_short_name || row.home_club_short_name,
      away_club_short_name: m.away_club_short_name || row.away_club_short_name,
      weather: m.weather ?? row.weather ?? null,
      pitch_condition: m.pitch_condition ?? row.pitch_condition ?? null,
      kit_season: m.kit_season ?? row.kit_season ?? null,
    };
  };

  if (data?.fixtures) data.fixtures = fx.map(merge);
  if (arrange?.fixtures) arrange.fixtures = arr.map(merge);
}

function formatOwnerTag(raw) {
  const t = String(raw || "").trim();
  if (!t) return "";
  return t.startsWith("@") ? t : `@${t}`;
}

async function enrichChecklistOwnerTags(data, arrange) {
  const fx = Array.isArray(data?.fixtures) ? data.fixtures : [];
  const arr = Array.isArray(arrange?.fixtures) ? arrange.fixtures : [];
  const shorts = new Set();
  for (const row of [...fx, ...arr]) {
    for (const key of ["home_club_short_name", "away_club_short_name", "opponent_short_name"]) {
      const s = String(row?.[key] || "").trim();
      if (s) shorts.add(s);
    }
  }
  if (!shorts.size) return;
  const { data: clubs, error } = await supabase
    .from("Clubs")
    .select("ShortName, owner")
    .in("ShortName", [...shorts]);
  if (error) {
    console.warn("checklist owner tags:", error.message);
    return;
  }
  const byShort = new Map();
  for (const c of clubs || []) {
    const tag = formatOwnerTag(c.owner);
    if (!c.ShortName || !tag) continue;
    byShort.set(String(c.ShortName).toUpperCase(), tag);
  }
  const merge = (row) => {
    const { home, away } = resolveHomeAway(row);
    return {
      ...row,
      home_owner_tag: byShort.get(home) || row.home_owner_tag || "",
      away_owner_tag: byShort.get(away) || row.away_owner_tag || "",
    };
  };
  if (data?.fixtures) data.fixtures = fx.map(merge);
  if (arrange?.fixtures) arrange.fixtures = arr.map(merge);
}

const REFRESH_MS = 120_000;
const TICK_MS = 30_000;
const COLLAPSE_KEY = "gpsl_mc_collapsed";
const UK_TZ = "Europe/London";

let lastData = null;
let strikeBoard = null;

function placeHoverBox(tip) {
  const box = tip.querySelector(":scope > .mc-tip-box");
  if (!box) return;
  const r = tip.getBoundingClientRect();
  const width = 260;
  const left = Math.min(Math.max(8, r.left), Math.max(8, window.innerWidth - width - 8));
  box.style.display = "block";
  box.style.left = `${left}px`;
  const h = box.offsetHeight || 72;
  const below = r.bottom + 6;
  const top = below + h < window.innerHeight - 8 ? below : Math.max(8, r.top - h - 6);
  box.style.top = `${top}px`;
}

function hideHoverBox(tip) {
  const box = tip?.querySelector(":scope > .mc-tip-box");
  if (box) box.style.display = "none";
}

function bindHoverTips(root) {
  if (!root || root.dataset.hoverTips === "1") return;
  root.dataset.hoverTips = "1";
  const tipFrom = (node) => node?.closest?.(".mc-tip");
  root.addEventListener("mouseover", (e) => {
    const tip = tipFrom(e.target);
    if (tip && root.contains(tip)) placeHoverBox(tip);
  });
  root.addEventListener("mouseout", (e) => {
    const tip = tipFrom(e.target);
    if (!tip || !root.contains(tip)) return;
    if (e.relatedTarget && tip.contains(e.relatedTarget)) return;
    hideHoverBox(tip);
  });
  root.addEventListener("focusin", (e) => {
    const tip = tipFrom(e.target);
    if (tip && root.contains(tip)) placeHoverBox(tip);
  });
  root.addEventListener("focusout", (e) => {
    const tip = tipFrom(e.target);
    if (!tip || !root.contains(tip)) return;
    if (e.relatedTarget && tip.contains(e.relatedTarget)) return;
    hideHoverBox(tip);
  });
  root.addEventListener("scroll", () => {
    root.querySelectorAll(".mc-tip").forEach(hideHoverBox);
  }, true);
}

function strikeNoteHtml(fixtureId) {
  if (!strikeBoard || strikeBoard.ok === false) return "";
  const row = (strikeBoard.fixtures || []).find((f) => Number(f.fixture_id) === Number(fixtureId));
  const matchStrikes = Number(row?.fixture_strikes ?? 0);
  const seasonStrikes = Number(strikeBoard.season_strikes ?? 0);
  const help =
    `This match: ${matchStrikes} of 3. A third strike forfeits it and adds ₿1m. ` +
    `Season: ${seasonStrikes}. Each strike is ₿500k. Strike 5, 10, 15… adds ₿1m.`;
  return `<div class="mc-flags"><span class="mc-flag mc-flag-info mc-tip" tabindex="0">Strikes ${matchStrikes}/3 · season ${seasonStrikes}<span class="mc-tip-box">${escapeHtml(help)}</span></span></div>`;
}
let ownerClubShort = "";
let ownerTz = UK_TZ;
/** owner_upcoming_arrangements(): next-month fixtures still to arrange */
let lastArrange = null;
let refreshTimer = null;
let tickTimer = null;

const STEP_ICON = {
  done: "✓",
  todo: "●",
  overdue: "!",
  warn: "⚠",
  waiting: "⏳",
  upcoming: "○",
  na: "–",
  missed: "✕",
};

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubLabel(short) {
  return fullClubName(short) || short || "?";
}

export function competitionShortLabel(fx) {
  if (String(fx.competition_type || "").toLowerCase() === "cup") {
    const code = String(fx.cup_code || "").toLowerCase();
    const map = { super8: "Super8", plate: "Plate", shield: "Shield", bowl: "Bowl", league_cup: "League Cup" };
    return `${map[code] || fx.cup_code || "Cup"} R${fx.cup_round ?? "?"}`;
  }
  return `MD${fx.matchday ?? "?"}`;
}

function zoneShort(tz) {
  const city = String(tz || UK_TZ).split("/").pop() || UK_TZ;
  return city.replace(/_/g, " ");
}

function formatClock(iso, timeZone) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const zone = timeZone || UK_TZ;
  const opts = {
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  };
  try {
    return d.toLocaleString("en-GB", { ...opts, timeZone: zone });
  } catch {
    return d.toLocaleString("en-GB", { ...opts, timeZone: UK_TZ });
  }
}

/** Kick-off in the owner's match-availability timezone. */
function formatOwnerClock(iso) {
  const local = formatClock(iso, ownerTz);
  if (!local) return "";
  if (ownerTz === UK_TZ) return local;
  return `${local} ${zoneShort(ownerTz)}`;
}

/** Deadlines that used to say "UK". Same clock, labelled with the owner's zone. */
function formatOwnerDeadline(iso) {
  const local = formatClock(iso, ownerTz);
  if (!local) return "";
  if (ownerTz === UK_TZ) return `${local} UK`;
  return `${local} ${zoneShort(ownerTz)}`;
}

function clockTitle(iso) {
  const uk = formatClock(iso, UK_TZ);
  if (!uk) return "";
  if (ownerTz === UK_TZ) return `${uk} UK`;
  return `${zoneShort(ownerTz)}: ${formatClock(iso, ownerTz)}. UK: ${uk}`;
}

async function loadOwnerTimezone() {
  if (!ownerClubShort) return;
  try {
    const { data, error } = await supabase.rpc("match_schedule_club_timezone", {
      p_club: ownerClubShort,
    });
    if (error) {
      console.warn("checklist timezone:", error.message);
      return;
    }
    const tz = String(data || "").trim();
    if (tz) ownerTz = tz;
  } catch (err) {
    console.warn("checklist timezone:", err);
  }
}

function relTime(iso) {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "";
  const diff = t - Date.now();
  const abs = Math.abs(diff);
  const mins = Math.round(abs / 60000);
  let txt;
  if (mins < 60) txt = `${mins}m`;
  else if (mins < 48 * 60) txt = `${Math.floor(mins / 60)}h ${mins % 60}m`;
  else txt = `${Math.floor(mins / 1440)}d ${Math.floor((mins % 1440) / 60)}h`;
  return diff >= 0 ? `in ${txt}` : `${txt} ago`;
}

function stepDue(step) {
  if (!step?.due_at) return "";
  if (step.state === "done") return formatOwnerDeadline(step.due_at);
  const rel = relTime(step.due_at);
  const past = new Date(step.due_at).getTime() < Date.now();
  if (step.key === "checkin" && step.state === "upcoming") return `opens ${rel}`;
  if (past) return `deadline passed ${rel}`;
  return `due ${rel}`;
}

function stepTitle(step) {
  const bits = [step.label];
  if (step.detail) bits.push(step.detail);
  const due = stepDue(step);
  if (due) bits.push(due);
  return bits.join(" — ");
}

function renderStepPill(step) {
  const state = step.state || "upcoming";
  return `<span class="mc-step mc-${escapeHtml(state)}" title="${escapeHtml(stepTitle(step))}">` +
    `<span class="mc-step-icon" aria-hidden="true">${STEP_ICON[state] || "○"}</span>` +
    `<span class="mc-step-label">${escapeHtml(shortStepName(step.key))}</span></span>`;
}

function shortStepName(key) {
  return {
    schedule: "Kick-off",
    squad: "Squad",
    checkin: "Check-in",
    result: "Result",
    stats: "Stats",
    confirm: "Confirmed",
    video: "Video",
  }[key] || key;
}

function renderActionButton(step, fixtureId) {
  if (!step) return "";
  if (step.key === "checkin" && step.state === "todo") {
    return `<button type="button" class="mc-btn mc-btn-primary" data-mc-checkin="${fixtureId}">Check in</button>`;
  }
  if (step.href === "discord") {
    return step.filename
      ? `<button type="button" class="mc-btn mc-btn-primary" data-mc-copy="${escapeHtml(step.filename)}" title="Copy filename, then post the video in the match videos Discord channel">Copy video filename</button>`
      : "";
  }
  if (!step.href) return "";
  return `<a class="mc-btn mc-btn-primary" href="${escapeHtml(step.href)}">${escapeHtml(step.action || "Open")}</a>`;
}

function renderFlags(flags) {
  if (!Array.isArray(flags) || !flags.length) return "";
  return flags
    .map((f) => {
      const text = escapeHtml(f.text);
      const inner = f.href ? `<a href="${escapeHtml(f.href)}">${text}</a>` : text;
      return `<span class="mc-flag mc-flag-${escapeHtml(f.level || "info")}">${inner}</span>`;
    })
    .join("");
}

/** Grouped recording ticks — order matches Match Day Display checks + Learning GPSL. */
const REC_GROUPS = [
  {
    heading: "Recording",
    items: [["rec_started", "Recording started"]],
  },
  {
    heading: "Pre-Match Settings",
    items: [
      ["rec_room_10min", "10-minute match"],
      ["rec_room_injuries", "Injuries Off"],
      ["rec_room_subs", "Substitutes: 5"],
      ["rec_room_intervals", "Sub intervals: 3"],
      ["rec_room_form", "Form: Random"],
    ],
  },
  {
    heading: "Prematch config",
    items: [
      ["rec_cfg_stadium", "Stadium shown"],
      ["rec_cfg_kits", "Kits shown"],
      ["rec_cfg_weather", "Weather / Pitch shown"],
    ],
  },
  {
    heading: "Personnel",
    items: [
      ["rec_pers_manager", "[show] Manager (GP)"],
      ["rec_pers_subtactic", "[show] Subtactic"],
      ["rec_pers_squad", "[show] Squad (incl. substitutes)"],
    ],
  },
  {
    heading: "Tactics",
    items: [
      ["rec_tac_instructions", "[Show] player instructions blank"],
      ["rec_tac_show_fluid", "show fluid formation"],
      ["rec_tac_subtactic", "Default Konami formation set before kick-off"],
      ["rec_tac_fluid", "No player dragging (sub tactic and Fluid set before the match)"],
    ],
  },
  {
    heading: "Pause before kick-off",
    items: [
      ["rec_pause_pa3", "PA3 or PA4 shown"],
      ["rec_pause_adv", "Advanced skill shown"],
    ],
  },
  {
    heading: "On the pitch",
    note: "Single Red/Blue from 80' · Double Red/Blue from 90' · NO DOGSO · NO TIMEWASTING · NO MATCH MANIPULATION",
    items: [
      ["rec_pitch_scoreboard", "Scoreboard on"],
      ["rec_pitch_hud", "HUD on for the whole match"],
    ],
  },
  {
    heading: "After the match",
    items: [
      ["rec_post_ratings", "Player ratings shown"],
      ["rec_post_potm", "Player of the match shown"],
      ["rec_post_stop", "Recording stopped"],
    ],
  },
];

const REC_ITEMS = REC_GROUPS.flatMap((g) => g.items);

/** Old compound ticks → expand so prior ticks still count. */
const REC_LEGACY_EXPAND = {
  rec_room_settings: [
    "rec_room_10min",
    "rec_room_injuries",
    "rec_room_subs",
    "rec_room_intervals",
    "rec_room_form",
  ],
  rec_prematch_config: ["rec_cfg_stadium", "rec_cfg_kits", "rec_cfg_weather"],
  rec_squad_tactics: [
    "rec_pers_manager",
    "rec_pers_subtactic",
    "rec_pers_squad",
    "rec_tac_instructions",
    "rec_tac_show_fluid",
    "rec_tac_subtactic",
    "rec_tac_fluid",
  ],
  rec_pause_pa: ["rec_pause_pa3", "rec_pause_adv"],
  rec_hud_on: ["rec_pitch_scoreboard", "rec_pitch_hud"],
  rec_post_match: ["rec_post_ratings", "rec_post_potm", "rec_post_stop"],
};

const REC_AFTER_MS = 2 * 60 * 60 * 1000;

/** fixture_id → Set of ticked rec_* keys */
let recTicks = new Map();

function expandRecTicks(raw) {
  const out = new Set(raw || []);
  for (const [legacy, kids] of Object.entries(REC_LEGACY_EXPAND)) {
    if (!out.has(legacy)) continue;
    for (const k of kids) out.add(k);
  }
  return out;
}

function checkinDone(fx) {
  return (fx.steps || []).some((s) => s.key === "checkin" && s.state === "done");
}

/** Both checked in makes the server offer Enter result. That is not the pre-match list. */
function enterResultIsOnlyBecauseCheckedIn(fx) {
  const next = fx.next_action;
  return checkinDone(fx) && next?.key === "result" && next?.action === "Enter result";
}

function recordingWindowOpen(fx) {
  if (!checkinDone(fx)) return false;
  if (!fx.agreed_kickoff_at) return true;
  const ko = new Date(fx.agreed_kickoff_at).getTime();
  if (!Number.isFinite(ko)) return true;
  return Date.now() <= ko + REC_AFTER_MS;
}

function renderRecordingBlock(fx) {
  if (!recordingWindowOpen(fx)) return "";
  const fid = Number(fx.fixture_id);
  const resultLink = enterResultIsOnlyBecauseCheckedIn(fx)
    ? `<div class="mc-actions"><a class="mc-btn" href="matchday.html?fixture=${fid}">Enter result when the match is played</a></div>`
    : "";
  const ticked = expandRecTicks(recTicks.get(fid));
  const done = REC_ITEMS.filter(([k]) => ticked.has(k)).length;
  const groupsHtml = REC_GROUPS.map((g) => {
    const items = g.items
      .map(
        ([k, label]) => `
        <label class="mc-rec-item${ticked.has(k) ? " done" : ""}">
          <input type="checkbox" data-mc-rec="${fid}" data-mc-rec-key="${k}"${ticked.has(k) ? " checked" : ""}>
          <span>${escapeHtml(label)}</span>
        </label>`
      )
      .join("");
    const cupNote =
      g.heading === "Pre-Match Settings" ? cupSwitchNote(cupFixtureKind(fx)) : "";
    const noteText = cupNote || g.note || "";
    const note = noteText
      ? `<p class="mc-rec-note">${escapeHtml(noteText)}</p>`
      : "";
    return `
      <div class="mc-rec-group">
        <div class="mc-rec-group-h">${escapeHtml(g.heading)}</div>
        ${note}
        ${items}
      </div>`;
  }).join("");
  return `
    <div class="mc-rec">
      <div class="mc-rec-head">🎥 <b>Pre-match checklist</b> <span>${done} / ${REC_ITEMS.length} ticked</span>
        <a href="learning_gpsl.html#matchday-checklist" target="_blank" rel="noopener">Full checklist</a></div>
      <div class="mc-rec-groups">${groupsHtml}</div>
      ${resultLink}
    </div>`;
}

async function loadRecTicks(fixtures) {
  const ids = (fixtures || []).filter(recordingWindowOpen).map((f) => Number(f.fixture_id));
  recTicks = new Map();
  if (!ids.length) return;
  const { data, error } = await supabase
    .from("owner_ready_ticks")
    .select("fixture_id, item_key")
    .in("fixture_id", ids);
  if (error) {
    console.warn("owner_ready_ticks:", error.message);
    return;
  }
  for (const row of data || []) {
    const fid = Number(row.fixture_id);
    if (!recTicks.has(fid)) recTicks.set(fid, new Set());
    recTicks.get(fid).add(row.item_key);
  }
}

async function onRecTick(box) {
  const fid = Number(box.dataset.mcRec);
  const key = box.dataset.mcRecKey;
  box.disabled = true;
  const { error } = await supabase.rpc("owner_ready_tick", {
    p_item_key: key,
    p_ticked: box.checked,
    p_fixture_id: fid,
  });
  if (error) {
    alert(error.message || "Could not save that tick.");
    box.checked = !box.checked;
    box.disabled = false;
    return;
  }
  if (!recTicks.has(fid)) recTicks.set(fid, new Set());
  if (box.checked) recTicks.get(fid).add(key);
  else recTicks.get(fid).delete(key);
  render();
}

function resolveHomeAway(fx, myClub) {
  const home =
    fx.home_club_short_name ||
    (fx.side === "home" ? myClub || lastData?.club_short_name : fx.opponent_short_name);
  const away =
    fx.away_club_short_name ||
    (fx.side === "home" ? fx.opponent_short_name : myClub || lastData?.club_short_name);
  return {
    home: home ? String(home).toUpperCase() : "",
    away: away ? String(away).toUpperCase() : "",
  };
}

function fixtureMatchupHtml(fx, href) {
  const { home, away } = resolveHomeAway(fx);
  const homeLabel = escapeHtml(clubLabel(home));
  const awayLabel = escapeHtml(clubLabel(away));
  const line = home && away
    ? `<span class="mc-fx-home" title="Home team">${homeLabel}</span> <span class="mc-fx-sep">vs</span> ${awayLabel}`
    : `${fx.side === "home" ? "vs" : "@"} ${escapeHtml(clubLabel(fx.opponent_short_name))}`;
  return `<a class="mc-fx-vs" href="${href}">${line}</a>`;
}

function fixtureMetaHtml(fx) {
  const { home } = resolveHomeAway(fx);
  const homeBit = home
    ? `<span class="mc-fx-meta-home">Home: <b>${escapeHtml(clubLabel(home))}</b></span>`
    : "";
  const condHtml =
    fx.kit_season || fx.weather || fx.pitch_condition
      ? `<span class="mc-fx-meta-wx">${formatMatchConditionsHtml({
          weather: fx.weather,
          pitch_condition: fx.pitch_condition,
          kit_season: fx.kit_season,
        })}</span>`
      : "";
  const ownerBits = [
    fx.home_owner_tag
      ? `<span class="mc-fx-meta-owner">Home ${escapeHtml(fx.home_owner_tag)}</span>`
      : "",
    fx.away_owner_tag
      ? `<span class="mc-fx-meta-owner">Away ${escapeHtml(fx.away_owner_tag)}</span>`
      : "",
  ].filter(Boolean);
  const ownerHtml = ownerBits.join(`<span class="mc-fx-meta-sep">·</span>`);
  const parts = [homeBit, ownerHtml, condHtml].filter(Boolean);
  if (!parts.length) return "";
  return `<div class="mc-fx-meta">${parts.join(`<span class="mc-fx-meta-sep">·</span>`)}</div>`;
}

function renderFixture(fx) {
  const fid = Number(fx.fixture_id);
  const steps = Array.isArray(fx.steps) ? fx.steps : [];
  const next = fx.next_action;
  const nextDetail = next
    ? [next.detail, stepDue(next)].filter(Boolean).join(" · ")
    : "";
  const video = steps.find((s) => s.key === "video");
  const showFilename = video?.filename && ["todo", "warn", "overdue"].includes(video.state);
  const ticksheetInstead = enterResultIsOnlyBecauseCheckedIn(fx);
  const actionNext = ticksheetInstead ? null : next;
  let status;
  if (ticksheetInstead) {
    status = `<div class="mc-next mc-next-todo"><b>Pre-match checklist</b> <span class="mc-next-detail">Check-in means both clubs are ready. Tick the list below yourself — check-in does not tick it.</span></div>`;
  } else if (next) {
    status = `<div class="mc-next mc-next-${escapeHtml(next.state)}"><b>${escapeHtml(next.label)}</b>${
      nextDetail ? ` <span class="mc-next-detail">${escapeHtml(nextDetail)}</span>` : ""
    }</div>`;
  } else {
    const waiting = steps.find((s) => s.state === "waiting");
    const upcoming = steps.find((s) => s.state === "upcoming");
    const info = waiting || upcoming;
    status = `<div class="mc-next mc-next-quiet">${
      info ? escapeHtml(stepTitle(info)) : "Nothing to do right now"
    }</div>`;
  }

  return `
    <div class="mc-fixture${fx.needs_you > 0 ? " mc-has-todo" : ""}" data-fixture-id="${fid}">
      <div class="mc-fx-head">
        <span class="mc-fx-comp">${escapeHtml(competitionShortLabel(fx))}</span>
        ${fixtureMatchupHtml(fx, `matchday.html?fixture=${fid}`)}
        ${fx.agreed_kickoff_at ? `<span class="mc-fx-ko" title="${escapeHtml(clockTitle(fx.agreed_kickoff_at))}">${escapeHtml(formatOwnerClock(fx.agreed_kickoff_at))}</span>` : ""}
      </div>
      ${fixtureMetaHtml(fx)}
      <div class="mc-steps">${steps.map(renderStepPill).join("")}</div>
      ${status}
      ${showFilename ? `<div class="mc-filename">Filename: <code>${escapeHtml(video.filename)}</code></div>` : ""}
      ${fx.flags?.length ? `<div class="mc-flags">${renderFlags(fx.flags)}</div>` : ""}
      ${strikeNoteHtml(fid)}
      ${actionNext ? `<div class="mc-actions">${renderActionButton(actionNext, fid)}</div>` : ""}
      ${renderRecordingBlock(fx)}
    </div>`;
}

function monthName(key) {
  const k = String(key || "");
  return k ? k[0].toUpperCase() + k.slice(1) : "";
}

function arrangeNeedsYou(a) {
  return a.state === "propose" || a.state === "reply";
}

function renderArrangeRow(a) {
  const fid = Number(a.fixture_id);
  const by = a.propose_by ? `${formatOwnerDeadline(a.propose_by)} (${relTime(a.propose_by)})` : "";
  const lateNow = a.late_fee_from && new Date(a.late_fee_from).getTime() <= Date.now();
  const replay = a.is_admin_replay === true;
  const catchUp = a.is_catch_up === true && !replay;
  const replayTag = replay ? "Replay · " : catchUp ? "Catch-up · " : "";
  let label;
  let detail = "";
  let cls = "mc-next-quiet";
  let action = "";
  if (a.state === "propose") {
    label = replay
      ? "Re-arrange replay — propose a new kick-off"
      : catchUp
        ? "Catch-up — propose a kick-off"
        : lateNow
          ? "Propose a kick-off now — ₿2.5m late fee applies"
          : "Propose a kick-off";
    detail = by ? `by ${by}` : "";
    cls = replay || catchUp || lateNow ? "mc-next-overdue" : "mc-next-todo";
    action = "Propose";
  } else if (a.state === "reply") {
    label = `${replayTag}Reply to kick-off proposal`;
    detail = a.response_due_at ? `due ${formatOwnerDeadline(a.response_due_at)} (${relTime(a.response_due_at)})` : "";
    cls = "mc-next-todo";
    action = "Reply";
  } else if (a.state === "waiting") {
    label = `${replayTag}Kick-off proposed — waiting on opponent`;
  } else {
    label = `${replayTag}Waiting for the home club to propose`;
    detail = by ? `they must propose by ${by}` : "";
  }
  return `
    <div class="mc-fixture mc-arrange-row${arrangeNeedsYou(a) ? " mc-has-todo" : ""}">
      <div class="mc-fx-head">
        <span class="mc-fx-comp">${escapeHtml(competitionShortLabel(a))}</span>
        ${fixtureMatchupHtml(a, `fixture_schedule.html?fixture=${fid}`)}
        <span class="mc-fx-ko">${replay ? "Replay · " : catchUp ? "Catch-up · " : ""}GPSL ${escapeHtml(monthName(a.gpsl_month))}</span>
      </div>
      ${fixtureMetaHtml(a)}
      <div class="mc-next ${cls}"><b>${escapeHtml(label)}</b>${detail ? ` <span class="mc-next-detail">${escapeHtml(detail)}</span>` : ""}</div>
      ${strikeNoteHtml(fid)}
      ${action ? `<div class="mc-actions"><a class="mc-btn mc-btn-primary" href="fixture_schedule.html?fixture=${fid}">${action}</a></div>` : ""}
    </div>`;
}

function renderArrangeBlock(list) {
  if (!list.length) return "";
  return `
    <div class="mc-arrange">
      <div class="mc-arrange-head">
        <b>Arrange now — upcoming months + replays</b>
        <ul class="mc-arrange-notes">
          <li><b>League.</b> Home proposes a kick-off before that GPSL month starts. The last 48 hours is a ₿1m late fee. Missing the unlock is ₿2.5m.</li>
          <li><b>Cups.</b> Drawn when the round month opens. No proposal at that lock is a strike, then each later lock. Away can open the tie once the round month has locked. A missed reply is a strike. No late-arrangement fee. May cups have no extra month.</li>
          <li><b>Replay / catch-up.</b> A reset or a closed month also appears here. Re-propose in the current window.</li>
          <li><b>Already agreed on Discord.</b> Use the Discord lock on the schedule page.</li>
          <li><b>Manual.</b> Both clubs with the GPSL match system off do not appear here.</li>
        </ul>
      </div>
      <div class="mc-list">${list.map(renderArrangeRow).join("")}</div>
    </div>`;
}

function isCollapsed() {
  try {
    return localStorage.getItem(COLLAPSE_KEY) === "1";
  } catch {
    return false;
  }
}

function setCollapsed(v) {
  try {
    localStorage.setItem(COLLAPSE_KEY, v ? "1" : "0");
  } catch {
    /* ignore */
  }
}

function render() {
  const section = document.getElementById("matchdayChecklist");
  if (!section) return;
  const data = lastData;
  const fixtures = Array.isArray(data?.fixtures) ? data.fixtures : [];
  const clubFlags = Array.isArray(data?.flags) ? data.flags : [];
  const arrange = Array.isArray(lastArrange?.fixtures) ? lastArrange.fixtures : [];

  if ((!data?.ok || (!fixtures.length && !clubFlags.length)) && !arrange.length) {
    section.hidden = true;
    section.innerHTML = "";
    return;
  }
  section.hidden = false;

  const arrangeNeeds = arrange.filter(arrangeNeedsYou).length;
  const needs = (Number(data?.needs_you) || 0) + arrangeNeeds;
  const open = fixtures.filter((f) => !f.all_done);
  const done = fixtures.filter((f) => f.all_done);
  const month = data?.gpsl_month ? data.gpsl_month[0].toUpperCase() + data.gpsl_month.slice(1) : "";
  const lock = data?.month_lock_at
    ? `<span class="mc-lock" title="${escapeHtml(clockTitle(data.month_lock_at))}">Month locks ${escapeHtml(relTime(data.month_lock_at))}</span>`
    : "";

  if (!open.length && !clubFlags.length && !arrange.length) {
    section.className = "mc-panel mc-all-done";
    section.innerHTML = `<div class="mc-head"><h2>✓ Matchday checklist</h2><span class="mc-count mc-count-done">All done${month ? ` for ${escapeHtml(month)}` : ""}</span>${lock}</div>`;
    return;
  }

  const collapsed = isCollapsed();
  section.className = `mc-panel${needs > 0 ? " mc-needs" : ""}${collapsed ? " mc-collapsed" : ""}`;
  const countText = needs > 0
    ? `${needs} thing${needs === 1 ? "" : "s"} need${needs === 1 ? "s" : ""} you`
    : "Nothing needs you right now";

  const doneLine = done.length
    ? `<div class="mc-done-line">✓ All done: ${done
        .map((f) => `${escapeHtml(competitionShortLabel(f))} ${f.side === "home" ? "vs" : "@"} ${escapeHtml(f.opponent_short_name)}`)
        .join(" · ")}</div>`
    : "";

  section.innerHTML = `
    <div class="mc-head">
      <h2>Matchday checklist${month ? ` · ${escapeHtml(month)}` : ""}</h2>
      <span class="mc-count${needs > 0 ? " mc-count-todo" : ""}">${escapeHtml(countText)}</span>
      ${lock}
      <button type="button" class="mc-toggle" aria-expanded="${collapsed ? "false" : "true"}">${collapsed ? "Show" : "Hide"}</button>
    </div>
    <div class="mc-body">
      ${clubFlags.length ? `<div class="mc-flags mc-club-flags">${renderFlags(clubFlags)}</div>` : ""}
      ${open.length ? `<div class="mc-list">${open.map(renderFixture).join("")}</div>` : ""}
      ${doneLine}
      ${renderArrangeBlock(arrange)}
      <div class="mc-legend">✓ done · ● your move · ⏳ waiting on opponent · ○ later · ! overdue</div>
    </div>`;

  section.querySelector(".mc-toggle")?.addEventListener("click", () => {
    setCollapsed(!isCollapsed());
    render();
  });
  section.querySelectorAll("[data-mc-checkin]").forEach((btn) => {
    btn.addEventListener("click", () => onCheckIn(Number(btn.dataset.mcCheckin), btn));
  });
  section.querySelectorAll("[data-mc-copy]").forEach((btn) => {
    btn.addEventListener("click", () => onCopy(btn));
  });
  section.querySelectorAll("[data-mc-rec]").forEach((box) => {
    box.addEventListener("change", () => onRecTick(box));
  });
}

async function onCopy(btn) {
  const text = btn.dataset.mcCopy || "";
  try {
    await navigator.clipboard.writeText(text);
    btn.textContent = "Copied ✓";
  } catch {
    window.prompt("Copy this filename:", text);
  }
  setTimeout(() => {
    btn.textContent = "Copy video filename";
  }, 2000);
}

async function onCheckIn(fixtureId, btn) {
  if (!fixtureId) return;
  btn.disabled = true;
  btn.textContent = "Checking in…";
  const { error } = await supabase.rpc("fixture_check_in", { p_fixture_id: fixtureId });
  if (error) {
    const msg = String(error.message || "");
    if (/matchday squad|saved (starting|matchday) xi|injured or suspended/i.test(msg)) {
      window.location = `matchday.html?fixture=${fixtureId}&fix_checkin_squad=1`;
      return;
    }
    alert(msg || "Could not check in.");
    btn.disabled = false;
    btn.textContent = "Check in";
    return;
  }
  await refreshMatchdayChecklist();
}

export async function fetchMatchdayChecklist() {
  const { data, error } = await supabase.rpc("dashboard_matchday_checklist");
  if (error) {
    console.warn("dashboard_matchday_checklist:", error.message);
    return null;
  }
  return data;
}

export async function fetchUpcomingArrangements() {
  const { data, error } = await supabase.rpc("owner_upcoming_arrangements");
  if (error) {
    console.warn("owner_upcoming_arrangements:", error.message);
    return null;
  }
  return data;
}

export async function refreshMatchdayChecklist() {
  [, lastData, lastArrange] = await Promise.all([
    loadOwnerTimezone(),
    fetchMatchdayChecklist(),
    fetchUpcomingArrangements(),
  ]);
  try {
    const { data, error } = await supabase.rpc("my_club_strike_board");
    if (!error) strikeBoard = data;
  } catch (err) {
    console.warn("strike board:", err);
  }
  try {
    await enrichChecklistFixturesWithHomeWeather(lastData, lastArrange);
  } catch (err) {
    console.warn("checklist home/weather enrich:", err);
  }
  try {
    await enrichChecklistOwnerTags(lastData, lastArrange);
  } catch (err) {
    console.warn("checklist owner tags:", err);
  }
  await loadRecTicks(lastData?.fixtures);
  render();
}

export function startMatchdayChecklist(clubShortName) {
  ownerClubShort = String(clubShortName || "").trim();
  const section = document.getElementById("matchdayChecklist");
  if (!section || !clubShortName) {
    if (section) section.hidden = true;
    return;
  }
  bindHoverTips(section);
  refreshMatchdayChecklist().then(() => {
    if (window.location.hash === "#matchdayChecklist") {
      setCollapsed(false);
      render();
      section.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  });
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshMatchdayChecklist, REFRESH_MS);
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = setInterval(render, TICK_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refreshMatchdayChecklist();
  });
}
